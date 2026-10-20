import Foundation
import Testing
@testable import GarageKit

@Suite struct FreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_792_481_509)

    /// Live up to 90 s, aging until the stale threshold (10 min by default), stale after; no timestamp is unknown.
    @Test func freshnessClassifiesByAge() {
        #expect(Freshness.of(now, now: now) == .live)
        #expect(Freshness.of(now.addingTimeInterval(-5 * 60), now: now) == .aging(5 * 60))
        #expect(Freshness.of(now.addingTimeInterval(-11 * 60), now: now) == .stale(11 * 60))
        #expect(Freshness.of(nil, now: now) == .unknown)
    }

    /// Clock skew between the bridge and the phone can put a timestamp in the future: it counts as age 0.
    @Test func freshnessClampsFutureTimestamps() {
        #expect(Freshness.of(now.addingTimeInterval(30), now: now) == .live)
    }

    /// The bridge is online while `bridge_seen_at` is at most 90 s old.
    @Test func bridgeOfflineAfter90s() {
        #expect(Freshness.bridge(seenAt: now.addingTimeInterval(-89), now: now) == true)
        #expect(Freshness.bridge(seenAt: now.addingTimeInterval(-91), now: now) == false)
        #expect(Freshness.bridge(seenAt: nil, now: now) == false)
    }
}
