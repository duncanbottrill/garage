import SwiftUI

/// Shows the onboarding step ``OnboardingFlow/step`` points at, wired to the ``AppModel``.
public struct OnboardingView: View {
    private let model: AppModel

    @State private var vehiclePhase: VehicleStep.Phase = .loading
    @State private var isChecking = false
    @State private var tailscaleInstalled = false
    @Environment(\.openURL) private var openURL

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let flow = model.flow
        Group {
            if !flow.hasEvaluated && flow.step == .signIn {
                ProgressView()
                    .tint(Tokens.Colors.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                step(flow)
            }
        }
        .background(Tokens.Colors.background.ignoresSafeArea())
        .animation(.snappy, value: flow.step)
    }

    @ViewBuilder
    private func step(_ flow: OnboardingFlow) -> some View {
        switch flow.step {
        case .signIn:
            SignInStep(
                isWorking: model.isWorking,
                errorMessage: flow.lastError,
                onAppleRequest: { model.prepareAppleRequest($0) },
                onAppleCompletion: { result in Task { await model.completeAppleSignIn(result) } },
                onEmailSignIn: { email, password in Task { await model.signIn(email: email, password: password) } }
            )
        case .connectTesla:
            ConnectTeslaStep(isWorking: model.isWorking, errorMessage: flow.lastError) {
                Task { await model.connectTesla() }
            }
        case .chooseVehicle:
            VehicleStep(
                phase: vehiclePhase,
                isWorking: model.isWorking,
                errorMessage: flow.lastError,
                onContinue: { vehicle in Task { await model.choose(vehicle) } },
                onRetry: { Task { await loadVehicles() } }
            )
            .task { await loadVehicles() }
        case .tailscale:
            TailscaleStep(
                proxyState: flow.proxyState,
                isChecking: isChecking,
                tailscaleInstalled: tailscaleInstalled,
                onOpenTailscale: { openURL(TailscaleLink.destination(installed: TailscaleLink.isInstalled())) },
                onCheckAgain: { Task { await checkAgain() } }
            )
            .onAppear { tailscaleInstalled = TailscaleLink.isInstalled() }
        case .done:
            Color.clear
        }
    }

    private func loadVehicles() async {
        vehiclePhase = .loading
        do {
            vehiclePhase = .loaded(try await model.loadVehicleChoices())
        } catch {
            vehiclePhase = .failed(OnboardingFlow.message(for: error))
        }
    }

    private func checkAgain() async {
        isChecking = true
        defer { isChecking = false }
        tailscaleInstalled = TailscaleLink.isInstalled()
        await model.refresh()
    }
}
