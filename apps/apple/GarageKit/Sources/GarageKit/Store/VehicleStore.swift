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
/// have been missed. Every new state is written back to the cache.
@MainActor
@Observable
public final class VehicleStore {
    /// The owner's car, once fetched (or as injected).
    public private(set) var vehicle: Vehicle?
    /// The latest known row: the cached snapshot, then fetched and Realtime rows.
    public private(set) var state: VehicleState?
    /// True while the Realtime channel is subscribed.
    public private(set) var isLive = false
    /// When the last Realtime row arrived.
    public private(set) var lastRealtimeAt: Date?

    @ObservationIgnored private let feed: any RealtimeFeed
    @ObservationIgnored private let fetcher: any VehicleRowFetcher
    @ObservationIgnored private let cache: any SnapshotCache
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var missedUpdates = false
    /// Bumped by every `start()` and `stop()`; work begun under an older value is abandoned.
    @ObservationIgnored private var generation = 0

    public init(
        feed: any RealtimeFeed,
        fetcher: any VehicleRowFetcher,
        cache: any SnapshotCache = FileSnapshotCache(),
        vehicle: Vehicle? = nil
    ) {
        self.feed = feed
        self.fetcher = fetcher
        self.cache = cache
        self.vehicle = vehicle
        state = cache.load()
    }

    /// A store wired to Supabase (PostgREST + Realtime) with the file snapshot cache.
    public convenience init(environment: SupabaseEnvironment) {
        self.init(
            feed: SupabaseRealtimeFeed(client: environment.client),
            fetcher: SupabaseRowFetcher(client: environment.client)
        )
    }

    /// Fetches the vehicle and its row, then starts following Realtime. Returns once the feed is
    /// running; does nothing more when the owner has no vehicle yet. Calling it again restarts, and
    /// a ``stop()`` or a newer `start()` while this one is still fetching wins: this one then returns
    /// without writing anything or opening a feed.
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

        let events = feed.events(for: vehicle.id)
        feedTask?.cancel()
        feedTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event, vehicleID: vehicle.id, generation: mine)
            }
        }
    }

    /// Stops following Realtime and abandons any `start()` still fetching. The current state stays on screen.
    public func stop() {
        generation &+= 1
        feedTask?.cancel()
        feedTask = nil
        isLive = false
        missedUpdates = false
    }

    /// Applies a Realtime record (column → value). Columns the record omits keep their current value;
    /// rows for another vehicle are ignored. The result is cached.
    public func apply(row: [String: AnyJSON]) {
        do {
            var merged = try currentStateJSON()
            merged.merge(row) { _, new in new }
            let next = try GarageJSON.decode(VehicleState.self, from: merged)
            if let expected = vehicle?.id, let actual = next.vehicleId, actual != expected { return }
            lastRealtimeAt = Date()
            adopt(next)
        } catch {
            Self.logger.error("Ignoring undecodable vehicle_state record: \(error)")
        }
    }

    private func handle(_ event: RealtimeFeedEvent, vehicleID: UUID, generation mine: Int) async {
        guard generation == mine else { return }
        switch event {
        case .subscribed:
            isLive = true
            if missedUpdates {
                missedUpdates = false
                let fetchedVehicle = await loadVehicle()
                let fetchedState = await loadState(vehicleID: vehicleID)
                guard generation == mine else { return }
                if let fetchedVehicle { vehicle = fetchedVehicle }
                adoptFetched(fetchedState)
            }
        case .disconnected:
            isLive = false
            missedUpdates = true
        case .row(let row):
            apply(row: row)
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
        adopt(fetched)
    }

    private func adopt(_ next: VehicleState) {
        guard next != state else { return }
        state = next
        cache.save(next)
    }

    private func currentStateJSON() throws -> [String: AnyJSON] {
        guard let state else { return [:] }
        return try JSONDecoder().decode([String: AnyJSON].self, from: GarageJSON.encoder.encode(state))
    }

    private static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "VehicleStore")
}
