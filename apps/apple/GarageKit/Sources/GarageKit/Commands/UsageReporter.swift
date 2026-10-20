import Foundation
import os
import Synchronization

/// Reports billable calls (commands, wakes) to the backend usage ledger without holding up the UI.
///
/// `POST /api/usage` allows 10 requests a minute per user and takes a `count` of up to 100, so counts
/// are batched per category:
/// - ``record(_:count:)`` returns at once and adds to the pending count.
/// - A batch goes out ``defaultCoalesce`` (1 s) after the first count waiting, so a burst of taps is
///   one report, and never sooner than ``defaultInterval`` (5 s) after the previous batch. Each
///   batch is one request per category, with at most ``maxCount`` each; any rest waits for the next.
/// - A 429 keeps the counts and sends them again after the window; it is not counted as a failed
///   attempt. Other transport and 5xx failures are tried again up to `attempts` times (waiting at
///   least `retryDelay`, doubled each time, and the window), then logged and dropped.
/// - ``flush()`` (the app going to the background) sends what is waiting without the waits.
///
/// A report that is dropped is never surfaced to the user, because the command it counts has
/// already succeeded.
public final class UsageReporter: Sendable {
    /// The least time between two batches.
    public static let defaultInterval: Duration = .seconds(5)
    /// How long the first count waits for others to join it.
    public static let defaultCoalesce: Duration = .seconds(1)
    /// The most one request counts (`/api/usage` caps `count` at 100).
    public static let maxCount = 100

    private static let log = Logger(subsystem: "com.duncanbottrill.garage", category: "usage")

    private struct Ledger {
        var pending: [UsageCategory: Int] = [:]
        /// Failed tries so far of each category's current batch (429s excluded).
        var failures: [UsageCategory: Int] = [:]
        /// When the oldest pending count was recorded.
        var firstPending: ContinuousClock.Instant?
        /// When the last batch went out.
        var lastBatch: ContinuousClock.Instant?
        /// No batch before this (after a failure).
        var retryAfter: ContinuousClock.Instant?
        /// ``flush()`` asked for the next batch to skip the waits.
        var urgent = false
        /// Sends batches while counts are pending; nil when idle.
        var worker: Task<Void, Never>?
        /// The worker's current wait, cancelled by ``flush()``.
        var sleeper: Task<Void, Never>?
    }

    private let send: @Sendable (UsageCategory, Int) async throws -> Void
    private let attempts: Int
    private let retryDelay: Duration
    private let interval: Duration
    private let coalesce: Duration
    private let ledger = Mutex(Ledger())

    /// - Parameters:
    ///   - attempts: Tries per batch before it is logged and dropped (at least 1; 429s do not count).
    ///   - retryDelay: Least pause before the second try; doubled before each later one.
    ///   - interval: The least time between two batches (``defaultInterval``).
    ///   - coalesce: How long the first pending count waits for others (``defaultCoalesce``).
    ///   - send: Delivers one report (normally ``GarageAPI/reportUsage(_:count:)``).
    public init(
        attempts: Int = 3,
        retryDelay: Duration = .seconds(2),
        interval: Duration = UsageReporter.defaultInterval,
        coalesce: Duration = UsageReporter.defaultCoalesce,
        send: @escaping @Sendable (UsageCategory, Int) async throws -> Void
    ) {
        self.attempts = max(1, attempts)
        self.retryDelay = retryDelay
        self.interval = interval
        self.coalesce = coalesce
        self.send = send
    }

    /// Reports through the Garage backend.
    public convenience init(api: GarageAPI) {
        self.init { category, count in try await api.reportUsage(category, count: count) }
    }

    /// Adds `count` units of `category` to the next batch; returns immediately.
    public func record(_ category: UsageCategory, count: Int = 1) {
        guard count > 0 else { return }
        ledger.withLock { ledger in
            ledger.pending[category, default: 0] += count
            if ledger.firstPending == nil { ledger.firstPending = .now }
            if ledger.worker == nil { ledger.worker = Task { [self] in await work() } }
        }
    }

    /// Sends what is waiting now, without the coalescing wait or the window (for the app going to the
    /// background). Does nothing when nothing is waiting.
    public func flush() {
        let sleeper = ledger.withLock { ledger -> Task<Void, Never>? in
            guard !ledger.pending.isEmpty else { return nil }
            ledger.urgent = true
            return ledger.sleeper
        }
        sleeper?.cancel()
    }

    /// Waits until every recorded count has been delivered or given up on.
    public func drain() async {
        while let worker = ledger.withLock({ $0.worker }) {
            await worker.value
        }
    }

    /// Transport failures, 5xx and 429 are worth another try; other 4xx answers are not.
    static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? APIError else { return true }
        switch error {
        case .rateLimited, .tokenUnavailable: return true
        case let .server(status): return !(400..<500).contains(status)
        case .unauthorized, .notConnected, .asleep, .budgetMinimal: return false
        }
    }

    // MARK: Worker

    private func work() async {
        while true {
            let due = ledger.withLock { ledger -> ContinuousClock.Instant? in
                guard !ledger.pending.isEmpty else {
                    ledger.worker = nil
                    ledger.urgent = false
                    return nil
                }
                if ledger.urgent { return .now }
                var due = (ledger.firstPending ?? .now).advanced(by: coalesce)
                if let last = ledger.lastBatch { due = max(due, last.advanced(by: interval)) }
                if let retryAfter = ledger.retryAfter { due = max(due, retryAfter) }
                return due
            }
            guard let due else { return }
            if due > .now { await wait(until: due) }

            let batch = ledger.withLock { ledger -> [(UsageCategory, Int)] in
                ledger.urgent = false
                ledger.retryAfter = nil
                ledger.lastBatch = .now
                var batch: [(UsageCategory, Int)] = []
                for category in UsageCategory.allCases {
                    guard let count = ledger.pending[category], count > 0 else { continue }
                    let taken = min(count, Self.maxCount)
                    batch.append((category, taken))
                    ledger.pending[category] = count > taken ? count - taken : nil
                }
                // A rest over the cap waits for the next window.
                ledger.firstPending = ledger.pending.isEmpty ? nil : .now
                return batch
            }
            for (category, count) in batch {
                await deliver(category, count: count)
            }
        }
    }

    /// Sleeps until `due`, or until ``flush()`` cancels the wait.
    private func wait(until due: ContinuousClock.Instant) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(until: due, clock: .continuous) }
        let urgent = ledger.withLock { ledger -> Bool in
            ledger.sleeper = sleeper
            return ledger.urgent
        }
        if urgent { sleeper.cancel() }
        await sleeper.value
        ledger.withLock { $0.sleeper = nil }
    }

    private func deliver(_ category: UsageCategory, count: Int) async {
        do {
            try await send(category, count)
            ledger.withLock { _ = $0.failures.removeValue(forKey: category) }
        } catch APIError.rateLimited {
            // Over `/api/usage`'s per-minute limit: keep the counts for after the window.
            Self.log.info("usage report \(category.rawValue, privacy: .public) x\(count) rate limited; kept for the next window")
            keep(category, count: count, retryAfter: nil)
        } catch where !Self.isRetryable(error) {
            // A client error (bad request, no session): the same report would be refused again.
            Self.log.error("usage report \(category.rawValue, privacy: .public) x\(count) dropped: \(error.localizedDescription, privacy: .public)")
            ledger.withLock { _ = $0.failures.removeValue(forKey: category) }
        } catch {
            let attempt = ledger.withLock { ledger -> Int in
                let attempt = (ledger.failures[category] ?? 0) + 1
                ledger.failures[category] = attempt < attempts ? attempt : nil
                return attempt
            }
            guard attempt < attempts else {
                Self.log.error("usage report \(category.rawValue, privacy: .public) x\(count) dropped after \(attempt) attempts: \(error.localizedDescription, privacy: .public)")
                return
            }
            let backoff = retryDelay * (1 << min(attempt - 1, 16))
            keep(category, count: count, retryAfter: ContinuousClock.now.advanced(by: backoff))
        }
    }

    /// Puts `count` back in front of the next batch.
    private func keep(_ category: UsageCategory, count: Int, retryAfter: ContinuousClock.Instant?) {
        ledger.withLock { ledger in
            ledger.pending[category, default: 0] += count
            if ledger.firstPending == nil { ledger.firstPending = .now }
            if let retryAfter { ledger.retryAfter = max(ledger.retryAfter ?? retryAfter, retryAfter) }
        }
    }
}
