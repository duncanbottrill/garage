import SwiftUI

/// The Charge sheet: state of charge and the charge line, the charge-limit slider, Start/Stop and
/// the charge port, and scheduled charging. See ``ChargeModel`` for what each sends.
public struct ChargeSheet: View {
    private let model: ChargeModel

    /// - Parameter model: The sheet's model; keep it alive across presentations.
    public init(model: ChargeModel) {
        self.model = model
    }

    public var body: some View {
        ControlSheet(title: "Charge", runner: model.runner, enabled: model.controlsEnabled) {
            hero
            Hairline()
            limit
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s) { pills }
                VStack(spacing: Tokens.Space.s) { pills }
            }
            Hairline()
            ControlRow(icon: .clock, title: "Scheduled", isPending: model.schedulePending) {
                DatePicker(
                    "Start time",
                    selection: Binding(get: { model.scheduleDate }, set: { model.setScheduleTime($0) }),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Tokens.Colors.accent)
                .environment(\.timeZone, model.timeZone)
                .opacity(model.schedule.enabled ? 1 : 0.5)
                .accessibilityLabel("Scheduled start time")
                GarageSwitch(label: "Scheduled charging", isOn: model.schedule.enabled) { model.setScheduleEnabled($0) }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let soc = model.soc {
                Numeral(value: soc, unit: "%", scale: .numeralL)
            } else {
                Text(verbatim: StatusModel.placeholder)
                    .garage(.numeralL)
                    .foregroundStyle(Tokens.Colors.muted)
            }
            Text(model.chargeLine)
                .garage(.body)
                .foregroundStyle(Tokens.Colors.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var limit: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(alignment: .center, spacing: Tokens.Space.s) {
                SmallCapsLabel("Charge limit")
                if model.limitPending { PendingRing() }
                Spacer(minLength: Tokens.Space.s)
                Numeral(value: Double(model.chargeLimit), unit: "%", scale: .numeralM)
            }
            .accessibilityHidden(true)
            LimitSlider(value: model.chargeLimit, onChange: { model.setChargeLimit($0) }, onEnd: { model.commitChargeLimit() })
        }
    }

    @ViewBuilder
    private var pills: some View {
        ControlPill(
            icon: .zap,
            label: model.isCharging ? "Stop charging" : "Start charging",
            active: model.isCharging,
            tint: Tokens.Colors.charging,
            isPending: model.chargingPending
        ) {
            Task { await model.toggleCharging() }
        }
        .disabled(model.isCharging ? !model.canStop : !model.canStart)
        ControlPill(
            icon: .plug,
            label: model.portOpen == true ? "Close port" : "Open port",
            active: model.portOpen == true,
            isPending: model.portPending
        ) {
            Task { await model.togglePort() }
        }
    }
}

/// The charge-limit slider: a hairline track, accent fill up to the value, a charging-colour tick at
/// the 80 % daily mark and an ink knob. Reports raw drag positions; the model snaps them to 5 %.
private struct LimitSlider: View {
    let value: Int
    let onChange: (Double) -> Void
    /// The drag ended: send now rather than after the quiet time.
    let onEnd: () -> Void

    static let knob: CGFloat = 22
    private static let lower = Double(ChargeModel.limitRange.lowerBound)
    private static let span = Double(ChargeModel.limitRange.upperBound - ChargeModel.limitRange.lowerBound)

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let inset = Self.knob / 2
            let width = max(1, geometry.size.width - Self.knob)
            let x = { (percent: Double) in inset + CGFloat((percent - Self.lower) / Self.span) * width }
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(Tokens.Opacity.hairline))
                    .frame(width: width, height: 4)
                    .offset(x: inset)
                Capsule(style: .continuous)
                    .fill(Tokens.Colors.accent)
                    .frame(width: max(0, x(Double(value)) - inset), height: 4)
                    .offset(x: inset)
                Capsule(style: .continuous)
                    .fill(Tokens.Colors.charging)
                    .frame(width: 2, height: 12)
                    .offset(x: x(Double(ChargeModel.dailyMark)) - 1)
                Circle()
                    .fill(Tokens.Colors.ink)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: x(Double(value)) - inset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onChange(Self.lower + Double((drag.location.x - inset) / width) * Self.span)
                    }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: 44)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.snappy, value: value)
        .accessibilityElement()
        .accessibilityLabel("Charge limit")
        .accessibilityValue("\(value) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(Double(value + ChargeModel.limitStep))
            case .decrement: onChange(Double(value - ChargeModel.limitStep))
            @unknown default: break
            }
        }
    }
}
