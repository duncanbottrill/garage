import CoreText
import SwiftUI

/// The nine steps of the Garage type scale, each backed by a generated `Tokens.Typography` style.
///
/// The four numeral scales are the only ones set in Big Shoulders Display (SemiBold, 22 pt and up);
/// everything else is Instrument Sans.
public enum TypeScale: CaseIterable, Sendable {
    case numeralHero, numeralL, numeralM, numeralS, title, body, caption, label, labelS

    /// The generated token for this scale.
    public var style: Tokens.TextStyle {
        switch self {
        case .numeralHero: Tokens.Typography.numeralHero
        case .numeralL: Tokens.Typography.numeralL
        case .numeralM: Tokens.Typography.numeralM
        case .numeralS: Tokens.Typography.numeralS
        case .title: Tokens.Typography.title
        case .body: Tokens.Typography.body
        case .caption: Tokens.Typography.caption
        case .label: Tokens.Typography.label
        case .labelS: Tokens.Typography.labelS
        }
    }

    /// True for the four numeral scales, the only ones set in the display face.
    public var isDisplay: Bool {
        switch self {
        case .numeralHero, .numeralL, .numeralM, .numeralS: true
        case .title, .body, .caption, .label, .labelS: false
        }
    }

    /// The SwiftUI font for this scale: the display face for numerals, the UI face for everything else.
    public var font: Font {
        isDisplay ? GarageFont.display(self) : GarageFont.ui(self)
    }

    /// Letter spacing in points: the token's tracking is a fraction of the size (0.12 = +12 %).
    var trackingPoints: CGFloat { style.tracking * style.size }

    /// The token line height (`lineHeight × size`) for SwiftUI's `lineHeight(_:)`. Display scales are a
    /// fixed size, so they get exact points. UI scales get `.multiple(factor:)` with the token multiplier
    /// itself: SwiftUI multiplies the font's point size (measured: 1.4 on 14 pt renders a 19.6 pt line),
    /// so the line keeps tracking the Dynamic Type size.
    public var lineHeight: AttributedString.LineHeight {
        isDisplay ? .exact(points: style.lineHeight * style.size) : .multiple(factor: style.lineHeight)
    }

    /// The face's own line height at this size (ascent + descent + leading), from the bundled font.
    var defaultLineHeight: CGFloat {
        GarageKit.registerFonts()
        let font = CTFontCreateWithName(style.family as CFString, style.size, nil)
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    /// How far up the glyphs move inside a display scale's line box. With an exact line height below the
    /// face's own, SwiftUI keeps the baseline an ascent below the top and trims only the bottom, so the
    /// glyphs hang out of the box (13 pt for the hero). Figma takes half the reduction off each edge;
    /// moving the glyphs up by that half matches it. Zero for the UI scales.
    var halfLeadingShift: CGFloat {
        guard isDisplay else { return 0 }
        return max(0, (defaultLineHeight - style.lineHeight * style.size) / 2)
    }

    /// The Dynamic Type style a UI scale grows with.
    fileprivate var relativeTextStyle: Font.TextStyle {
        switch self {
        case .title: .headline
        case .body: .body
        case .caption: .caption
        case .label, .labelS: .caption2
        case .numeralHero, .numeralL, .numeralM, .numeralS: .largeTitle
        }
    }
}

/// Fonts for the Garage type scale. Prefer `Text.garage(_:tabular:)`, which also applies tracking,
/// line spacing and tabular figures.
public enum GarageFont {
    /// Big Shoulders Display SemiBold for a numeral scale, at a fixed size so it never drops below 22 pt.
    /// - Precondition: `scale.isDisplay`; the display face is for numerals only.
    public static func display(_ scale: TypeScale) -> Font {
        precondition(scale.isDisplay, "GarageFont.display is for the numeral scales only, not \(scale)")
        GarageKit.registerFonts()
        let style = scale.style
        return Font.custom(style.family, fixedSize: style.size).weight(style.weight)
    }

    /// Instrument Sans for a UI scale, scaling with Dynamic Type from the token size.
    /// - Precondition: `!scale.isDisplay`; numerals use `display(_:)`.
    public static func ui(_ scale: TypeScale) -> Font {
        precondition(!scale.isDisplay, "GarageFont.ui is for the UI scales, not the numeral scale \(scale)")
        GarageKit.registerFonts()
        let style = scale.style
        return Font.custom(style.family, size: style.size, relativeTo: scale.relativeTextStyle).weight(style.weight)
    }
}

extension Text {
    /// Sets this text in a Garage type scale: family, size and weight from the token, tracking as a
    /// fraction of the size, the token line height, and tabular figures for the numeral scales or
    /// wherever `tabular` is true (any column of numbers).
    public func garage(_ scale: TypeScale, tabular: Bool = false) -> some View {
        garageText(scale, tabular: tabular).garageLineBox(scale)
    }

    /// Everything `garage(_:tabular:)` applies except the line height, still a `Text`, so styled runs
    /// can be interpolated into one `Text` that then takes a single line height.
    func garageText(_ scale: TypeScale, tabular: Bool = false) -> Text {
        let styled = font(scale.font).tracking(scale.trackingPoints)
        return scale.isDisplay || tabular ? styled.monospacedDigit() : styled
    }
}

extension View {
    /// Applies a scale's line height and, for the display scales, the half-leading correction: glyphs
    /// drawn `halfLeadingShift` higher, with the text baselines moved to match so baseline alignment
    /// still lines up with the drawn glyphs.
    nonisolated func garageLineBox(_ scale: TypeScale) -> some View {
        let shift = scale.halfLeadingShift
        return lineHeight(scale.lineHeight)
            .offset(y: -shift)
            .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] - shift }
            .alignmentGuide(.lastTextBaseline) { $0[.lastTextBaseline] - shift }
    }
}
