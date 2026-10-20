import Foundation
import Testing
@testable import GarageKit

@MainActor @Suite struct ClimateModelTests {
    private let debounce: Duration = .milliseconds(40)

    private func model(_ car: FakeCar, state: VehicleState = .awake()) -> ClimateModel {
        let model = ClimateModel(send: car.send, wake: car.wake, locale: Locale(identifier: "en_GB"), debounce: debounce)
        model.state = state
        model.reachability = .reachable
        model.runner.hostsPrompt = true
        return model
    }

    /// Quick steps coalesce into one `set_temps` with the last value, driver and passenger alike,
    /// and the stepper stays inside 15–28 °C in 0.5 steps.
    @Test func tempStepperClampsAndDebounces() async {
        let car = FakeCar()
        let model = model(car)
        #expect(model.targetC == 21)
        #expect(ClimateModel.defaultDebounce == .milliseconds(800))

        model.increaseTarget()
        model.increaseTarget()
        model.increaseTarget()
        #expect(model.targetC == 22.5)
        #expect(model.targetText == "22.5°")
        #expect(car.sent.isEmpty, "nothing is sent before the quiet time")

        #expect(await eventually { car.sent.count == 1 })
        try? await Task.sleep(for: debounce * 3)
        #expect(car.sent == [.setTemps(driver: 22.5, passenger: 22.5)])

        for _ in 0..<40 { model.increaseTarget() }
        #expect(model.targetC == 28)
        for _ in 0..<60 { model.decreaseTarget() }
        #expect(model.targetC == 15)
        model.setTarget(21.3)
        #expect(model.targetC == 21.5)

        #expect(await eventually { car.sent.count == 2 })
        try? await Task.sleep(for: debounce * 3)
        #expect(car.sent.last == .setTemps(driver: 21.5, passenger: 21.5))
        #expect(car.sent.count == 2)
    }

    /// A change made while a `set_temps` is in flight is not dropped by the client's per-name guard:
    /// it is sent once the first completes, with the latest value.
    @Test func changeDuringSendIsSentAfterwards() async {
        let car = FakeCar()
        let model = model(car)
        car.holding = true

        model.increaseTarget() // 21.5
        #expect(await eventually { car.heldCount == 1 })
        #expect(model.targetPending)

        model.increaseTarget() // 22.0
        model.increaseTarget() // 22.5
        try? await Task.sleep(for: debounce * 3)
        #expect(car.sent.count == 1, "the newer value waits for the send in flight")

        car.release()
        #expect(await eventually { car.sent.count == 2 })
        #expect(car.sent == [.setTemps(driver: 21.5, passenger: 21.5), .setTemps(driver: 22.5, passenger: 22.5)])
        #expect(await eventually { !model.targetPending })
    }

    /// An asleep car asks first; nothing (no wake, no command) goes out until the user confirms,
    /// and then exactly one wake and the original command.
    @Test func asleepTriggersWakePromptNotWake() async {
        let car = FakeCar()
        let model = model(car, state: .awake("asleep"))

        let toggle = Task { await model.toggleClimate() }
        #expect(await eventually { model.isAskingToWake })
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)
        #expect(model.climateOn, "the toggle shows its target while waiting")
        #expect(model.climatePending)

        model.confirmWake()
        await toggle.value
        #expect(car.wakes == 1)
        #expect(car.sent == [.autoConditioningStart])
        #expect(!model.isAskingToWake)
        #expect(model.climateOn)
    }

    /// Cancel sends nothing and puts the toggle back.
    @Test func cancelledWakeRevertsAndSendsNothing() async {
        let car = FakeCar()
        let model = model(car, state: .awake("asleep"))

        let toggle = Task { await model.toggleDefrost() }
        #expect(await eventually { model.isAskingToWake })
        #expect(model.defrostOn)
        model.cancelWake()
        await toggle.value
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)
        #expect(!model.defrostOn)
        #expect(model.runner.toast == nil)
    }

    /// The row said awake but the car answered asleep: prompt, wake, resend once; asleep again is the
    /// "still waking" toast, with no second prompt and no polling.
    @Test func asleepErrorPromptsThenStillWaking() async {
        let car = FakeCar()
        let model = model(car)
        car.asleepFailures = 2

        let toggle = Task { await model.toggleClimate() }
        #expect(await eventually { model.isAskingToWake })
        #expect(car.sent == [.autoConditioningStart])
        model.confirmWake()
        await toggle.value
        #expect(car.wakes == 1)
        #expect(car.sent == [.autoConditioningStart, .autoConditioningStart])
        #expect(model.runner.toast?.message == "The car is still waking. Try again in a moment.")
        #expect(!model.climateOn, "the failed toggle reverts")
    }

    /// An error reverts the optimistic toggle and puts the error's copy in the toast.
    @Test func toggleRevertsOnError() async {
        let car = FakeCar()
        var state = VehicleState.awake()
        state.hvacOn = true
        let model = model(car, state: state)
        car.failure = .timeout

        #expect(model.climateOn)
        await model.toggleClimate()
        #expect(car.sent == [.autoConditioningStop])
        #expect(model.climateOn)
        #expect(model.runner.toast?.message == CommandError.timeout.errorDescription)
    }

    /// Seat heaters send `remote_seat_heater_request` per seat (0–3), and Defrost
    /// `set_preconditioning_max` with the manual override.
    @Test func seatHeaterAndDefrostCommands() async {
        let car = FakeCar()
        let model = model(car)

        model.setSeatHeater(.driver, level: 5)
        model.setSeatHeater(.passenger, level: 2)
        #expect(model.seatLevel(.driver) == 3)
        #expect(await eventually { car.sent.count == 2 })
        #expect(car.sent.contains(.remoteSeatHeater(.driver, level: 3)))
        #expect(car.sent.contains(.remoteSeatHeater(.passenger, level: 2)))

        await model.toggleDefrost()
        #expect(car.sent.last == .setPreconditioningMax(on: true, manualOverride: true))
        #expect(model.defrostOn)
    }

    /// Cancel clears the work queued behind the prompt: a second tap on the same seat and the other
    /// seat's tap are declined too, with no second prompt and no wake, and every seat reverts.
    @Test func cancelledWakeDeclinesQueuedSeatHeaters() async {
        let car = FakeCar()
        let model = model(car, state: .awake("asleep"))

        model.setSeatHeater(.driver, level: 1)
        model.setSeatHeater(.driver, level: 3)
        model.setSeatHeater(.passenger, level: 2)
        #expect(await eventually { model.isAskingToWake })
        model.cancelWake()

        #expect(await eventually { !model.seatPending(.driver) && !model.seatPending(.passenger) })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!model.isAskingToWake, "no second prompt")
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)
        #expect(model.seatLevel(.driver) == 0)
        #expect(model.seatLevel(.passenger) == 0)
    }

    /// With the sheet gone (no prompt on screen), a debounced target hitting an asleep car is declined
    /// and reverted, never woken.
    @Test func debouncedSendWithoutPromptIsDeclined() async {
        let car = FakeCar()
        let model = model(car, state: .awake("asleep"))
        model.runner.hostsPrompt = false

        model.increaseTarget()
        #expect(model.targetC == 21.5)
        #expect(await eventually { model.targetC == 21 })
        #expect(!model.isAskingToWake)
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)
    }

    /// A change inside the quiet time restarts it: the one send comes a full quiet time after the
    /// last change, not after the first.
    @Test func laterChangeRestartsQuietTime() async {
        let car = FakeCar()
        let quiet: Duration = .milliseconds(80)
        let model = ClimateModel(send: car.send, wake: car.wake, locale: Locale(identifier: "en_GB"), debounce: quiet)
        model.state = .awake()
        model.runner.hostsPrompt = true

        model.increaseTarget()
        try? await Task.sleep(for: .milliseconds(30))
        model.increaseTarget()
        let lastChange = ContinuousClock.now

        #expect(await eventually { car.sent.count == 1 })
        try? await Task.sleep(for: quiet * 2)
        #expect(car.sent == [.setTemps(driver: 22, passenger: 22)])
        #expect(car.sentAt[0] - lastChange >= quiet)
    }
}
