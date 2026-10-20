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
        defaults.set("https://garage-bridge.other.ts.net:4443", forKey: ProxyOverride.key)
        let model = makeModel(connected: { throw APIError.unauthorized }, defaults: defaults, cache: cache) { ended += 1 }
        #expect(model.vehicleStore.state != nil)
        let more = model.moreModel
        #expect(model.moreModel === more, "one More model, kept")

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
        #expect(defaults.string(forKey: ProxyOverride.key) == nil, "the override belongs to the old account's bridge")
        #expect(model.moreModel !== more, "the More model goes with the account")
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

    /// The More override (https, with a host) wins over the bridge's published proxy URL, for both
    /// commands and the reachability probe; anything else in the override is ignored.
    @Test func proxyOverrideTakesPrecedence() throws {
        let (defaults, cache) = try seed()
        let model = makeModel(connected: { true }, defaults: defaults, cache: cache) {}
        let published = URL(string: "https://garage-bridge.tail068c8f.ts.net:4443")!
        let override = URL(string: "https://garage-bridge.other.ts.net:4443")!

        #expect(AppModel.proxyBaseURL(published: published, defaults: defaults) == published)
        #expect(model.proxyBaseURL == nil, "no vehicle loaded and no override")

        defaults.set(override.absoluteString, forKey: ProxyOverride.key)
        #expect(AppModel.proxyBaseURL(published: published, defaults: defaults) == override)
        #expect(model.proxyBaseURL == override)

        defaults.set("http://garage-bridge.other.ts.net", forKey: ProxyOverride.key)
        #expect(AppModel.proxyBaseURL(published: published, defaults: defaults) == published)
        defaults.set("not a url", forKey: ProxyOverride.key)
        #expect(AppModel.proxyBaseURL(published: published, defaults: defaults) == published)
        #expect(model.proxyBaseURL == nil)
    }
}

extension AppModelTests {
    /// Offline at launch, the store's first fetch fails, so nothing follows the car; the next refresh
    /// (the app coming back to the foreground) on Status starts it. The onboarding checks are faked to
    /// pass (a stored session and a completed onboarding keep the owner on Status offline too); only
    /// the store's own fetch sees the network.
    @Test func refreshStartsStoreWhenFirstLaunchWasOffline() async throws {
        let (defaults, cache) = try seed()
        let vehicle = Vehicle(id: vehicleID, vin: "LRWYGCEK0PC123456", displayName: "Model Y")
        let network = Connectivity()
        let user = userID
        let config = SupabaseEnvironment.Config(
            supabaseURL: URL(string: "https://stub-\(UUID().uuidString).test")!,
            publishableKey: "sb_publishable_test",
            apiBaseURL: URL(string: "https://api-\(UUID().uuidString).test")!
        )
        let model = AppModel(
            environment: SupabaseEnvironment(config: config, authStorage: MemoryAuthStorage()),
            defaults: defaults,
            cache: cache,
            checks: OnboardingFlow.Checks(
                sessionUserID: { user },
                isTeslaConnected: { true },
                vehicle: { vehicle },
                proxyReachability: { .reachable }
            ),
            endSession: {},
            // Supabase is unreachable too while offline, so the store's own fetch fails.
            makeStore: { VehicleStore(feed: IdleFeed(), fetcher: StaticRows(vehicle: vehicle, network: network), cache: cache) }
        )

        await model.launch()
        #expect(model.flow.step == .done)
        #expect(!model.vehicleStore.isStarted)
        #expect(model.vehicleStore.state != nil, "the cached snapshot is on screen")

        network.online = true
        await model.refresh()
        #expect(model.vehicleStore.isStarted)
        #expect(model.vehicleStore.vehicle == vehicle)

        // Already following: a later refresh does not restart it.
        let store = model.vehicleStore
        await model.refresh()
        #expect(model.vehicleStore === store)
        #expect(model.vehicleStore.isStarted)
    }

    /// Going to the background writes the store's pending snapshot.
    @Test func backgroundFlushesSnapshot() async throws {
        let (defaults, cache) = try seed()
        let vehicleID = vehicleID
        let model = AppModel(
            environment: SupabaseEnvironment(
                config: SupabaseEnvironment.Config(
                    supabaseURL: URL(string: "https://stub-\(UUID().uuidString).test")!,
                    publishableKey: "sb_publishable_test",
                    apiBaseURL: URL(string: "https://api-\(UUID().uuidString).test")!
                ),
                authStorage: MemoryAuthStorage()
            ),
            defaults: defaults,
            cache: cache,
            checks: nil,
            endSession: {},
            makeStore: {
                VehicleStore(feed: LiveOnlyFeed(), fetcher: StaticRows(vehicle: nil), cache: cache, vehicle: Vehicle(id: vehicleID, vin: "VIN", displayName: "Model Y"), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
            }
        )
        let store = model.vehicleStore
        await store.start()
        #expect(await eventually { store.isLive })
        var row = try Fixture.row("vehicle_state_live")
        row["vehicle_id"] = .string(vehicleID.uuidString.lowercased())
        row["soc"] = .double(11)
        store.apply(row: row)
        row["soc"] = .double(12)
        store.apply(row: row)
        #expect(cache.load()?.soc == 11)

        model.didEnterBackground()
        #expect(cache.load()?.soc == 12)
        store.stop()
    }
}

/// Whether the fake network is up.
private final class Connectivity: @unchecked Sendable {
    private let lock = NSLock()
    private var _online = false
    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
}

/// A fetcher that answers with `vehicle` and no row, or fails while `network` is down.
private struct StaticRows: VehicleRowFetcher {
    let vehicle: Vehicle?
    var network: Connectivity?

    func fetchVehicle() async throws -> Vehicle? {
        if let network, !network.online { throw URLError(.notConnectedToInternet) }
        return vehicle
    }

    func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        if let network, !network.online { throw URLError(.notConnectedToInternet) }
        return nil
    }
}

/// A feed that joins and then stays quiet.
private struct LiveOnlyFeed: RealtimeFeed {
    func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        AsyncStream { $0.yield(.subscribed) }
    }
}
