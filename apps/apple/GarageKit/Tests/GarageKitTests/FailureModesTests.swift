import Foundation
import Supabase
import Synchronization
import Testing
@testable import GarageKit

/// Supabase session storage in memory, so the model never touches the keychain in tests.
private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}

/// The spec §10 failure modes, each as the screen shows it: bridge offline, Tailscale off, a
/// rejected command and a token failure.
@MainActor @Suite struct FailureModesTests {
    /// 2026-10-20 14:30:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_792_506_600)
    private static let utc = TimeZone(identifier: "UTC")!

    private func liveRow() throws -> VehicleState {
        var state = try Fixture.state("vehicle_state_live")
        let fresh = Self.now.addingTimeInterval(-20)
        state.chargeAt = fresh
        state.climateAt = fresh
        state.locationAt = fresh
        state.bodyAt = fresh
        state.bridgeSeenAt = Self.now.addingTimeInterval(-10)
        return state
    }

    /// The bridge last checked in 2 min ago (past the 90 s window): the paused banner with its time,
    /// and the car drawn as a solid dot without the live halo.
    @Test func bridgeOfflineShowsPausedBannerAndSolidDot() throws {
        var state = try liveRow()
        let seen = Self.now.addingTimeInterval(-120)
        state.bridgeSeenAt = seen

        let status = StatusModel(state: state, vehicle: nil, now: Self.now, reachability: .reachable, timeZone: Self.utc)

        #expect(status.banner == .telemetryPaused(since: seen))
        #expect(status.bannerMessage == "Telemetry paused since 14:28")
        #expect(!status.bridgeOnline)
        let dot = CarAnnotation(online: status.bridgeOnline, heading: status.heading, moving: status.isMoving)
        #expect(!dot.online, "solid dot, no breathing halo")

        // Inside the window the car is live again and the banner goes.
        state.bridgeSeenAt = Self.now.addingTimeInterval(-60)
        let live = StatusModel(state: state, vehicle: nil, now: Self.now, reachability: .reachable, timeZone: Self.utc)
        #expect(live.bridgeOnline)
        #expect(live.banner == nil)
    }

    /// The proxy cannot be reached: the Tailscale banner, and the quick actions are disabled.
    @Test func proxyUnreachableDisablesControls() throws {
        let state = try liveRow()

        let off = StatusModel(state: state, vehicle: nil, now: Self.now, reachability: .unreachable, timeZone: Self.utc)
        #expect(off.banner == .tailscaleOff)
        #expect(off.bannerMessage == "Connect Tailscale to control the car")
        #expect(off.quickActionsEnabled == false)
        let actions = QuickActions(lockState: off.lockState, pending: [], enabled: off.quickActionsEnabled, actions: .init())
        #expect(actions.enabled == false)

        // Reachable, or not probed yet: the controls work (a failed send says why).
        #expect(StatusModel(state: state, vehicle: nil, now: Self.now, reachability: .reachable).quickActionsEnabled)
        #expect(StatusModel(state: state, vehicle: nil, now: Self.now, reachability: .unknown).quickActionsEnabled)
    }

    /// Lock flips the icon at once; the car rejects it, so the icon goes back to unlocked and the
    /// toast gives the reason.
    @Test func rejectedCommandRevertsOptimisticState() async throws {
        var state = try liveRow()
        state.locked = false
        let car = FakeCar()
        car.holding = true
        car.failure = .rejected(reason: "door is open")
        let runner = CommandRunner(send: car.send, wake: car.wake)
        let lock = OptimisticLock()
        func status() -> StatusModel {
            StatusModel(state: state, vehicle: nil, now: Self.now, reachability: .reachable, optimisticLocked: lock.target)
        }
        #expect(status().lockState == .unlocked)

        let tap = Task { await lock.toggle(to: true, with: runner) { state.locked } }
        #expect(await eventually { car.heldCount == 1 })
        #expect(status().lockState == .locked, "optimistic: flipped before the car answers")
        #expect(car.sent == [.doorLock])

        car.release()
        #expect(await tap.value == .failed)
        #expect(lock.target == nil)
        #expect(status().lockState == .unlocked, "reverted to the row")
        #expect(runner.toast?.message == CommandError.rejected(reason: "door is open").errorDescription)
        #expect(runner.toast?.message.contains("door is open") == true)
    }

    /// `/api/token` refusing the session (401) or renewing (503) is a red Connection row in More and
    /// a toast, never a sign-out: the session, the car, the cache and onboarding all stay.
    @Test func tokenFailureNeverSignsOut() async throws {
        let backend = URLStub()
        let proxy = URLStub()
        let userID = UUID()
        let vehicleID = UUID()
        let defaults = UserDefaults(suiteName: "FailureModesTests-\(UUID().uuidString)")!
        let cache = FileSnapshotCache(url: try Fixture.temporaryDirectory().appendingPathComponent("vehicle_state.json"))
        cache.save(try liveRow())
        VehicleSelection.set(vehicleID, in: defaults)
        OnboardingFlow.markCompleted(by: userID, in: defaults)
        ProxyOverride.set(proxy.baseURL(port: 4443), in: defaults)

        let config = SupabaseEnvironment.Config(
            supabaseURL: URL(string: "https://stub-\(UUID().uuidString).test")!,
            publishableKey: "sb_publishable_test",
            apiBaseURL: backend.baseURL()
        )
        let vehicle = Vehicle(id: vehicleID, vin: "VIN", displayName: "Model Y")
        var ended = 0
        let model = AppModel(
            environment: SupabaseEnvironment(config: config, authStorage: MemoryAuthStorage()),
            defaults: defaults,
            cache: cache,
            checks: OnboardingFlow.Checks(
                sessionUserID: { userID },
                isTeslaConnected: { true },
                vehicle: { vehicle },
                proxyReachability: { .reachable }
            ),
            endSession: { ended += 1 },
            api: GarageAPI(baseURL: backend.baseURL(), session: backend.session, supabaseToken: { "sb-jwt" }),
            makeStore: { VehicleStore(feed: IdleFeed(), fetcher: NoRows(), cache: cache) },
            proxySession: proxy.session
        )
        await model.refresh()
        #expect(model.flow.step == .done)

        // The backend refuses the Supabase session for the token.
        backend.on("GET", "/api/token") { _ in .json(401, #"{"error":"unauthorized"}"#) }
        await #expect(throws: CommandError.sessionExpired) { try await model.commandClient.send(.doorLock, vin: "VIN") }
        #expect(model.commandClient.tokenFailure == .sessionExpired)
        let refused = try #require(model.moreModel.row(.connection))
        #expect(refused.tone == .failed)
        #expect(refused.detail == MoreModel.tokenFailureDetail(.sessionExpired))
        #expect(proxy.requests.isEmpty, "nothing reaches the proxy without a token")

        // Renewing: also red, with its own copy.
        backend.on("GET", "/api/token") { _ in .json(503, #"{"error":"token_unavailable","retry_at":"2026-10-20T08:15:00Z"}"#) }
        await #expect(throws: CommandError.tokenUnavailable(retryAt: Date(timeIntervalSince1970: 1_792_484_100))) {
            try await model.commandClient.send(.doorLock, vin: "VIN")
        }
        #expect(model.moreModel.row(.connection)?.tone == .failed)

        // Still signed in, on Status, with the car, its cache and the completion record.
        await model.refresh()
        #expect(ended == 0)
        #expect(model.flow.step == .done)
        #expect(VehicleSelection.current(in: defaults) == vehicleID)
        #expect(OnboardingFlow.hasCompleted(by: userID, in: defaults))
        #expect(cache.load() != nil)

        // A token again: the command goes through and the row is no longer red.
        backend.on("GET", "/api/token") { _ in .json(200, #"{"access_token":"tesla-1","expires_at":"2099-01-01T00:00:00Z"}"#) }
        backend.on("POST", "/api/usage") { _ in .json(200, #"{"ok":true}"#) }
        proxy.on("POST", "/api/1/vehicles/VIN/command/door_lock") { _ in .json(200, #"{"response":{"result":true,"reason":""}}"#) }
        #expect(try await model.commandClient.send(.doorLock, vin: "VIN"))
        #expect(model.commandClient.tokenFailure == nil)
        #expect(model.moreModel.row(.connection)?.tone != .failed)
    }
}

/// A feed that never reports anything.
struct IdleFeed: RealtimeFeed {
    func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        AsyncStream { _ in }
    }
}

/// A fetcher with no rows at all.
struct NoRows: VehicleRowFetcher {
    func fetchVehicle() async throws -> Vehicle? { nil }
    func fetchState(vehicleID: UUID) async throws -> VehicleState? { nil }
}
