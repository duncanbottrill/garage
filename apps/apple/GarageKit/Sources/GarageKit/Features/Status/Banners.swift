import SwiftUI

/// A pill-shaped glass strip with an icon and one line of copy: the Status banners and command toasts.
/// With an action, the whole strip is a button; ``showsChevron`` marks one that navigates.
struct NoticeStrip: View {
    let icon: Icon.Name
    let tint: Color
    let message: String
    /// Ends the strip in a chevron: the action goes somewhere (Tailscale), not just dismisses.
    var showsChevron = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content(chevron: showsChevron) }
                .buttonStyle(.plain)
        } else {
            content(chevron: showsChevron)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: Tokens.Space.s) {
            Icon(icon).foregroundStyle(tint)
            Text(message)
                .garage(.body)
                .foregroundStyle(Tokens.Colors.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if chevron {
                Icon(.chevronRight).foregroundStyle(Tokens.Colors.muted)
            }
        }
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.m)
        .glassCapsule(strength: .strong)
        .accessibilityElement(children: .combine)
    }
}

/// The one Status banner (``StatusModel/Banner``), pinned above the sheet.
struct StatusBanner: View {
    let banner: StatusModel.Banner
    let message: String
    /// Opens Tailscale (`tailscale://`, or its App Store page when it is not installed).
    let onOpenTailscale: () -> Void

    var body: some View {
        switch banner {
        case .telemetryPaused:
            NoticeStrip(icon: .wifiOff, tint: Tokens.Colors.warning, message: message)
        case .budget(.minimal):
            NoticeStrip(icon: .gauge, tint: Tokens.Colors.warning, message: message)
        case .budget:
            NoticeStrip(icon: .gauge, tint: Tokens.Colors.muted, message: message)
        case .tailscaleOff:
            NoticeStrip(icon: .circleAlert, tint: Tokens.Colors.warning, message: message, showsChevron: true, action: onOpenTailscale)
                .accessibilityHint("Opens Tailscale")
        }
    }
}
