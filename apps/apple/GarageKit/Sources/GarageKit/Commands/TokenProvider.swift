import Foundation

/// Hands out the Tesla access token the command proxy needs, fetched from `GET /api/token`.
///
/// The token is held in memory only and reused until 60 s before its `expires_at`. Concurrent
/// callers share one fetch. After the proxy answers 401, ``CommandClient`` asks once with
/// `forceRefresh: true` and then gives up, so a broken token can never cause a request loop.
public actor TokenProvider {
    /// How long before `expires_at` a cached token stops being handed out.
    public static let refreshMargin: TimeInterval = 60

    private let fetch: @Sendable () async throws -> TeslaToken
    private let now: @Sendable () -> Date
    private var cached: TeslaToken?
    private var inflight: Task<TeslaToken, any Error>?

    /// - Parameters:
    ///   - fetch: Fetches a fresh token (normally ``GarageAPI/token()``).
    ///   - now: The clock, injectable for tests.
    public init(fetch: @escaping @Sendable () async throws -> TeslaToken, now: @escaping @Sendable () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    /// Tokens from the Garage backend.
    public init(api: GarageAPI, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(fetch: { try await api.token() }, now: now)
    }

    /// The current access token: the cached one while it has more than 60 s left, otherwise a fresh one.
    ///
    /// - Parameter forceRefresh: Skip the cache (the proxy just refused the cached token). A fetch
    ///   already in flight is joined rather than repeated, since it is fresh by definition.
    /// - Throws: ``APIError`` from the backend, or a transport error.
    public func current(forceRefresh: Bool = false) async throws -> String {
        if forceRefresh {
            cached = nil
        } else if let cached, now() < cached.expiresAt.addingTimeInterval(-Self.refreshMargin) {
            return cached.accessToken
        }
        if let inflight {
            return try await inflight.value.accessToken
        }
        let fetch = self.fetch
        let task = Task { try await fetch() }
        inflight = task
        defer { inflight = nil }
        let token = try await task.value
        cached = token
        return token.accessToken
    }

    /// Drops the cached token (for example on sign-out).
    public func invalidate() {
        cached = nil
    }
}
