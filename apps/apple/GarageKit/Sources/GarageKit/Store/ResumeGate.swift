import Synchronization

/// Resumes one continuation exactly once, with the value of whichever caller gets there first (an
/// Observation change, a timer or a task cancellation); a value fired before the continuation is
/// armed is delivered as soon as it is.
final class ResumeGate<Value: Sendable>: Sendable {
    private enum State: Sendable { case idle, armed(CheckedContinuation<Value, Never>), fired(Value), done }
    private let state = Mutex<State>(.idle)

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        let early = state.withLock { state -> Value? in
            if case let .fired(value) = state {
                state = .done
                return value
            }
            state = .armed(continuation)
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func fire(_ value: Value) {
        let armed = state.withLock { state -> CheckedContinuation<Value, Never>? in
            switch state {
            case let .armed(continuation):
                state = .done
                return continuation
            case .idle:
                state = .fired(value)
                return nil
            case .fired, .done:
                return nil
            }
        }
        armed?.resume(returning: value)
    }
}
