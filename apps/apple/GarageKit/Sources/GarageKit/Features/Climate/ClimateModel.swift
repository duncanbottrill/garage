import Foundation
import Observation

/// What the Climate sheet shows and sends: climate on/off, the cabin target, the two front seat
/// heaters and Defrost.
///
/// - On/off sends `auto_conditioning_start`/`stop` and shows its target at once (reverting on error).
/// - The target steps 15–28 °C by 0.5 and sends one `set_temps` (driver and passenger the same)
///   ``debounce`` after the last step; a step while one is in flight is sent after it. In °F a step
///   is one whole degree on screen, stored as the nearest 0.5 °C (always within 0.45 °F of it, so
///   the number shown never repeats or skips).
/// - Seat heaters send `remote_seat_heater_request {heater, level}` (0–3) per seat, latest level wins.
/// - Defrost sends `set_preconditioning_max {on, manual_override: true}`.
///
/// The row has no target, seat or defrost fields, so those start at 21 °C, off and off and follow
/// what the sheet last sent. A debounced target fires after the quiet time even if the sheet has
/// closed (up to 800 ms later); if the car is asleep by then it is declined, not woken. Everything
/// goes through ``runner``, which asks before waking the car.
@MainActor
@Observable
public final class ClimateModel {
    /// The target temperature range, °C.
    public static let targetRange: ClosedRange<Double> = 15...28
    /// One stepper step, °C.
    public static let targetStep: Double = 0.5
    /// The target before anything has been sent.
    public static let defaultTarget: Double = 21
    /// The quiet time before a target change is sent.
    public static let defaultDebounce: Duration = .milliseconds(800)
    /// Seat heater levels: 0 is off.
    public static let seatLevels: ClosedRange<Int> = 0...3

    /// The car's latest row; set it whenever the store's row changes.
    public var state: VehicleState? {
        didSet { hvac.rowChanged(state?.hvacOn) }
    }

    /// The proxy's reachability; the controls are disabled unless it is reachable.
    public var reachability: ProxyReachability.State = .unknown

    /// Sends the commands, and holds the wake prompt and the toast.
    public let runner: CommandRunner

    /// The cabin target, °C.
    public private(set) var targetC: Double

    /// True when climate is on, or heading on.
    public var climateOn: Bool { hvac.value ?? state?.hvacOn ?? false }
    /// Defrost (max preconditioning) as last set from here.
    public private(set) var defrostOn = false

    @ObservationIgnored let hvac: PendingOverlay<Bool>
    private var seats: [Command.SeatHeater: Int] = [.driver: 0, .passenger: 0]
    private var sendingSeats: Set<Command.SeatHeater> = []

    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var confirmedTarget: Double
    @ObservationIgnored private var confirmedSeats: [Command.SeatHeater: Int] = [.driver: 0, .passenger: 0]
    @ObservationIgnored private let temps = Coalescer<Double>()
    @ObservationIgnored private let seatSenders: [Command.SeatHeater: Coalescer<Int>] = [.driver: Coalescer(), .passenger: Coalescer()]

    private static let tempsName = Command.setTemps(driver: 0, passenger: 0).name
    private static let defrostName = Command.setPreconditioningMax(on: true, manualOverride: true).name

    /// - Parameters:
    ///   - send: Sends a command (``CommandClient/send(_:vin:)`` for the car).
    ///   - wake: Wakes the car (``CommandClient/wake(vin:)``); only after the user confirms.
    ///   - awaitAwake: Waits for the row to say the car is online after a confirmed wake
    ///     (``CommandRunner/AwaitAwake``); the default does not wait.
    ///   - now: The clock (the runner's wake grace).
    ///   - locale: °C or °F for the inside temperature and target (``Units``).
    ///   - debounce: Quiet time before a target change is sent.
    ///   - hold: How long a sent on/off waits for the row to agree.
    public init(
        send: @escaping CommandRunner.Send,
        wake: @escaping CommandRunner.Wake,
        awaitAwake: @escaping CommandRunner.AwaitAwake = { true },
        now: @escaping @MainActor () -> Date = { .now },
        locale: Locale = .current,
        debounce: Duration = ClimateModel.defaultDebounce,
        hold: Duration = .seconds(30)
    ) {
        runner = CommandRunner(send: send, wake: wake, awaitAwake: awaitAwake, now: now)
        hvac = PendingOverlay(hold: hold)
        targetC = Self.defaultTarget
        confirmedTarget = Self.defaultTarget
        self.locale = locale
        self.debounce = debounce
        runner.isAsleep = { [weak self] in self?.state?.sleepState?.lowercased() == "asleep" }
        temps.deliver = { [weak self] in await self?.deliverTarget($0) }
        for (seat, sender) in seatSenders {
            sender.deliver = { [weak self] in await self?.deliverSeat(seat, level: $0) }
        }
    }

    // MARK: Display

    /// The controls can send: the proxy is reachable.
    public var controlsEnabled: Bool { reachability == .reachable }
    /// Inside temperature in the locale's unit, or nil.
    public var inside: Double? { state?.insideC.map { Units.temperature(c: $0, locale: locale).value } }
    /// "°C" or "°F".
    public var temperatureUnit: String { usesFahrenheit ? "°F" : "°C" }
    /// The target as shown: "21.0°" (°C, one decimal) or "70°" (°F, whole degrees).
    public var targetText: String {
        var value = Units.temperature(c: targetC, locale: locale).value
        // Rounded the way the °F stepper reads it back, so the shown number and the next step agree.
        if usesFahrenheit { value.round() }
        let digits = usesFahrenheit ? 0 : 1
        return value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "en_US_POSIX"))) + "°"
    }

    /// The level shown for `seat`, 0–3.
    public func seatLevel(_ seat: Command.SeatHeater) -> Int { seats[seat] ?? 0 }

    /// On/off is in flight (or waiting for the wake prompt).
    public var climatePending: Bool {
        runner.pending.contains(Command.autoConditioningStart.name) || runner.pending.contains(Command.autoConditioningStop.name)
    }
    /// A `set_temps` is in flight.
    public var targetPending: Bool { runner.pending.contains(Self.tempsName) }
    /// Defrost is in flight.
    public var defrostPending: Bool { runner.pending.contains(Self.defrostName) }
    /// `seat`'s heater command is in flight.
    public func seatPending(_ seat: Command.SeatHeater) -> Bool { sendingSeats.contains(seat) }

    /// True while the wake prompt should show.
    public var isAskingToWake: Bool { runner.isAskingToWake }
    /// The prompt's Wake button.
    public func confirmWake() { runner.confirmWake() }
    /// The prompt's Cancel button.
    public func cancelWake() { runner.cancelWake() }

    // MARK: Actions

    /// Turns climate on or off; ignored while the last toggle is in flight.
    public func toggleClimate() async {
        guard !climatePending else { return }
        let target = !climateOn
        hvac.show(target)
        if await runner.run(target ? .autoConditioningStart : .autoConditioningStop) == .sent {
            hvac.markSent()
        } else {
            hvac.failed()
        }
    }

    /// One step warmer: 0.5 °C, or 1 °F as shown.
    public func increaseTarget() { step(by: 1) }
    /// One step cooler: 0.5 °C, or 1 °F as shown.
    public func decreaseTarget() { step(by: -1) }

    private func step(by direction: Double) {
        guard usesFahrenheit else {
            setTarget(targetC + direction * Self.targetStep)
            return
        }
        let shown = Units.temperature(c: targetC, locale: locale).value.rounded()
        let next = Measurement(value: shown + direction, unit: UnitTemperature.fahrenheit).converted(to: .celsius).value
        setTarget(next)
    }

    /// Sets the target (rounded to 0.5, clamped to 15–28 °C) and sends it after the quiet time.
    public func setTarget(_ celsius: Double) {
        let stepped = (celsius / Self.targetStep).rounded() * Self.targetStep
        let clamped = min(max(stepped, Self.targetRange.lowerBound), Self.targetRange.upperBound)
        guard clamped != targetC else { return }
        targetC = clamped
        temps.submit(clamped, after: debounce)
    }

    /// Sets a seat heater (clamped to 0–3) and sends it; a newer level replaces one not yet sent.
    public func setSeatHeater(_ seat: Command.SeatHeater, level: Int) {
        let level = min(max(level, Self.seatLevels.lowerBound), Self.seatLevels.upperBound)
        guard seats[seat] != level else { return }
        seats[seat] = level
        seatSenders[seat]?.submit(level, after: .zero)
    }

    /// Turns Defrost on or off; ignored while the last toggle is in flight.
    public func toggleDefrost() async {
        guard !defrostPending else { return }
        let target = !defrostOn
        defrostOn = target
        if await runner.run(.setPreconditioningMax(on: target, manualOverride: true)) != .sent {
            defrostOn = !target
        }
    }

    // MARK: Delivery

    private var usesFahrenheit: Bool { Units.temperature(c: 0, locale: locale).unit == .fahrenheit }

    private func deliverTarget(_ celsius: Double) async {
        if await runner.run(.setTemps(driver: celsius, passenger: celsius)) == .sent {
            confirmedTarget = celsius
        } else if !temps.hasQueued {
            targetC = confirmedTarget
        }
    }

    private func deliverSeat(_ seat: Command.SeatHeater, level: Int) async {
        sendingSeats.insert(seat)
        defer { sendingSeats.remove(seat) }
        if await runner.run(.remoteSeatHeater(seat, level: level)) == .sent {
            confirmedSeats[seat] = level
        } else if seatSenders[seat]?.hasQueued == false {
            seats[seat] = confirmedSeats[seat]
        }
    }
}
