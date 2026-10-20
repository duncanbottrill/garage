import SwiftUI

/// One tile of the Status grid: a small-caps title over the value, with a caption saying how fresh
/// the value is on the same line, trailing (stale captions in the warning colour). When the line is
/// too narrow (large Dynamic Type) the caption drops below the value.
struct StatusTile<Value: View>: View {
    let title: String
    /// Empty when there is no value to qualify.
    let caption: String
    let freshness: Freshness
    @ViewBuilder let value: Value

    /// At least a `numeralM` line tall, growing with Dynamic Type for the word tiles.
    @ScaledMetric(relativeTo: .headline) private var valueHeight = Tokens.Typography.numeralM.size * Tokens.Typography.numeralM.lineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SmallCapsLabel(title)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                    valueRow
                    Spacer(minLength: 0)
                    captionText
                }
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    valueRow
                    captionText
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s)
        .glassSurface(radius: Tokens.Radius.tile)
        .accessibilityElement(children: .combine)
    }

    private var valueRow: some View {
        value
            .fixedSize()
            .frame(minHeight: valueHeight, alignment: .leading)
    }

    @ViewBuilder
    private var captionText: some View {
        if !caption.isEmpty {
            Text(caption)
                .garage(.caption)
                .foregroundStyle(captionColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var captionColor: Color {
        if case .stale = freshness { return Tokens.Colors.warning }
        return Tokens.Colors.muted
    }
}

extension StatusTile where Value == AnyView {
    /// A temperature (or other number) tile: the value in `numeralM` with its unit, or a dash with no caption.
    static func numeral(title: String, value: Double?, unit: String, caption: String, freshness: Freshness) -> StatusTile {
        let content = if let value {
            AnyView(Numeral(value: value, unit: unit, scale: .numeralM))
        } else {
            AnyView(Text(verbatim: StatusModel.placeholder).garage(.numeralM).foregroundStyle(Tokens.Colors.muted))
        }
        return StatusTile(title: title, caption: value == nil ? "" : caption, freshness: freshness) { content }
    }

    /// A state tile (locks, charge port): an icon and a word in the title scale; a dash has no caption.
    static func word(title: String, icon: Icon.Name, tint: Color, word: String, caption: String, freshness: Freshness) -> StatusTile {
        let missing = word == StatusModel.placeholder
        let content = AnyView(
            HStack(spacing: Tokens.Space.s) {
                Icon(icon).foregroundStyle(tint)
                Text(word)
                    .garage(.title)
                    .foregroundStyle(missing ? Tokens.Colors.muted : Tokens.Colors.ink)
            }
        )
        return StatusTile(title: title, caption: missing ? "" : caption, freshness: freshness) { content }
    }
}
