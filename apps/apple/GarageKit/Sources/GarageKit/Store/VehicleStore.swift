import Foundation
import Observation
import os
import Supabase

/// Reads the owner's rows over PostgREST. Injected into ``VehicleStore`` so tests never touch the network.
public protocol VehicleRowFetcher: Sendable {
    /// The owner's car (RLS limits `vehicles` to the signed-in owner), or nil when none is linked yet.
    func fetchVehicle() async throws -> Vehicle?
    /// The car's `vehicle_state` row, or nil when the bridge has not written one yet.
    func fetchState(vehicleID: UUID) async throws -> VehicleState?
}

/// The car the owner picked in onboarding, kept in `UserDefaults` under ``key``.
public enum VehicleSelection {
    /// The `UserDefaults` key holding the chosen vehicle's id.
    public static let key = "selectedVehicleID"

    /// The chosen vehicle's id, or nil when none was picked.
    public static func current(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// Records `id` as the chosen vehicle, or forgets the choice when nil.
    public static func set(_ id: UUID?, in defaults: UserDefaults = .standard) {
        if let id { defaults.set(id.uuidString.lowercased(), forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// ``VehicleRowFetcher`` over the Supabase client, decoding with ``GarageJSON/decoder``.
public struct SupabaseRowFetcher: VehicleRowFetcher {
    let client: SupabaseClient
    let selectedVehicleID: @Sendable () -> UUID?

    /// - Parameters:
    ///   - client: The Supabase client (RLS scopes rows to the signed-in owner).
    ///   - selectedVehicleID: The car picked in onboarding; by default ``VehicleSelection/current(in:)``.
    public init(client: SupabaseClient, selectedVehicleID: @escaping @Sendable () -> UUID? = { VehicleSelection.current() }) {
        self.client = client
        self.selectedVehicleID = selectedVehicleID
    }

    public func fetchVehicle() async throws -> Vehicle? {
        if let id = selectedVehicleID() {
            let response = try await client.from("vehicles")
                .select(Vehicle.selectColumns)
                .eq("id", value: id.uuidString.lowercased())
                .limit(1)
                .execute()
            if let chosen = try GarageJSON.decoder.decode([Vehicle].self, from: response.data).first { return chosen }
            // The chosen car is gone (unlinked, or another account's choice): fall back to the first.
        }
        // Slice 1 is single-vehicle: the first car the owner linked.
        let response = try await client.from("vehicles")
            .select(Vehicle.selectColumns)
            .order("created_at", ascending: true)
            .limit(1)
            .execute()
        return try GarageJSON.decoder.decode([Vehicle].self, from: response.data).first
    }

    public func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        let response = try await client.from("vehicle_state")
            .select()
            .eq("vehicle_id", value: vehicleID.uuidString.lowercased())
            .limit(1)
            .execute()
        return try GarageJSON.decoder.decode([VehicleState].self, from: response.data).first
    }
}

/// The car's live state for every screen.
///
/// On `init` it loads the cached snapshot synchronously, so `state` is non-nil before any network when
/// the app has run before. ``start()`` fetches the vehicle and its row, then follows Realtime UPDATEs
/// on `public.vehicle_state`; after a dropped channel rejoins it re-fetches the row, since updates may
/// have been missed.
///
/// **Supervision.** When the channel drops (or its stream ends) while the store is started and the
/// Supabase client has not rejoined it within the delay, the store opens a fresh channel. The delay
/// starts at 2 s and doubles to at most 60 s while channels keep failing (``resubscribeDelay(attempt:)``);
/// a channel that joins resets it.
///
/// **Cache writes.** Fetched rows are written to the cache at once. Realtime rows are written at most
/// once per ``cacheWriteInterval`` (5 s): the first at once, later ones in the window when it ends.
/// ``stop()``, ``flushCache()`` (the app calls it on going to the background) and deinit write any
/// pending row.
///
/// Releasing a started store is safe: its `isolated deinit` cancels the feed and writes the pending
/// row. Call ``stop()`` when the store is replaced on purpose (sign-out) so that happens at a known time.
@MainActor
@Observable
public final class VehicleStore {
    /// The longest a Realtime row waits before it is written to the cache.
    public static let cacheWriteInterval: Duration = .seconds(5)
    /// The first re-subscribe delay after a dropped channel; it doubles per failed attempt.
    public static let resubscribeBaseDelay: Duration = .seconds(2)
    /// The longest re-subscribe delay.
    public static let resubscribeMaxDelay: Duration = .seconds(60)

    /// The owner's car, once fetched (or as injected).
    public private(set) var vehicle: Vehicle?
    /// The latest known row: the cached snapshot, then fetched and Realtime rows.
    public private(set) var state: VehicleState?
    /// True while the Realtime channel is subscribed.
    public private(set) var isLive = false
    /// When the last Realtime row arrived.
    public private(set) var lastRealtimeAt: Date?
    /// True from a ``start()`` that found the car (it is following, or re-subscribing to, its
    /// channel) until ``stop()``.
    public private(set) var isStarted = false

    @ObservationIgnored private let feed: any RealtimeFeed
    @ObservationIgnored private let fetcher: any VehicleRowFetcher
    @ObservationIgnored private let cache: any SnapshotCache
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var resubscribeTask: Task<Void, Never>?
    @ObservationIgnored private var resubscribeAttempt = 0
    @ObservationIgnored private var missedUpdates = false
    @ObservationIgnored private var pendingWrite: VehicleState?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastLiveWrite: ContinuousClock.Instant?
    /// Bumped by every `start()` and `stop()`; work begun under an older value is abandoned.
    @ObservationIgnored private var generation = 0

    public convenience init(
        feed: any RealtimeFeed,
        fetcher: any VehicleRowFetcher,
        cache: any SnapshotCache = FileSnapshotCache(),
        vehicle: Vehicle? = nil
    ) {
        self.init(feed: feed, fetcher: fetcher, cache: cache, vehicle: vehicle, sleep: { try await Task.sleep(for: $0) })
    }

    /// - Parameters:
    ///   - sleep: Waits out a re-subscribe delay or a cache-write window; tests shorten it.
    ///   - now: The clock for the cache-write window.
    init(
        feed: any RealtimeFeed,
        fetcher: any VehicleRowFetcher,
        cache: any SnapshotCache = FileSnapshotCache(),
        vehicle: Vehicle? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.feed = feed
        self.fetcher = fetcher
        self.cache = cache
        self.vehicle = vehicle
        self.sleep = sleep
        self.now = now
        state = cache.load()
    }

    /// A store wired to Supabase (PostgREST + Realtime) with the file snapshot cache.
    public convenience init(environment: SupabaseEnvironment) {
        self.init(
            feed: SupabaseRealtimeFeed(client: environment.client),
            fetcher: SupabaseRowFetcher(client: environment.client)
        )
    }

    isolated deinit {
        feedTask?.cancel()
        resubscribeTask?.cancel()
        flushTask?.cancel()
        if let pendingWrite { cache.save(pendingWrite) }
    }

    /// The wait before re-subscribe attempt `attempt` (0-based): 2 s doubling, at most 60 s.
    public static func resubscribeDelay(attempt: Int) -> Duration {
        let seconds = 2 * pow(2, Double(min(max(attempt, 0), 10)))
        return min(.seconds(seconds), resubscribeMaxDelay)
    }

    /// Fetches the vehicle and its row, then starts following Realtime. Returns once the feed is
    /// running; does nothing more when the owner has no vehicle yet (or it could not be fetched and
    /// none is known). Calling it again restarts, and a ``stop()`` or a newer `start()` while this
    /// one is still fetching wins: this one then returns without writing anything or opening a feed.
    public func start() async {
        stop()
        let mine = generation

        let fetchedVehicle = await loadVehicle()
        guard generation == mine else { return }
        if let fetchedVehicle { vehicle = fetchedVehicle }
        guard let vehicle else { return }
        // A snapshot cached for another car (a different account) must not be shown or merged into.
        if let cachedID = state?.vehicleId, cachedID != vehicle.id {
            state = nil
        }

        let fetchedState = await loadState(vehicleID: vehicle.id)
        guard generation == mine else { return }
        adoptFetched(fetchedState)

        isStarted = true
        subscribe(vehicleID: vehicle.id, generation: mine)
    }

    /// Stops following Realtime and abandons any `start()` still fetching. The current state stays on
    /// screen, and a Realtime row still waiting for the cache is written now.
    public func stop() {
        generation &+= 1
        feedTask?.cancel()
        feedTask = nil
        resubscribeTask?.cancel()
        resubscribeTask = nil
        resubscribeAttempt = 0
        isLive = false
        isStarted = false
        missedUpdates = false
        flushCache()
    }

    /// Writes a Realtime row still waiting for its cache window, if any (for example when the app
    /// goes to the background).
    public func flushCache() {
        flushTask?.cancel()
        flushTask = nil
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        cache.save(pending)
        lastLiveWrite = now()
    }

    /// Applies a Realtime record (column → value). Columns the record omits keep their current value;
    /// rows for another vehicle are ignored. The result is cached (at most once per ``cacheWriteInterval``).
    public func apply(row: [String: AnyJSON]) {
        do {
            var merged = try currentStateJSON()
            merged.merge(row) { _, new in new }
            let next = try GarageJSON.decode(VehicleState.self, from: merged)
            if let expected = vehicle?.id, let actual = next.vehicleId, actual != expected { return }
            lastRealtimeAt = Date()
            adopt(next, live: true)
        } catch {
            Self.logger.error("Ignoring undecodable vehicle_state record: \(error)")
        }
    }

    /// Merges a row read elsewhere: More's "Refresh now" answer, which is the bridge-less PATCH the
    /// backend wrote (no `vehicle_id`, `bridge_seen_at` or `bridge_health`). Only the fields it carries
    /// replace the current ones, as for a Realtime record; the result is then adopted and cached like a
    /// fetched row unless it is older than the current row. Ignored while no car is loaded (after
    /// sign-out) or when it names another car.
    public func apply(state patch: VehicleState) {
        guard let expected = vehicle?.id else { return }
        if let actual = patch.vehicleId, actual != expected { return }
        do {
            // The encoder omits nil fields, so absent columns keep their current values.
            let fields = try JSONDecoder().decode([String: AnyJSON].self, from: GarageJSON.encoder.encode(patch))
            var merged = try currentStateJSON()
            merged.merge(fields) { _, new in new }
            var next = try GarageJSON.decode(VehicleState.self, from: merged)
            next.vehicleId = next.vehicleId ?? expected
            adoptFetched(next)
        } catch {
            Self.logger.error("Ignoring undecodable refreshed row: \(error)")
        }
    }

    // MARK: Feed

    /// Opens a channel and follows it. A stream that ends on its own counts as a dropped channel.
    private func subscribe(vehicleID: UUID, generation mine: Int) {
        // Cancel first: tearing the old stream down records its channel removal, which the new
        // subscription then waits for, so two channels are not joined at once.
        feedTask?.cancel()
        feedTask = nil
        let events = feed.events(for: vehicleID)
        feedTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event, vehicleID: vehicleID, generation: mine)
            }
            guard !Task.isCancelled else { return }
            self?.channelDropped(vehicleID: vehicleID, generation: mine)
        }
    }

    private func handle(_ event: RealtimeFeedEvent, vehicleID: UUID, generation mine: Int) async {
        guard generation == mine else { return }
        switch event {
        case .subscribed:
            isLive = true
            resubscribeTask?.cancel()
            resubscribeTask = nil
            resubscribeAttempt = 0
            if missedUpdates {
                missedUpdates = false
                let fetchedVehicle = await loadVehicle()
                let fetchedState = await loadState(vehicleID: vehicleID)
                guard generation == mine else { return }
                if let fetchedVehicle { vehicle = fetchedVehicle }
                adoptFetched(fetchedState)
            }
        case .disconnected:
            channelDropped(vehicleID: vehicleID, generation: mine)
        case .row(let row):
            apply(row: row)
        }
    }

    private func channelDropped(vehicleID: UUID, generation mine: Int) {
        guard generation == mine else { return }
        isLive = false
        missedUpdates = true
        scheduleResubscribe(vehicleID: vehicleID, generation: mine)
    }

    /// After the next delay, opens a fresh channel unless one has joined meanwhile, and keeps doing so
    /// (with growing delays) until one does.
    private func scheduleResubscribe(vehicleID: UUID, generation mine: Int) {
        guard resubscribeTask == nil else { return }
        let delay = Self.resubscribeDelay(attempt: resubscribeAttempt)
        resubscribeAttempt += 1
        let sleep = sleep
        resubscribeTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.resubscribeTask = nil
            guard !self.isLive else { return }
            Self.logger.info("Realtime channel still down after \(delay); re-subscribing")
            self.subscribe(vehicleID: vehicleID, generation: mine)
            self.scheduleResubscribe(vehicleID: vehicleID, generation: mine)
        }
    }

    /// `vehicles` is not in the Realtime publication, so budget mode and proxy URL refresh on fetch.
    private func loadVehicle() async -> Vehicle? {
        do {
            return try await fetcher.fetchVehicle()
        } catch {
            Self.logger.error("Vehicle fetch failed: \(error)")
            return nil
        }
    }

    private func loadState(vehicleID: UUID) async -> VehicleState? {
        do {
            return try await fetcher.fetchState(vehicleID: vehicleID)
        } catch {
            Self.logger.error("vehicle_state fetch failed: \(error)")
            return nil
        }
    }

    private func adoptFetched(_ fetched: VehicleState?) {
        guard let fetched else { return }
        // A slow fetch must not roll back a newer Realtime row.
        if let current = state?.updatedAt, let incoming = fetched.updatedAt, incoming < current { return }
        adopt(fetched, live: false)
    }

    /// Shows `next` and caches it: fetched rows at once, Realtime rows at most once per window.
    private func adopt(_ next: VehicleState, live: Bool) {
        guard next != state else { return }
        state = next
        guard live else {
            pendingWrite = nil
            flushTask?.cancel()
            flushTask = nil
            cache.save(next)
            return
        }
        let at = now()
        guard let last = lastLiveWrite, at < last.advanced(by: Self.cacheWriteInterval) else {
            pendingWrite = nil
            cache.save(next)
            lastLiveWrite = at
            return
        }
        pendingWrite = next
        guard flushTask == nil else { return }
        let wait = last.advanced(by: Self.cacheWriteInterval) - at
        let sleep = sleep
        flushTask = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flushCache()
        }
    }

    private func currentStateJSON() throws -> [String: AnyJSON] {
        guard let state else { return [:] }
        return try JSONDecoder().decode([String: AnyJSON].self, from: GarageJSON.encoder.encode(state))
    }

    private static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "VehicleStore")
}
