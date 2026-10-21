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

/// A feed whose every stream plays the next script: some events, then either staying open (like a
/// live channel) or finishing (the channel closed for good). Streams past the last script stay silent.
private final class ScriptedFeed: RealtimeFeed, @unchecked Sendable {
    enum Script {
        case open([RealtimeFeedEvent])
        case finish([RealtimeFeedEvent])
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var _opened = 0
    private var _terminated = 0
    private var continuations: [AsyncStream<RealtimeFeedEvent>.Continuation] = []
    var opened: Int { lock.withLock { _opened } }
    var terminated: Int { lock.withLock { _terminated } }

    init(_ scripts: [Script]) {
        self.scripts = scripts
    }

    /// Sends `event` on the newest stream.
    func emit(_ event: RealtimeFeedEvent) {
        _ = lock.withLock { continuations.last }?.yield(event)
    }

    func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        let script: Script? = lock.withLock {
            _opened += 1
            return scripts.isEmpty ? nil : scripts.removeFirst()
        }
        return AsyncStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self._terminated += 1 }
            }
            switch script {
            case let .open(events)?:
                events.forEach { continuation.yield($0) }
            case let .finish(events)?:
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case nil:
                break
            }
        }
    }
}

/// A sleeper the test drives: each sleep waits until ``release()`` and is recorded then; a cancelled
/// one throws at once and is not recorded.
private final class GatedSleeper: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var cancelledEarly: Set<UUID> = []
    private var _released: [Duration] = []
    /// Delays that ran to the end, in order.
    var released: [Duration] { lock.withLock { _released } }
    /// Delays waiting to be released, oldest first.
    var waiting: [Duration] { lock.withLock { waiters.map(\.duration) } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let cancelled = lock.withLock {
                        if cancelledEarly.remove(id) != nil { return true }
                        waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                        return false
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let waiter: Waiter? = lock.withLock {
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                        cancelledEarly.insert(id)
                        return nil
                    }
                    return waiters.remove(at: index)
                }
                waiter?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Ends the oldest waiting sleep.
    func release() {
        let waiter: Waiter? = lock.withLock {
            guard !waiters.isEmpty else { return nil }
            let first = waiters.removeFirst()
            _released.append(first.duration)
            return first
        }
        waiter?.continuation.resume()
    }
}

/// A snapshot cache that counts its writes.
private final class CountingCache: SnapshotCache, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VehicleState?
    private var _saves = 0
    var saves: Int { lock.withLock { _saves } }

    func load() -> VehicleState? { lock.withLock { stored } }

    func save(_ state: VehicleState) {
        lock.withLock {
            stored = state
            _saves += 1
        }
    }
}

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = ContinuousClock.now
    var now: @Sendable () -> ContinuousClock.Instant { { [self] in lock.withLock { _now } } }
    func advance(_ duration: Duration) { lock.withLock { _now = _now.advanced(by: duration) } }
}

/// A sleeper that never returns before it is cancelled.
private let sleepForever: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

extension VehicleStoreTests {
    /// The channel closes while the store is started and the client does not rejoin it: the store
    /// re-subscribes after 2 s, then 4 s while the new channel stays down, and starts again at 2 s
    /// once a channel has joined. Every replaced stream is torn down.
    @Test func resubscribesWithBackoffAfterChannelCloses() async throws {
        let feed = ScriptedFeed([
            .open([.subscribed, .disconnected]),
            .open([]),
            .open([.subscribed, .disconnected]),
            .open([.subscribed]),
        ])
        let sleeper = GatedSleeper()
        let fetcher = FakeFetcher(vehicle: testVehicle, state: try Fixture.state("vehicle_state_sparse"))
        let store = VehicleStore(feed: feed, fetcher: fetcher, cache: InMemorySnapshotCache(), sleep: sleeper.sleep)

        await store.start()
        // Channel 1 joins, then drops: a 2 s wait.
        await waitUntil { sleeper.waiting == [.seconds(2)] && !store.isLive }
        #expect(sleeper.waiting == [.seconds(2)])
        sleeper.release()
        // Channel 2 never joins: the next wait is 4 s.
        await waitUntil { feed.opened == 2 && sleeper.waiting == [.seconds(4)] }
        #expect(sleeper.waiting == [.seconds(4)])
        sleeper.release()
        // Channel 3 joins (cancelling the 8 s wait armed with it) and drops: back to 2 s.
        await waitUntil { feed.opened == 3 && sleeper.waiting == [.seconds(2)] }
        #expect(sleeper.waiting == [.seconds(2)])
        sleeper.release()
        // Channel 4 joins and stays.
        await waitUntil { feed.opened == 4 && store.isLive && sleeper.waiting.isEmpty }

        #expect(feed.opened == 4)
        #expect(sleeper.released == [.seconds(2), .seconds(4), .seconds(2)])
        #expect(sleeper.waiting.isEmpty)
        #expect(feed.terminated == 3)
        #expect(store.isLive)
        #expect(fetcher.stateCalls >= 2, "the row is fetched again after rejoining")
        store.stop()
        await waitUntil { feed.terminated == 4 }
        #expect(feed.terminated == 4)
    }

    /// A stream that ends on its own (the channel is gone) is replaced too.
    @Test func resubscribesWhenStreamEnds() async throws {
        let feed = ScriptedFeed([.finish([.subscribed]), .open([.subscribed])])
        let sleeper = GatedSleeper()
        let store = VehicleStore(feed: feed, fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: InMemorySnapshotCache(), sleep: sleeper.sleep)

        await store.start()
        await waitUntil { sleeper.waiting == [.seconds(2)] }
        #expect(feed.opened == 1)
        sleeper.release()
        await waitUntil { feed.opened == 2 && store.isLive && sleeper.waiting.isEmpty }

        #expect(feed.opened == 2)
        #expect(sleeper.released == [.seconds(2)])
        #expect(store.isLive)
        store.stop()
    }

    /// The client rejoining by itself inside the delay keeps the channel: nothing is re-opened.
    @Test func keepsChannelThatRejoinsInTime() async throws {
        let feed = ScriptedFeed([.open([.subscribed])])
        let store = VehicleStore(feed: feed, fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: InMemorySnapshotCache(), sleep: { _ in
            try await Task.sleep(for: .milliseconds(100))
        })

        await store.start()
        await waitUntil { store.isLive }
        feed.emit(.disconnected)
        await waitUntil { !store.isLive }
        feed.emit(.subscribed)
        try await Task.sleep(for: .milliseconds(300))

        #expect(feed.opened == 1)
        #expect(store.isLive)
        store.stop()
    }

    /// Delays double from 2 s and stay at 60 s.
    @Test func resubscribeDelaysCapAtOneMinute() {
        let delays = (0..<8).map(VehicleStore.resubscribeDelay(attempt:))
        #expect(delays == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60), .seconds(60)])
    }

    /// While live, Realtime rows reach the cache at most once per 5 s; the latest pending row is
    /// written on `stop()`, and a row after the window is written at once.
    @Test func coalescesCacheWritesWhileLive() async throws {
        let cache = CountingCache()
        let clock = ManualClock()
        let feed = ScriptedFeed([.open([.subscribed])])
        let store = VehicleStore(feed: feed, fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: cache, sleep: sleepForever, now: clock.now)
        await store.start()
        await waitUntil { store.isLive }
        var row = try Fixture.row("vehicle_state_live")

        store.apply(row: row)
        #expect(cache.saves == 1, "the first live row is written at once")
        for soc in [40.0, 41, 42] {
            clock.advance(.seconds(1))
            row["soc"] = .double(soc)
            store.apply(row: row)
        }
        #expect(store.state?.soc == 42)
        #expect(cache.saves == 1, "rows inside the window wait")

        clock.advance(.seconds(5))
        row["soc"] = .double(43)
        store.apply(row: row)
        #expect(cache.saves == 2, "past the window: written at once")
        #expect(cache.load()?.soc == 43)

        clock.advance(.seconds(1))
        row["soc"] = .double(44)
        store.apply(row: row)
        #expect(cache.saves == 2)
        store.stop()
        #expect(cache.saves == 3, "stop() flushes the pending row")
        #expect(cache.load()?.soc == 44)
        store.stop()
        #expect(cache.saves == 3, "nothing left to flush")
    }

    /// A pending row is written when the window ends, and on `flushCache()` (the app going to the background).
    @Test func flushesPendingRowAfterWindowAndOnDemand() async throws {
        let cache = CountingCache()
        let clock = ManualClock()
        let feed = ScriptedFeed([.open([.subscribed])])
        let store = VehicleStore(feed: feed, fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: cache, sleep: { _ in
            try await Task.sleep(for: .milliseconds(50))
        }, now: clock.now)
        await store.start()
        await waitUntil { store.isLive }
        var row = try Fixture.row("vehicle_state_live")
        store.apply(row: row)
        row["soc"] = .double(50)
        store.apply(row: row)
        #expect(cache.saves == 1)
        await waitUntil { cache.saves == 2 }
        #expect(cache.saves == 2, "the window's timer writes the pending row")
        #expect(cache.load()?.soc == 50)

        clock.advance(.seconds(1))
        row["soc"] = .double(51)
        store.apply(row: row)
        store.flushCache()
        #expect(cache.saves == 3)
        #expect(cache.load()?.soc == 51)
        store.stop()
    }

    /// A store released without `stop()` still writes its pending row and closes its feed.
    @Test func deinitFlushesAndCancels() async throws {
        let cache = CountingCache()
        let clock = ManualClock()
        let feed = ScriptedFeed([.open([.subscribed])])
        var store: VehicleStore? = VehicleStore(feed: feed, fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: cache, sleep: sleepForever, now: clock.now)
        await store?.start()
        await waitUntil { store?.isLive == true }
        var row = try Fixture.row("vehicle_state_live")
        store?.apply(row: row)
        row["soc"] = .double(60)
        store?.apply(row: row)
        #expect(cache.saves == 1)

        store = nil
        await waitUntil { cache.saves == 2 && feed.terminated == 1 }
        #expect(cache.saves == 2)
        #expect(cache.load()?.soc == 60)
        #expect(feed.terminated == 1)
    }

    /// "Refresh now" hands back a full row: it is adopted unless it is older or another car's.
    @Test func applyStateMergesRefreshedRow() async throws {
        let cache = CountingCache()
        let store = VehicleStore(feed: IdleFeed(), fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: cache)
        await store.start()
        var refreshed = try Fixture.state("vehicle_state_live")
        store.apply(state: refreshed)
        #expect(store.state == refreshed)
        #expect(cache.load() == refreshed)

        var older = refreshed
        older.soc = 10
        older.updatedAt = refreshed.updatedAt?.addingTimeInterval(-60)
        store.apply(state: older)
        #expect(store.state?.soc == refreshed.soc)

        var other = refreshed
        other.vehicleId = UUID()
        other.updatedAt = refreshed.updatedAt?.addingTimeInterval(60)
        store.apply(state: other)
        #expect(store.state?.vehicleId == vehicleID)

        refreshed.soc = 70
        refreshed.updatedAt = refreshed.updatedAt?.addingTimeInterval(60)
        store.apply(state: refreshed)
        #expect(store.state?.soc == 70)
        store.stop()
    }

    /// The Refresh-now answer is the backend's PATCH: no `vehicle_id`, bridge fields or `updated_at`
    /// beyond what it wrote. Merged, the bridge check-in, its health and the car id survive.
    @Test func applyPatchKeepsBridgeFields() async throws {
        let cache = CountingCache()
        let fetcher = FakeFetcher(vehicle: testVehicle, state: try Fixture.state("vehicle_state_live"))
        let store = VehicleStore(feed: IdleFeed(), fetcher: fetcher, cache: cache)
        await store.start()
        let before = try #require(store.state)
        #expect(before.bridgeSeenAt != nil)
        #expect(before.bridgeHealth != nil)

        var patch = VehicleState()
        patch.soc = 81
        patch.rangeKm = 390
        patch.chargeAt = before.chargeAt?.addingTimeInterval(600)
        store.apply(state: patch)

        #expect(store.state?.soc == 81)
        #expect(store.state?.rangeKm == 390)
        #expect(store.state?.bridgeSeenAt == before.bridgeSeenAt)
        #expect(store.state?.bridgeHealth == before.bridgeHealth)
        #expect(store.state?.vehicleId == vehicleID)
        #expect(store.state?.locked == before.locked, "fields the patch omits are kept")
        #expect(cache.load() == store.state, "the merged row is what gets cached")

        // A patch stamped older than the current row is still refused.
        var old = VehicleState()
        old.soc = 5
        old.updatedAt = before.updatedAt?.addingTimeInterval(-60)
        store.apply(state: old)
        #expect(store.state?.soc == 81)
        store.stop()
    }

    /// With no car loaded (the store after sign-out) a late Refresh-now answer is dropped.
    @Test func applyStateIgnoredWithoutVehicle() throws {
        let cache = CountingCache()
        let store = VehicleStore(feed: IdleFeed(), fetcher: FakeFetcher(vehicle: nil, state: nil), cache: cache)
        var patch = VehicleState()
        patch.soc = 50

        store.apply(state: patch)

        #expect(store.state == nil)
        #expect(cache.saves == 0)
    }

    /// `isStarted` is true from a `start()` that found the car until `stop()`.
    @Test func isStartedFollowsStartAndStop() async throws {
        let store = VehicleStore(feed: IdleFeed(), fetcher: FakeFetcher(vehicle: testVehicle, state: nil), cache: InMemorySnapshotCache())
        #expect(!store.isStarted)
        await store.start()
        #expect(store.isStarted)
        store.stop()
        #expect(!store.isStarted)

        let empty = VehicleStore(feed: IdleFeed(), fetcher: FakeFetcher(vehicle: nil, state: nil), cache: InMemorySnapshotCache())
        await empty.start()
        #expect(!empty.isStarted, "no car: nothing to follow")
    }

    /// `waitUntilAwake` returns as soon as a row flips `sleep_state` off asleep, true at once when the
    /// car is already awake, and false when nothing changes within the timeout.
    @Test func waitUntilAwakeFollowsTheRow() async throws {
        let store = VehicleStore(
            feed: FakeFeed(events: []),
            fetcher: FakeFetcher(vehicle: testVehicle, state: nil),
            cache: InMemorySnapshotCache(),
            vehicle: testVehicle
        )
        var asleep = try Fixture.state("vehicle_state_live")
        asleep.sleepState = "asleep"
        store.apply(state: asleep)
        #expect(store.isAsleep)

        #expect(await store.waitUntilAwake(timeout: .milliseconds(50)) == false)

        let waiting = Task { await store.waitUntilAwake(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        store.apply(row: ["sleep_state": .string("online")])
        #expect(await waiting.value)
        #expect(!store.isAsleep)
        #expect(await store.waitUntilAwake(timeout: .zero))
    }
}
