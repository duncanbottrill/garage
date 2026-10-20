import Foundation
import Synchronization
import Testing
@testable import GarageKit

/// What a fake `/api/usage` was sent, and when.
private final class UsageLedger: Sendable {
    struct Call: Equatable {
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

    func send(_ category: UsageCategory, _ count: Int) throws {
        calls.withLock { $0.append(Call(category: category, count: count, at: .now)) }
        let reply = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if let reply { throw reply }
    }
}

@Suite struct UsageReporterTests {
    /// `/api/usage` allows 10 requests a minute per user: a burst of commands is one report.
    @Test func burstIsOneReport() async throws {
        let ledger = UsageLedger()
        let reporter = UsageReporter { try ledger.send($0, $1) }
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
        let reporter = UsageReporter(attempts: 1, interval: .milliseconds(300), coalesce: .zero) { try ledger.send($0, $1) }
        reporter.record(.commands, count: 3)
        #expect(await waitFor { ledger.recorded.count == 1 })
        reporter.record(.commands, count: 2)
        await reporter.drain()

        #expect(ledger.counts == [3, 5], "a 429 is not an attempt, and loses nothing")
        let calls = ledger.recorded
        #expect(calls[1].at - calls[0].at >= .milliseconds(290))
    }

    /// Nothing sent in the last window: the first report goes out at once (after the short coalescing
    /// wait); later ones wait for the window.
    @Test func reportsAtMostOncePerWindow() async throws {
        let ledger = UsageLedger()
        let reporter = UsageReporter(interval: .milliseconds(400), coalesce: .zero) { try ledger.send($0, $1) }
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
        let reporter = UsageReporter(interval: .milliseconds(50), coalesce: .zero) { try ledger.send($0, $1) }
        reporter.record(.commands, count: 130)
        await reporter.drain()
        #expect(ledger.counts == [100, 30])
    }

    /// `flush()` (the app going to the background) sends what is waiting without the window.
    @Test func flushSkipsTheWindow() async throws {
        let ledger = UsageLedger()
        let reporter = UsageReporter(interval: .seconds(60), coalesce: .zero) { try ledger.send($0, $1) }
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
        let reporter = UsageReporter(attempts: 2, retryDelay: .milliseconds(10), interval: .milliseconds(20), coalesce: .zero) { try ledger.send($0, $1) }
        reporter.record(.commands, count: 2)
        await reporter.drain()
        #expect(ledger.counts == [2, 2])
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
