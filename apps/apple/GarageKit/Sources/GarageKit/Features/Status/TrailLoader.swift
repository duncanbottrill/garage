import Foundation
import Observation
import Supabase

/// One position from the `signals` table (`name = 'Location'`).
public struct TrailPoint: Sendable, Equatable {
    /// Degrees north.
    public let latitude: Double
    /// Degrees east.
    public let longitude: Double
    /// When the car reported this position (`signals.recorded_at`).
    public let recordedAt: Date

    public init(latitude: Double, longitude: Double, recordedAt: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.recordedAt = recordedAt
    }
}

/// Reads recent `Location` signals. Injected into ``TrailLoader`` so tests never touch the network.
public protocol TrailFetching: Sendable {
    /// The car's `Location` signals recorded after `since`, oldest first.
    func locations(vehicleID: UUID, since: Date) async throws -> [TrailPoint]
}

/// ``TrailFetching`` over PostgREST: `signals` where `vehicle_id = id`, `name = 'Location'` and
/// `recorded_at > since`, selecting `value_json, recorded_at`.
public struct SupabaseTrailFetcher: TrailFetching {
    /// The most rows one query asks for (PostgREST caps responses; 30 min at 1 Hz is 1 800).
    static let rowLimit = 2000

    let client: SupabaseClient

    /// - Parameter client: The Supabase client (RLS scopes `signals` to the owner's cars).
    public init(client: SupabaseClient) {
        self.client = client
    }

    public func locations(vehicleID: UUID, since: Date) async throws -> [TrailPoint] {
        // Newest first under the row cap, so a capped response drops the oldest points, not the latest.
        let response = try await client.from("signals")
            .select("value_json,recorded_at")
            .eq("vehicle_id", value: vehicleID.uuidString.lowercased())
            .eq("name", value: "Location")
            .gt("recorded_at", value: since.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            .order("recorded_at", ascending: false)
            .limit(Self.rowLimit)
            .execute()
        return try Self.decode(response.data).sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Decodes `[{"value_json":{"latitude":…,"longitude":…},"recorded_at":"…"}]`. Rows without a
    /// usable coordinate are skipped rather than failing the trail.
    static func decode(_ data: Data) throws -> [TrailPoint] {
        try GarageJSON.decoder.decode([Row].self, from: data).compactMap { row in
            guard let lat = row.value?.latitude, let lng = row.value?.longitude else { return nil }
            return TrailPoint(latitude: lat, longitude: lng, recordedAt: row.recordedAt)
        }
    }

    private struct Row: Decodable {
        struct Value: Decodable {
            let latitude: Double?
            let longitude: Double?
        }

        let value: Value?
        let recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case value = "value_json"
            case recordedAt = "recorded_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try? c.decodeIfPresent(Value.self, forKey: .value)
            recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        }
    }
}

/// The car's trail for the map: the last ``window`` of `Location` signals, loaded once per vehicle and
/// extended with each live position so the map does not query on every Realtime row.
@MainActor
@Observable
public final class TrailLoader {
    /// How far back the trail reaches.
    public static let window: TimeInterval = 30 * 60
    /// How often Status calls ``prune(now:)`` while it is on screen.
    public static let pruneInterval: Duration = .seconds(60)

    /// The trail, oldest first, all within ``window`` of the last load or append.
    public private(set) var points: [TrailPoint] = []

    @ObservationIgnored private let fetcher: any TrailFetching

    /// - Parameter fetcher: Where the signals come from.
    public init(fetcher: any TrailFetching) {
        self.fetcher = fetcher
    }

    /// Replaces the trail with the signals of the last ``window`` before `now`, keeping any live
    /// positions appended while the fetch was in flight (merged by time, one point per timestamp). A
    /// failed fetch keeps the current trail (the map is decoration; nothing to report).
    public func load(vehicleID: UUID, now: Date = Date()) async {
        let since = now.addingTimeInterval(-Self.window)
        guard let fetched = try? await fetcher.locations(vehicleID: vehicleID, since: since) else { return }
        var byTime: [Date: TrailPoint] = [:]
        for point in fetched + points where point.recordedAt > since {
            byTime[point.recordedAt] = byTime[point.recordedAt] ?? point
        }
        points = byTime.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Drops points older than ``window`` before `now`.
    public func prune(now: Date = Date()) {
        let since = now.addingTimeInterval(-Self.window)
        guard points.first.map({ $0.recordedAt <= since }) == true else { return }
        points.removeAll { $0.recordedAt <= since }
    }

    /// Adds a live position (ignoring one no newer than the last point) and drops points older than ``window``.
    public func append(_ point: TrailPoint, now: Date = Date()) {
        if let last = points.last, point.recordedAt <= last.recordedAt { return }
        let since = now.addingTimeInterval(-Self.window)
        points = (points + [point]).filter { $0.recordedAt > since }
    }
}
