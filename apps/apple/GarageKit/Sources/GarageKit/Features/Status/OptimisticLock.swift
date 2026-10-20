import Foundation
import Observation

/// The lock state a lock or unlock command is heading for, shown before the car confirms it.
///
/// - ``begin(target:)`` flips the overlay at once; while that intent is unsent a second tap is
///   ignored (returns nil), so a double tap cannot flip the icon back.
/// - ``failed(_:)`` reverts at once (the caller shows why).
/// - ``sent(_:rowLocked:)`` marks it sent, clears it if the row already agrees, and otherwise waits
///   up to ``hold`` for ``rowChanged(locked:)`` to report a matching row before giving up.
@MainActor
@Observable
final class OptimisticLock {
    /// How long a sent intent waits for the row to confirm it.
    static let defaultHold: Duration = .seconds(30)

    /// The overlay: wins over `vehicle_state.locked` while set.
    private(set) var target: Bool?

    @ObservationIgnored private var current: Intent?
    @ObservationIgnored private let hold: Duration

    /// One tap's intent; pass it back to ``failed(_:)`` or ``sent(_:rowLocked:)``.
    struct Intent: Equatable, Sendable {
        fileprivate let id = UUID()
        let target: Bool
        fileprivate(set) var sent = false
    }

    /// - Parameter hold: How long a sent intent may wait for a confirming row.
    init(hold: Duration = OptimisticLock.defaultHold) {
        self.hold = hold
    }

    /// Starts an intent towards `target`, or returns nil while an earlier one is still unsent.
    func begin(target: Bool) -> Intent? {
        if let current, !current.sent { return nil }
        let intent = Intent(target: target)
        current = intent
        self.target = target
        return intent
    }

    /// The command failed or was not sent: revert.
    func failed(_ intent: Intent) {
        guard current?.id == intent.id else { return }
        clear()
    }

    /// The command went through. Clears at once when `rowLocked` already matches; otherwise waits
    /// for a matching row (``rowChanged(locked:)``) or ``hold``, whichever comes first.
    func sent(_ intent: Intent, rowLocked: Bool?) async {
        guard current?.id == intent.id else { return }
        current?.sent = true
        rowChanged(locked: rowLocked)
        try? await Task.sleep(for: hold)
        if current?.id == intent.id { clear() }
    }

    /// A new row: drops a sent intent the row now agrees with.
    func rowChanged(locked: Bool?) {
        guard let current, current.sent, locked == current.target else { return }
        clear()
    }

    private func clear() {
        current = nil
        target = nil
    }
}
