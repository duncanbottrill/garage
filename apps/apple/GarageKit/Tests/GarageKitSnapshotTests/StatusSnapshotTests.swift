#if os(iOS)
import SnapshotTesting
import SwiftUI
import Testing
@testable import GarageKit

/// The Status screen in its five states, on iPhone 17 Pro and in a 1280 × 800 Mac window, both dark.
/// The map is the flat ground (`mapEnabled: false`) so nothing depends on MapKit tiles.
@MainActor @Suite struct StatusSnapshotTests {
    /// 2026-10-20 14:30:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_792_506_600)

    private enum Screen {
        case iPhone, iPhoneAX1, mac
    }

    private func check(_ view: StatusView, on screen: Screen, fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column) {
        GarageKit.registerFonts()
        let themed = view.environment(\.colorScheme, .dark)
        switch screen {
        case .iPhone:
            assertSnapshot(
                of: themed,
                as: .image(
                    precision: SnapshotTolerance.precision,
                    perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                    layout: .device(config: .iPhone17ProDark)
                ),
                fileID: fileID, file: file, testName: testName, line: line, column: column
            )
        case .iPhoneAX1:
            assertSnapshot(
                of: themed.environment(\.dynamicTypeSize, .accessibility1),
                as: .image(
                    precision: SnapshotTolerance.precision,
                    perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                    layout: .device(config: .iPhone17ProDarkAX1)
                ),
                fileID: fileID, file: file, testName: testName, line: line, column: column
            )
        case .mac:
            assertSnapshot(
                of: themed,
                as: .image(
                    precision: SnapshotTolerance.precision,
                    perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                    layout: .fixed(width: 1280, height: 800),
                    traits: .mac1280Dark
                ),
                fileID: fileID, file: file, testName: testName, line: line, column: column
            )
        }
    }

    // MARK: States

    private enum Fixture {
        case live, stale, offline, pending, sparse
    }

    private func status(_ fixture: Fixture, stop: SheetStop = .full) -> StatusView {
        let now = Self.now
        let vehicle = Vehicle(
            id: UUID(uuidString: "7C1F0A0E-8A43-4D43-9A39-2F1B6F5D1E11")!,
            vin: "LRWYGCEK0PC123456",
            displayName: "Model Y",
            budgetMode: fixture == .stale ? .reduced : .normal
        )
        var state = VehicleState()
        state.vehicleId = vehicle.id
        state.soc = 68
        state.rangeKm = 380
        state.chargeState = "Charging"
        state.chargerPowerKw = 7.2
        state.chargeLimitSoc = 90
        state.chargePortOpen = true
        state.insideC = 19.6
        state.outsideC = 11.2
        state.locked = true
        state.lat = 51.5014
        state.lng = -0.1419
        state.heading = 0
        state.speedKph = 0
        state.sleepState = "online"
        state.bridgeSeenAt = now.addingTimeInterval(-10)
        let fresh = now.addingTimeInterval(-20)
        state.chargeAt = fresh
        state.climateAt = fresh
        state.bodyAt = fresh
        state.locationAt = fresh

        var reachability = ProxyReachability.State.reachable
        var optimisticLocked: Bool?
        var pending: Set<String> = []

        switch fixture {
        case .live:
            break
        case .stale:
            // Asleep for two hours with the bridge still checking in; the backend is saving budget.
            let old = now.addingTimeInterval(-2 * 3600)
            state.soc = 54
            state.rangeKm = 301
            state.chargeState = "Disconnected"
            state.chargePortOpen = false
            state.scheduledChargeAt = now.addingTimeInterval(9 * 3600)
            state.sleepState = "asleep"
            state.chargeAt = old
            state.climateAt = old
            state.bodyAt = old
            state.locationAt = old
        case .offline:
            // The bridge last checked in at 14:02; Tailscale is off too, but telemetry wins the banner.
            let lastSeen = now.addingTimeInterval(-28 * 60)
            state.bridgeSeenAt = lastSeen
            state.chargeState = "Disconnected"
            state.chargePortOpen = false
            state.locked = false
            state.chargeAt = lastSeen
            state.climateAt = lastSeen
            state.bodyAt = lastSeen
            state.locationAt = lastSeen
            reachability = .unreachable
        case .pending:
            // Driving, unlocked, with a lock command in flight: the lock flips at once.
            state.locked = false
            state.speedKph = 42
            state.heading = 120
            state.chargeState = "Disconnected"
            state.chargePortOpen = false
            optimisticLocked = true
            pending = [Command.doorLock.name]
        case .sparse:
            // A young row: keys and a bridge check-in, nothing else. Tailscale is off.
            state = VehicleState()
            state.vehicleId = vehicle.id
            state.bridgeSeenAt = now.addingTimeInterval(-5)
            reachability = .unreachable
        }

        let model = StatusModel(
            state: state,
            vehicle: vehicle,
            now: now,
            reachability: reachability,
            optimisticLocked: optimisticLocked,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        return StatusView(status: model, pending: pending, mapEnabled: false, sheetStop: stop)
    }

    // MARK: iPhone

    @Test func status_live_iphone() { check(status(.live), on: .iPhone) }
    @Test func status_stale_iphone() { check(status(.stale), on: .iPhone) }
    @Test func status_offline_iphone() { check(status(.offline), on: .iPhone) }
    @Test func status_pending_iphone() { check(status(.pending), on: .iPhone) }
    @Test func status_sparse_iphone() { check(status(.sparse), on: .iPhone) }
    /// The compact stop: numeral, charge line and quick actions, no tiles, more map.
    @Test func status_live_iphone_compact() { check(status(.live, stop: .compact), on: .iPhone) }
    /// The first accessibility text size: tiles stack their captions, pills drop to the icon above
    /// or alone, and the sheet scrolls if it outgrows the screen.
    @Test func status_live_iphone_ax() { check(status(.live), on: .iPhoneAX1) }

    // MARK: Mac

    @Test func status_live_mac() { check(status(.live), on: .mac) }
    @Test func status_stale_mac() { check(status(.stale), on: .mac) }
    @Test func status_offline_mac() { check(status(.offline), on: .mac) }
    @Test func status_pending_mac() { check(status(.pending), on: .mac) }
    @Test func status_sparse_mac() { check(status(.sparse), on: .mac) }
}
#endif
