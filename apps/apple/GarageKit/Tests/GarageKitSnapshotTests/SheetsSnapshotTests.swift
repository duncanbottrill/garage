#if os(iOS)
import SnapshotTesting
import SwiftUI
import Testing
@testable import GarageKit

/// The Climate and Charge sheets as standalone views (not inside a system sheet) at 402 × 560 on the
/// iPhone 17 Pro dark traits, over the app background, in their idle, pending, unreachable, charging
/// and scheduled states.
@MainActor @Suite struct SheetsSnapshotTests {
    /// 2026-10-20 14:30:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_792_506_600)
    private static let utc = TimeZone(identifier: "UTC")!
    private static let uk = Locale(identifier: "en_GB")

    private func check(_ sheet: some View, fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function, line: UInt = #line, column: UInt = #column) {
        GarageKit.registerFonts()
        let view = ZStack {
            Tokens.Colors.background
            sheet
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Self.uk)
        .environment(\.statusMotion, false)
        assertSnapshot(
            of: view,
            as: .image(
                precision: SnapshotTolerance.precision,
                perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                layout: .fixed(width: 402, height: 560),
                traits: ViewImageConfig.iPhone17ProDark.traits
            ),
            fileID: fileID, file: file, testName: testName, line: line, column: column
        )
    }

    private func row(_ edit: (inout VehicleState) -> Void) -> VehicleState {
        var state = VehicleState()
        state.sleepState = "online"
        state.insideC = 19.6
        state.outsideC = 11.2
        state.soc = 68
        state.chargeLimitSoc = 90
        edit(&state)
        return state
    }

    // MARK: Climate

    @Test func climate_idle() {
        let car = SnapshotCar()
        let model = ClimateModel(send: car.send, wake: car.wake, locale: Self.uk)
        model.state = row { $0.hvacOn = false }
        model.reachability = .reachable
        check(ClimateSheet(model: model))
    }

    /// Climate turning on and a new target on its way, with the driver's seat already at 2.
    @Test func climate_pending() async {
        let car = SnapshotCar()
        let model = ClimateModel(send: car.send, wake: car.wake, locale: Self.uk, debounce: .milliseconds(1))
        model.state = row { $0.hvacOn = false }
        model.reachability = .reachable

        model.setSeatHeater(.driver, level: 2)
        #expect(await until { car.sent.count == 1 && !model.seatPending(.driver) })

        car.holding = true
        let toggle = Task { await model.toggleClimate() }
        model.increaseTarget()
        model.increaseTarget()
        #expect(await until { model.climatePending && model.targetPending && car.heldCount == 2 })
        check(ClimateSheet(model: model))

        car.release()
        await toggle.value
        #expect(await until { !model.targetPending })
    }

    /// The bridge's proxy can't be reached (Tailscale off): the controls are disabled with the
    /// Tailscale line (spec §12).
    @Test func climate_unreachable() {
        let car = SnapshotCar()
        let model = ClimateModel(send: car.send, wake: car.wake, locale: Self.uk)
        model.state = row { $0.hvacOn = false }
        model.reachability = .unreachable
        check(ClimateSheet(model: model))
    }

    // MARK: Charge

    @Test func charge_charging() {
        let car = SnapshotCar()
        let model = ChargeModel(send: car.send, wake: car.wake, now: { Self.now }, timeZone: Self.utc)
        model.state = row {
            $0.chargeState = "Charging"
            $0.chargerPowerKw = 7.2
            $0.chargePortOpen = true
        }
        model.reachability = .reachable
        check(ChargeSheet(model: model))
    }

    /// Plugged in and waiting for a 23:30 start, limit 80 %.
    @Test func charge_scheduled() {
        let car = SnapshotCar()
        let model = ChargeModel(send: car.send, wake: car.wake, now: { Self.now }, timeZone: Self.utc)
        model.state = row {
            $0.soc = 54
            $0.chargeState = "Stopped"
            $0.chargePortOpen = true
            $0.chargeLimitSoc = 80
            $0.scheduledChargeAt = Self.now.addingTimeInterval(9 * 3600) // 23:30 UTC
        }
        model.reachability = .reachable
        check(ChargeSheet(model: model))
    }

    /// Plugged in and not charging: Start and a new 80 % limit on their way to the car (spec §12).
    @Test func charge_pending() async {
        let car = SnapshotCar()
        let model = ChargeModel(send: car.send, wake: car.wake, now: { Self.now }, timeZone: Self.utc, debounce: .milliseconds(1))
        model.state = row {
            $0.soc = 54
            $0.chargeState = "Stopped"
            $0.chargePortOpen = true
            $0.chargeLimitSoc = 90
        }
        model.reachability = .reachable

        car.holding = true
        let start = Task { await model.toggleCharging() }
        model.setChargeLimit(80)
        model.commitChargeLimit()
        #expect(await until { model.chargingPending && model.limitPending && car.heldCount == 2 })
        check(ChargeSheet(model: model))

        car.release()
        await start.value
        #expect(await until { !model.limitPending })
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// Records commands and can hold them in flight, for the pending snapshot.
@MainActor
private final class SnapshotCar {
    private(set) var sent: [Command] = []
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    var send: CommandRunner.Send {
        { [unowned self] command in
            self.sent.append(command)
            if self.holding { await withCheckedContinuation { self.held.append($0) } }
            return true
        }
    }

    var wake: CommandRunner.Wake { { true } }

    func release() {
        holding = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}
#endif
