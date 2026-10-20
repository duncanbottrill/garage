import SwiftUI

/// The frame every onboarding step shares: "Step n of 4", the step numeral, a title, a short message,
/// the step's content, and an error line when the last action failed.
struct OnboardingStepLayout<Content: View>: View {
    let step: OnboardingFlow.Step
    let title: String
    let message: String
    let errorMessage: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                if let number = step.number {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                        Text(String(format: "%02d", number))
                            .garage(.numeralL)
                            .foregroundStyle(Tokens.Colors.accent)
                        SmallCapsLabel("Step \(number) of 4")
                    }
                }
                Text(title)
                    .garage(.title)
                    .foregroundStyle(Tokens.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .garage(.body)
                    .foregroundStyle(Tokens.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            if let errorMessage {
                OnboardingNotice(icon: .circleAlert, text: errorMessage, tint: Tokens.Colors.danger)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Tokens.Colors.background.ignoresSafeArea())
    }
}

/// A one-line status or error with an icon, on a glass tile.
struct OnboardingNotice: View {
    let icon: Icon.Name
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            Icon(icon, size: 16)
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .garage(.caption)
                .foregroundStyle(Tokens.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.m)
        .glassSurface(radius: Tokens.Radius.control)
    }
}

/// Onboarding buttons: `primary` is the accent pill, `secondary` the glass pill.
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    let kind: Kind
    var isWorking = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.pill, style: .continuous)
        ZStack {
            configuration.label
                .font(TypeScale.title.font)
                .opacity(isWorking ? 0 : 1)
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(kind == .primary ? Tokens.Colors.background : Tokens.Colors.ink)
            }
        }
        .foregroundStyle(kind == .primary ? Tokens.Colors.background : Tokens.Colors.ink)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background {
            switch kind {
            case .primary: shape.fill(Tokens.Colors.accent)
            case .secondary: Color.clear.glassSurface(radius: Tokens.Radius.pill)
            }
        }
        .contentShape(shape)
        .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension Button {
    /// Styles this button as an onboarding pill.
    func onboarding(_ kind: OnboardingButtonStyle.Kind, isWorking: Bool = false) -> some View {
        buttonStyle(OnboardingButtonStyle(kind: kind, isWorking: isWorking))
            .disabled(isWorking)
    }
}
