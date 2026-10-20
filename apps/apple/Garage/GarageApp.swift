import GarageKit
import SwiftUI

@main
struct GarageApp: App {
    @State private var model: AppModel

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
                    // Task 9 replaces this with RootView (tabs on iPhone, split view on Mac).
                    ZStack {
                        Tokens.Colors.background.ignoresSafeArea()
                        Text("Garage")
                            .garage(.numeralL)
                            .foregroundStyle(Tokens.Colors.ink)
                    }
                }
            }
            .task { await model.launch() }
            .onOpenURL { model.handle(url: $0) }
        }
    }
}
