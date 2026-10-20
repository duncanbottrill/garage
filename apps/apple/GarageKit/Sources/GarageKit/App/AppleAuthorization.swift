import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A one-time nonce for Sign in with Apple. Apple gets the SHA-256 of it (``hashed``) in the request
/// and puts that in the ID token; Supabase gets the ``raw`` value and checks the two match, so a stolen
/// ID token cannot be replayed.
public struct AppleNonce: Sendable, Equatable {
    /// The value sent to Supabase with the ID token.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    /// Lower-case hex SHA-256 of ``raw``, for `ASAuthorizationAppleIDRequest.nonce`.
    public var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh nonce of `length` characters from the system's secure random generator.
    public static func random(length: Int = 32) -> AppleNonce {
        // 64 URL-safe characters (no "W"), so a byte modulo the count is unbiased.
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        assert(charset.count == 64)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return AppleNonce(raw: String(bytes.map { charset[Int($0) % charset.count] }))
    }
}

/// Why Sign in with Apple produced no usable credential.
public enum AppleSignInError: Error, Sendable, Equatable, LocalizedError {
    /// The authorization was not an Apple ID credential, or it carried no ID token.
    case missingIdentityToken
    /// Sign in with Apple was started without a nonce (the request was not prepared by Garage).
    case missingNonce

    public var errorDescription: String? {
        switch self {
        case .missingIdentityToken: "Apple didn't return a sign-in token. Try again."
        case .missingNonce: "Sign in with Apple didn't start properly. Try again."
        }
    }
}

enum AppleCredential {
    /// The ID token (a JWT) from a completed Sign in with Apple authorization.
    static func idToken(from authorization: ASAuthorization) throws -> String {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8)
        else { throw AppleSignInError.missingIdentityToken }
        return token
    }

    /// Whether `error` is the user closing the Apple sheet, which is not worth an error message.
    static func isCancellation(_ error: any Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    /// Prepares an Apple ID request: email scope and the hashed nonce.
    static func prepare(_ request: ASAuthorizationAppleIDRequest, nonce: AppleNonce) {
        request.requestedScopes = [.email]
        request.nonce = nonce.hashed
    }
}

/// The window one authentication sheet attaches to, captured when that call starts.
///
/// Each call gets its own provider, so a later call can neither swap the window an earlier sheet asks
/// for nor clear it from under it. Both sessions hold their provider weakly: the caller keeps it alive.
@MainActor
final class PresentationAnchorProvider: NSObject, ASAuthorizationControllerPresentationContextProviding, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// Runs Sign in with Apple without a button (for "Link Apple ID") and returns the ID token.
@MainActor
final class AppleAuthorizer: NSObject, ASAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<ASAuthorization, any Error>?
    private var controller: ASAuthorizationController?
    /// The current request's anchor; kept because the controller holds it weakly.
    private var provider: PresentationAnchorProvider?

    /// Shows the Apple sheet and waits for the user. Throws `ASAuthorizationError` (`.canceled` when
    /// dismissed, or when a newer call replaces this one), or
    /// `ASWebAuthenticationSessionError(.presentationContextInvalid)` with no window to show it on.
    func idToken(nonce: AppleNonce) async throws -> String {
        let provider = PresentationAnchorProvider(anchor: try PresentationAnchor.current())
        let request = ASAuthorizationAppleIDProvider().createRequest()
        AppleCredential.prepare(request, nonce: nonce)
        let authorization = try await withCheckedThrowingContinuation { continuation in
            self.continuation?.resume(throwing: ASAuthorizationError(.canceled))
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = provider
            self.controller = controller
            self.provider = provider
            controller.performRequests()
        }
        return try AppleCredential.idToken(from: authorization)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        finish(controller, .success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        finish(controller, .failure(error))
    }

    /// Settles the call `source` belongs to. A superseded request (its continuation was already
    /// cancelled) leaves the newer one alone.
    private func finish(_ source: ASAuthorizationController, _ result: Result<ASAuthorization, any Error>) {
        guard source === controller else { return }
        controller = nil
        provider = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

/// Opens a URL in `ASWebAuthenticationSession` (the Tesla sign-in) and returns the callback URL.
@MainActor
final class WebAuthenticator: NSObject {
    private var session: ASWebAuthenticationSession?
    /// Identifies ``session``, so a finished older session's clean-up cannot clear a newer one.
    private var sessionID: UUID?

    /// Shows `url` in the system browser sheet, sharing Safari's cookies (`prefersEphemeralWebBrowserSession`
    /// is false, so a saved Tesla login is reused), and returns when it redirects to `callbackURLScheme`.
    /// Throws `ASWebAuthenticationSessionError` (`.canceledLogin` when the user closes the sheet,
    /// `.presentationContextInvalid` when there is no window to show it on).
    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        session?.cancel()
        let provider = PresentationAnchorProvider(anchor: try PresentationAnchor.current())
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { [weak self] callback, error in
                // The session holds its provider weakly; this closure keeps it until the sheet is done.
                withExtendedLifetime(provider) {}
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.session = nil
                    self.sessionID = nil
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = provider
            self.session = session
            sessionID = id
            if !session.start() {
                self.session = nil
                sessionID = nil
                continuation.resume(throwing: ASWebAuthenticationSessionError(.presentationContextInvalid))
            }
        }
    }

    /// Whether `error` is the user closing the browser sheet.
    static func isCancellation(_ error: any Error) -> Bool {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}

/// The window authentication sheets attach to: the key window of the frontmost scene.
@MainActor
enum PresentationAnchor {
    /// - Throws: `ASWebAuthenticationSessionError(.presentationContextInvalid)` when no window exists.
    static func current() throws -> ASPresentationAnchor {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        #else
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        #endif
        guard let window else { throw ASWebAuthenticationSessionError(.presentationContextInvalid) }
        return window
    }
}
