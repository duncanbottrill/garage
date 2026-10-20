#if os(iOS)
import SnapshotTesting
import SwiftUI
import Testing
@testable import GarageKit

@MainActor @Suite struct OnboardingSnapshotTests {
    private func check(_ view: some View, fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column) {
        GarageKit.registerFonts()
        assertSnapshot(
            of: view.environment(\.colorScheme, .dark),
            as: .image(
                precision: SnapshotTolerance.precision,
                perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                layout: .device(config: .iPhone17ProDark)
            ),
            fileID: fileID, file: file, testName: testName, line: line, column: column
        )
    }

    @Test func signIn() {
        check(
            SignInStep(
                isWorking: false,
                errorMessage: nil,
                showsEmail: true,
                onAppleRequest: { _ in },
                onAppleCompletion: { _ in },
                onEmailSignIn: { _, _ in }
            )
        )
    }

    @Test func connectTesla() {
        check(ConnectTeslaStep(isWorking: false, errorMessage: nil, onConnect: {}))
    }

    @Test func chooseVehicle() {
        let ghost = Vehicle(
            id: UUID(uuidString: "7C1F0A0E-8A43-4D43-9A39-2F1B6F5D1E11")!,
            vin: "LRWYGCEK0PC123456",
            displayName: "Model Y"
        )
        check(
            VehicleStep(phase: .loaded(VehicleSync(vehicles: [ghost])), onContinue: { _ in }, onRetry: {})
        )
    }

    @Test func tailscale() {
        check(
            TailscaleStep(proxyState: .unreachable, isChecking: false, tailscaleInstalled: false, onOpenTailscale: {}, onCheckAgain: {})
        )
    }
}
#endif
