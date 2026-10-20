import Foundation
import Observation

/// Sends one surface's commands (a control sheet, or the Status quick actions) and owns what goes
/// with them: the wake prompt, the error toast and the pending markers.
///
/// Rules:
/// - **Never wakes on its own.** When the row says the car is asleep, or a send throws
///   ``CommandError/asleep``, ``run(_:)`` raises ``isAskingToWake`` and waits. Only ``confirmWake()``
///   (the prompt's Wake button) sends `wake_up`; ``cancelWake()`` gives up with ``Outcome/declined``.
///   Commands that need a wake while the prompt is up share it, and one wake.
/// - After a confirmed wake the original command is sent once, without polling. If it is still
///   asleep, the toast says ``stillWakingMessage``. For ``wakeGrace`` after a wake the row's stale
///   `asleep` does not ask again (the bridge lags the car).
/// - **One command per wire name at a time.** ``CommandClient`` drops a second send of a name that
///   is in flight, so `run` queues it behind the first instead (seat heaters share one name).
/// - Errors other than asleep put their ``CommandError`` copy in ``toast``.
@MainActor
@Observable
public final class CommandRunner {
    /// Sends one command and reports whether it was carried out (``CommandClient/send(_:vin:)``).
    public typealias Send = @MainActor (Command) async throws -> Bool
    /// Wakes the car (``CommandClient/wake(vin:)``).
    public typealias Wake = @MainActor () async throws -> Bool

    /// How a ``run(_:)`` ended.
    public enum Outcome: Sendable, Equatable {
        /// The car carried it out.
        case sent
        /// The client dropped it: the same command was already in flight from another surface.
        case ignored
        /// The car was asleep and the user did not wake it (or no prompt could be shown).
        case declined
        /// It failed; ``toast`` says why.
        case failed
    }

    /// One error message for the toast; a new one replaces the old even with the same text.
    public struct Toast: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let message: String

        public init(message: String) {
            id = UUID()
            self.message = message
        }
    }

    /// The toast after a wake when the car still answers asleep.
    public static let stillWakingMessage = "The car is still waking. Try again in a moment."
    /// How long after a wake the row's `asleep` is not trusted.
    public static let wakeGrace: TimeInterval = 120

    /// True while the wake prompt should be up.
    public private(set) var isAskingToWake = false
    /// Wire names (``Command/name``) of the commands this runner is sending, queueing or holding for
    /// the wake prompt, for the pending rings.
    public internal(set) var pending: Set<String> = []
    /// The latest error, until dismissed.
    public private(set) var toast: Toast?

    /// Whether a ``WakePrompt`` is on screen to ask. Without one, a command that needs a wake is
    /// declined at once rather than left waiting for a prompt nobody can see.
    var hostsPrompt = false

    /// Whether the car is asleep, per its row. Set by the owner after init.
    @ObservationIgnored var isAsleep: @MainActor () -> Bool = { false }

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let wake: Wake
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var activity: [String: Int] = [:]
    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private var lanes: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var promptWaiters: [CheckedContinuation<Task<CommandError?, Never>?, Never>] = []
    @ObservationIgnored private var wakeTask: Task<CommandError?, Never>?
    @ObservationIgnored private var wokeAt: Date?

    /// - Parameters:
    ///   - send: Sends a command (`CommandClient.send(_:vin:)`).
    ///   - wake: Wakes the car (`CommandClient.wake(vin:)`); called only from ``confirmWake()``.
    ///   - now: The clock for ``wakeGrace``.
    public init(send: @escaping Send, wake: @escaping Wake, now: @escaping @MainActor () -> Date = { .now }) {
        self.send = send
        self.wake = wake
        self.now = now
    }

    /// True when sending now would ask to wake the car first.
    public var needsWakePrompt: Bool { isAsleep() && !recentlyWoke }

    /// Sends `command`, asking to wake the car first when it is asleep. See the type's rules.
    @discardableResult
    public func run(_ command: Command) async -> Outcome {
        let name = command.name
        track(name, by: 1)
        defer { track(name, by: -1) }
        await acquire(name)
        defer { release(name) }

        var woke = false
        if needsWakePrompt {
            switch await ensureAwake() {
            case .awake: woke = true
            case .declined: return .declined
            case .failed: return .failed
            }
        }
        while true {
            do {
                return try await send(command) ? .sent : .ignored
            } catch let error as CommandError where error == .asleep {
                if woke || recentlyWoke {
                    show(Self.stillWakingMessage)
                    return .failed
                }
                switch await ensureAwake() {
                case .awake: woke = true
                case .declined: return .declined
                case .failed: return .failed
                }
            } catch let error as CommandError {
                show(error.errorDescription ?? "")
                return .failed
            } catch is CancellationError {
                return .failed
            } catch {
                show(error.localizedDescription)
                return .failed
            }
        }
    }

    /// The prompt's Wake button: sends one `wake_up`, then lets every waiting command go.
    public func confirmWake() {
        guard isAskingToWake else { return }
        isAskingToWake = false
        let task = Task { () -> CommandError? in
            let failure: CommandError?
            do {
                // `false` means a wake is already in flight elsewhere: the car is on its way up.
                _ = try await wake()
                failure = nil
            } catch let error as CommandError {
                failure = error
            } catch {
                failure = .rejected(reason: error.localizedDescription)
            }
            if let error = failure {
                show(error.errorDescription ?? "")
            } else {
                wokeAt = now()
            }
            wakeTask = nil
            return failure
        }
        wakeTask = task
        let waiting = promptWaiters
        promptWaiters = []
        waiting.forEach { $0.resume(returning: task) }
    }

    /// The prompt's Cancel button (or the prompt going away): every waiting command is declined.
    public func cancelWake() {
        isAskingToWake = false
        let waiting = promptWaiters
        promptWaiters = []
        waiting.forEach { $0.resume(returning: nil) }
    }

    /// Clears the toast.
    public func dismissToast() {
        toast = nil
    }

    /// Clears the toast if it is still `id` (an auto-dismiss that a newer toast has not replaced).
    public func dismissToast(id: UUID) {
        if toast?.id == id { toast = nil }
    }

    // MARK: Internals

    private enum WakeResult { case awake, declined, failed }

    private var recentlyWoke: Bool {
        guard let wokeAt else { return false }
        return now().timeIntervalSince(wokeAt) < Self.wakeGrace
    }

    private func ensureAwake() async -> WakeResult {
        let task: Task<CommandError?, Never>?
        if let wakeTask {
            task = wakeTask
        } else {
            guard hostsPrompt else { return .declined }
            task = await withCheckedContinuation { continuation in
                promptWaiters.append(continuation)
                isAskingToWake = true
            }
        }
        guard let task else { return .declined }
        return await task.value == nil ? .awake : .failed
    }

    private func show(_ message: String) {
        toast = Toast(message: message)
    }

    private func track(_ name: String, by delta: Int) {
        let count = (activity[name] ?? 0) + delta
        if count > 0 {
            activity[name] = count
            if !pending.contains(name) { pending.insert(name) }
        } else {
            activity[name] = nil
            pending.remove(name)
        }
    }

    private func acquire(_ name: String) async {
        guard busy.contains(name) else {
            busy.insert(name)
            return
        }
        await withCheckedContinuation { lanes[name, default: []].append($0) }
    }

    private func release(_ name: String) {
        if var queue = lanes[name], !queue.isEmpty {
            let next = queue.removeFirst()
            lanes[name] = queue.isEmpty ? nil : queue
            next.resume() // the lane passes straight to the next command; `busy` stays set
        } else {
            busy.remove(name)
        }
    }
}
