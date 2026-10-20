import Foundation
import os
import Synchronization

/// Reports billable calls (commands, wakes) to the backend usage ledger without holding up the UI.
///
/// ``record(_:count:)`` returns at once; the report goes out in the background and is retried a
/// few times on failure. A report that still fails is logged and dropped: it is never surfaced to
/// the user, because the command it counts has already succeeded.
public final class UsageReporter: Sendable {
    private static let log = Logger(subsystem: "com.duncanbottrill.garage", category: "usage")

    private let send: @Sendable (UsageCategory, Int) async throws -> Void
    private let attempts: Int
    private let retryDelay: Duration
    private let outstanding = Mutex<[UUID: Task<Void, Never>]>([:])

    /// - Parameters:
    ///   - attempts: Tries per report before it is logged and dropped (at least 1).
    ///   - retryDelay: Pause before the second try; doubled before each later one.
    ///   - send: Delivers one report (normally ``GarageAPI/reportUsage(_:count:)``).
    public init(
        attempts: Int = 3,
        retryDelay: Duration = .seconds(2),
        send: @escaping @Sendable (UsageCategory, Int) async throws -> Void
    ) {
        self.attempts = max(1, attempts)
        self.retryDelay = retryDelay
        self.send = send
    }

    /// Reports through the Garage backend.
    public convenience init(api: GarageAPI) {
        self.init { category, count in try await api.reportUsage(category, count: count) }
    }

    /// Queues one report of `count` units of `category`; returns immediately.
    public func record(_ category: UsageCategory, count: Int = 1) {
        let id = UUID()
        // Inserted under the lock, so the task's own removal (which takes the same lock) always comes after.
        outstanding.withLock { tasks in
            tasks[id] = Task { [self] in
                await deliver(category, count: count)
                _ = outstanding.withLock { $0.removeValue(forKey: id) }
            }
        }
    }

    /// Waits until every queued report has been delivered or given up on.
    public func drain() async {
        while true {
            let tasks = outstanding.withLock { Array($0.values) }
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }

    private func deliver(_ category: UsageCategory, count: Int) async {
        var delay = retryDelay
        for attempt in 1...attempts {
            do {
                try await send(category, count)
                return
            } catch APIError.unauthorized {
                // No session: retrying cannot help.
                Self.log.error("usage report \(category.rawValue, privacy: .public) x\(count) dropped: session refused")
                return
            } catch {
                guard attempt < attempts else {
                    Self.log.error("usage report \(category.rawValue, privacy: .public) x\(count) dropped after \(attempt) attempts: \(error.localizedDescription, privacy: .public)")
                    return
                }
                try? await Task.sleep(for: delay)
                delay *= 2
            }
        }
    }
}
