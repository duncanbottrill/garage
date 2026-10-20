import Foundation
import Observation

/// Decides which onboarding step to show, from what is true right now.
///
/// ``evaluate()`` asks, in order, and stops at the first "no":
/// 1. Is there a Supabase session (a signed-in user id)? No → ``Step/signIn``.
/// 2. Is a Tesla account connected (`GET /api/connection` `.connected`)? No → ``Step/connectTesla``.
/// 3. Does the owner have a vehicle? No → ``Step/chooseVehicle``.
/// 4. Is the bridge's command proxy reachable over the tailnet? No → ``Step/tailscale``.
/// 5. Otherwise ``Step/done``.
///
/// A failed check (no network, a server error) never moves the user: the current step is kept and
/// the failure is published as ``lastError``. A refused session (``APIError/unauthorized``) is not a
/// failure but an answer, and goes to ``Step/signIn``.
///
/// Landing on ``Step/signIn`` clears the completion flag and calls ``onSignedOut`` (when coming from
/// another step, on the first evaluation, or when the session was refused), so the app can drop the
/// previous account's car, cache and choices.
///
/// Once onboarding has reached ``Step/done`` for the signed-in user on this device, an unreachable proxy
/// no longer blocks it: the Status screen shows its "Tailscale is off" banner instead, so the owner can
/// still read the car away from home. The flag stores that user's id, so it never carries over to
/// another account.
@MainActor
@Observable
public final class OnboardingFlow {
    /// The onboarding steps, in order.
    public enum Step: Sendable, Equatable, CaseIterable {
        case signIn, connectTesla, chooseVehicle, tailscale, done

        /// The 1-based position shown as "Step n of 4", or nil for ``done``.
        public var number: Int? {
            switch self {
            case .signIn: 1
            case .connectTesla: 2
            case .chooseVehicle: 3
            case .tailscale: 4
            case .done: nil
            }
        }
    }

    /// The questions ``evaluate()`` asks. Injected so tests run with fakes and no network.
    public struct Checks {
        /// The signed-in user's id, or nil without a session. Throws only for failures other than "signed out".
        public var sessionUserID: @MainActor () async throws -> UUID?
        /// Whether a Tesla account is connected to this Garage account (`/api/connection`).
        public var isTeslaConnected: @MainActor () async throws -> Bool
        /// The owner's vehicle, fetching it when it is not loaded yet; nil when there is none.
        public var vehicle: @MainActor () async throws -> Vehicle?
        /// One reachability probe of the command proxy.
        public var proxyReachability: @MainActor () async -> ProxyReachability.State

        public init(
            sessionUserID: @escaping @MainActor () async throws -> UUID?,
            isTeslaConnected: @escaping @MainActor () async throws -> Bool,
            vehicle: @escaping @MainActor () async throws -> Vehicle?,
            proxyReachability: @escaping @MainActor () async -> ProxyReachability.State
        ) {
            self.sessionUserID = sessionUserID
            self.isTeslaConnected = isTeslaConnected
            self.vehicle = vehicle
            self.proxyReachability = proxyReachability
        }
    }

    /// The `UserDefaults` key holding the id of the user who reached ``Step/done`` on this device.
    public static let completedKey = "onboardingCompleted"

    /// The step to show.
    public var step: Step
    /// True once the first ``evaluate()`` has finished, so the view can wait instead of flashing a step.
    public private(set) var hasEvaluated = false
    /// True while ``evaluate()`` runs.
    public private(set) var isEvaluating = false
    /// The last proxy probe result (``Step/tailscale`` words its copy from it).
    public private(set) var proxyState: ProxyReachability.State = .unknown
    /// Plain-language copy for the last failure, for the current step's view; nil when the last check passed.
    public var lastError: String?
    /// Called after an evaluation lands on ``Step/signIn``; `sessionRefused` is true when the backend
    /// refused the session (``APIError/unauthorized``), so the app should also end it locally.
    @ObservationIgnored public var onSignedOut: (@MainActor (_ sessionRefused: Bool) async -> Void)?

    @ObservationIgnored private let checks: Checks
    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped by every evaluation; an older one still in flight then publishes nothing.
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - step: The step to show before the first evaluation (``Step/done`` when a session and a
    ///     completed onboarding are already on the device, so Status opens straight away).
    ///   - checks: The questions to ask.
    ///   - defaults: Where completion is recorded.
    public init(step: Step = .signIn, checks: Checks, defaults: UserDefaults = .standard) {
        self.step = step
        self.checks = checks
        self.defaults = defaults
    }

    /// Re-runs the checks and moves to the step they point at. Overlapping calls are fine: the latest wins.
    public func evaluate() async {
        generation &+= 1
        let mine = generation
        let previous = step
        let first = !hasEvaluated
        isEvaluating = true
        defer {
            if mine == generation {
                isEvaluating = false
                hasEvaluated = true
            }
        }

        let decision: (step: Step, userID: UUID?)
        do {
            decision = try await decide()
        } catch APIError.unauthorized {
            guard mine == generation else { return }
            await landOnSignIn(refused: true, notify: true)
            return
        } catch {
            guard mine == generation else { return }
            lastError = Self.message(for: error)
            return
        }
        guard mine == generation else { return }
        switch decision.step {
        case .signIn:
            await landOnSignIn(refused: false, notify: first || previous != .signIn)
        case .done:
            lastError = nil
            step = .done
            if let userID = decision.userID { Self.markCompleted(by: userID, in: defaults) }
        default:
            lastError = nil
            step = decision.step
        }
    }

    private func landOnSignIn(refused: Bool, notify: Bool) async {
        lastError = nil
        step = .signIn
        Self.resetCompletion(in: defaults)
        if notify { await onSignedOut?(refused) }
    }

    /// Handles a URL opened by the app. `garage://connected` (the backend's redirect after the Tesla
    /// OAuth) re-runs ``evaluate()``; an `error` query item on it is shown as ``lastError``.
    /// - Returns: true when the URL was the connect callback, false for anything else (left alone).
    @discardableResult
    public func handle(url: URL) async -> Bool {
        guard Self.isConnectedCallback(url) else { return false }
        let failure = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "error" }?.value
        await evaluate()
        if let failure, step == .connectTesla {
            lastError = Self.callbackMessage(for: failure)
        }
        return true
    }

    /// Back to `step` with nothing remembered: ``Step/signIn`` on sign-out (the default), or
    /// ``Step/connectTesla`` for "Reconnect Tesla" in More. An evaluation still in flight is abandoned.
    /// The step is a known state, so ``hasEvaluated`` becomes true: the view shows it rather than
    /// waiting on an evaluation that will never publish. The completion record is left alone (sign-out
    /// clears it separately), so finishing the Tesla sign-in goes straight back to ``Step/done``.
    public func reset(to step: Step = .signIn) {
        generation &+= 1
        isEvaluating = false
        hasEvaluated = true
        self.step = step
        proxyState = .unknown
        lastError = nil
    }

    /// Records a failure from a step's own action (sign-in, Tesla, vehicle sync) for the view.
    public func report(_ error: any Error) {
        lastError = Self.message(for: error)
    }

    /// Whether `url` is the backend's `garage://connected` redirect (scheme and host, any query).
    public static func isConnectedCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "garage" && url.host()?.lowercased() == "connected"
    }

    /// Whether `userID` has reached ``Step/done`` on this device before.
    public static func hasCompleted(by userID: UUID, in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: completedKey) == userID.uuidString.lowercased()
    }

    /// Records that `userID` reached ``Step/done`` on this device.
    public static func markCompleted(by userID: UUID, in defaults: UserDefaults = .standard) {
        defaults.set(userID.uuidString.lowercased(), forKey: completedKey)
    }

    /// Fixed copy for the `error` code on `garage://connected?error=…`. The query text itself is never
    /// shown: the backend may put exception text there.
    public static func callbackMessage(for code: String) -> String {
        switch code {
        case "access_denied": "Tesla access wasn't allowed. Connect again and approve Garage's permissions."
        // The backend sends `bad_state` for an unknown or expired OAuth state.
        case "state_mismatch", "bad_state": "The Tesla sign-in expired or came from another attempt. Connect again."
        case "token_exchange_failed": "Tesla signed you in, but Garage couldn't finish connecting. Try again in a minute."
        default: "Tesla sign-in didn't complete. Try again."
        }
    }

    /// Forgets that onboarding was completed (on sign-out), so the next account goes through every step.
    public static func resetCompletion(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completedKey)
    }

    private func decide() async throws -> (step: Step, userID: UUID?) {
        guard let userID = try await checks.sessionUserID() else { return (.signIn, nil) }
        guard try await checks.isTeslaConnected() else { return (.connectTesla, userID) }
        guard try await checks.vehicle() != nil else { return (.chooseVehicle, userID) }
        if Self.hasCompleted(by: userID, in: defaults) { return (.done, userID) }
        let reachability = await checks.proxyReachability()
        proxyState = reachability
        return (reachability == .reachable ? .done : .tailscale, userID)
    }

    /// Copy for a failure: the error's own description when it has one, a generic line otherwise.
    static func message(for error: any Error) -> String {
        if let error = error as? APIError, let text = error.errorDescription { return text }
        if error is URLError { return "Garage can't reach the internet right now. Check the connection and try again." }
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        return "Something went wrong. Try again."
    }
}
