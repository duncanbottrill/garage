import Foundation
@testable import GarageKit

/// Stands in for ``CommandClient`` in the sheet model tests: records every command and wake, can
/// hold sends in flight until ``release()``, and can fail the next sends with an error.
@MainActor
final class FakeCar {
    private(set) var sent: [Command] = []
    /// When each of ``sent`` arrived.
    private(set) var sentAt: [ContinuousClock.Instant] = []
    private(set) var wakes = 0
    /// While true, each send is recorded and then waits for ``release()``.
    var holding = false
    /// The next this-many sends throw ``CommandError/asleep``.
    var asleepFailures = 0
    /// Every send throws this (after the asleep failures) while set.
    var failure: CommandError?
    private var held: [CheckedContinuation<Void, Never>] = []

    var send: @MainActor (Command) async throws -> Bool {
        { [unowned self] command in try await self.perform(command) }
    }

    var wake: @MainActor () async throws -> Bool {
        { [unowned self] in
            self.wakes += 1
            return true
        }
    }

    /// Sends recorded but not yet released.
    var heldCount: Int { held.count }

    func release() {
        holding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    private func perform(_ command: Command) async throws -> Bool {
        sent.append(command)
        sentAt.append(.now)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        if asleepFailures > 0 {
            asleepFailures -= 1
            throw CommandError.asleep
        }
        if let failure { throw failure }
        return true
    }
}

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    var now: Date

    init(_ now: Date = Date(timeIntervalSince1970: 1_792_506_600)) {
        self.now = now
    }

    var read: @MainActor () -> Date { { [unowned self] in self.now } }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes; returns whether it held.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

extension VehicleState {
    /// A row for an awake car, with the given sleep state.
    static func awake(_ sleepState: String = "online") -> VehicleState {
        var state = VehicleState()
        state.sleepState = sleepState
        return state
    }
}
