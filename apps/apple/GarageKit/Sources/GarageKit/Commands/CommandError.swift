import Foundation

/// Why a command did not reach the car or the car did not carry it out, with copy for the user.
/// Every message is plain language and names the next action (spec copy rules: no exclamation marks).
public enum CommandError: Error, Sendable, Equatable, LocalizedError {
    /// The bridge's proxy could not be reached (Tailscale off, bridge down, or no proxy URL yet).
    case unreachable
    /// Tesla refused the token even after one refresh, or the backend has no usable token.
    case unauthorized
    /// The car is asleep or offline. The caller may offer a wake (never automatic).
    case asleep
    /// The car has not paired Garage's virtual key.
    case keyMissing
    /// The car or Tesla declined the command, with its reason.
    case rejected(reason: String)
    /// No answer within the command timeout (10 s).
    case timeout
    /// The Tesla budget is spent or in minimal mode, so the request was refused.
    case budgetBlocked

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            "Can't reach your home bridge. Check that Tailscale is on, then try again."
        case .unauthorized:
            "Tesla didn't accept Garage's sign-in. Reconnect Tesla in More."
        case .asleep:
            "The car is asleep. Wake it to send this."
        case .keyMissing:
            "The car hasn't paired Garage's key yet. Pair the key, then try again."
        case let .rejected(reason):
            "That didn't go through (\(reason)). Check the car, then try again."
        case .timeout:
            "The car didn't answer in time. Check its state before trying again."
        case .budgetBlocked:
            "This month's Tesla budget is spent, so commands are paused. Check Budget in More."
        }
    }
}
