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
    private var _stateCalls = 0
    var calls: Int { lock.withLock { _calls } }
    var stateCalls: Int { lock.withLock { _stateCalls } }

    init(vehicle: Vehicle?, state: VehicleState?) {
        self.vehicle = vehicle
        self.state = state
    }

    func fetchVehicle() async throws -> Vehicle? {
        lock.withLock { _calls += 1 }
        return vehicle
    }

    func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        lock.withLock {
            _calls += 1
            _stateCalls += 1
        }
        return state
    }
}

/// A feed that replays fixed events and records how many streams were opened and torn down.
private final class RecordingFeed: RealtimeFeed, @unchecked Sendable {
    let events: [RealtimeFeedEvent]
    private let lock = NSLock()
    private var _opened = 0
    private var _terminated = 0
    var opened: Int { lock.withLock { _opened } }
    var terminated: Int { lock.withLock { _terminated } }

    init(events: [RealtimeFeedEvent]) {
        self.events = events
    }

    func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        lock.withLock { _opened += 1 }
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self._terminated += 1 }
            }
        }
    }
}

/// A fetcher whose `fetchVehicle` suspends until `release()`, so a test can act while `start()` is mid-fetch.
private final class GatedFetcher: VehicleRowFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _entered = 0
    var entered: Int { lock.withLock { _entered } }

    func fetchVehicle() async throws -> Vehicle? {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                _entered += 1
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return testVehicle
    }

    func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        try Fixture.state("vehicle_state_sparse")
    }

    func release() {
        let pending = lock.withLock {
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
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

    /// After a dropped channel rejoins, the row is fetched again (once at start, once on reconnect).
    @Test func refetchesOnReconnect() async throws {
        let fetcher = FakeFetcher(vehicle: testVehicle, state: try Fixture.state("vehicle_state_sparse"))
        let store = VehicleStore(
            feed: FakeFeed(events: [.subscribed, .disconnected, .subscribed]),
            fetcher: fetcher,
            cache: InMemorySnapshotCache()
        )

        await store.start()
        await waitUntil { fetcher.stateCalls >= 2 && store.isLive }

        #expect(fetcher.stateCalls == 2)
        #expect(store.isLive)
        store.stop()
    }

    /// `stop()` while `start()` is still fetching wins: no feed is opened and the store never goes live.
    @Test func stopDuringStartPreventsSubscription() async throws {
        let fetcher = GatedFetcher()
        let feed = RecordingFeed(events: [.subscribed])
        let store = VehicleStore(feed: feed, fetcher: fetcher, cache: InMemorySnapshotCache())

        let starting = Task { await store.start() }
        await waitUntil { fetcher.entered == 1 }
        store.stop()
        fetcher.release()
        await starting.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(feed.opened == 0)
        #expect(store.isLive == false)
        #expect(store.vehicle == nil)
        #expect(store.state == nil)
    }

    /// Overlapping starts open exactly one feed, and a later restart tears the previous feed down.
    @Test func secondStartCancelsFirstFeed() async throws {
        let fetcher = GatedFetcher()
        let feed = RecordingFeed(events: [.subscribed])
        let store = VehicleStore(feed: feed, fetcher: fetcher, cache: InMemorySnapshotCache())

        let first = Task { await store.start() }
        await waitUntil { fetcher.entered == 1 }
        let second = Task { await store.start() }
        await waitUntil { fetcher.entered == 2 }
        fetcher.release()
        await first.value
        await second.value
        await waitUntil { store.isLive }

        #expect(feed.opened == 1)
        #expect(store.isLive)

        await store.start()
        await waitUntil { feed.terminated == 1 }
        #expect(feed.opened == 2)
        #expect(feed.terminated == 1)
        store.stop()
        await waitUntil { feed.terminated == 2 }
        #expect(feed.terminated == 2)
    }
}
