import Foundation
import Synchronization
import Testing
@testable import GarageKit

/// What a fake `/api/usage` was sent, and when.
private final class UsageLedger: Sendable {
    struct Call: Equatable {
        let id: UUID
        let category: UsageCategory
        let count: Int
        let at: ContinuousClock.Instant
        static func == (a: Call, b: Call) -> Bool { a.category == b.category && a.count == b.count }
    }

    private let calls = Mutex<[Call]>([])
    /// Replies for the next calls, in order; a call past the end succeeds.
    private let replies: Mutex<[(any Error)?]>

    init(replies: [(any Error)?] = []) {
        self.replies = Mutex(replies)
    }

    var recorded: [Call] { calls.withLock { $0 } }
    var counts: [Int] { recorded.map(\.count) }
    var ids: [UUID] { recorded.map(\.id) }

    func send(_ batch: UsageReporter.Batch) throws {
        calls.withLock { $0.append(Call(id: batch.id, category: batch.category, count: batch.count, at: .now)) }
        let reply = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if let reply { throw reply }
    }
}

/// A `/api/usage` that never answers until released: a request in flight when the app is killed.
private final class StuckLedger: Sendable {
    private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let received = Mutex<[UsageReporter.Batch]>([])

    var batches: [UsageReporter.Batch] { received.withLock { $0 } }

    func send(_ batch: UsageReporter.Batch) async {
        received.withLock { $0.append(batch) }
        await withCheckedContinuation { continuation in
            waiting.withLock { $0.append(continuation) }
        }
    }

    func release() {
        let continuations = waiting.withLock { waiting -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }
}

@Suite struct UsageReporterTests {
    /// `/api/usage` allows 10 requests a minute per user: a burst of commands is one report.
    @Test func burstIsOneReport() async throws {
        let ledger = UsageLedger()
        let reporter = UsageReporter { try ledger.send($0) }
        for _ in 0..<12 {
            reporter.record(.commands)
            try await Task.sleep(for: .milliseconds(50))
        }
        await reporter.drain()
        #expect(ledger.recorded.map(\.category) == [.commands])
        #expect(ledger.counts == [12])
    }

    /// A 429 keeps the counts and sends them, with anything recorded meanwhile, after the window.
    @Test func rateLimitedKeepsCountsAndRetriesAfterWindow() async throws {
        let ledger = UsageLedger(replies: [APIError.rateLimited])
        let reporter = UsageReporter(attempts: 1, interval: .milliseconds(300), coalesce: .zero) { try ledger.send($0) }
        reporter.record(.commands, count: 3)
        #expect(await waitFor { ledger.recorded.count == 1 })
        reporter.record(.commands, count: 2)
        await reporter.drain()

        #expect(ledger.counts == [3, 3, 2], "a 429 is not an attempt, and loses nothing")
        #expect(ledger.ids[0] == ledger.ids[1], "the kept batch keeps its id, so the backend counts it once")
        #expect(ledger.ids[1] != ledger.ids[2], "the counts recorded meanwhile wait for it, then go as their own batch")
        let calls = ledger.recorded
        #expect(calls[1].at - calls[0].at >= .milliseconds(290))
    }

    /// Nothing sent in the last window: the first report goes out at once (after the short coalescing
    /// wait); later ones wait for the window.
    @Test func reportsAtMostOncePerWindow() async throws {
        let ledger = UsageLedger()
        let reporter = UsageReporter(interval: .milliseconds(400), coalesce: .zero) { try ledger.send($0) }
        let start = ContinuousClock.now
        reporter.record(.commands)
        #expect(await waitFor { ledger.recorded.count == 1 })
        #expect(ledger.recorded[0].at - start < .milliseconds(200))

        reporter.record(.commands)
        reporter.record(.wakes)
        reporter.record(.commands)
        await reporter.drain()
        #expect(ledger.recorded.map(\.category) == [.commands, .commands, .wakes])
        #expect(ledger.counts == [1, 2, 1])
        #expect(ledger.recorded[1].at - ledger.recorded[0].at >= .milliseconds(390))
    }

    /// One request carries at most 100 (the backend's cap); the rest go in the next window.
    @Test func splitsCountsOver100() async {
        let ledger = UsageLedger()
        let reporter = UsageReporter(interval: .milliseconds(50), coalesce: .zero) { try ledger.send($0) }
        reporter.record(.commands, count: 130)
        await reporter.drain()
        #expect(ledger.counts == [100, 30])
    }

    /// `flush()` (the app going to the background) sends what is waiting without the window.
    @Test func flushSkipsTheWindow() async throws {
        let ledger = UsageLedger()
        let reporter = UsageReporter(interval: .seconds(60), coalesce: .zero) { try ledger.send($0) }
        reporter.record(.commands)
        #expect(await waitFor { ledger.recorded.count == 1 })
        reporter.record(.commands, count: 4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ledger.recorded.count == 1, "inside the window")

        reporter.flush()
        #expect(await waitFor { ledger.recorded.count == 2 })
        #expect(ledger.counts == [1, 4])
    }

    /// Other retryable failures still give up after `attempts`.
    @Test func serverErrorsGiveUpAfterAttempts() async {
        let ledger = UsageLedger(replies: [APIError.server(status: 500), APIError.server(status: 500)])
        let reporter = UsageReporter(attempts: 2, retryDelay: .milliseconds(10), interval: .milliseconds(20), coalesce: .zero) { try ledger.send($0) }
        reporter.record(.commands, count: 2)
        await reporter.drain()
        #expect(ledger.counts == [2, 2])
        #expect(ledger.ids[0] == ledger.ids[1], "a retry carries the same id")
    }

    /// The store keeps what the backend has not acknowledged: counts recorded, and a batch whose
    /// request was in flight when the app died. The next reporter on the store sends the batch
    /// under its old id (so the backend counts it once however the first request ended) and the
    /// counts as a new one.
    @Test func storeCarriesUnansweredCountsToTheNextLaunch() async throws {
        let store = InMemoryUsageStore()
        let stuck = StuckLedger()
        let first = UsageReporter(interval: .milliseconds(20), coalesce: .zero, store: store) { await stuck.send($0) }
        first.record(.commands, count: 2)
        #expect(await waitFor { stuck.batches.count == 1 })
        first.record(.wakes)
        let saved = try #require(store.saved)
        #expect(saved.batches == stuck.batches, "the batch was saved before its request went out")
        #expect(saved.counts == [.wakes: 1])

        // "Relaunch": a new reporter on the same store, with a backend that answers.
        let ledger = UsageLedger()
        let second = UsageReporter(interval: .milliseconds(20), coalesce: .zero, store: store) { try ledger.send($0) }
        await second.drain()
        #expect(ledger.recorded.map(\.category) == [.commands, .wakes])
        #expect(ledger.counts == [2, 1])
        #expect(ledger.ids[0] == stuck.batches[0].id)
        #expect(store.saved == nil, "acknowledged: nothing left for a third launch")
        // Let the "killed" reporter's request return, with nothing left for it to send.
        first.discard()
        stuck.release()
        await first.drain()
    }

    /// An empty or unreadable store starts the reporter idle; a save happens on the first change.
    @Test func emptyStoreStartsIdle() async {
        let store = InMemoryUsageStore()
        let ledger = UsageLedger()
        let reporter = UsageReporter(coalesce: .zero, store: store) { try ledger.send($0) }
        await reporter.drain()
        #expect(ledger.recorded.isEmpty)
        #expect(store.saves == 0)
        reporter.record(.commands)
        #expect(store.saves >= 1)
        await reporter.drain()
        #expect(store.saved == nil)
    }

    /// `discard()` drops the counts, the batches and the store (sign-out).
    @Test func discardDropsEverything() async throws {
        let store = InMemoryUsageStore()
        let ledger = UsageLedger(replies: [APIError.rateLimited])
        let reporter = UsageReporter(interval: .seconds(60), coalesce: .zero, store: store) { try ledger.send($0) }
        reporter.record(.commands, count: 3)
        #expect(await waitFor { ledger.recorded.count == 1 })
        reporter.record(.wakes)
        #expect(try #require(store.saved).batches.count == 1, "the 429'd batch is kept")

        reporter.discard()
        await reporter.drain()
        #expect(ledger.recorded.count == 1, "nothing more was sent")
        #expect(store.saved == nil)
        reporter.record(.commands)
        await reporter.drain()
        #expect(ledger.counts == [3, 1], "the reporter still works afterwards")
    }

    /// `drain(timeout:)` flushes, then gives up after the timeout when the backend does not answer.
    @Test func drainWithTimeoutGivesUp() async {
        let stuck = StuckLedger()
        let reporter = UsageReporter(interval: .seconds(60), coalesce: .seconds(60)) { await stuck.send($0) }
        reporter.record(.commands)
        let start = ContinuousClock.now
        #expect(await reporter.drain(timeout: .milliseconds(150)) == false)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(stuck.batches.count == 1, "the flush sent it without the coalescing wait")

        stuck.release()
        #expect(await reporter.drain(timeout: .seconds(3)))
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}
