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
        // One style for the whole row, so the pills match: icon beside the label; icon above it;
        // the icon alone (still labelled for VoiceOver) on narrow phones at large text sizes.
        ViewThatFits(in: .horizontal) {
            row(.beside)
            row(.stacked)
            row(.iconOnly)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    /// The lock pill's longer label. Each candidate row is measured with it, so the row picks the same
    /// style for Lock and Unlock and never changes layout when the car locks.
    static let widestLockLabel = "Unlock"

    private var lockLabel: String { lockState == .locked ? "Unlock" : "Lock" }

    /// A candidate row as wide as its widest-label version: the visible row is laid out in that width
    /// (its pills fill it either way), and `ViewThatFits` compares the widest version.
    @ViewBuilder
    private func row(_ style: QuickActionPill.Style) -> some View {
        if lockLabel == Self.widestLockLabel {
            row(style, lockLabel: lockLabel)
        } else {
            ZStack {
                row(style, lockLabel: Self.widestLockLabel)
                    .hidden()
                    .accessibilityHidden(true)
                row(style, lockLabel: lockLabel)
            }
        }
    }

    private func row(_ style: QuickActionPill.Style, lockLabel: String) -> some View {
        HStack(spacing: Tokens.Space.s) {
            QuickActionPill(
                iconName: lockState == .unlocked ? .lockOpen : .lock,
                label: lockLabel,
                style: style,
                isPending: pending.contains(Command.doorLock.name) || pending.contains(Command.doorUnlock.name),
                action: actions.toggleLock
            )
            QuickActionPill(iconName: .fan, label: "Climate", style: style, isPending: false, action: actions.openClimate)
            QuickActionPill(iconName: .zap, label: "Charge", style: style, isPending: false, action: actions.openCharge)
            QuickActionPill(iconName: .carFront, label: "Frunk", style: style, isPending: pending.contains(Command.actuateFrunk.name), action: actions.openFrunk)
        }
    }
}

/// One quick-action pill: glass capsule, icon and label (at least 44 pt tall).
struct QuickActionPill: View {
    /// How icon and label share the pill.
    enum Style {
        case beside, stacked, iconOnly
    }

    let iconName: Icon.Name
    let label: String
    let style: Style
    let isPending: Bool
    let action: () -> Void

    static let height: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Group {
                switch style {
                case .beside:
                    // The ring sits 2 pt outside the icon; 5 pt more keeps it clear of the label.
                    HStack(spacing: Tokens.Space.xs + 1) {
                        icon
                        labelText
                    }
                case .stacked:
                    VStack(spacing: Tokens.Space.xs) {
                        icon
                        labelText
                    }
                    .padding(.vertical, Tokens.Space.xs)
                case .iconOnly:
                    icon
                }
            }
            .padding(.horizontal, Tokens.Space.xs)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .contentShape(.capsule)
        }
        .buttonStyle(PillButtonStyle())
        .glassCapsule()
        .disabled(isPending)
        .accessibilityLabel(label)
        .accessibilityValue(isPending ? "Sending" : "")
    }

    private var icon: some View {
        Icon(self.iconName)
            .foregroundStyle(Tokens.Colors.ink)
            .frame(width: PendingRing.size, height: PendingRing.size)
            .overlay { if isPending { PendingRing() } }
    }

    private var labelText: some View {
        Text(label)
            .garage(.label)
            .foregroundStyle(Tokens.Colors.ink)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A thin accent arc spinning around a pending pill's icon (still in snapshots).
struct PendingRing: View {
    /// 2 pt clear of the 18 pt icon all round.
    static let size: CGFloat = 22

    @Environment(\.statusMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Tokens.Colors.accent.opacity(Tokens.Opacity.accentStroke), style: StrokeStyle(lineWidth: 1, lineCap: .round))
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
