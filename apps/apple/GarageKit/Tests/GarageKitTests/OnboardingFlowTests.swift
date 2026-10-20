import Foundation
import Testing
@testable import GarageKit

/// The world the onboarding checks look at, with every answer settable and every call counted.
@MainActor
private final class FakeWorld {
    var session = false
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
            hasSession: { [unowned self] in
                sessionCalls += 1
                return session
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
        #expect(OnboardingFlow.hasCompleted(in: defaults))
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
        #expect(flow.lastError == "Tesla didn't connect (access_denied). Try again.")
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

    @Test func connectedCallbackRecognised() throws {
        #expect(OnboardingFlow.isConnectedCallback(try #require(URL(string: "garage://connected"))))
        #expect(OnboardingFlow.isConnectedCallback(try #require(URL(string: "GARAGE://connected?ok=1"))))
        #expect(!OnboardingFlow.isConnectedCallback(try #require(URL(string: "garage://other"))))
    }
}
