import Foundation
import Testing
@testable import GarageKit

@MainActor @Suite struct ChargeModelTests {
    /// 2026-10-20 14:30:00 UTC (15:30 in London, BST).
    private let now = Date(timeIntervalSince1970: 1_792_506_600)
    private let london = TimeZone(identifier: "Europe/London")!
    private let debounce: Duration = .milliseconds(40)

    private func model(_ car: FakeCar, state: VehicleState = .awake(), timeZone: TimeZone? = nil) -> ChargeModel {
        let now = self.now
        let model = ChargeModel(send: car.send, wake: car.wake, now: { now }, timeZone: timeZone ?? london, debounce: debounce)
        model.state = state
        model.reachability = .reachable
        model.runner.hostsPrompt = true
        return model
    }

    /// The limit snaps to 5 % steps inside 50–100, and a drag sends one `set_charge_limit` with
    /// where it stopped.
    @Test func chargeLimitSnapsToFive() async {
        #expect(ChargeModel.snapLimit(87.4) == 85)
        #expect(ChargeModel.snapLimit(88) == 90)
        #expect(ChargeModel.snapLimit(72.5) == 75)
        #expect(ChargeModel.snapLimit(42) == 50)
        #expect(ChargeModel.snapLimit(103) == 100)
        #expect(ChargeModel.defaultDebounce == .milliseconds(600))

        let car = FakeCar()
        var state = VehicleState.awake()
        state.chargeLimitSoc = 80
        let model = model(car, state: state)
        #expect(model.chargeLimit == 80)

        model.setChargeLimit(83)
        model.setChargeLimit(86.9)
        model.setChargeLimit(91)
        #expect(model.chargeLimit == 90)
        #expect(car.sent.isEmpty)
        #expect(await eventually { car.sent.count == 1 })
        try? await Task.sleep(for: debounce * 3)
        #expect(car.sent == [.setChargeLimit(percent: 90)])

        // The row catching up drops the overlay; the row then speaks for itself.
        state.chargeLimitSoc = 90
        model.state = state
        #expect(model.chargeLimit == 90)
    }

    /// The picker's time is minutes after local midnight in the device time zone: 23:30 → 1410.
    @Test func scheduledMinutesConversion() async {
        let car = FakeCar()
        let model = model(car)
        // 22:30 UTC is 23:30 in London on 20 October (BST).
        let half11 = Date(timeIntervalSince1970: 1_792_535_400)
        #expect(model.minutesAfterMidnight(half11) == 1410)
        #expect(model.date(minutesAfterMidnight: 1410) == half11)

        let utcModel = self.model(FakeCar(), timeZone: TimeZone(identifier: "UTC")!)
        #expect(utcModel.minutesAfterMidnight(half11) == 1350)

        // Picking a time while the schedule is off only moves the picker.
        model.setScheduleTime(half11)
        #expect(model.schedule == ChargeModel.Schedule(enabled: false, minutes: 1410))
        try? await Task.sleep(for: debounce * 3)
        #expect(car.sent.isEmpty)

        model.setScheduleEnabled(true)
        #expect(await eventually { car.sent.count == 1 })
        #expect(car.sent == [.setScheduledCharging(enable: true, time: 1410)])

        model.setScheduleEnabled(false)
        #expect(await eventually { car.sent.count == 2 })
        #expect(car.sent.last == .setScheduledCharging(enable: false, time: 0))
    }

    /// Start needs the port open and the car not charging; Stop needs it charging.
    @Test func startDisabledWhileCharging() async {
        let car = FakeCar()
        var state = VehicleState.awake()
        state.chargePortOpen = true
        state.chargeState = "Charging"
        let model = model(car, state: state)
        #expect(model.isCharging)
        #expect(!model.canStart)
        #expect(model.canStop)

        state.chargeState = "Stopped"
        model.state = state
        #expect(model.canStart)
        #expect(!model.canStop)

        state.chargePortOpen = false
        model.state = state
        #expect(!model.canStart)
        #expect(!model.canStop)

        // Start shows charging at once and sends `charge_start`.
        state.chargePortOpen = true
        model.state = state
        await model.toggleCharging()
        #expect(car.sent == [.chargeStart])
        #expect(model.isCharging)
    }

    /// The port toggles open and closed; a failure reverts it.
    @Test func portToggleRevertsOnError() async {
        let car = FakeCar()
        var state = VehicleState.awake()
        state.chargePortOpen = false
        let model = model(car, state: state)

        await model.togglePort()
        #expect(car.sent == [.chargePortDoorOpen])
        #expect(model.portOpen == true)

        car.failure = .unreachable
        await model.togglePort()
        #expect(car.sent.last == .chargePortDoorClose)
        #expect(model.portOpen == true, "reverted to open")
        #expect(model.runner.toast?.message == CommandError.unreachable.errorDescription)
    }

    /// The bridge never clears `scheduled_charge_at`, so a sent "off" holds (no timer) until that
    /// column changes, whatever else the row reports in the meantime.
    @Test func disableHoldsUntilRowChanges() async {
        let car = FakeCar()
        var state = VehicleState.awake()
        state.scheduledChargeAt = now.addingTimeInterval(9 * 3600) // 00:30 London
        let model = ChargeModel(send: car.send, wake: car.wake, now: { [now] in now }, timeZone: london, debounce: debounce, hold: .milliseconds(20))
        model.state = state
        model.runner.hostsPrompt = true
        #expect(model.schedule == ChargeModel.Schedule(enabled: true, minutes: 30))

        model.setScheduleEnabled(false)
        #expect(await eventually { car.sent.count == 1 })
        #expect(car.sent == [.setScheduledCharging(enable: false, time: 0)])

        try? await Task.sleep(for: .milliseconds(100)) // well past the 20 ms hold
        state.soc = 61 // a row update that leaves the schedule column alone
        model.state = state
        #expect(!model.schedule.enabled, "stays off: the column did not change")

        state.scheduledChargeAt = now.addingTimeInterval(10 * 3600) // 01:30 London
        model.state = state
        #expect(model.schedule == ChargeModel.Schedule(enabled: true, minutes: 90), "a new value: the row speaks again")
    }

    /// A sent "on" holds until the row reports that start time.
    @Test func enableHoldsUntilRowReportsTime() async {
        let car = FakeCar()
        let model = ChargeModel(send: car.send, wake: car.wake, now: { [now] in now }, timeZone: london, debounce: debounce, hold: .milliseconds(20))
        model.state = .awake()
        model.runner.hostsPrompt = true
        model.setScheduleTime(Date(timeIntervalSince1970: 1_792_535_400)) // 23:30 London
        model.setScheduleEnabled(true)
        #expect(await eventually { car.sent.count == 1 })

        try? await Task.sleep(for: .milliseconds(100))
        var state = VehicleState.awake()
        state.soc = 61
        model.state = state
        #expect(model.schedule == ChargeModel.Schedule(enabled: true, minutes: 1410))

        state.scheduledChargeAt = Date(timeIntervalSince1970: 1_792_535_400)
        model.state = state
        #expect(model.schedule == ChargeModel.Schedule(enabled: true, minutes: 1410))
    }

    /// A start time already past today is the daily schedule's last run: still on.
    @Test func pastScheduleStillShowsEnabled() {
        var state = VehicleState.awake()
        state.scheduledChargeAt = now.addingTimeInterval(-3 * 3600) // 12:30 London
        let model = model(FakeCar(), state: state)
        #expect(model.schedule == ChargeModel.Schedule(enabled: true, minutes: 750))
    }

    /// Letting go of the slider sends the limit at once instead of after the quiet time, still once.
    @Test func releasingSliderSendsOnce() async {
        let car = FakeCar()
        let model = ChargeModel(send: car.send, wake: car.wake, now: { [now] in now }, timeZone: london, debounce: .seconds(5))
        model.state = .awake()
        model.runner.hostsPrompt = true

        model.setChargeLimit(70)
        model.setChargeLimit(75)
        model.commitChargeLimit()
        #expect(await eventually(timeout: .seconds(1)) { car.sent.count == 1 })
        model.commitChargeLimit()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(car.sent == [.setChargeLimit(percent: 75)])
    }
}
