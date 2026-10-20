import Foundation
import Testing
@testable import GarageKit

@Suite struct StatusModelTests {
    /// 2026-10-20 14:30:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_506_600)
    private let utc = TimeZone(identifier: "UTC")!
    private let uk = Locale(identifier: "en_GB")

    private func model(
        _ state: VehicleState?,
        vehicle: Vehicle? = nil,
        reachability: ProxyReachability.State = .reachable
    ) -> StatusModel {
        StatusModel(state: state, vehicle: vehicle, now: now, reachability: reachability, locale: uk, timeZone: utc)
    }

    private func vehicle(budget: BudgetMode) -> Vehicle {
        Vehicle(id: UUID(), vin: "LRWYGCEK0PC123456", displayName: "Model Y", budgetMode: budget)
    }

    /// Charging shows the charger power and the limit; a schedule in the future shows its local time.
    @Test func chargeLineWhileCharging() {
        var state = VehicleState()
        state.chargeState = "Charging"
        state.chargerPowerKw = 7.2
        state.chargeLimitSoc = 90
        #expect(model(state).chargeLine == "Charging 7.2 kW · 90 % limit")

        state.chargeState = "Disconnected"
        #expect(model(state).chargeLine == "Not charging")
    }

    @Test func chargeLineScheduled() {
        var state = VehicleState()
        state.chargeState = "Stopped"
        state.scheduledChargeAt = now.addingTimeInterval(9 * 3600) // 23:30 UTC
        #expect(model(state).chargeLine == "Scheduled 23:30")

        // A schedule already in the past is not shown.
        state.scheduledChargeAt = now.addingTimeInterval(-60)
        #expect(model(state).chargeLine == "Not charging")
    }

    /// One banner at a time: telemetry paused wins over budget, which wins over Tailscale.
    @Test func bannerPriorityTelemetryBeforeBudget() {
        var state = VehicleState()
        state.bridgeSeenAt = now.addingTimeInterval(-28 * 60) // 14:02
        let reduced = vehicle(budget: .reduced)

        let paused = model(state, vehicle: reduced, reachability: .unreachable)
        #expect(paused.bridgeOnline == false)
        #expect(paused.banner == .telemetryPaused(since: state.bridgeSeenAt))
        #expect(paused.bannerMessage == "Telemetry paused since 14:02")

        state.bridgeSeenAt = now.addingTimeInterval(-10)
        let budget = model(state, vehicle: reduced, reachability: .unreachable)
        #expect(budget.bridgeOnline == true)
        #expect(budget.banner == .budget(.reduced))
        #expect(budget.bannerMessage == "Reduced update rate to stay in budget")
        #expect(model(state, vehicle: vehicle(budget: .minimal)).bannerMessage == "Minimal updates: budget nearly used")

        let tailscale = model(state, vehicle: vehicle(budget: .normal), reachability: .unreachable)
        #expect(tailscale.banner == .tailscaleOff)
        #expect(tailscale.bannerMessage == "Connect Tailscale to control the car")

        #expect(model(state, vehicle: vehicle(budget: .normal)).banner == nil)
    }

    /// Refresh now is offered only when the newest telemetry is older than 10 min and the car is not asleep.
    @Test func refreshNowRulesRequireAwakeAndOldTelemetry() {
        var state = VehicleState()
        state.sleepState = "online"
        state.climateAt = now.addingTimeInterval(-20 * 60)
        state.bodyAt = now.addingTimeInterval(-15 * 60)
        #expect(model(state).showsRefreshNow == true)

        state.sleepState = "asleep"
        #expect(model(state).showsRefreshNow == false)

        state.sleepState = "online"
        state.chargeAt = now.addingTimeInterval(-2 * 60)
        #expect(model(state).showsRefreshNow == false)

        #expect(model(nil).showsRefreshNow == false)
    }

    /// A young row with nothing in it renders placeholders, never zeros.
    @Test func sparseStateShowsPlaceholders() {
        var state = VehicleState()
        state.vehicleId = UUID()
        let sparse = model(state)
        #expect(sparse.socText == "—")
        #expect(sparse.rangeText == "—")
        #expect(sparse.insideText == "—")
        #expect(sparse.outsideText == "—")
        #expect(sparse.chargeLine == "—")
        #expect(sparse.chargePortText == "—")
        #expect(sparse.freshnessCaption(.climate) == "—")
        #expect(model(nil).socText == "—")

        state.soc = 34.4
        state.rangeKm = 160.9344
        state.insideC = 21.4
        let filled = model(state)
        #expect(filled.socText == "34")
        #expect(filled.rangeText == "100")
        #expect(filled.rangeUnit == "mi")
        #expect(filled.insideText == "21 °C")
    }

    /// No lock reading is "unknown", not "unlocked"; the optimistic overlay wins while a command is pending.
    @Test func lockLabelUnknownWhenNil() {
        var state = VehicleState()
        #expect(model(state).lockState == .unknown)
        #expect(model(state).lockLabel == "—")

        state.locked = true
        #expect(model(state).lockState == .locked)
        #expect(model(state).lockLabel == "Locked")

        state.locked = false
        #expect(model(state).lockLabel == "Unlocked")
        let optimistic = StatusModel(state: state, vehicle: nil, now: now, reachability: .reachable, optimisticLocked: true, locale: uk, timeZone: utc)
        #expect(optimistic.lockState == .locked)
    }

    /// Captions: "now", minutes ago, "Stale · HH:mm", or a dash.
    @Test func freshnessCaptions() {
        var state = VehicleState()
        state.climateAt = now.addingTimeInterval(-30)
        state.bodyAt = now.addingTimeInterval(-2 * 60 - 10)
        state.chargeAt = now.addingTimeInterval(-28 * 60)
        let captions = model(state)
        #expect(captions.freshnessCaption(.climate) == "now")
        #expect(captions.freshnessCaption(.body) == "2 min ago")
        #expect(captions.freshnessCaption(.charge) == "Stale · 14:02")
        #expect(captions.freshnessCaption(.location) == "—")
        #expect(captions.fieldFreshness(.climate) == .live)
    }
}

@Suite struct TrailLoaderTests {
    private let now = Date(timeIntervalSince1970: 1_792_506_600)

    private struct FakeFetcher: TrailFetching {
        let points: [TrailPoint]
        let recorded: Recorder

        func locations(vehicleID: UUID, since: Date) async throws -> [TrailPoint] {
            await recorded.record(vehicleID: vehicleID, since: since)
            return points
        }
    }

    private actor Recorder {
        var calls: [(UUID, Date)] = []
        func record(vehicleID: UUID, since: Date) { calls.append((vehicleID, since)) }
    }

    /// `signals` rows carry the coordinate in `value_json`.
    @Test func signalRowsDecode() throws {
        let json = Data("""
        [{"value_json":{"latitude":51.5,"longitude":-0.12},"recorded_at":"2026-10-20T14:10:00+00:00"},
         {"value_json":{"latitude":51.6,"longitude":-0.13},"recorded_at":"2026-10-20 14:20:00+00"}]
        """.utf8)
        let points = try SupabaseTrailFetcher.decode(json)
        #expect(points.count == 2)
        #expect(points[0].latitude == 51.5)
        #expect(points[1].longitude == -0.13)
        #expect(points[1].recordedAt == Date(timeIntervalSince1970: 1_792_506_000))
    }

    /// The loader asks for the last 30 min and keeps only points inside the window, oldest first.
    @MainActor @Test func loaderQueriesWindowAndPrunes() async {
        let id = UUID()
        let recorder = Recorder()
        let points = [
            TrailPoint(latitude: 51.4, longitude: -0.1, recordedAt: now.addingTimeInterval(-40 * 60)),
            TrailPoint(latitude: 51.5, longitude: -0.1, recordedAt: now.addingTimeInterval(-10 * 60)),
        ]
        let loader = TrailLoader(fetcher: FakeFetcher(points: points, recorded: recorder))
        await loader.load(vehicleID: id, now: now)
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == id)
        #expect(calls.first?.1 == now.addingTimeInterval(-30 * 60))
        #expect(loader.points.map(\.latitude) == [51.5])

        loader.append(TrailPoint(latitude: 51.6, longitude: -0.1, recordedAt: now), now: now)
        #expect(loader.points.map(\.latitude) == [51.5, 51.6])
    }
}
