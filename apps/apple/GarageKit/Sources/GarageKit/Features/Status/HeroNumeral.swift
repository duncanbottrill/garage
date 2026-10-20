import SwiftUI

/// The sheet's hero row: state of charge in the hero numeral with "%", and the range in `numeralS`
/// with its unit, right-aligned on the same baseline. Dashes stand in for values not reported yet.
struct HeroNumeral: View {
    let model: StatusModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.l) {
            if let soc = model.soc {
                Numeral(value: soc, unit: "%", scale: .numeralHero)
            } else {
                placeholder(.numeralHero)
            }
            Spacer(minLength: 0)
            if let range = model.range {
                Numeral(value: range, unit: model.rangeUnit, scale: .numeralS)
            } else {
                placeholder(.numeralS)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func placeholder(_ scale: TypeScale) -> some View {
        Text(verbatim: StatusModel.placeholder)
            .garage(scale)
            .foregroundStyle(Tokens.Colors.muted)
    }

    private var accessibilityText: String {
        let charge = model.soc == nil ? "Charge not reported" : "Charge \(model.socText) percent"
        let range = model.range == nil ? "range not reported" : "range \(model.rangeText) \(model.rangeUnit == "mi" ? "miles" : "kilometres")"
        return "\(charge), \(range)"
    }
}
