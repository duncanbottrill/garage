import Foundation
import Observation

/// Decides which onboarding step to show, from what is true right now.
///
/// ``evaluate()`` asks, in order, and stops at the first "no":
/// 1. Is there a Supabase session? No → ``Step/signIn``.
/// 2. Is a Tesla account connected (`GET /api/connection` `.connected`)? No → ``Step/connectTesla``.
/// 3. Does the owner have a vehicle? No → ``Step/chooseVehicle``.
/// 4. Is the bridge's command proxy reachable over the tailnet? No → ``Step/tailscale``.
/// 5. Otherwise ``Step/done``.
///
/// A failed check (no network, a server error) never moves the user: the current step is kept and
/// the failure is published as ``lastError``. A refused session (``APIError/unauthorized``) is not a
/// failure but an answer, and goes to ``Step/signIn``.
///
/// Once onboarding has reached ``Step/done`` on this device, an unreachable proxy no longer blocks it:
/// the Status screen shows its "Tailscale is off" banner instead, so the owner can still read the car
/// away from home. Signing out resets this (``resetCompletion(in:)``).
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
        /// Whether a Supabase session exists. Throws only for failures other than "signed out".
        public var hasSession: @MainActor () async throws -> Bool
        /// Whether a Tesla account is connected to this Garage account (`/api/connection`).
        public var isTeslaConnected: @MainActor () async throws -> Bool
        /// The owner's vehicle, fetching it when it is not loaded yet; nil when there is none.
        public var vehicle: @MainActor () async throws -> Vehicle?
        /// One reachability probe of the command proxy.
        public var proxyReachability: @MainActor () async -> ProxyReachability.State

        public init(
            hasSession: @escaping @MainActor () async throws -> Bool,
            isTeslaConnected: @escaping @MainActor () async throws -> Bool,
            vehicle: @escaping @MainActor () async throws -> Vehicle?,
            proxyReachability: @escaping @MainActor () async -> ProxyReachability.State
        ) {
            self.hasSession = hasSession
            self.isTeslaConnected = isTeslaConnected
            self.vehicle = vehicle
            self.proxyReachability = proxyReachability
        }
    }

    /// The `UserDefaults` key recording that onboarding reached ``Step/done`` on this device.
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
        isEvaluating = true
        defer {
            if mine == generation {
                isEvaluating = false
                hasEvaluated = true
            }
        }

        let next: Step
        do {
            next = try await decide()
        } catch APIError.unauthorized {
            guard mine == generation else { return }
            lastError = nil
            step = .signIn
            return
        } catch {
            guard mine == generation else { return }
            lastError = Self.message(for: error)
            return
        }
        guard mine == generation else { return }
        lastError = nil
        step = next
        if next == .done { defaults.set(true, forKey: Self.completedKey) }
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
            lastError = "Tesla didn't connect (\(failure)). Try again."
        }
        return true
    }

    /// Back to ``Step/signIn`` with nothing remembered (sign-out). An evaluation still in flight is abandoned.
    public func reset() {
        generation &+= 1
        isEvaluating = false
        step = .signIn
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

    /// Whether onboarding has reached ``Step/done`` on this device before.
    public static func hasCompleted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    /// Forgets that onboarding was completed (on sign-out), so the next account goes through every step.
    public static func resetCompletion(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completedKey)
    }

    private func decide() async throws -> Step {
        guard try await checks.hasSession() else { return .signIn }
        guard try await checks.isTeslaConnected() else { return .connectTesla }
        guard try await checks.vehicle() != nil else { return .chooseVehicle }
        if Self.hasCompleted(in: defaults) { return .done }
        let reachability = await checks.proxyReachability()
        proxyState = reachability
        return reachability == .reachable ? .done : .tailscale
    }

    /// Copy for a failure: the error's own description when it has one, a generic line otherwise.
    static func message(for error: any Error) -> String {
        if let error = error as? APIError, let text = error.errorDescription { return text }
        if error is URLError { return "Garage can't reach the internet right now. Check the connection and try again." }
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        return "Something went wrong. Try again."
    }
}
