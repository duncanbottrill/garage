import Foundation

/// The bridge's self-report (`vehicle_state.bridge_health` jsonb): MQTT event counters, the car's
/// telemetry connectivity and any active vehicle alerts.
public struct BridgeHealth: Codable, Sendable, Equatable {
    /// Telemetry events dropped (could not be written).
    public var dropped: Int?
    /// Patches flushed to Supabase.
    public var flushed: Int?
    /// Telemetry events received from the car.
    public var received: Int?
    /// The car's fleet-telemetry connectivity as reported, for example `"CONNECTED"`.
    public var connectivity: String?
    /// Active vehicle alert names.
    public var activeAlerts: [String]?
    /// When the bridge last received an event from the car.
    public var lastEventAt: Date?
    /// Patches the bridge failed to write.
    public var patchFailures: Int?

    public init(
        dropped: Int? = nil,
        flushed: Int? = nil,
        received: Int? = nil,
        connectivity: String? = nil,
        activeAlerts: [String]? = nil,
        lastEventAt: Date? = nil,
        patchFailures: Int? = nil
    ) {
        self.dropped = dropped
        self.flushed = flushed
        self.received = received
        self.connectivity = connectivity
        self.activeAlerts = activeAlerts
        self.lastEventAt = lastEventAt
        self.patchFailures = patchFailures
    }

    enum CodingKeys: String, CodingKey {
        case dropped, flushed, received, connectivity
        case activeAlerts = "active_alerts"
        case lastEventAt = "last_event_at"
        case patchFailures = "patch_failures"
    }
}
