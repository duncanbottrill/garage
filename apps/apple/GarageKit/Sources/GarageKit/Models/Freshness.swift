import Foundation

/// How recent a reading is, from its `*_at` timestamp (spec §10).
///
/// - `.live`: at most ``liveWindow`` (90 s) old, the same window that decides whether the bridge is online.
/// - `.aging(age)`: older than 90 s but younger than the stale threshold.
/// - `.stale(age)`: at least the stale threshold old (10 min by default).
/// - `.unknown`: never reported.
///
/// Ages are clamped at 0, so a timestamp slightly in the future (clock skew) reads as `.live`.
public enum Freshness: Sendable, Equatable {
    case live
    case aging(TimeInterval)
    case stale(TimeInterval)
    case unknown

    /// Readings up to this age are live, and the bridge is online while it last checked in within it.
    public static let liveWindow: TimeInterval = 90
    /// The default age at which a field is stale (10 min).
    public static let defaultStaleAfter: TimeInterval = 600

    /// Classifies a reading stamped `date` as of `now`.
    public static func of(_ date: Date?, now: Date = Date(), staleAfter: TimeInterval = defaultStaleAfter) -> Freshness {
        guard let date else { return .unknown }
        let age = max(0, now.timeIntervalSince(date))
        if age <= liveWindow { return .live }
        if age < staleAfter { return .aging(age) }
        return .stale(age)
    }

    /// Whether the bridge counts as online: it checked in (`bridge_seen_at`) at most 90 s before `now`.
    public static func bridge(seenAt: Date?, now: Date = Date()) -> Bool {
        guard let seenAt else { return false }
        return max(0, now.timeIntervalSince(seenAt)) <= liveWindow
    }
}
