import GarageKit
import SwiftUI

@main
struct GarageApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GarageKit.registerFonts()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.flow.step != .done {
                    OnboardingView(model: model)
                } else {
                    RootView(model: model)
                }
            }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 600)
            #endif
            .task { await model.launch() }
            .onOpenURL { model.handle(url: $0) }
            .onChange(of: scenePhase) { _, phase in
                // Back in the foreground: re-check onboarding, which also starts the store when the
                // launch check ran offline. Skipped while the launch evaluation is still running.
                guard phase == .active, !model.flow.isEvaluating else { return }
                Task { await model.refresh() }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
