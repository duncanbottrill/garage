import SwiftUI

/// The glass sheet over the map: hero numeral and range, the charge line, the 2×2 tile grid
/// (inside, outside, locks, charge port) and the quick actions, separated by hairlines.
struct StatusSheet: View {
    let model: StatusModel
    let pending: Set<String>
    let actionsEnabled: Bool
    let actions: QuickActions.Actions
    /// iPhone: a grab indicator on top, square to the bottom edge (the glass runs off the screen).
    /// Mac: a floating panel with no grabber.
    let docked: Bool
    /// Extra bottom padding inside the glass (the home-indicator safe area when docked).
    var bottomInset: CGFloat = 0

    var body: some View {
        // The sheet keeps its natural height; when that is more than the layout allows (large
        // Dynamic Type, short windows) the same content scrolls inside the allowed height.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
        .glassSurface(radius: Tokens.Radius.sheet, strength: .strong)
        // Docked, the glass runs one corner radius past the bottom edge so only the top corners show.
        .padding(.bottom, docked ? -Tokens.Radius.sheet : 0)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            if docked {
                GrabIndicator()
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                HeroNumeral(model: model)
                Text(model.chargeLine)
                    .garage(.body)
                    .foregroundStyle(Tokens.Colors.muted)
            }
            Hairline()
            tiles
            Hairline()
            QuickActions(lockState: model.lockState, pending: pending, enabled: actionsEnabled, actions: actions)
            if let caption = model.quickActionsCaption {
                Text(caption)
                    .garage(.caption)
                    .foregroundStyle(Tokens.Colors.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, docked ? Tokens.Space.s : Tokens.Space.xl)
        .padding(.bottom, docked ? Tokens.Space.s + bottomInset + Tokens.Radius.sheet : Tokens.Space.xl)
    }

    private var tiles: some View {
        Grid(horizontalSpacing: Tokens.Space.s, verticalSpacing: Tokens.Space.s) {
            GridRow {
                StatusTile.numeral(
                    title: "Inside", value: model.inside, unit: model.temperatureUnit,
                    caption: model.freshnessCaption(.climate), freshness: model.fieldFreshness(.climate)
                )
                StatusTile.numeral(
                    title: "Outside", value: model.outside, unit: model.temperatureUnit,
                    caption: model.freshnessCaption(.climate), freshness: model.fieldFreshness(.climate)
                )
            }
            GridRow {
                StatusTile.word(
                    title: "Doors", icon: model.lockState == .unlocked ? .lockOpen : .lock, tint: lockTint,
                    word: model.lockLabel, caption: model.freshnessCaption(.body), freshness: model.fieldFreshness(.body)
                )
                StatusTile.word(
                    title: "Charge port", icon: .plug, tint: model.chargePortOpen == true ? Tokens.Colors.accent : Tokens.Colors.muted,
                    word: model.chargePortText, caption: model.freshnessCaption(.charge), freshness: model.fieldFreshness(.charge)
                )
            }
        }
    }

    private var lockTint: Color {
        switch model.lockState {
        case .locked: Tokens.Colors.ink
        case .unlocked: Tokens.Colors.warning
        case .unknown: Tokens.Colors.muted
        }
    }
}
