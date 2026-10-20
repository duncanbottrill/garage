#if os(iOS)
import SnapshotTesting
import SwiftUI
import Testing
@testable import GarageKit

/// The More screen on iPhone 17 Pro, dark: everything healthy, and the Tesla token rotation failing.
/// Rendered taller than the screen so every group is in the image.
@MainActor @Suite struct MoreSnapshotTests {
    /// 2026-10-20 14:30:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_506_600)

    /// iPhone 17 Pro's width, safe areas and traits, tall enough for the whole list.
    private static let tallPhone = ViewImageConfig(
        safeArea: ViewImageConfig.iPhone17ProDark.safeArea,
        size: CGSize(width: 402, height: 1480),
        traits: ViewImageConfig.iPhone17ProDark.traits
    )

    private func check(_ more: MoreModel, fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column) {
        GarageKit.registerFonts()
        assertSnapshot(
            of: MoreView(more: more).environment(\.colorScheme, .dark),
            as: .image(
                precision: SnapshotTolerance.precision,
                perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                layout: .device(config: Self.tallPhone)
            ),
            fileID: fileID, file: file, testName: testName, line: line, column: column
        )
    }

    @Test func more_healthy() async {
        let more = await Self.model(health: ConnectionHealth(connected: true, rotatedAt: Self.now.addingTimeInterval(-2 * 3600)))
        check(more)
    }

    /// The rotation failed (red, "Reconnect Tesla"); telemetry is two hours old so "Refresh now"
    /// shows, and the account has no Apple identity yet ("Link Apple ID").
    @Test func more_tokenFailed() async {
        let more = await Self.model(
            health: ConnectionHealth(
                connected: true,
                rotatedAt: Self.now.addingTimeInterval(-26 * 3600),
                lastError: "Tesla refused the refresh token (invalid_grant)",
                refreshFailures: 3
            ),
            telemetryAge: 2 * 3600,
            appleLinked: false
        )
        check(more)
    }

    /// A More model on fixed data, with the connection health already loaded.
    static func model(health: ConnectionHealth, telemetryAge: TimeInterval = 20, appleLinked: Bool = true) async -> MoreModel {
        let now = now
        let more = MoreModel(
            api: MoreModel.API(connection: { health }, refreshVehicleData: { _ in VehicleState() }),
            probe: { _ in .reachable },
            defaults: UserDefaults(suiteName: "MoreSnapshotTests-\(UUID().uuidString)")!,
            now: { now },
            appVersion: MoreModel.AppVersion(version: "0.1.0", build: "1")
        )
        more.vehicle = Vehicle(
            id: UUID(uuidString: "7C1F0A0E-8A43-4D43-9A39-2F1B6F5D1E11")!,
            vin: "LRWYGCEK0PC123456",
            displayName: "Model Y",
            proxyBaseURL: URL(string: "https://garage-bridge.tail068c8f.ts.net:4443")!
        )
        var state = VehicleState()
        state.sleepState = "online"
        let stamp = now.addingTimeInterval(-telemetryAge)
        state.chargeAt = stamp
        state.climateAt = stamp
        state.locationAt = stamp
        state.bodyAt = stamp
        state.bridgeSeenAt = now.addingTimeInterval(-10)
        state.bridgeHealth = BridgeHealth(dropped: 0, connectivity: "CONNECTED", patchFailures: 0)
        more.state = state
        more.reachability = .reachable
        more.accountEmail = "owner@example.com"
        more.hasAppleIdentity = appleLinked
        await more.loadConnection()
        return more
    }
}
#endif
