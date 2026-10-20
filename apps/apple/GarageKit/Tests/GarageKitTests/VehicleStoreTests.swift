import Foundation
import Supabase
import Testing
@testable import GarageKit

/// A Realtime feed that replays fixed events and then stays open, like a live channel.
private struct FakeFeed: RealtimeFeed {
    let events: [RealtimeFeedEvent]

    func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
        }
    }
}

/// A row fetcher with canned answers that counts its calls, so tests can tell whether the network was asked.
private final class FakeFetcher: VehicleRowFetcher, @unchecked Sendable {
    let vehicle: Vehicle?
    let state: VehicleState?
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(vehicle: Vehicle?, state: VehicleState?) {
        self.vehicle = vehicle
        self.state = state
    }

    func fetchVehicle() async throws -> Vehicle? {
        lock.withLock { _calls += 1 }
        return vehicle
    }

    func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        lock.withLock { _calls += 1 }
        return state
    }
}

private let vehicleID = UUID(uuidString: "e821390b-f84c-4cd4-a125-9f2f3188e45f")!
private let testVehicle = Vehicle(id: vehicleID, vin: "TESTVIN0000000000", displayName: "Model Y", model: "Model Y", budgetMode: .normal)

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite struct VehicleStoreTests {
    /// A Realtime UPDATE record replaces the state, marks the store live and is written to the cache file.
    @Test func storeAppliesRealtimeRowAndPersists() async throws {
        let dir = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garage/vehicle_state.json")
        let row = try Fixture.row("vehicle_state_live")
        let store = VehicleStore(
            feed: FakeFeed(events: [.subscribed, .row(row)]),
            fetcher: FakeFetcher(vehicle: testVehicle, state: try Fixture.state("vehicle_state_sparse")),
            cache: FileSnapshotCache(url: url)
        )
        #expect(store.state == nil)

        await store.start()
        await waitUntil { store.lastRealtimeAt != nil }

        #expect(store.vehicle == testVehicle)
        #expect(store.state?.soc == 33.93464052287582)
        #expect(store.state?.tpmsBar?.fl == 3.1)
        #expect(store.isLive)
        #expect(store.lastRealtimeAt != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileSnapshotCache(url: url).load()?.soc == 33.93464052287582)

        store.stop()
        #expect(store.isLive == false)
    }

    /// With a cached snapshot on disk, `state` is populated by `init` itself, before any fetch.
    @Test func storeLoadsCacheBeforeNetwork() throws {
        let dir = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FileSnapshotCache(url: dir.appendingPathComponent("garage/vehicle_state.json"))
        let cached = try Fixture.state("vehicle_state_live")
        cache.save(cached)
        let fetcher = FakeFetcher(vehicle: testVehicle, state: nil)

        let store = VehicleStore(feed: FakeFeed(events: []), fetcher: fetcher, cache: cache)

        #expect(store.state == cached)
        #expect(store.isLive == false)
        #expect(fetcher.calls == 0)
    }
}
