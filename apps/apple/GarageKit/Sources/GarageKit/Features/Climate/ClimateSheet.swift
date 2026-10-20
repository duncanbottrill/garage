import SwiftUI

/// The Climate sheet: the inside temperature, climate on/off as the primary action, the cabin target
/// stepper, the two front seat heaters and Defrost. See ``ClimateModel`` for what each sends.
public struct ClimateSheet: View {
    private let model: ClimateModel

    /// - Parameter model: The sheet's model; keep it alive across presentations so the target, seats
    ///   and Defrost keep what was last sent.
    public init(model: ClimateModel) {
        self.model = model
    }

    public var body: some View {
        ControlSheet(title: "Climate", runner: model.runner, enabled: model.controlsEnabled) {
            hero
            ControlPill(
                icon: .fan,
                label: model.climateOn ? "Climate on" : "Climate off",
                active: model.climateOn,
                isPending: model.climatePending
            ) {
                Task { await model.toggleClimate() }
            }
            .accessibilityLabel("Climate")
            .accessibilityValue(model.climateOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
            Hairline()
            ControlRow(icon: .thermometer, title: "Target", isPending: model.targetPending) {
                TargetStepper(model: model)
            }
            Hairline()
            VStack(spacing: Tokens.Space.s) {
                seatRow(.driver, title: "Driver")
                seatRow(.passenger, title: "Passenger")
            }
            Hairline()
            ControlRow(icon: .snowflake, title: "Defrost", isPending: model.defrostPending) {
                GarageSwitch(label: "Defrost", isOn: model.defrostOn) { _ in
                    Task { await model.toggleDefrost() }
                }
                .disabled(model.defrostPending)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            SmallCapsLabel("Inside")
            if let inside = model.inside {
                Numeral(value: inside, unit: model.temperatureUnit, scale: .numeralL)
            } else {
                Text(verbatim: StatusModel.placeholder)
                    .garage(.numeralL)
                    .foregroundStyle(Tokens.Colors.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.inside.map { "Inside \(Int($0.rounded())) degrees" } ?? "Inside temperature not reported")
    }

    private func seatRow(_ seat: Command.SeatHeater, title: String) -> some View {
        ControlRow(icon: .flame, title: title, isPending: model.seatPending(seat)) {
            SeatLevelControl(name: title, level: model.seatLevel(seat)) { model.setSeatHeater(seat, level: $0) }
        }
    }
}

/// `−` / the target / `+`, stepping 0.5 °C. One adjustable element for VoiceOver.
private struct TargetStepper: View {
    let model: ClimateModel

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            GlassIconButton(icon: .minus, accessibilityLabel: "Cooler") { model.decreaseTarget() }
                .disabled(model.targetC <= ClimateModel.targetRange.lowerBound)
            Text(verbatim: model.targetText)
                .garage(.numeralM)
                .foregroundStyle(Tokens.Colors.ink)
                .contentTransition(.numericText(value: model.targetC))
                .animation(.snappy, value: model.targetC)
                .frame(minWidth: 64)
            GlassIconButton(icon: .plus, accessibilityLabel: "Warmer") { model.increaseTarget() }
                .disabled(model.targetC >= ClimateModel.targetRange.upperBound)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(model.targetText.dropLast()) degrees")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.increaseTarget()
            case .decrement: model.decreaseTarget()
            @unknown default: break
            }
        }
    }
}

/// A seat heater's four levels as small glass segments: Off, then three flames lit up to the level.
private struct SeatLevelControl: View {
    let name: String
    let level: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            ForEach(ClimateModel.seatLevels, id: \.self) { segment in
                Button { select(segment) } label: {
                    let lit = segment == 0 ? level == 0 : segment <= level
                    Group {
                        if segment == 0 {
                            Text("Off").garage(.labelS)
                        } else {
                            Icon(.flame, size: 14)
                        }
                    }
                    .foregroundStyle(lit ? (segment == 0 ? Tokens.Colors.ink : Tokens.Colors.accent) : Tokens.Colors.muted)
                    .frame(width: 38, height: 30)
                    .background {
                        if lit, segment > 0 {
                            Capsule(style: .continuous).fill(Tokens.Colors.accent.opacity(Tokens.Opacity.accentFill))
                        }
                    }
                    .glassCapsule()
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(DimWhenPressed())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) seat heater")
        .accessibilityValue(level == 0 ? "Off" : "Level \(level) of \(ClimateModel.seatLevels.upperBound)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(level + 1)
            case .decrement: select(level - 1)
            @unknown default: break
            }
        }
    }
}
