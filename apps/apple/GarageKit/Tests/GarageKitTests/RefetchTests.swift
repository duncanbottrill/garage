import Foundation
import Testing
@testable import GarageKit

/// A row fetcher whose answers the test changes as it goes, counting calls; `holdState` makes the
/// next state fetches wait until `release()`.
final class MutableRows: VehicleRowFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _vehicle: Vehicle?
    private var _state: VehicleState?
    private var _vehicleCalls = 0
    private var _stateCalls = 0
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(vehicle: Vehicle?, state: VehicleState? = nil) {
        _vehicle = vehicle
        _state = state
    }

    var vehicle: Vehicle? {
        get { lock.withLock { _vehicle } }
        set { lock.withLock { _vehicle = newValue } }
    }
    var state: VehicleState? {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var vehicleCalls: Int { lock.withLock { _vehicleCalls } }
    var stateCalls: Int { lock.withLock { _stateCalls } }
    var waiting: Int { lock.withLock { waiters.count } }

    func holdState() { lock.withLock { holding = true } }

    func release() {
        let pending = lock.withLock {
            holding = false
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func fetchVehicle() async throws -> Vehicle? {
        lock.withLock {
            _vehicleCalls += 1
            return _vehicle
        }
    }

    func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        await withCheckedContinuation { continuation in
            let wait = lock.withLock {
                _stateCalls += 1
                if holding { waiters.append(continuation) }
                return holding
            }
            if !wait { continuation.resume() }
        }
        return state
    }
}

private let carID = UUID(uuidString: "5B0B8E2C-3D0F-4C1A-9E59-1C2A3B4D5E6F")!
private let published = URL(string: "https://garage-bridge.tail068c8f.ts.net:4443")!

private func car(proxy: URL? = nil) -> Vehicle {
    Vehicle(id: carID, vin: "LRWYGCEK0PC123456", displayName: "Model Y", proxyBaseURL: proxy)
}

private func row(soc: Double, updatedAt: TimeInterval) -> VehicleState {
    var state = VehicleState()
    state.vehicleId = carID
    state.soc = soc
    state.updatedAt = Date(timeIntervalSince1970: updatedAt)
    return state
}

@MainActor
private final class FlowRef {
    weak var flow: OnboardingFlow?
}

/// `VehicleStore.refetch()`: the free PostgREST re-read the app does on returning to the foreground.
@MainActor @Suite struct VehicleStoreRefetchTests {
    @Test func refetchAdoptsNewerRowAndVehicle() async {
        let rows = MutableRows(vehicle: car(), state: row(soc: 50, updatedAt: 1000))
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache())
        await store.start()
        #expect(store.state?.soc == 50)

        rows.state = row(soc: 61, updatedAt: 2000)
        rows.vehicle = car(proxy: published)
        await store.refetch()
        #expect(store.state?.soc == 61)
        #expect(store.vehicle?.proxyBaseURL == published)
        #expect(store.isStarted, "a re-read, not a restart")
    }

    @Test func refetchKeepsNewerCurrentRow() async {
        let rows = MutableRows(vehicle: car(), state: row(soc: 50, updatedAt: 2000))
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache())
        await store.start()

        rows.state = row(soc: 40, updatedAt: 1000)
        await store.refetch()
        #expect(store.state?.soc == 50, "an older row never rolls back a newer one")
    }

    @Test func refetchAbandonedByStop() async {
        let rows = MutableRows(vehicle: car(), state: row(soc: 50, updatedAt: 1000))
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache())
        await store.start()

        rows.state = row(soc: 70, updatedAt: 3000)
        rows.holdState()
        let refetch = Task { await store.refetch() }
        #expect(await eventually { rows.waiting == 1 })
        store.stop()
        rows.release()
        await refetch.value
        #expect(store.state?.soc == 50, "stopped while fetching: nothing written")
    }

    @Test func refetchDoesNothingUnlessStarted() async {
        let rows = MutableRows(vehicle: car(), state: row(soc: 50, updatedAt: 1000))
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache(), vehicle: car())
        await store.refetch()
        #expect(rows.vehicleCalls == 0)
        #expect(rows.stateCalls == 0)
        #expect(store.state == nil)
    }
}

/// Onboarding's vehicle check re-reads the vehicles row while the proxy URL is unknown, so the
/// Tailscale step's "Check again" picks up a URL the bridge published after the app launched.
@MainActor @Suite struct OnboardingVehicleRefetchTests {
    @Test func checkAgainPicksUpPublishedProxyURL() async {
        let rows = MutableRows(vehicle: car())
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache())
        await store.start()
        let defaults = UserDefaults(suiteName: "OnboardingVehicleRefetchTests-\(UUID().uuidString)")!
        let user = UUID()
        let owner = FlowRef()
        let flow = OnboardingFlow(
            checks: OnboardingFlow.Checks(
                sessionUserID: { user },
                isTeslaConnected: { true },
                vehicle: {
                    // As the app's check does: the flow's last probe decides whether to re-read.
                    let proxyState = owner.flow?.proxyState ?? .unknown
                    return try await AppModel.onboardingVehicle(store: store, proxyState: proxyState) { try await rows.fetchVehicle() }.vehicle
                },
                // No published URL: nothing to probe.
                proxyReachability: { store.vehicle?.proxyBaseURL == nil ? .unknown : .reachable }
            ),
            defaults: defaults
        )
        owner.flow = flow

        await flow.evaluate()
        #expect(flow.step == .tailscale)
        #expect(flow.proxyState == .unknown)

        // The bridge publishes its URL while the app is open; "Check again" re-evaluates.
        rows.vehicle = car(proxy: published)
        await flow.evaluate()
        #expect(store.vehicle?.proxyBaseURL == published)
        #expect(flow.step == .done)
    }

    /// With a URL known and probed, the in-memory car is used as is (no extra read).
    @Test func knownURLIsNotRefetched() async throws {
        let rows = MutableRows(vehicle: car(proxy: published))
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache())
        await store.start()
        let calls = rows.vehicleCalls

        let found = try await AppModel.onboardingVehicle(store: store, proxyState: .unreachable) { try await rows.fetchVehicle() }
        #expect(found.vehicle == car(proxy: published))
        #expect(!found.refetched)
        #expect(rows.vehicleCalls == calls)
    }

    /// No car in memory: the throwing fetch decides, and a found car starts the store.
    @Test func noCarInMemoryFetchesAndStarts() async throws {
        let rows = MutableRows(vehicle: car(proxy: published))
        let store = VehicleStore(feed: IdleFeed(), fetcher: rows, cache: InMemorySnapshotCache())
        let found = try await AppModel.onboardingVehicle(store: store, proxyState: .unknown) { try await rows.fetchVehicle() }
        #expect(found.vehicle?.id == carID)
        #expect(store.isStarted)

        let none = VehicleStore(feed: IdleFeed(), fetcher: MutableRows(vehicle: nil), cache: InMemorySnapshotCache())
        await #expect(throws: URLError.self) {
            _ = try await AppModel.onboardingVehicle(store: none, proxyState: .unknown) { throw URLError(.notConnectedToInternet) }
        }
    }
}
