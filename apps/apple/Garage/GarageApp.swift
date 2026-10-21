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
                switch phase {
                case .background:
                    // Write the snapshot the store is holding back (Realtime rows are cached at most every 5 s).
                    model.didEnterBackground()
                case .inactive:
                    // Send the usage counts still waiting while a request can still go out (on macOS
                    // this is often the only phase change before a quit).
                    model.willResignActive()
                case .active:
                    // Back in the foreground: re-check onboarding, which also starts the store when the
                    // launch check ran offline. Skipped while the launch evaluation is still running.
                    guard !model.flow.isEvaluating else { return }
                    Task { await model.refresh() }
                default:
                    break
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
