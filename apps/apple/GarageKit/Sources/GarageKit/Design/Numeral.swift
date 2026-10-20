import SwiftUI

/// A number that rolls digit by digit when it changes, with an optional muted unit in the label scale.
///
/// Numeral scales set it in Big Shoulders Display; any other scale sets it in Instrument Sans with
/// tabular figures, for numbers in rows and columns.
public struct Numeral: View {
    private let value: Double
    private let unit: String?
    private let scale: TypeScale
    private let fractionDigits: Int

    /// - Parameters:
    ///   - value: The number shown and animated.
    ///   - unit: A unit after the number, such as `"%"` or `"mi"`, shown muted in the label scale.
    ///   - scale: The type scale (`.numeralL` by default).
    ///   - fractionDigits: Digits after the decimal point (0 by default).
    public init(value: Double, unit: String? = nil, scale: TypeScale = .numeralL, fractionDigits: Int = 0) {
        self.value = value
        self.unit = unit
        self.scale = scale
        self.fractionDigits = fractionDigits
    }

    public var body: some View {
        // One Text for number and unit: a single line box at the scale's line height, the unit on the
        // number's baseline. (An HStack of two Texts inflates the line box past the token height.)
        Text("\(number)\(unitRun)")
            .garageLineBox(scale)
            .contentTransition(.numericText(value: value))
            .animation(.snappy, value: value)
    }

    private var number: Text {
        Text(value, format: .number.precision(.fractionLength(fractionDigits)))
            .garageText(scale, tabular: true)
            .foregroundStyle(Tokens.Colors.ink)
    }

    /// A word space in the label face (about 4 pt with its tracking) and the unit, muted; empty without a unit.
    private var unitRun: Text {
        guard let unit else { return Text(verbatim: "") }
        return Text(verbatim: " \(unit)")
            .garageText(.label)
            .foregroundStyle(Tokens.Colors.muted)
    }
}
