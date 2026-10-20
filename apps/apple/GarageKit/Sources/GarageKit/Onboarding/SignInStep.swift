import AuthenticationServices
import SwiftUI

/// Step 1: Sign in with Apple, or email and password behind "Use email" (the owner's bootstrap account).
public struct SignInStep: View {
    private let isWorking: Bool
    private let errorMessage: String?
    private let onAppleRequest: (ASAuthorizationAppleIDRequest) -> Void
    private let onAppleCompletion: (Result<ASAuthorization, any Error>) -> Void
    private let onEmailSignIn: (_ email: String, _ password: String) -> Void

    @State private var showsEmail: Bool
    @State private var email = ""
    @State private var password = ""

    /// - Parameters:
    ///   - isWorking: A sign-in is in progress (the buttons are disabled).
    ///   - errorMessage: The last failure's copy, shown under the buttons.
    ///   - showsEmail: Whether the email fields start expanded.
    ///   - onAppleRequest: Prepares the Apple request (``AppModel/prepareAppleRequest(_:)``).
    ///   - onAppleCompletion: Finishes the Apple sign-in (``AppModel/completeAppleSignIn(_:)``).
    ///   - onEmailSignIn: Signs in with email and password.
    public init(
        isWorking: Bool,
        errorMessage: String?,
        showsEmail: Bool = false,
        onAppleRequest: @escaping (ASAuthorizationAppleIDRequest) -> Void,
        onAppleCompletion: @escaping (Result<ASAuthorization, any Error>) -> Void,
        onEmailSignIn: @escaping (_ email: String, _ password: String) -> Void
    ) {
        self.isWorking = isWorking
        self.errorMessage = errorMessage
        self.onAppleRequest = onAppleRequest
        self.onAppleCompletion = onAppleCompletion
        self.onEmailSignIn = onEmailSignIn
        _showsEmail = State(initialValue: showsEmail)
    }

    public var body: some View {
        OnboardingStepLayout(
            step: .signIn,
            title: "Sign in to Garage",
            message: "Your Garage account holds the car's data. Sign in with Apple, or use email.",
            errorMessage: errorMessage
        ) {
            VStack(spacing: Tokens.Space.l) {
                SignInWithAppleButton(.signIn, onRequest: onAppleRequest, onCompletion: onAppleCompletion)
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.pill, style: .continuous))
                    .overlay {
                        // A black button on the near-black background needs an edge to read as a button.
                        RoundedRectangle(cornerRadius: Tokens.Radius.pill, style: .continuous)
                            // Centred on the edge, so it also covers the native button's frame edge,
                            // which `clipShape` does not clip.
                            .stroke(Color.white.opacity(Tokens.Opacity.controlEdge), lineWidth: 1)
                    }
                    .disabled(isWorking)

                emailDisclosure
            }
        }
    }

    private var emailDisclosure: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Button {
                withAnimation(.snappy) { showsEmail.toggle() }
            } label: {
                HStack(spacing: Tokens.Space.xs) {
                    Text("Use email")
                        .garage(.body)
                    Icon(.chevronRight, size: 14)
                        .rotationEffect(.degrees(showsEmail ? 90 : 0))
                }
                .foregroundStyle(Tokens.Colors.muted)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsEmail ? "Expanded" : "Collapsed")

            if showsEmail {
                VStack(spacing: Tokens.Space.m) {
                    OnboardingField(placeholder: "Email", text: $email, kind: .email)
                    OnboardingField(placeholder: "Password", text: $password, kind: .password)
                    Button("Sign in") { onEmailSignIn(email, password) }
                        .onboarding(.secondary, isWorking: isWorking)
                        .disabled(email.isEmpty || password.isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A text field on a glass control, for the email sign-in.
struct OnboardingField: View {
    enum Kind { case email, password }

    let placeholder: String
    @Binding var text: String
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .email:
                TextField(placeholder, text: $text)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                #endif
            case .password:
                SecureField(placeholder, text: $text)
                    .textContentType(.password)
            }
        }
        .textFieldStyle(.plain)
        .font(TypeScale.body.font)
        .foregroundStyle(Tokens.Colors.ink)
        .padding(.horizontal, Tokens.Space.l)
        .frame(minHeight: 48)
        .glassSurface(radius: Tokens.Radius.control)
    }
}
