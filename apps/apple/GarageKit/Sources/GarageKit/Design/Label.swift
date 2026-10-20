import SwiftUI

/// A section or tile label: label scale (Instrument Sans Medium 11 pt, or 10 pt with `.labelS`),
/// small caps, +12 % tracking, muted.
///
/// Instrument Sans has no small-caps glyphs, so the text is also uppercased: small caps at this size
/// read as capitals, and the `.smallCaps()` request stays in place for a face that has them.
public struct SmallCapsLabel: View {
    private let text: String
    private let scale: TypeScale

    /// - Parameters:
    ///   - text: The label, for example `"CHARGE"`; any case is shown in capitals.
    ///   - scale: `.label` (default) or `.labelS`.
    public init(_ text: String, scale: TypeScale = .label) {
        precondition(scale == .label || scale == .labelS, "SmallCapsLabel takes the label scales only")
        self.text = text
        self.scale = scale
    }

    public var body: some View {
        Text(text)
            .font(scale.font.smallCaps())
            .tracking(scale.trackingPoints)
            .textCase(.uppercase)
            .lineSpacing(scale.lineSpacing)
            .foregroundStyle(Tokens.Colors.muted)
    }
}
