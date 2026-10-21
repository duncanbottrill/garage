import Foundation
import Testing
@testable import GarageKit

/// The wake rules ``CommandRunner`` adds on top of the prompt: the grace after a wake and the
/// short window after a Cancel.
@MainActor @Suite struct CommandRunnerTests {
    private func runner(_ car: FakeCar, clock: TestClock, asleep: Bool = true) -> CommandRunner {
        let runner = CommandRunner(send: car.send, wake: car.wake, awaitAwake: car.awaitAwake, now: clock.read)
        runner.isAsleep = { asleep }
        runner.hostsPrompt = true
        return runner
    }

    /// Wakes once through the prompt and returns after the command went out.
    private func wakeAndSend(_ runner: CommandRunner) async {
        let first = Task { await runner.run(.flashLights) }
        #expect(await eventually { runner.isAskingToWake })
        runner.confirmWake()
        #expect(await first.value == .sent)
    }

    /// Inside the 120 s grace a stale `asleep` row sends without asking; past it, the prompt is back.
    @Test func graceSkipsPromptThenExpires() async {
        let car = FakeCar()
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        await wakeAndSend(runner)
        #expect(car.wakes == 1)

        clock.advance(119)
        #expect(!runner.needsWakePrompt)
        #expect(await runner.run(.honkHorn) == .sent)
        #expect(car.sent == [.flashLights, .honkHorn])
        #expect(car.wakes == 1)

        clock.advance(2) // 121 s after the wake
        #expect(runner.needsWakePrompt)
        let late = Task { await runner.run(.honkHorn) }
        #expect(await eventually { runner.isAskingToWake })
        runner.cancelWake()
        #expect(await late.value == .declined)
        #expect(car.wakes == 1)
    }

    /// While a control sheet covers Status, Status's prompt cannot be seen: a Status command that
    /// needs a wake is declined at once instead of waiting on it, and one already waiting is declined.
    @Test func coveredHostDeclinesInsteadOfAsking() async {
        let car = FakeCar()
        let clock = TestClock()
        let runner = runner(car, clock: clock)

        let waiting = Task { await runner.run(.flashLights) }
        #expect(await eventually { runner.isAskingToWake })
        runner.isCovered = true
        #expect(await waiting.value == .declined)
        #expect(!runner.isAskingToWake)

        clock.advance(5) // past the decline window: only the cover declines now
        #expect(await runner.run(.honkHorn) == .declined)
        #expect(!runner.isAskingToWake)
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)

        runner.isCovered = false
        let later = Task { await runner.run(.honkHorn) }
        #expect(await eventually { runner.isAskingToWake }, "uncovered: the prompt asks again")
        runner.confirmWake()
        #expect(await later.value == .sent)
    }

    /// An asleep answer inside the grace is "still waking": no prompt and no second wake.
    @Test func asleepErrorInsideGraceIsStillWaking() async {
        let car = FakeCar()
        let clock = TestClock()
        let runner = runner(car, clock: clock, asleep: false)
        car.asleepFailures = 1
        await wakeAndSend(runner) // asleep error → prompt → wake → resend succeeds

        clock.advance(30)
        car.asleepFailures = 1
        #expect(await runner.run(.honkHorn) == .failed)
        #expect(!runner.isAskingToWake)
        #expect(car.wakes == 1)
        #expect(runner.toast?.message == CommandRunner.stillWakingMessage)
    }

    /// For a second after Cancel, a command that needs a wake is declined without asking again.
    @Test func cancelDeclinesForOneSecond() async {
        let car = FakeCar()
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        #expect(CommandRunner.declineWindow == 1)

        let first = Task { await runner.run(.flashLights) }
        #expect(await eventually { runner.isAskingToWake })
        runner.cancelWake()
        #expect(await first.value == .declined)

        clock.advance(0.5)
        #expect(await runner.run(.honkHorn) == .declined)
        #expect(!runner.isAskingToWake)

        clock.advance(0.6)
        let later = Task { await runner.run(.honkHorn) }
        #expect(await eventually { runner.isAskingToWake })
        runner.cancelWake()
        _ = await later.value
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)
    }

    /// A wake confirmed on another surface (a sheet, More) inside the grace skips this runner's
    /// prompt too, and the later of the two wakes is the one that counts.
    @Test func wakeElsewhereIsThisRunnersGraceToo() async {
        let car = FakeCar()
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        var elsewhere: Date? = nil
        runner.lastWakeElsewhere = { elsewhere }
        #expect(runner.needsWakePrompt)

        elsewhere = clock.now.addingTimeInterval(-30)
        #expect(!runner.needsWakePrompt)
        #expect(await runner.run(.honkHorn) == .sent)
        #expect(car.wakes == 0)
        #expect(car.sent == [.honkHorn])

        clock.advance(100) // 130 s after the other surface's wake
        #expect(runner.needsWakePrompt)
        elsewhere = clock.now.addingTimeInterval(-10)
        #expect(!runner.needsWakePrompt)

        // This runner's own wake counts too: the grace then runs from its time even though the
        // other surface's wake is older.
        elsewhere = clock.now.addingTimeInterval(-200)
        #expect(runner.needsWakePrompt)
        await wakeAndSend(runner)
        #expect(car.wakes == 1)
        clock.advance(119)
        #expect(!runner.needsWakePrompt)
    }

    /// Without a prompt on screen, a command that needs a wake is declined at once.
    @Test func noPromptHostDeclines() async {
        let car = FakeCar()
        let runner = runner(car, clock: TestClock())
        runner.hostsPrompt = false
        #expect(await runner.run(.flashLights) == .declined)
        #expect(!runner.isAskingToWake)
        #expect(car.wakes == 0)
        #expect(car.sent.isEmpty)
    }

    /// After the Wake tap the command is held until the row says the car is online, then sent once.
    @Test func waitsForOnlineAfterWakeBeforeSending() async {
        let car = FakeCar()
        car.holdingOnline = true
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        let run = Task { await runner.run(.flashLights) }
        #expect(await eventually { runner.isAskingToWake })
        runner.confirmWake()
        #expect(await eventually { car.wakes == 1 && car.onlineWaits == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(car.sent.isEmpty, "nothing is sent while the row still says asleep")

        car.comeOnline()
        #expect(await run.value == .sent)
        #expect(car.sent == [.flashLights])
    }

    /// If the row never flips inside the wait, the command still goes once (and an asleep answer
    /// then reads as still waking).
    @Test func sendsOnceWhenOnlineWaitGivesUp() async {
        let car = FakeCar()
        car.onlineAfterWake = false
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        await wakeAndSend(runner)
        #expect(car.onlineWaits == 1)
        #expect(car.sent == [.flashLights])

        car.asleepFailures = 1
        #expect(await runner.run(.honkHorn) == .failed)
        #expect(runner.toast?.message == CommandRunner.stillWakingMessage)
    }

    /// A different command tapped while the car is coming online joins the wait instead of going out
    /// early (inside the grace the prompt is skipped, but the car is not up yet).
    @Test func commandDuringOnlineWaitJoinsIt() async {
        let car = FakeCar()
        car.holdingOnline = true
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        let first = Task { await runner.run(.flashLights) }
        #expect(await eventually { runner.isAskingToWake })
        runner.confirmWake()
        #expect(await eventually { car.onlineWaits == 1 })
        #expect(!runner.needsWakePrompt, "inside the grace")

        let second = Task { await runner.run(.honkHorn) }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(car.sent.isEmpty)
        #expect(!runner.isAskingToWake)

        car.comeOnline()
        #expect(await first.value == .sent)
        #expect(await second.value == .sent)
        #expect(Set(car.sent) == [.flashLights, .honkHorn])
        #expect(car.wakes == 1)
    }

    /// Cancelling while the car is coming online (the host going away, a sheet covering it) declines
    /// the woken commands: nothing is sent late.
    @Test func cancelDuringOnlineWaitDeclines() async {
        let car = FakeCar()
        car.holdingOnline = true
        let clock = TestClock()
        let runner = runner(car, clock: clock)
        let run = Task { await runner.run(.actuateFrunk) }
        #expect(await eventually { runner.isAskingToWake })
        runner.confirmWake()
        #expect(await eventually { car.onlineWaits == 1 })

        runner.cancelWake()
        #expect(await run.value == .declined)
        #expect(car.sent.isEmpty)
        #expect(car.wakes == 1)

        // The cover does the same.
        car.holdingOnline = true
        clock.advance(130) // past the grace, so the prompt asks again
        let again = Task { await runner.run(.actuateFrunk) }
        #expect(await eventually { runner.isAskingToWake })
        runner.confirmWake()
        #expect(await eventually { car.onlineWaits == 2 })
        runner.isCovered = true
        #expect(await again.value == .declined)
        #expect(car.sent.isEmpty)
    }
}
