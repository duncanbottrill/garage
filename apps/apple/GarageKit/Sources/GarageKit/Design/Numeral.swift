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
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
            Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                .garage(scale, tabular: true)
                .foregroundStyle(Tokens.Colors.ink)
                .contentTransition(.numericText(value: value))
            if let unit {
                Text(unit)
                    .garage(.label)
                    .foregroundStyle(Tokens.Colors.muted)
            }
        }
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}
