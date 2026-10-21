import Foundation
import Observation

/// What the Charge sheet shows and sends: the charge limit, Start/Stop, the port and scheduled charging.
///
/// - The limit snaps to 5 % between 50 and 100 and sends one `set_charge_limit` ``debounce`` after
///   the last change; a change while one is in flight is sent after it.
/// - Start (`charge_start`) needs the port open and the car not charging; Stop (`charge_stop`) needs
///   it charging. Start/Stop and the port (`charge_port_door_open`/`close`) show their target at once
///   and revert on error.
/// - Scheduled charging sends `set_scheduled_charging {enable, time}`, `time` in minutes after
///   midnight; turning it off sends `time: 0`. Picking a time while it is off only moves the picker.
///   The car reads `time` in its own local time; the app counts it in ``timeZone`` (the device's),
///   which assumes phone and car are in the same zone.
///
/// **Schedule data gap.** The bridge never clears `scheduled_charge_at` (a null from telemetry means
/// "no change", and the bridge-side clear is not built yet), so the row cannot say "off". The model
/// tolerates it:
/// - Any `scheduled_charge_at`, past or future, reads as on: a past one is the daily schedule's last
///   start. Only a row without one reads as off.
/// - A sent "off" is kept, with no timer, until `scheduled_charge_at` changes to any other value.
/// - A sent "on" is kept until the row's `scheduled_charge_at` reports the sent start time.
///
/// Debounced sends fire after the quiet time even if the sheet has closed (up to 600 ms later);
/// if the car is asleep by then, the send is declined rather than woken (no prompt on screen).
///
/// Everything goes through ``runner``, which asks before waking the car.
@MainActor
@Observable
public final class ChargeModel {
    /// The allowed charge limits, percent.
    public static let limitRange: ClosedRange<Int> = 50...100
    /// The slider's step, percent.
    public static let limitStep = 5
    /// The daily-driving mark on the slider, percent.
    public static let dailyMark = 80
    /// The limit shown before the row reports one.
    public static let defaultLimit = 80
    /// The quiet time before a limit or schedule-time change is sent.
    public static let defaultDebounce: Duration = .milliseconds(600)

    /// Scheduled charging: on or off, and the start time in minutes after local midnight.
    public struct Schedule: Equatable, Sendable {
        public var enabled: Bool
        public var minutes: Int

        public init(enabled: Bool, minutes: Int) {
            self.enabled = enabled
            self.minutes = minutes
        }
    }

    /// The car's latest row; set it whenever the store's row changes.
    public var state: VehicleState? {
        didSet {
            charging.rowChanged(rowCharging)
            port.rowChanged(state?.chargePortOpen)
            limit.rowChanged(state?.chargeLimitSoc)
            releaseScheduleIfReported()
        }
    }

    /// The proxy's reachability; the controls are disabled unless it is reachable.
    public var reachability: ProxyReachability.State = .unknown

    /// Sends the commands, and holds the wake prompt and the toast.
    public let runner: CommandRunner

    /// The time zone schedule times are read and written in (the device's).
    public let timeZone: TimeZone

    @ObservationIgnored let charging: PendingOverlay<Bool>
    @ObservationIgnored let port: PendingOverlay<Bool>
    @ObservationIgnored let limit: PendingOverlay<Int>
    @ObservationIgnored let scheduleOverlay: PendingOverlay<Schedule>

    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let limitSender = Coalescer<Int>()
    @ObservationIgnored private let scheduleSender = Coalescer<Schedule>()
    /// `scheduled_charge_at` as the row had it when the shown schedule was sent.
    @ObservationIgnored private var scheduleSentAgainst: Date?

    private static let limitName = Command.setChargeLimit(percent: 0).name
    private static let scheduleName = Command.setScheduledCharging(enable: false, time: 0).name

    /// - Parameters:
    ///   - send: Sends a command (``CommandClient/send(_:vin:)`` for the car).
    ///   - wake: Wakes the car (``CommandClient/wake(vin:)``); only after the user confirms.
    ///   - awaitAwake: Waits for the row to say the car is online after a confirmed wake
    ///     (``CommandRunner/AwaitAwake``); the default does not wait.
    ///   - now: The clock (schedule day, charge line, wake grace).
    ///   - timeZone: Where "minutes after midnight" is counted (the device's).
    ///   - debounce: Quiet time before a limit or schedule-time change is sent.
    ///   - hold: How long a sent toggle or limit waits for the row to agree.
    public init(
        send: @escaping CommandRunner.Send,
        wake: @escaping CommandRunner.Wake,
        awaitAwake: @escaping CommandRunner.AwaitAwake = { true },
        now: @escaping @MainActor () -> Date = { .now },
        timeZone: TimeZone = .current,
        debounce: Duration = ChargeModel.defaultDebounce,
        hold: Duration = .seconds(30)
    ) {
        runner = CommandRunner(send: send, wake: wake, awaitAwake: awaitAwake, now: now)
        charging = PendingOverlay(hold: hold)
        port = PendingOverlay(hold: hold)
        limit = PendingOverlay(hold: hold)
        // No timer: the row may never report "off" (see the type's schedule data gap).
        scheduleOverlay = PendingOverlay(hold: nil)
        self.now = now
        self.timeZone = timeZone
        self.debounce = debounce
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        runner.isAsleep = { [weak self] in self?.state?.sleepState?.lowercased() == "asleep" }
        limitSender.deliver = { [weak self] in await self?.deliverLimit($0) }
        scheduleSender.deliver = { [weak self] in await self?.deliverSchedule($0) }
    }

    // MARK: Display

    /// The controls can send: the proxy is reachable.
    public var controlsEnabled: Bool { reachability == .reachable }
    /// State of charge, whole percent, or nil.
    public var soc: Double? { state?.soc.map { $0.rounded() } }
    /// The Status charge line: "Charging 7.2 kW · 90 % limit", "Scheduled 23:30", "Not charging"…
    public var chargeLine: String { StatusModel.chargeLine(state, now: now(), timeZone: timeZone) }
    /// The limit shown: the one being set, else the row's (snapped), else 80.
    public var chargeLimit: Int { limit.value ?? state?.chargeLimitSoc.map { Self.snapLimit(Double($0)) } ?? Self.defaultLimit }
    /// Charging, or heading that way.
    public var isCharging: Bool { charging.value ?? rowCharging }
    /// The port is open (or opening), closed, or not reported.
    public var portOpen: Bool? { port.value ?? state?.chargePortOpen }
    /// Start is offered: the port is open and the car is not charging.
    public var canStart: Bool { portOpen == true && !isCharging }
    /// Stop is offered: the car is charging.
    public var canStop: Bool { isCharging }
    /// The schedule shown: the one being set, else the row's (on whenever `scheduled_charge_at` is set).
    public var schedule: Schedule { scheduleOverlay.value ?? rowSchedule }
    /// ``schedule``'s start time today, for the time picker.
    public var scheduleDate: Date { date(minutesAfterMidnight: schedule.minutes) }

    /// A limit request snapped to 5 % and clamped to 50–100.
    public static func snapLimit(_ raw: Double) -> Int {
        let snapped = Int((raw / Double(limitStep)).rounded()) * limitStep
        return min(max(snapped, limitRange.lowerBound), limitRange.upperBound)
    }

    /// Minutes after midnight of `date`'s day in ``timeZone``: 23:30 → 1410.
    public func minutesAfterMidnight(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Today (per `now`, in ``timeZone``) at `minutes` after midnight.
    public func date(minutesAfterMidnight minutes: Int) -> Date {
        let today = now()
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: today) ?? today
    }

    /// Start/Stop is in flight (or waiting for the wake prompt).
    public var chargingPending: Bool {
        runner.pending.contains(Command.chargeStart.name) || runner.pending.contains(Command.chargeStop.name)
    }
    /// The port command is in flight.
    public var portPending: Bool {
        runner.pending.contains(Command.chargePortDoorOpen.name) || runner.pending.contains(Command.chargePortDoorClose.name)
    }
    /// A `set_charge_limit` is in flight.
    public var limitPending: Bool { runner.pending.contains(Self.limitName) }
    /// A `set_scheduled_charging` is in flight.
    public var schedulePending: Bool { runner.pending.contains(Self.scheduleName) }

    /// True while the wake prompt should show.
    public var isAskingToWake: Bool { runner.isAskingToWake }
    /// The prompt's Wake button.
    public func confirmWake() { runner.confirmWake() }
    /// The prompt's Cancel button.
    public func cancelWake() { runner.cancelWake() }

    // MARK: Actions

    /// Sets the limit (snapped) and sends it after the quiet time.
    public func setChargeLimit(_ raw: Double) {
        let percent = Self.snapLimit(raw)
        guard percent != chargeLimit else { return }
        limit.show(percent)
        limitSender.submit(percent, after: debounce)
    }

    /// The slider was let go: send the waiting limit now instead of after the quiet time (still once).
    public func commitChargeLimit() {
        limitSender.flush()
    }

    /// Starts charging, or stops it while charging; ignored when not offered or in flight.
    public func toggleCharging() async {
        let stopping = isCharging
        guard stopping ? canStop : canStart, !chargingPending else { return }
        charging.show(!stopping)
        if await runner.run(stopping ? .chargeStop : .chargeStart) == .sent {
            charging.markSent()
        } else {
            charging.failed()
        }
    }

    /// Opens the port, or closes it while open; ignored while in flight.
    public func togglePort() async {
        guard !portPending else { return }
        let opening = portOpen != true
        port.show(opening)
        if await runner.run(opening ? .chargePortDoorOpen : .chargePortDoorClose) == .sent {
            port.markSent()
        } else {
            port.failed()
        }
    }

    /// Turns scheduled charging on (at the picker's time) or off, and sends it at once.
    public func setScheduleEnabled(_ enabled: Bool) {
        var next = schedule
        guard next.enabled != enabled else { return }
        next.enabled = enabled
        scheduleOverlay.show(next)
        scheduleSender.submit(next, after: .zero)
    }

    /// Moves the start time to `date`'s time of day; sent after the quiet time while the schedule is on.
    public func setScheduleTime(_ date: Date) {
        var next = schedule
        next.minutes = minutesAfterMidnight(date)
        guard next != schedule else { return }
        scheduleOverlay.show(next)
        if next.enabled { scheduleSender.submit(next, after: debounce) }
    }

    // MARK: Delivery

    private var rowCharging: Bool { state?.chargeState?.lowercased() == "charging" }

    private var rowSchedule: Schedule {
        guard let at = state?.scheduledChargeAt else { return Schedule(enabled: false, minutes: 0) }
        return Schedule(enabled: true, minutes: minutesAfterMidnight(at))
    }

    /// Drops a sent schedule once the row reflects it: "off" when `scheduled_charge_at` has changed
    /// since the send, "on" when it reports the sent start time.
    private func releaseScheduleIfReported() {
        guard scheduleOverlay.isSent, let sent = scheduleOverlay.value else { return }
        let at = state?.scheduledChargeAt
        let reported = sent.enabled
            ? at.map { minutesAfterMidnight($0) == sent.minutes } ?? false
            : at != scheduleSentAgainst
        if reported { scheduleOverlay.clear() }
    }

    private func deliverLimit(_ percent: Int) async {
        let outcome = await runner.run(.setChargeLimit(percent: percent))
        guard !limitSender.hasQueued else { return }
        if outcome == .sent { limit.markSent() } else { limit.failed() }
    }

    private func deliverSchedule(_ schedule: Schedule) async {
        let outcome = await runner.run(.setScheduledCharging(enable: schedule.enabled, time: schedule.enabled ? schedule.minutes : 0))
        guard !scheduleSender.hasQueued else { return }
        if outcome == .sent {
            scheduleSentAgainst = state?.scheduledChargeAt
            scheduleOverlay.markSent()
        } else {
            scheduleOverlay.failed()
        }
    }
}
