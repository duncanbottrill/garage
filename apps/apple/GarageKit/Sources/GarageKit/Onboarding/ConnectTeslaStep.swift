import SwiftUI

/// Step 2: connect the Tesla account. The button opens the Tesla sign-in in a browser sheet, which
/// returns to the app on `garage://connected`.
public struct ConnectTeslaStep: View {
    private let isWorking: Bool
    private let errorMessage: String?
    private let onConnect: () -> Void
    private let onNotNow: (() -> Void)?

    /// - Parameters:
    ///   - isWorking: The Tesla sign-in is open or being started.
    ///   - errorMessage: The last failure's copy.
    ///   - onNotNow: When set (a reconnect from More), a "Not now" button that goes back to the app.
    ///   - onConnect: Starts the Tesla sign-in (``AppModel/connectTesla()``).
    public init(isWorking: Bool, errorMessage: String?, onNotNow: (() -> Void)? = nil, onConnect: @escaping () -> Void) {
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.onNotNow = onNotNow
        self.onConnect = onConnect
    }

    public var body: some View {
        OnboardingStepLayout(
            step: .connectTesla,
            title: "Connect Tesla",
            message: "Sign in to your Tesla account so Mews can read the car and send it commands. You'll come straight back here.",
            errorMessage: errorMessage
        ) {
            VStack(spacing: Tokens.Space.l) {
                Button("Connect Tesla", action: onConnect)
                    .onboarding(.primary, isWorking: isWorking)
                if let onNotNow {
                    Button("Not now", action: onNotNow)
                        .onboarding(.secondary)
                        .disabled(isWorking)
                }
                OnboardingNotice(
                    icon: .lock,
                    text: "Mews never sees your Tesla password. Tesla asks which permissions to grant.",
                    tint: Tokens.Colors.muted
                )
            }
        }
    }
}
