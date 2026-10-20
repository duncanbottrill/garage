import Foundation
import Observation

/// Coalesces changes to one value and sends the latest after a quiet time.
///
/// - Each ``submit(_:after:)`` replaces the value and restarts the quiet time; when it passes, the
///   latest value is delivered once.
/// - A value that comes due while a delivery is in flight is delivered as soon as that one completes,
///   with whatever is latest then (so a newer value is never dropped).
/// - Deliveries run in their own task: restarting the quiet time never cancels a send in flight.
@MainActor
final class Coalescer<Value> {
    /// Sends one value. Set by the owner once it is fully initialised.
    var deliver: @MainActor (Value) async -> Void = { _ in }

    private var latest: Value?
    private var timer: Task<Void, Never>?
    private var draining = false
    private var dueWhileDraining = false

    /// True while a value is waiting for its quiet time or for the delivery in flight.
    var hasQueued: Bool { latest != nil }

    /// Makes `value` the one to deliver, `quiet` after the last call (`.zero`: as soon as possible).
    func submit(_ value: Value, after quiet: Duration) {
        latest = value
        timer?.cancel()
        guard quiet > .zero else {
            timer = nil
            due()
            return
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled else { return }
            self?.due()
        }
    }

    private func due() {
        timer = nil
        if draining {
            dueWhileDraining = true
            return
        }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        repeat {
            dueWhileDraining = false
            guard let value = latest else { break }
            latest = nil
            await deliver(value)
        } while dueWhileDraining
        draining = false
    }
}

/// A value shown ahead of the car's row while a change is on its way: set at once, and after a
/// successful send kept until the row agrees or ``hold`` passes. A failure goes back to what was
/// shown before the change: the last value sent (if it is still held), else the row.
@MainActor
@Observable
final class PendingOverlay<Value: Equatable> {
    /// The value to show instead of the row's, or nil.
    private(set) var value: Value?

    @ObservationIgnored private var sent = false
    /// The sent value the unsent ``value`` replaced, restored by ``failed()``.
    @ObservationIgnored private var fallback: Value?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private let hold: Duration

    /// - Parameter hold: How long a sent value waits for the row to agree.
    init(hold: Duration) {
        self.hold = hold
    }

    /// The user changed it: show `value` until the send settles.
    func show(_ value: Value) {
        if sent {
            fallback = self.value
        } else if self.value == nil {
            fallback = nil
        }
        self.value = value
        restart()
    }

    /// The change failed or was declined: back to the last value sent, else the row.
    func failed() {
        let previous = fallback
        fallback = nil
        value = previous
        restart()
        if previous != nil { startHold() }
    }

    /// The change went through: keep it until the row agrees or `hold` passes.
    func markSent() {
        guard value != nil else { return }
        fallback = nil
        restart()
        startHold()
    }

    /// A new row: a sent value the row now reports is no longer needed.
    func rowChanged(_ row: Value?) {
        guard sent, let value, row == value else { return }
        clear()
    }

    private func clear() {
        value = nil
        fallback = nil
        restart()
    }

    private func startHold() {
        sent = true
        let mine = generation
        holdTask = Task { [weak self, hold] in
            try? await Task.sleep(for: hold)
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.clear()
        }
    }

    private func restart() {
        generation += 1
        sent = false
        holdTask?.cancel()
        holdTask = nil
    }
}
