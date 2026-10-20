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

/// ``VehicleRowFetcher`` over the Supabase client, decoding with ``GarageJSON/decoder``.
public struct SupabaseRowFetcher: VehicleRowFetcher {
    let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func fetchVehicle() async throws -> Vehicle? {
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
    /// running; does nothing more when the owner has no vehicle yet. Calling it again restarts.
    public func start() async {
        stop()
        await refreshVehicle()
        guard let vehicle else { return }
        // A snapshot cached for another car (a different account) must not be shown or merged into.
        if let cachedID = state?.vehicleId, cachedID != vehicle.id {
            state = nil
        }
        await refetchState(vehicleID: vehicle.id)

        let events = feed.events(for: vehicle.id)
        feedTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event, vehicleID: vehicle.id)
            }
        }
    }

    /// Stops following Realtime. The current state stays on screen.
    public func stop() {
        feedTask?.cancel()
        feedTask = nil
        isLive = false
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

    private func handle(_ event: RealtimeFeedEvent, vehicleID: UUID) async {
        switch event {
        case .subscribed:
            isLive = true
            if missedUpdates {
                missedUpdates = false
                await refreshVehicle()
                await refetchState(vehicleID: vehicleID)
            }
        case .disconnected:
            isLive = false
            missedUpdates = true
        case .row(let row):
            apply(row: row)
        }
    }

    /// `vehicles` is not in the Realtime publication, so budget mode and proxy URL refresh on fetch.
    private func refreshVehicle() async {
        do {
            if let fetched = try await fetcher.fetchVehicle() { vehicle = fetched }
        } catch {
            Self.logger.error("Vehicle fetch failed: \(error)")
        }
    }

    private func refetchState(vehicleID: UUID) async {
        do {
            guard let fetched = try await fetcher.fetchState(vehicleID: vehicleID) else { return }
            // A slow fetch must not roll back a newer Realtime row.
            if let current = state?.updatedAt, let incoming = fetched.updatedAt, incoming < current { return }
            adopt(fetched)
        } catch {
            Self.logger.error("vehicle_state fetch failed: \(error)")
        }
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
