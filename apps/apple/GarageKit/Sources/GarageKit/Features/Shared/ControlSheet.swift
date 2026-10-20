import SwiftUI

/// The frame the Climate and Charge sheets share: Status's strong glass with the sheet radius, our own
/// grab indicator (the system one is hidden), a small-caps title with a close button, the Tailscale
/// banner while the proxy is unreachable (controls disabled), the error toast at the bottom, and the
/// wake prompt.
///
/// Present it as a system sheet; the presentation modifiers are applied here: medium and large
/// detents, a clear presentation background (the glass is the background) and no system grabber.
struct ControlSheet<Content: View>: View {
    let title: String
    let runner: CommandRunner
    /// False while the proxy is unreachable: the banner shows and every control is disabled.
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                #if os(iOS)
                GrabIndicator()
                #endif
                header
                if !enabled {
                    StatusBanner(banner: .tailscaleOff, message: StatusModel.message(for: .tailscaleOff, timeZone: .current)) {
                        openURL(TailscaleLink.destination(installed: TailscaleLink.isInstalled()))
                    }
                }
                VStack(alignment: .leading, spacing: Tokens.Space.l, content: content)
                    .disabled(!enabled)
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.top, topPadding)
            .padding(.bottom, Tokens.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassSurface(radius: Tokens.Radius.sheet, strength: .strong)
        .overlay(alignment: .bottom) {
            if let toast = runner.toast {
                CommandToast(message: toast.message) { runner.dismissToast() }
                    .padding(Tokens.Space.l)
            }
        }
        .animation(.snappy, value: runner.toast)
        .autoDismissingToast(runner)
        .wakePrompt(runner)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 560, idealHeight: 620)
        #endif
        .presentationDetents([.medium, .large])
        .presentationBackground(.clear)
        .presentationDragIndicator(.hidden)
    }

    private var topPadding: CGFloat {
        #if os(iOS)
        Tokens.Space.s
        #else
        Tokens.Space.xl
        #endif
    }

    private var header: some View {
        HStack {
            SmallCapsLabel(title)
            Spacer(minLength: Tokens.Space.s)
            Button { dismiss() } label: {
                Icon(.x)
                    .foregroundStyle(Tokens.Colors.ink)
                    .frame(width: 32, height: 32)
                    .glassCapsule()
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        // The close button's 44 pt target overhangs its 32 pt glass; keep the glass on the padding edge.
        .padding(.trailing, -(44 - 32) / 2)
        .padding(.vertical, -(44 - 32) / 2)
    }
}

/// The sheets' grab indicator: a short muted capsule, centred.
struct GrabIndicator: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Tokens.Colors.muted.opacity(Tokens.Opacity.accentStroke))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// An 18 pt icon in a 22 pt box with Status's accent ring around it while its command is pending.
struct PendingIcon: View {
    let name: Icon.Name
    let isPending: Bool

    init(_ name: Icon.Name, isPending: Bool) {
        self.name = name
        self.isPending = isPending
    }

    var body: some View {
        Icon(name)
            .frame(width: PendingRing.size, height: PendingRing.size)
            .overlay { if isPending { PendingRing() } }
    }
}

/// A sheet's primary toggle: a tall glass capsule with an icon and a title-scale label, tinted
/// (fill at the accent-fill opacity, edge at the accent-stroke opacity) while `active`.
struct ControlPill: View {
    let icon: Icon.Name
    let label: String
    let active: Bool
    var tint: Color = Tokens.Colors.accent
    let isPending: Bool
    let action: () -> Void

    static let height: CGFloat = 52

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s) {
                PendingIcon(icon, isPending: isPending)
                Text(label)
                    .garage(.title)
                    .lineLimit(1)
            }
            .foregroundStyle(active ? tint : Tokens.Colors.ink)
            .padding(.horizontal, Tokens.Space.l)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .contentShape(.capsule)
        }
        .buttonStyle(DimWhenPressed())
        .background {
            if active { Capsule(style: .continuous).fill(tint.opacity(Tokens.Opacity.accentFill)) }
        }
        .overlay {
            if active { Capsule(style: .continuous).strokeBorder(tint.opacity(Tokens.Opacity.accentStroke), lineWidth: 1) }
        }
        .glassCapsule()
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(isPending)
        .accessibilityValue(isPending ? "Sending" : "")
    }
}

/// One control row: a muted icon (with the pending ring), a body-scale title and the control trailing.
/// Dims as a whole while disabled.
struct ControlRow<Trailing: View>: View {
    let icon: Icon.Name
    let title: String
    var isPending = false
    @ViewBuilder let trailing: Trailing

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            PendingIcon(icon, isPending: isPending)
                .foregroundStyle(Tokens.Colors.muted)
            Text(title)
                .garage(.body)
                .foregroundStyle(Tokens.Colors.ink)
                .lineLimit(1)
                .accessibilityHidden(true)
            Spacer(minLength: Tokens.Space.s)
            trailing
        }
        .frame(minHeight: 44)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// An on/off switch in the glass language: a capsule track (hairline when off, accent fill and edge
/// when on) with a knob. VoiceOver sees a standard toggle labelled `label`.
struct GarageSwitch: View {
    let label: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    static let size = CGSize(width: 46, height: 26)

    var body: some View {
        Button { onChange(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? Tokens.Colors.accent.opacity(Tokens.Opacity.accentFill) : Color.white.opacity(Tokens.Opacity.hairline))
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? Tokens.Colors.accent.opacity(Tokens.Opacity.accentStroke) : Color.white.opacity(Tokens.Opacity.hairline), lineWidth: 1)
                Circle()
                    .fill(isOn ? Tokens.Colors.accent : Tokens.Colors.muted)
                    .frame(width: Self.size.height - 6, height: Self.size.height - 6)
                    .padding(3)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isOn)
        .accessibilityRepresentation {
            Toggle(label, isOn: Binding(get: { isOn }, set: { onChange($0) }))
        }
    }
}

/// A 36 pt glass circle holding one icon, inside a 44 pt target.
struct GlassIconButton: View {
    let icon: Icon.Name
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Icon(icon)
                .foregroundStyle(Tokens.Colors.ink)
                .frame(width: 36, height: 36)
                .glassCapsule()
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(DimWhenPressed())
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Dims a control while pressed.
struct DimWhenPressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
