import Foundation
import Testing
@testable import GarageKit

/// The world the onboarding checks look at, with every answer settable and every call counted.
@MainActor
private final class FakeWorld {
    var session = false
    /// The signed-in user's id while `session` is true.
    var userID = UUID()
    /// Awaited inside the session check when set, so a test can act while an evaluation is in flight.
    var sessionGate: (@MainActor () async -> Void)?
    var connected = false
    var vehicle: Vehicle?
    var reachability: ProxyReachability.State = .unreachable
    /// Thrown by the connection check instead of answering, when set.
    var connectionError: (any Error)?

    var sessionCalls = 0
    var connectionCalls = 0
    var vehicleCalls = 0
    var reachabilityCalls = 0

    var checks: OnboardingFlow.Checks {
        OnboardingFlow.Checks(
            sessionUserID: { [unowned self] in
                sessionCalls += 1
                if let sessionGate { await sessionGate() }
                return session ? userID : nil
            },
            isTeslaConnected: { [unowned self] in
                connectionCalls += 1
                if let connectionError { throw connectionError }
                return connected
            },
            vehicle: { [unowned self] in
                vehicleCalls += 1
                return vehicle
            },
            proxyReachability: { [unowned self] in
                reachabilityCalls += 1
                return reachability
            }
        )
    }

    /// Everything in place: signed in, Tesla connected, one car, proxy reachable.
    func allGood() {
        session = true
        connected = true
        vehicle = Vehicle(id: UUID(), vin: "LRWYGCEK0PC000001", displayName: "Ghost")
        reachability = .reachable
    }
}

/// A private, empty defaults domain per test, so "completed before" never leaks between tests.
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "OnboardingFlowTests-\(UUID().uuidString)")!
}

@MainActor @Suite struct OnboardingFlowTests {
    @Test func flowStartsAtSignInWithoutSession() async {
        let world = FakeWorld()
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())

        #expect(flow.step == .signIn)
        await flow.evaluate()

        #expect(flow.step == .signIn)
        #expect(flow.hasEvaluated)
        // Nothing past the session check is asked without a session.
        #expect(world.connectionCalls == 0)
        #expect(world.vehicleCalls == 0)
        #expect(world.reachabilityCalls == 0)
    }

    @Test func flowGoesToConnectTeslaWhenNotConnected() async {
        let world = FakeWorld()
        world.session = true
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())

        await flow.evaluate()

        #expect(flow.step == .connectTesla)
        #expect(world.vehicleCalls == 0)
    }

    @Test func flowGoesToVehicleWhenNoVehicles() async {
        let world = FakeWorld()
        world.session = true
        world.connected = true
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())

        await flow.evaluate()

        #expect(flow.step == .chooseVehicle)
        #expect(world.reachabilityCalls == 0)
    }

    @Test func flowGoesToTailscaleWhenProxyUnreachable() async {
        let world = FakeWorld()
        world.allGood()
        world.reachability = .unreachable
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())

        await flow.evaluate()

        #expect(flow.step == .tailscale)
        #expect(flow.proxyState == .unreachable)

        // No published proxy URL yet is not "reachable" either.
        world.reachability = .unknown
        await flow.evaluate()
        #expect(flow.step == .tailscale)
        #expect(flow.proxyState == .unknown)
    }

    @Test func flowDoneWhenAllGood() async {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        let flow = OnboardingFlow(checks: world.checks, defaults: defaults)

        await flow.evaluate()

        #expect(flow.step == .done)
        #expect(flow.lastError == nil)
        #expect(OnboardingFlow.hasCompleted(by: world.userID, in: defaults))
    }

    @Test func callbackURLReevaluates() async throws {
        let world = FakeWorld()
        world.session = true
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())
        await flow.evaluate()
        #expect(flow.step == .connectTesla)

        // The Tesla OAuth finished on the backend, which then redirects to garage://connected.
        world.connected = true
        world.vehicle = Vehicle(id: UUID(), vin: "LRWYGCEK0PC000001", displayName: "Ghost")
        world.reachability = .reachable
        let handled = await flow.handle(url: try #require(URL(string: "garage://connected?ok=1")))

        #expect(handled)
        #expect(flow.step == .done)
        #expect(world.connectionCalls == 2)
    }

    // MARK: Beyond the brief

    @Test func unrelatedURLIsIgnored() async throws {
        let world = FakeWorld()
        world.session = true
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())
        await flow.evaluate()

        #expect(await flow.handle(url: try #require(URL(string: "https://example.com/connected"))) == false)
        #expect(await flow.handle(url: try #require(URL(string: "garage://elsewhere"))) == false)
        #expect(world.connectionCalls == 1)
    }

    @Test func callbackErrorIsSurfacedAndStepKept() async throws {
        let world = FakeWorld()
        world.session = true
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())
        await flow.evaluate()

        let handled = await flow.handle(url: try #require(URL(string: "garage://connected?error=access_denied")))

        #expect(handled)
        #expect(flow.step == .connectTesla)
        #expect(flow.lastError == "Tesla access wasn't allowed. Connect again and approve Garage's permissions.")
    }

    @Test func callbackErrorCodesHaveFixedCopy() {
        #expect(OnboardingFlow.callbackMessage(for: "state_mismatch") == "The Tesla sign-in expired or came from another attempt. Connect again.")
        #expect(OnboardingFlow.callbackMessage(for: "bad_state") == OnboardingFlow.callbackMessage(for: "state_mismatch"))
        #expect(OnboardingFlow.callbackMessage(for: "token_exchange_failed") == "Tesla signed you in, but Garage couldn't finish connecting. Try again in a minute.")
        // Anything else, including raw exception text from the backend, is never shown as is.
        #expect(OnboardingFlow.callbackMessage(for: "fetch failed: <script>") == "Tesla sign-in didn't complete. Try again.")
    }

    @Test func networkErrorKeepsCurrentStep() async {
        let world = FakeWorld()
        world.allGood()
        let flow = OnboardingFlow(checks: world.checks, defaults: freshDefaults())
        await flow.evaluate()
        #expect(flow.step == .done)

        world.connectionError = URLError(.notConnectedToInternet)
        await flow.evaluate()

        #expect(flow.step == .done)
        #expect(flow.lastError != nil)

        // The next good answer clears it.
        world.connectionError = nil
        await flow.evaluate()
        #expect(flow.lastError == nil)
    }

    @Test func refusedSessionGoesToSignIn() async {
        let world = FakeWorld()
        world.allGood()
        world.connectionError = APIError.unauthorized
        let flow = OnboardingFlow(step: .done, checks: world.checks, defaults: freshDefaults())

        await flow.evaluate()

        #expect(flow.step == .signIn)
    }

    @Test func unreachableProxyDoesNotBlockAfterFirstCompletion() async {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        let first = OnboardingFlow(checks: world.checks, defaults: defaults)
        await first.evaluate()
        #expect(first.step == .done)

        // Next launch, away from home with Tailscale off: Status shows its banner instead.
        world.reachability = .unreachable
        let next = OnboardingFlow(checks: world.checks, defaults: defaults)
        await next.evaluate()
        #expect(next.step == .done)

        OnboardingFlow.resetCompletion(in: defaults)
        await next.evaluate()
        #expect(next.step == .tailscale)
    }

    @Test func completionFlagIgnoredForDifferentUser() async {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        let first = OnboardingFlow(checks: world.checks, defaults: defaults)
        await first.evaluate()
        #expect(first.step == .done)

        // Another account on the same device, Tailscale off: the first user's completion does not count.
        world.userID = UUID()
        world.reachability = .unreachable
        let next = OnboardingFlow(checks: world.checks, defaults: defaults)
        await next.evaluate()
        #expect(next.step == .tailscale)
    }

    @Test func everyRouteToSignInClearsCompletion() async {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        let flow = OnboardingFlow(checks: world.checks, defaults: defaults)
        await flow.evaluate()
        #expect(OnboardingFlow.hasCompleted(by: world.userID, in: defaults))

        world.session = false
        await flow.evaluate()
        #expect(flow.step == .signIn)
        #expect(!OnboardingFlow.hasCompleted(by: world.userID, in: defaults))

        world.session = true
        await flow.evaluate()
        #expect(flow.step == .done)
        world.connectionError = APIError.unauthorized
        await flow.evaluate()
        #expect(flow.step == .signIn)
        #expect(!OnboardingFlow.hasCompleted(by: world.userID, in: defaults))
    }

    @Test func signedOutHookRunsWhenLandingOnSignIn() async {
        let world = FakeWorld()
        world.allGood()
        let flow = OnboardingFlow(step: .done, checks: world.checks, defaults: freshDefaults())
        var calls: [Bool] = []
        flow.onSignedOut = { refused in calls.append(refused) }

        await flow.evaluate()
        #expect(calls.isEmpty)

        world.connectionError = APIError.unauthorized
        await flow.evaluate()
        #expect(calls == [true])

        world.connectionError = nil
        world.session = false
        await flow.evaluate()
        // Already on sign-in and not refused: nothing new to clean up.
        #expect(calls == [true])
    }

    @Test func resetMidEvaluateShowsSignIn() async {
        let world = FakeWorld()
        world.allGood()
        let (gate, open) = AsyncStream<Void>.makeStream()
        world.sessionGate = {
            for await _ in gate { break }
        }
        let flow = OnboardingFlow(step: .done, checks: world.checks, defaults: freshDefaults())

        let evaluation = Task { await flow.evaluate() }
        while world.sessionCalls == 0 { await Task.yield() }
        // The SDK emitted .signedOut (revoked refresh token) while the evaluation was waiting.
        flow.reset()
        open.yield()
        open.finish()
        await evaluation.value

        #expect(flow.step == .signIn)
        #expect(flow.hasEvaluated)
        #expect(!flow.isEvaluating)
    }

    /// "Reconnect Tesla" in More: from the app proper straight to the Connect step, abandoning any
    /// evaluation in flight and keeping this device's completion record.
    @Test func resetToConnectTeslaShowsConnectStep() async {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        OnboardingFlow.markCompleted(by: world.userID, in: defaults)
        let (gate, open) = AsyncStream<Void>.makeStream()
        world.sessionGate = {
            for await _ in gate { break }
        }
        let flow = OnboardingFlow(step: .done, checks: world.checks, defaults: defaults)
        flow.lastError = "old"

        let evaluation = Task { await flow.evaluate() }
        while world.sessionCalls == 0 { await Task.yield() }
        flow.reset(to: .connectTesla)
        open.yield()
        open.finish()
        await evaluation.value

        #expect(flow.step == .connectTesla)
        #expect(flow.reconnectRequested)
        #expect(flow.lastError == nil)
        #expect(flow.hasEvaluated)
        #expect(!flow.isEvaluating)
        #expect(OnboardingFlow.hasCompleted(by: world.userID, in: defaults))
    }

    /// `/api/connection` still says connected after a failed rotation, so a requested reconnect must
    /// hold Connect through evaluations until the Tesla sign-in comes back cleanly.
    @Test func reconnectHoldsConnectUntilCallback() async throws {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        OnboardingFlow.markCompleted(by: world.userID, in: defaults)
        let flow = OnboardingFlow(step: .done, checks: world.checks, defaults: defaults)

        flow.reset(to: .connectTesla)
        await flow.evaluate()
        #expect(flow.step == .connectTesla, "evaluate (scene active) must not bounce back to done")
        #expect(flow.reconnectRequested)

        // A sign-in that came back with an error keeps the owner on Connect.
        await flow.handle(url: try #require(URL(string: "garage://connected?error=access_denied")))
        #expect(flow.step == .connectTesla)
        #expect(flow.reconnectRequested)

        await flow.handle(url: try #require(URL(string: "garage://connected")))
        #expect(!flow.reconnectRequested)
        #expect(flow.step == .done)
    }

    /// "Not now" on a requested reconnect returns to the app without connecting.
    @Test func notNowReturnsToDone() async {
        let world = FakeWorld()
        world.allGood()
        let defaults = freshDefaults()
        OnboardingFlow.markCompleted(by: world.userID, in: defaults)
        let flow = OnboardingFlow(step: .done, checks: world.checks, defaults: defaults)

        flow.reset(to: .connectTesla)
        flow.cancelReconnect()
        #expect(flow.step == .done)
        #expect(!flow.reconnectRequested)
        await flow.evaluate()
        #expect(flow.step == .done)

        // Signing out drops a pending request too.
        flow.reset(to: .connectTesla)
        flow.reset()
        #expect(!flow.reconnectRequested)
        #expect(flow.step == .signIn)
    }

    @Test func connectedCallbackRecognised() throws {
        #expect(OnboardingFlow.isConnectedCallback(try #require(URL(string: "garage://connected"))))
        #expect(OnboardingFlow.isConnectedCallback(try #require(URL(string: "GARAGE://connected?ok=1"))))
        #expect(!OnboardingFlow.isConnectedCallback(try #require(URL(string: "garage://other"))))
    }

    /// The callback's `error` item is read the same way by the flow and the app model.
    @Test func callbackErrorReadsTheQueryItem() {
        #expect(OnboardingFlow.callbackError(in: URL(string: "garage://connected")!) == nil)
        #expect(OnboardingFlow.callbackError(in: URL(string: "garage://connected?auth_callback=1")!) == nil)
        #expect(OnboardingFlow.callbackError(in: URL(string: "garage://connected?error=access_denied")!) == "access_denied")
    }
}
