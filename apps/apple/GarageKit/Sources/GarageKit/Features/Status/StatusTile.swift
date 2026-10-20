import SwiftUI

/// One tile of the Status grid: a small-caps title, a value one numeral-M line tall, and a caption
/// saying how fresh the value is (stale captions in the warning colour).
struct StatusTile<Value: View>: View {
    let title: String
    let caption: String
    let freshness: Freshness
    @ViewBuilder let value: Value

    /// The value row is the height of a `numeralM` line, so word tiles and number tiles line up.
    static var valueHeight: CGFloat { Tokens.Typography.numeralM.size * Tokens.Typography.numeralM.lineHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SmallCapsLabel(title)
            value
                .frame(height: Self.valueHeight, alignment: .leading)
            Text(caption)
                .garage(.caption)
                .foregroundStyle(captionColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.m)
        .glassSurface(radius: Tokens.Radius.tile)
        .accessibilityElement(children: .combine)
    }

    private var captionColor: Color {
        if case .stale = freshness { return Tokens.Colors.warning }
        return Tokens.Colors.muted
    }
}

extension StatusTile where Value == AnyView {
    /// A temperature (or other number) tile: the value in `numeralM` with its unit, or a dash.
    static func numeral(title: String, value: Double?, unit: String, caption: String, freshness: Freshness) -> StatusTile {
        let content = if let value {
            AnyView(Numeral(value: value, unit: unit, scale: .numeralM))
        } else {
            AnyView(Text(verbatim: StatusModel.placeholder).garage(.numeralM).foregroundStyle(Tokens.Colors.muted))
        }
        return StatusTile(title: title, caption: caption, freshness: freshness) { content }
    }

    /// A state tile (locks, charge port): an icon and a word in the title scale.
    static func word(title: String, icon: Icon.Name, tint: Color, word: String, caption: String, freshness: Freshness) -> StatusTile {
        let content = AnyView(
            HStack(spacing: Tokens.Space.s) {
                Icon(icon).foregroundStyle(tint)
                Text(word)
                    .garage(.title)
                    .foregroundStyle(word == StatusModel.placeholder ? Tokens.Colors.muted : Tokens.Colors.ink)
            }
        )
        return StatusTile(title: title, caption: caption, freshness: freshness) { content }
    }
}
