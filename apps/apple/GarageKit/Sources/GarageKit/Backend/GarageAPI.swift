import Foundation

/// A ledger category the app reports to `POST /api/usage`: one per command sent, one per wake.
public enum UsageCategory: String, Codable, Sendable, CaseIterable {
    case commands
    case wakes
}

/// A short-lived Tesla access token from `GET /api/token`, for the bridge's command proxy.
/// Kept in memory only (see ``TokenProvider``); never logged or persisted.
public struct TeslaToken: Decodable, Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

/// The owner's Tesla connection health from `GET /api/connection` (the More screen's Connection row).
public struct ConnectionHealth: Decodable, Sendable, Equatable {
    /// Whether a Tesla account is connected at all.
    public var connected: Bool
    /// When the refresh token last rotated.
    public var rotatedAt: Date?
    /// The last rotation error, when the most recent attempt failed.
    public var lastError: String?
    /// When the current access token expires.
    public var accessExpiresAt: Date?
    /// Whether a rotation is running right now.
    public var rotating: Bool
    /// Consecutive failed rotations.
    public var refreshFailures: Int
    /// When the next rotation is due (or the next retry after a failure).
    public var nextRefreshAt: Date?

    public init(
        connected: Bool,
        rotatedAt: Date? = nil,
        lastError: String? = nil,
        accessExpiresAt: Date? = nil,
        rotating: Bool = false,
        refreshFailures: Int = 0,
        nextRefreshAt: Date? = nil
    ) {
        self.connected = connected
        self.rotatedAt = rotatedAt
        self.lastError = lastError
        self.accessExpiresAt = accessExpiresAt
        self.rotating = rotating
        self.refreshFailures = refreshFailures
        self.nextRefreshAt = nextRefreshAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = try c.decode(Bool.self, forKey: .connected)
        rotatedAt = try c.decodeIfPresent(Date.self, forKey: .rotatedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        accessExpiresAt = try c.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
        rotating = try c.decodeIfPresent(Bool.self, forKey: .rotating) ?? false
        refreshFailures = try c.decodeIfPresent(Int.self, forKey: .refreshFailures) ?? 0
        nextRefreshAt = try c.decodeIfPresent(Date.self, forKey: .nextRefreshAt)
    }

    enum CodingKeys: String, CodingKey {
        case connected
        case rotatedAt = "rotated_at"
        case lastError = "last_error"
        case accessExpiresAt = "access_expires_at"
        case rotating
        case refreshFailures = "refresh_failures"
        case nextRefreshAt = "next_refresh_at"
    }
}

/// The answer of `POST /api/vehicles/sync`.
public struct VehicleSync: Decodable, Sendable, Equatable {
    /// This owner's vehicles after the import (only `id`, `vin` and `display_name` are filled in).
    public var vehicles: [Vehicle]
    /// VINs on the Tesla account that were skipped because another Garage account already owns them.
    public var conflicts: [String]

    public init(vehicles: [Vehicle], conflicts: [String] = []) {
        self.vehicles = vehicles
        self.conflicts = conflicts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vehicles = try c.decode([Vehicle].self, forKey: .vehicles)
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
    }

    enum CodingKeys: String, CodingKey { case vehicles, conflicts }
}

/// A typed failure from the Garage backend. Transport failures (no network) arrive as `URLError`.
public enum APIError: Error, Sendable, Equatable, LocalizedError {
    /// The Supabase session was refused (401). Sign in again.
    case unauthorized
    /// No Tesla account is connected to this Garage account.
    case notConnected
    /// The backend has no usable Tesla token right now; it retries at `retryAt` when known.
    case tokenUnavailable(retryAt: Date?)
    /// The car is asleep; the backend will not wake it.
    case asleep
    /// Too many requests; try again later.
    case rateLimited
    /// The monthly Tesla budget is in minimal mode, so the request was refused.
    case budgetMinimal
    /// Any other failure, by HTTP status (a 2xx here means the body could not be read).
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Your Garage session has ended. Sign in again."
        case .notConnected: "Garage isn't connected to Tesla. Connect Tesla to continue."
        case .tokenUnavailable: "Tesla isn't answering Garage right now. Try again in a few minutes."
        case .asleep: "The car is asleep."
        case .rateLimited: "Too many requests in a short time. Try again in a minute."
        case .budgetMinimal: "This month's Tesla budget is nearly spent, so Garage is saving it. Check Budget in More."
        case let .server(status): "The Garage server had a problem (\(status)). Try again shortly."
        }
    }
}

/// The Garage backend on Vercel. Every call carries the signed-in user's Supabase access token.
public struct GarageAPI: Sendable {
    public let baseURL: URL
    let session: URLSession
    let supabaseToken: @Sendable () async throws -> String

    /// - Parameters:
    ///   - baseURL: The API origin, for example `https://garage.duncanbottrill.com`.
    ///   - session: The session requests go through (tests pass one with a stub protocol).
    ///   - supabaseToken: Returns the current Supabase access token; called once per request.
    public init(baseURL: URL, session: URLSession, supabaseToken: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL
        self.session = session
        self.supabaseToken = supabaseToken
    }

    /// The backend from `environment` (its `apiBaseURL`), authenticated with its Supabase session.
    public init(environment: SupabaseEnvironment, session: URLSession = URLSession(configuration: .ephemeral)) {
        let client = environment.client
        self.init(baseURL: environment.config.apiBaseURL, session: session) {
            try await client.auth.session.accessToken
        }
    }

    /// `POST /auth/start`: the Tesla authorisation URL to open in `ASWebAuthenticationSession`.
    public func authStart() async throws -> URL {
        struct Body: Decodable { var url: URL }
        return try await request("POST", "auth/start", as: Body.self).url
    }

    /// `GET /api/token`: the current Tesla access token for the command proxy.
    public func token() async throws -> TeslaToken {
        try await request("GET", "api/token", as: TeslaToken.self)
    }

    /// `GET /api/connection`: Tesla token and rotation health.
    public func connection() async throws -> ConnectionHealth {
        try await request("GET", "api/connection", as: ConnectionHealth.self)
    }

    /// `POST /api/vehicles/sync`: imports the Tesla account's vehicles and returns this owner's rows.
    ///
    /// The rows carry only `id`, `vin` and `display_name`: use them to pick a car, never as the
    /// ``VehicleStore``'s vehicle.
    public func syncVehicles() async throws -> [Vehicle] {
        try await vehicleSync().vehicles
    }

    /// `POST /api/vehicles/sync` with the VINs the backend skipped because another Garage account owns them.
    public func vehicleSync() async throws -> VehicleSync {
        try await request("POST", "api/vehicles/sync", as: VehicleSync.self)
    }

    /// `POST /api/vehicle-data`: one billed `vehicle_data` read ("Refresh now"), merged into
    /// `vehicle_state` by the backend and returned as the patch it wrote. Never wakes the car:
    /// a sleeping car throws ``APIError/asleep``.
    public func refreshVehicleData(vehicleID: UUID) async throws -> VehicleState {
        struct Body: Decodable { var state: VehicleState }
        return try await request(
            "POST", "api/vehicle-data",
            body: ["vehicle_id": vehicleID.uuidString.lowercased()],
            as: Body.self
        ).state
    }

    /// `POST /api/usage`: adds `count` to this month's `category` in the usage ledger.
    public func reportUsage(_ category: UsageCategory, count: Int = 1) async throws {
        struct Body: Encodable { var category: UsageCategory; var count: Int }
        struct Reply: Decodable {}
        _ = try await request("POST", "api/usage", body: Body(category: category, count: count), as: Reply.self)
    }

    // MARK: Transport

    private struct Empty: Encodable {}

    private func request<T: Decodable>(_ method: String, _ path: String, as type: T.Type) async throws -> T {
        try await request(method, path, body: Optional<Empty>.none, as: type)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)?, as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(try await supabaseToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = Self.error(status: status, data: data) { throw error }
        do {
            return try GarageJSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.server(status: status)
        }
    }

    /// Maps a response to its typed error, or nil for a success. The body's `error` code wins over
    /// the status (`/api/vehicles/sync` reports `not_connected` as a 502).
    static func error(status: Int, data: Data) -> APIError? {
        struct Failure: Decodable {
            var error: String?
            var retryAt: String?
            enum CodingKeys: String, CodingKey { case error, retryAt = "retry_at" }
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        switch failure?.error {
        case "unauthorized": return .unauthorized
        case "not_connected": return .notConnected
        case "token_unavailable": return .tokenUnavailable(retryAt: failure?.retryAt.flatMap(GarageJSON.parseDate))
        case "asleep": return .asleep
        case "rate_limited": return .rateLimited
        case "budget_minimal": return .budgetMinimal
        default: break
        }
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 409: return .asleep
        case 429: return .rateLimited
        default: return .server(status: status)
        }
    }
}
