import Foundation
import Supabase
import Testing
@testable import GarageKit

/// Supabase session storage in memory, so the model never touches the keychain in tests.
private final class MemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}

@MainActor @Suite struct AppModelTests {
    let userID = UUID()
    let vehicleID = UUID()

    /// A model on a project that is never contacted, with every onboarding check faked.
    private func makeModel(
        connected: @escaping @MainActor () async throws -> Bool,
        session: Bool = true,
        defaults: UserDefaults,
        cache: FileSnapshotCache,
        onEndSession: @escaping @MainActor () async -> Void
    ) -> AppModel {
        let config = SupabaseEnvironment.Config(
            supabaseURL: URL(string: "https://stub-\(UUID().uuidString).test")!,
            publishableKey: "sb_publishable_test",
            apiBaseURL: URL(string: "https://api-\(UUID().uuidString).test")!
        )
        let environment = SupabaseEnvironment(config: config, authStorage: MemoryAuthStorage())
        let user = userID
        let vehicle = Vehicle(id: vehicleID, vin: "LRWYGCEK0PC123456", displayName: "Model Y")
        return AppModel(
            environment: environment,
            defaults: defaults,
            cache: cache,
            checks: OnboardingFlow.Checks(
                sessionUserID: { session ? user : nil },
                isTeslaConnected: connected,
                vehicle: { vehicle },
                proxyReachability: { .reachable }
            ),
            endSession: onEndSession
        )
    }

    /// Account-bound state of a previous session: a cached snapshot, a chosen car and a completion flag.
    private func seed() throws -> (UserDefaults, FileSnapshotCache) {
        let defaults = UserDefaults(suiteName: "AppModelTests-\(UUID().uuidString)")!
        let cache = FileSnapshotCache(url: try Fixture.temporaryDirectory().appendingPathComponent("vehicle_state.json"))
        cache.save(try Fixture.state("vehicle_state_live"))
        VehicleSelection.set(vehicleID, in: defaults)
        OnboardingFlow.markCompleted(by: userID, in: defaults)
        return (defaults, cache)
    }

    @Test func unauthorizedResetsStateAndCache() async throws {
        let (defaults, cache) = try seed()
        var ended = 0
        let model = makeModel(connected: { throw APIError.unauthorized }, defaults: defaults, cache: cache) { ended += 1 }
        #expect(model.vehicleStore.state != nil)

        await model.refresh()

        #expect(model.flow.step == .signIn)
        #expect(model.flow.hasEvaluated)
        #expect(ended == 1)
        #expect(cache.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
        #expect(model.vehicleStore.state == nil)
        #expect(model.vehicleStore.vehicle == nil)
        #expect(VehicleSelection.current(in: defaults) == nil)
        #expect(!OnboardingFlow.hasCompleted(by: userID, in: defaults))
    }

    @Test func missingSessionResetsStateWithoutServerSignOut() async throws {
        let (defaults, cache) = try seed()
        var ended = 0
        let model = makeModel(connected: { true }, session: false, defaults: defaults, cache: cache) { ended += 1 }

        await model.refresh()

        #expect(model.flow.step == .signIn)
        #expect(ended == 0)
        #expect(cache.load() == nil)
        #expect(model.vehicleStore.state == nil)
        #expect(VehicleSelection.current(in: defaults) == nil)
    }
}
