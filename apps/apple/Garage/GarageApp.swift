import GarageKit
import SwiftUI

@main
struct GarageApp: App {
    init() {
        GarageKit.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Tokens.Colors.background.ignoresSafeArea()
                Text("Garage")
                    .font(.custom(Tokens.Typography.numeralL.family, size: Tokens.Typography.numeralL.size))
                    .foregroundStyle(Tokens.Colors.ink)
            }
        }
    }
}
