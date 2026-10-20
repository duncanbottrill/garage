import Foundation

/// How hard the backend may spend the Tesla API budget for this car (`vehicles.budget_mode`).
public enum BudgetMode: String, Codable, Sendable, CaseIterable {
    case normal
    case reduced
    case minimal

    /// Unknown values (a newer backend) read as `.normal` rather than failing the whole row.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BudgetMode(rawValue: raw) ?? .normal
    }
}

/// One row of `public.vehicles` as the owner sees it.
public struct Vehicle: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var ownerId: UUID?
    public var vin: String
    public var displayName: String
    public var model: String?
    public var budgetMode: BudgetMode
    /// When the car confirmed the fleet-telemetry configuration; nil until it has.
    public var telemetryConfirmedAt: Date?
    /// The bridge's command proxy, published by the bridge (for example
    /// `https://garage-bridge.tail068c8f.ts.net:4443`); nil until a bridge has published one.
    public var proxyBaseURL: URL?

    public init(
        id: UUID,
        ownerId: UUID? = nil,
        vin: String,
        displayName: String,
        model: String? = nil,
        budgetMode: BudgetMode = .normal,
        telemetryConfirmedAt: Date? = nil,
        proxyBaseURL: URL? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.vin = vin
        self.displayName = displayName
        self.model = model
        self.budgetMode = budgetMode
        self.telemetryConfirmedAt = telemetryConfirmedAt
        self.proxyBaseURL = proxyBaseURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ownerId = try c.decodeIfPresent(UUID.self, forKey: .ownerId)
        vin = try c.decode(String.self, forKey: .vin)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Model Y"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        budgetMode = try c.decodeIfPresent(BudgetMode.self, forKey: .budgetMode) ?? .normal
        telemetryConfirmedAt = try c.decodeIfPresent(Date.self, forKey: .telemetryConfirmedAt)
        // Blank or malformed text is treated as "not published yet".
        let proxy = try c.decodeIfPresent(String.self, forKey: .proxyBaseURL)?.trimmingCharacters(in: .whitespaces)
        proxyBaseURL = proxy.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(ownerId, forKey: .ownerId)
        try c.encode(vin, forKey: .vin)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(budgetMode, forKey: .budgetMode)
        try c.encodeIfPresent(telemetryConfirmedAt, forKey: .telemetryConfirmedAt)
        try c.encodeIfPresent(proxyBaseURL?.absoluteString, forKey: .proxyBaseURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case vin
        case displayName = "display_name"
        case model
        case budgetMode = "budget_mode"
        case telemetryConfirmedAt = "telemetry_confirmed_at"
        case proxyBaseURL = "proxy_base_url"
    }

    /// The columns ``Vehicle`` reads, for a PostgREST `select`.
    static let selectColumns = "id,owner_id,vin,display_name,model,budget_mode,telemetry_confirmed_at,proxy_base_url"
}
