import SwiftUI

/// The sheet's row of four glass pills: Lock/Unlock, Climate, Charge and Frunk. A pending command
/// shows an accent ring around its pill's icon.
struct QuickActions: View {
    /// What each pill does. The frunk action is expected to ask for confirmation before sending.
    struct Actions {
        var toggleLock: () -> Void = {}
        var openClimate: () -> Void = {}
        var openCharge: () -> Void = {}
        var openFrunk: () -> Void = {}
    }

    let lockState: StatusModel.LockState
    /// ``CommandClient/pending``: names of the commands in flight.
    let pending: Set<String>
    /// False until a car is linked: nothing to send to.
    let enabled: Bool
    let actions: Actions

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            QuickActionPill(
                icon: lockState == .unlocked ? .lockOpen : .lock,
                label: lockState == .locked ? "Unlock" : "Lock",
                isPending: pending.contains(Command.doorLock.name) || pending.contains(Command.doorUnlock.name),
                action: actions.toggleLock
            )
            QuickActionPill(icon: .fan, label: "Climate", isPending: false, action: actions.openClimate)
            QuickActionPill(icon: .zap, label: "Charge", isPending: false, action: actions.openCharge)
            QuickActionPill(icon: .carFront, label: "Frunk", isPending: pending.contains(Command.actuateFrunk.name), action: actions.openFrunk)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// One quick-action pill: glass capsule, icon and label.
struct QuickActionPill: View {
    let icon: Icon.Name
    let label: String
    let isPending: Bool
    let action: () -> Void

    static let height: CGFloat = 44

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.xs) {
                Icon(icon)
                    .foregroundStyle(isPending ? Tokens.Colors.accent : Tokens.Colors.ink)
                    .frame(width: PendingRing.size, height: PendingRing.size)
                    .overlay { if isPending { PendingRing() } }
                Text(label)
                    .garage(.label)
                    .foregroundStyle(Tokens.Colors.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .contentShape(.capsule)
        }
        .buttonStyle(PillButtonStyle())
        .glassSurface(radius: Tokens.Radius.pill)
        .disabled(isPending)
        .accessibilityLabel(label)
        .accessibilityValue(isPending ? "Sending" : "")
    }
}

/// A thin accent arc spinning around a pending pill's icon (still in snapshots).
private struct PendingRing: View {
    /// Just clear of the 18 pt icon.
    static let size: CGFloat = 24

    @Environment(\.statusMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Tokens.Colors.accent, style: StrokeStyle(lineWidth: Icon.strokeWidth, lineCap: .round))
            .frame(width: Self.size, height: Self.size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard motion, !reduceMotion else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityHidden(true)
    }
}

/// Dims the pill while pressed.
private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
