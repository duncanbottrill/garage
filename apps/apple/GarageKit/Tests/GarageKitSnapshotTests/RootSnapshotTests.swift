#if os(iOS)
import SnapshotTesting
import SwiftUI
import Testing
@testable import GarageKit

/// The app's navigation, dark, on the Status destination with the flat map: the iPhone tab bar,
/// and the Mac split view (sidebar + Status) rendered at 1280 × 800 with the iPad-trait stand-in.
@MainActor @Suite struct RootSnapshotTests {
    private func root(layout: RootView.Layout) async -> some View {
        let now = MoreSnapshotTests.now
        let vehicle = Vehicle(
            id: UUID(uuidString: "7C1F0A0E-8A43-4D43-9A39-2F1B6F5D1E11")!,
            vin: "LRWYGCEK0PC123456",
            displayName: "Model Y"
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
        let status = StatusModel(
            state: state,
            vehicle: vehicle,
            now: now,
            reachability: .reachable,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        let more = await MoreSnapshotTests.model(health: ConnectionHealth(connected: true, rotatedAt: now.addingTimeInterval(-2 * 3600)))
        return RootView(status: status, more: more, selection: .status, layout: layout)
            .environment(\.colorScheme, .dark)
            .environment(\.statusMotion, false)
    }

    @Test func root_iphone() async {
        GarageKit.registerFonts()
        let view = await root(layout: .tabs)
        assertSnapshot(
            of: view,
            as: .image(
                precision: SnapshotTolerance.precision,
                perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                layout: .device(config: .iPhone17ProDark)
            )
        )
    }

    @Test func root_mac() async {
        GarageKit.registerFonts()
        let view = await root(layout: .sidebar)
        assertSnapshot(
            of: view,
            as: .image(
                precision: SnapshotTolerance.precision,
                perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                layout: .fixed(width: 1280, height: 800),
                traits: .mac1280Dark
            )
        )
    }
}
#endif
