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
/// - A batch carries a ``Batch/id`` and is sent with that id until the backend answers, so a reply
///   lost after the server counted it, or a relaunch with the batch still on disk, re-sends the same
///   id and is counted once. A category's new counts wait while a batch of it is still unanswered,
///   so there is at most one unanswered batch per category.
/// - A 429 keeps the batch and sends it again after the window; it is not counted as a failed
///   attempt. No answer at all (offline, a token that cannot be renewed yet) keeps it too, trying
///   again after `retryDelay` doubled each time up to ``offlineRetryMax``: the id makes the resend
///   safe. A 5xx answer is tried again up to `attempts` times (waiting at least `retryDelay`,
///   doubled each time, and the window), then logged and dropped; a 4xx is dropped at once.
/// - With a ``UsageStore`` the pending counts and the formed batches are saved on every change and
///   picked up by the next reporter on the same store (the next launch), so a kill or a suspension
///   loses nothing. A batch older than ``maxAge`` is dropped on load (the backend's memory of ids
///   is 30 days). ``retire()`` drops them and stops the reporter for good (sign-out: they belong to
///   the old account, and the store now belongs to the next reporter).
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
    /// The longest pause between tries while the backend gives no answer.
    public static let offlineRetryMax: Duration = .seconds(600)
    /// A saved batch older than this is dropped on load rather than sent (the backend remembers an
    /// id for 30 days; after that a resend would count twice).
    public static let maxAge: TimeInterval = 25 * 24 * 3600

    /// One report to `/api/usage`: formed from the pending counts of one category, sent under its
    /// `id` until the backend acknowledges it.
    public struct Batch: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let category: UsageCategory
        public let count: Int
        /// When the batch was formed, for ``maxAge``.
        public let createdAt: Date

        public init(id: UUID = UUID(), category: UsageCategory, count: Int, createdAt: Date = .now) {
            self.id = id
            self.category = category
            self.count = count
            self.createdAt = createdAt
        }
    }

    /// Delivers one batch (normally ``GarageAPI/reportUsage(_:count:reportID:)``).
    public typealias Send = @Sendable (Batch) async throws -> Void

    private static let log = Logger(subsystem: "com.duncanbottrill.garage", category: "usage")

    private struct Ledger {
        /// Counts not yet in a batch.
        var pending: [UsageCategory: Int] = [:]
        /// Batches formed and not yet acknowledged (or dropped), in sending order.
        var batches: [Batch] = []
        /// Failed 5xx tries so far of each batch (429s and no-answer failures excluded).
        var failures: [UUID: Int] = [:]
        /// Consecutive sends with no answer from the backend, for the offline backoff.
        var offlineStreak = 0
        /// ``retire()`` was called: nothing is recorded, sent or saved any more.
        var retired = false
        /// When the oldest pending count was recorded.
        var firstPending: ContinuousClock.Instant?
        /// When the last batch went out.
        var lastBatch: ContinuousClock.Instant?
        /// No batch before this (after a failure).
        var retryAfter: ContinuousClock.Instant?
        /// ``flush()`` asked for the next batch to skip the waits.
        var urgent = false
        /// Sends batches while anything is waiting; nil when idle.
        var worker: Task<Void, Never>?
        /// The worker's current wait, cancelled by ``flush()`` and ``discard()``.
        var sleeper: Task<Void, Never>?

        var hasWork: Bool { !pending.isEmpty || !batches.isEmpty }
        var saved: PendingUsage { PendingUsage(counts: pending, batches: batches) }
    }

    private let send: Send
    private let store: (any UsageStore)?
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
    ///   - store: Where the unanswered counts are kept between launches; nil keeps them in memory
    ///     only. What the store holds is sent first.
    ///   - send: Delivers one batch (normally ``GarageAPI/reportUsage(_:count:reportID:)``).
    public init(
        attempts: Int = 3,
        retryDelay: Duration = .seconds(2),
        interval: Duration = UsageReporter.defaultInterval,
        coalesce: Duration = UsageReporter.defaultCoalesce,
        store: (any UsageStore)? = nil,
        send: @escaping Send
    ) {
        self.attempts = max(1, attempts)
        self.retryDelay = retryDelay
        self.interval = interval
        self.coalesce = coalesce
        self.store = store
        self.send = send
        guard let saved = store?.load(), !saved.isEmpty else { return }
        ledger.withLock { ledger in
            ledger.pending = saved.counts.filter { $0.value > 0 }
            ledger.batches = saved.batches.filter { $0.count > 0 && Date.now.timeIntervalSince($0.createdAt) < Self.maxAge }
            if !ledger.pending.isEmpty { ledger.firstPending = .now }
            startWorker(&ledger)
        }
    }

    /// Reports through the Garage backend, keeping the unanswered counts in `store`.
    public convenience init(api: GarageAPI, store: (any UsageStore)? = nil) {
        self.init(store: store) { batch in
            try await api.reportUsage(batch.category, count: batch.count, reportID: batch.id)
        }
    }

    /// Adds `count` units of `category` to the next batch; returns immediately.
    public func record(_ category: UsageCategory, count: Int = 1) {
        guard count > 0 else { return }
        ledger.withLock { ledger in
            guard !ledger.retired else { return }
            ledger.pending[category, default: 0] += count
            if ledger.firstPending == nil { ledger.firstPending = .now }
            persist(ledger)
            startWorker(&ledger)
        }
    }

    /// Sends what is waiting now, without the coalescing wait or the window (for the app going to the
    /// background). Does nothing when nothing is waiting.
    public func flush() {
        let sleeper = ledger.withLock { ledger -> Task<Void, Never>? in
            guard ledger.hasWork else { return nil }
            ledger.urgent = true
            return ledger.sleeper
        }
        sleeper?.cancel()
    }

    /// Drops every unanswered count, here and in the store. A request already in flight finishes
    /// on its own; the reporter keeps working afterwards.
    public func discard() {
        let sleeper = ledger.withLock { ledger -> Task<Void, Never>? in
            clear(&ledger)
            persist(ledger)
            return ledger.sleeper
        }
        sleeper?.cancel()
    }

    /// ``discard()``, then stops the reporter for good: nothing it is asked to record, nothing a
    /// request still in flight returns, and nothing it would save reaches the store again. For
    /// sign-out, where the counts belong to the account that is leaving and the store to the
    /// reporter that replaces this one.
    public func retire() {
        let sleeper = ledger.withLock { ledger -> Task<Void, Never>? in
            clear(&ledger)
            persist(ledger)
            ledger.retired = true
            return ledger.sleeper
        }
        sleeper?.cancel()
    }

    /// Call under the lock.
    private func clear(_ ledger: inout Ledger) {
        ledger.pending = [:]
        ledger.batches = []
        ledger.failures = [:]
        ledger.offlineStreak = 0
        ledger.firstPending = nil
        ledger.lastBatch = nil
        ledger.retryAfter = nil
        ledger.urgent = false
    }

    /// Waits until every recorded count has been delivered or given up on.
    public func drain() async {
        while let worker = ledger.withLock({ $0.worker }) {
            await worker.value
        }
    }

    /// ``flush()`` then ``drain()``, giving up after `timeout` (the batches then stay in the store).
    /// - Returns: Whether everything was delivered (or given up on) in time.
    public func drain(timeout: Duration) async -> Bool {
        flush()
        let gate = ResumeGate<Bool>()
        let draining = Task { [self] in
            await drain()
            gate.fire(true)
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.fire(false)
        }
        let delivered = await withTaskCancellationHandler {
            await withCheckedContinuation { gate.arm($0) }
        } onCancel: {
            gate.fire(false)
        }
        timer.cancel()
        if !delivered { draining.cancel() }
        return delivered
    }

    /// No answer from the backend at all (a transport failure, or a token that cannot be renewed
    /// yet): the batch is kept and tried again, with the offline backoff and no attempt counted.
    static func isNoAnswer(_ error: any Error) -> Bool {
        guard let error = error as? APIError else { return true }
        if case .tokenUnavailable = error { return true }
        return false
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

    /// Starts the worker if it is not running. Call under the lock.
    private func startWorker(_ ledger: inout Ledger) {
        guard ledger.worker == nil, ledger.hasWork else { return }
        ledger.worker = Task { [self] in await work() }
    }

    /// Writes the ledger to the store. Call under the lock, so saves land in order. A retired
    /// reporter never writes: the store belongs to its successor.
    private func persist(_ ledger: Ledger) {
        guard !ledger.retired else { return }
        store?.save(ledger.saved)
    }

    private func work() async {
        while true {
            let due = ledger.withLock { ledger -> ContinuousClock.Instant? in
                guard ledger.hasWork else {
                    ledger.worker = nil
                    ledger.urgent = false
                    return nil
                }
                if ledger.urgent { return .now }
                var due: ContinuousClock.Instant = .now
                if !ledger.pending.isEmpty { due = (ledger.firstPending ?? .now).advanced(by: coalesce) }
                if let last = ledger.lastBatch { due = max(due, last.advanced(by: interval)) }
                if let retryAfter = ledger.retryAfter { due = max(due, retryAfter) }
                return due
            }
            guard let due else { return }
            if due > .now {
                // Woken early by flush() or discard(): go round again rather than forming batches
                // now (a discard leaves nothing to send, and must not stamp a new window).
                await wait(until: due)
                continue
            }

            let batches = ledger.withLock { ledger -> [Batch] in
                ledger.urgent = false
                ledger.retryAfter = nil
                ledger.lastBatch = .now
                for category in UsageCategory.allCases {
                    guard let count = ledger.pending[category], count > 0 else { continue }
                    // A batch of this category is still unanswered: the new counts wait for it, so it
                    // keeps its id and the ledger never holds two unanswered batches of one category.
                    guard !ledger.batches.contains(where: { $0.category == category }) else { continue }
                    let taken = min(count, Self.maxCount)
                    ledger.batches.append(Batch(category: category, count: taken))
                    ledger.pending[category] = count > taken ? count - taken : nil
                }
                // A rest (over the cap, or behind an unanswered batch) waits for the next window.
                ledger.firstPending = ledger.pending.isEmpty ? nil : .now
                persist(ledger)
                return ledger.batches
            }
            for batch in batches {
                await deliver(batch)
            }
        }
    }

    /// Sleeps until `due`, or until ``flush()`` or ``discard()`` cancels the wait.
    private func wait(until due: ContinuousClock.Instant) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(until: due, clock: .continuous) }
        let urgent = ledger.withLock { ledger -> Bool in
            ledger.sleeper = sleeper
            return ledger.urgent || !ledger.hasWork
        }
        if urgent { sleeper.cancel() }
        await sleeper.value
        ledger.withLock { $0.sleeper = nil }
    }

    private func deliver(_ batch: Batch) async {
        // Discarded or retired since the batches were snapshotted: nothing to send.
        guard isLive(batch) else { return }
        let label = "\(batch.category.rawValue) x\(batch.count) (\(batch.id.uuidString.prefix(8)))"
        do {
            try await send(batch)
            ledger.withLock { $0.offlineStreak = 0 }
            settle(batch)
        } catch APIError.rateLimited {
            // Over `/api/usage`'s per-minute limit: the batch keeps its id for after the window.
            Self.log.info("usage report \(label, privacy: .public) rate limited; kept for the next window")
        } catch where Self.isNoAnswer(error) {
            // Nothing answered: the batch keeps its id (a reply lost after the server counted it is
            // the id's job), and the next try waits longer each time, up to ``offlineRetryMax``.
            let pause = ledger.withLock { ledger -> Duration? in
                guard ledger.batches.contains(where: { $0.id == batch.id }) else { return nil }
                ledger.offlineStreak += 1
                let pause = min(retryDelay * (1 << min(ledger.offlineStreak - 1, 16)), Self.offlineRetryMax)
                let retryAfter = ContinuousClock.now.advanced(by: pause)
                ledger.retryAfter = max(ledger.retryAfter ?? retryAfter, retryAfter)
                return pause
            }
            if let pause {
                Self.log.info("usage report \(label, privacy: .public) got no answer (\(error.localizedDescription, privacy: .public)); next try in \(pause.components.seconds, privacy: .public) s")
            }
        } catch where !Self.isRetryable(error) {
            // A client error (bad request, no session): the same report would be refused again.
            Self.log.error("usage report \(label, privacy: .public) dropped: \(error.localizedDescription, privacy: .public)")
            settle(batch)
        } catch {
            // The backend answered with a 5xx: a few more tries, then give up.
            let attempt = ledger.withLock { ledger -> Int in
                guard ledger.batches.contains(where: { $0.id == batch.id }) else { return 0 }
                let attempt = (ledger.failures[batch.id] ?? 0) + 1
                if attempt < attempts {
                    ledger.failures[batch.id] = attempt
                    let backoff = retryDelay * (1 << min(attempt - 1, 16))
                    let retryAfter = ContinuousClock.now.advanced(by: backoff)
                    ledger.retryAfter = max(ledger.retryAfter ?? retryAfter, retryAfter)
                }
                return attempt
            }
            guard attempt >= attempts else { return }
            Self.log.error("usage report \(label, privacy: .public) dropped after \(attempt) attempts: \(error.localizedDescription, privacy: .public)")
            settle(batch)
        }
    }

    private func isLive(_ batch: Batch) -> Bool {
        ledger.withLock { ledger in !ledger.retired && ledger.batches.contains { $0.id == batch.id } }
    }

    /// Removes `batch` from the ledger: acknowledged, or given up on. Saves only when it was still
    /// there (after a discard there is nothing of this reporter's left to save over).
    private func settle(_ batch: Batch) {
        ledger.withLock { ledger in
            let before = ledger.batches.count
            ledger.batches.removeAll { $0.id == batch.id }
            ledger.failures[batch.id] = nil
            if ledger.batches.count != before { persist(ledger) }
        }
    }
}
