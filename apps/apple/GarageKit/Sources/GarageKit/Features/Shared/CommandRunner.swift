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
/// - After a confirmed wake the runner waits for the row to say the car is online (`awaitAwake`,
///   the vehicle store following Realtime for up to ``onlineWait``; no polling and nothing billed),
///   then sends the original command once. If the row never flips, the command still goes once; an
///   asleep answer then reads as ``stillWakingMessage``. For ``wakeGrace`` after a wake the row's
///   stale `asleep` does not ask again (the bridge lags the car); a wake confirmed on another
///   surface, or from More, counts (``lastWakeElsewhere``). A command arriving during that wait
///   joins it rather than going out early.
/// - **Cancel means no.** It declines every command waiting on the prompt and every command queued
///   behind one, and for ``declineWindow`` any further command that would need a wake is declined
///   without asking (so a coalesced follow-up cannot raise the prompt again). It also calls off a
///   wait for the car to come online: the woken commands are declined, never sent late.
/// - A command that needs a wake while no ``WakePrompt`` is on screen, or while another surface covers
///   it (``isCovered``: a control sheet over Status), is declined, never woken.
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
    /// Waits for the row to say the car is online after a wake (``VehicleStore/waitUntilAwake(timeout:)``
    /// with ``onlineWait``); true once it is, false when it gave up waiting.
    public typealias AwaitAwake = @MainActor () async -> Bool

    /// How long a woken command waits for the row to say the car is online before it is sent anyway.
    public static let onlineWait: Duration = .seconds(30)

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
    /// How long after a confirmed wake the row's `asleep` is not trusted, in seconds.
    ///
    /// The grace only skips the prompt; it can never send `wake_up` (only ``confirmWake()`` does).
    /// If the car falls back asleep inside the window, its commands fail with the
    /// ``stillWakingMessage`` toast and the user waits out the rest of the two minutes before the
    /// prompt is offered again.
    public static let wakeGrace: TimeInterval = 120
    /// How long after a Cancel commands that need a wake are declined without asking, in seconds.
    public static let declineWindow: TimeInterval = 1

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

    /// Whether another surface covers this runner's prompt (a Climate or Charge sheet over Status), so
    /// the prompt cannot be seen: commands that need a wake are declined instead of waiting on it, and
    /// covering declines any already waiting.
    var isCovered = false {
        didSet { if isCovered, !oldValue { cancelWake() } }
    }

    /// Whether the car is asleep, per its row. Set by the owner after init.
    @ObservationIgnored var isAsleep: @MainActor () -> Bool = { false }

    /// When the car was last woken through any surface (``CommandClient/lastWakeAt``), so the
    /// ``wakeGrace`` after a wake confirmed in a sheet, or from More, holds here too. Set by the
    /// owner after init; nil when nothing outside this runner can wake the car.
    @ObservationIgnored var lastWakeElsewhere: @MainActor () -> Date? = { nil }

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let wake: Wake
    @ObservationIgnored private let awaitAwake: AwaitAwake
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var activity: [String: Int] = [:]
    @ObservationIgnored private var busy: Set<String> = []
    @ObservationIgnored private var lanes: [String: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var promptWaiters: [CheckedContinuation<Task<WakeResult, Never>?, Never>] = []
    @ObservationIgnored private var wakeTask: Task<WakeResult, Never>?
    /// The wait for the row to say online after a wake, while it runs; cancelled by ``cancelWake()``.
    @ObservationIgnored private var onlineWait: Task<Bool, Never>?
    @ObservationIgnored private var wokeAt: Date?
    @ObservationIgnored private var declinedAt: Date?
    /// Bumped by each Cancel; a command queued before it is declined when its turn comes.
    @ObservationIgnored private var declineEpoch = 0

    /// - Parameters:
    ///   - send: Sends a command (`CommandClient.send(_:vin:)`).
    ///   - wake: Wakes the car (`CommandClient.wake(vin:)`); called only from ``confirmWake()``.
    ///   - awaitAwake: Waits for the row to say the car is online after that wake; the default does
    ///     not wait (fixed screens and tests without a store).
    ///   - now: The clock for ``wakeGrace``.
    public init(
        send: @escaping Send,
        wake: @escaping Wake,
        awaitAwake: @escaping AwaitAwake = { true },
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.send = send
        self.wake = wake
        self.awaitAwake = awaitAwake
        self.now = now
    }

    /// True when sending now would ask to wake the car first.
    public var needsWakePrompt: Bool { isAsleep() && !recentlyWoke }

    /// Sends `command`, asking to wake the car first when it is asleep. See the type's rules.
    @discardableResult
    public func run(_ command: Command) async -> Outcome {
        let name = command.name
        let epoch = declineEpoch
        track(name, by: 1)
        defer { track(name, by: -1) }
        await acquire(name)
        defer { release(name) }
        // Queued behind a command whose wake the user cancelled: that cancel covers this one too.
        if declineEpoch != epoch { return .declined }

        var woke = false
        // A wake in progress (sent, or waiting for the car to come online) is joined, not skipped:
        // the grace already hides the prompt, but the car is not up yet.
        if needsWakePrompt || wakeTask != nil {
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

    /// The prompt's Wake button: sends one `wake_up`, waits for the row to say the car is online
    /// (``onlineWait`` at most), then lets every waiting command go.
    public func confirmWake() {
        guard isAskingToWake else { return }
        isAskingToWake = false
        let task = Task { () -> WakeResult in
            do {
                // `false` means a wake is already in flight elsewhere: the car is on its way up.
                _ = try await wake()
            } catch let error as CommandError {
                show(error.errorDescription ?? "")
                wakeTask = nil
                return .failed
            } catch {
                show(error.localizedDescription)
                wakeTask = nil
                return .failed
            }
            wokeAt = now()
            // The wait is its own task so Cancel, a covering sheet or the host going away can call
            // it off. Awake or timed out, the commands then go once; called off, they are declined.
            let wait = Task { await awaitAwake() }
            onlineWait = wait
            _ = await wait.value
            onlineWait = nil
            wakeTask = nil
            return wait.isCancelled ? .declined : .awake
        }
        wakeTask = task
        let waiting = promptWaiters
        promptWaiters = []
        waiting.forEach { $0.resume(returning: task) }
    }

    /// The prompt's Cancel button (or the prompt going away): every waiting command is declined,
    /// every command queued behind one too, and for ``declineWindow`` nothing asks again.
    public func cancelWake() {
        guard isAskingToWake || !promptWaiters.isEmpty || onlineWait != nil else { return }
        isAskingToWake = false
        declinedAt = now()
        declineEpoch += 1
        onlineWait?.cancel()
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
        guard let latest = [wokeAt, lastWakeElsewhere()].compactMap({ $0 }).max() else { return false }
        return now().timeIntervalSince(latest) < Self.wakeGrace
    }

    private var recentlyDeclined: Bool {
        guard let declinedAt else { return false }
        return now().timeIntervalSince(declinedAt) < Self.declineWindow
    }

    private func ensureAwake() async -> WakeResult {
        let task: Task<WakeResult, Never>?
        if let wakeTask {
            task = wakeTask
        } else {
            guard hostsPrompt, !isCovered, !recentlyDeclined else { return .declined }
            task = await withCheckedContinuation { continuation in
                promptWaiters.append(continuation)
                isAskingToWake = true
            }
        }
        guard let task else { return .declined }
        return await task.value
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
