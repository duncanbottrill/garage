import Foundation
import Testing
@testable import GarageKit

@Suite struct GarageAPITests {
    let stub = URLStub()

    var api: GarageAPI {
        GarageAPI(baseURL: stub.baseURL(), session: stub.session, supabaseToken: { "sb-jwt" })
    }

    @Test func authStartReturnsURL() async throws {
        stub.on("POST", "/auth/start") { _ in .json(200, #"{"url":"https://auth.tesla.com/oauth2/v3/authorize?state=abc"}"#) }

        let url = try await api.authStart()

        #expect(url == URL(string: "https://auth.tesla.com/oauth2/v3/authorize?state=abc"))
        let request = try #require(stub.requests("POST", "/auth/start").first)
        #expect(request.bearer == "Bearer sb-jwt")
    }

    @Test func tokenMaps404ToNotConnected() async {
        stub.on("GET", "/api/token") { _ in .json(404, #"{"error":"not_connected"}"#) }

        await #expect(throws: APIError.notConnected) { try await api.token() }
    }

    @Test func tokenMaps503WithRetryAt() async {
        stub.on("GET", "/api/token") { _ in .json(503, #"{"error":"token_unavailable","retry_at":"2026-10-20T08:15:00.000+00:00"}"#) }

        let expected = Date(timeIntervalSince1970: 1_792_484_100) // 2026-10-20T08:15:00Z
        await #expect(throws: APIError.tokenUnavailable(retryAt: expected)) { try await api.token() }
    }

    @Test func tokenDecodesAccessTokenAndExpiry() async throws {
        stub.on("GET", "/api/token") { _ in .json(200, #"{"access_token":"tesla-1","expires_at":"2026-10-20T08:15:00Z"}"#) }

        let token = try await api.token()

        #expect(token == TeslaToken(accessToken: "tesla-1", expiresAt: Date(timeIntervalSince1970: 1_792_484_100)))
    }

    @Test func unauthorizedOn401() async {
        stub.on("GET", "/api/connection") { _ in .json(401, #"{"error":"unauthorized"}"#) }

        await #expect(throws: APIError.unauthorized) { try await api.connection() }
    }

    @Test func connectionDecodesHealth() async throws {
        stub.on("GET", "/api/connection") { _ in
            .json(200, #"{"connected":true,"rotated_at":"2026-10-20T06:00:00.123456+00:00","last_error":null,"access_expires_at":"2026-10-20T14:00:00+00:00","rotating":false,"refresh_failures":0,"next_refresh_at":null}"#)
        }

        let health = try await api.connection()

        #expect(health.connected)
        #expect(health.lastError == nil)
        #expect(health.rotating == false)
        #expect(health.refreshFailures == 0)
        #expect(health.nextRefreshAt == nil)
        #expect(health.accessExpiresAt == Date(timeIntervalSince1970: 1_792_504_800))
        #expect(health.rotatedAt != nil)
    }

    @Test func syncVehiclesDecodesRows() async throws {
        stub.on("POST", "/api/vehicles/sync") { _ in
            .json(200, #"{"vehicles":[{"id":"7c1f0a0e-8a43-4d43-9a39-2f1b6f5d1e11","vin":"LRWYGCEK0PC000001","display_name":"Ghost"}],"conflicts":[]}"#)
        }

        let vehicles = try await api.syncVehicles()

        #expect(vehicles.map(\.vin) == ["LRWYGCEK0PC000001"])
        #expect(vehicles.first?.displayName == "Ghost")
    }

    @Test func syncVehiclesMaps502NotConnected() async {
        stub.on("POST", "/api/vehicles/sync") { _ in .json(502, #"{"vehicles":[],"conflicts":[],"error":"not_connected"}"#) }

        await #expect(throws: APIError.notConnected) { try await api.syncVehicles() }
    }

    @Test func vehicleDataMapsAsleepAndBudget() async throws {
        let id = UUID(uuidString: "7C1F0A0E-8A43-4D43-9A39-2F1B6F5D1E11")!
        stub.on("POST", "/api/vehicle-data", sequence: [
            .json(409, #"{"error":"asleep"}"#),
            .json(429, #"{"error":"budget_minimal"}"#),
            .json(429, #"{"error":"rate_limited"}"#),
            .json(200, #"{"state":{"soc":61.5,"sleep_state":"online","charge_at":"2026-10-20T07:31:49Z"}}"#),
        ])

        await #expect(throws: APIError.asleep) { try await api.refreshVehicleData(vehicleID: id) }
        await #expect(throws: APIError.budgetMinimal) { try await api.refreshVehicleData(vehicleID: id) }
        await #expect(throws: APIError.rateLimited) { try await api.refreshVehicleData(vehicleID: id) }
        let state = try await api.refreshVehicleData(vehicleID: id)

        #expect(state.soc == 61.5)
        #expect(state.sleepState == "online")
        let body = try #require(stub.requests("POST", "/api/vehicle-data").first?.jsonBody)
        #expect(body == ["vehicle_id": "7c1f0a0e-8a43-4d43-9a39-2f1b6f5d1e11"])
    }

    @Test func reportUsagePostsCategoryAndCount() async throws {
        stub.on("POST", "/api/usage") { _ in .json(200, #"{"ok":true}"#) }

        try await api.reportUsage(.wakes, count: 2)

        let request = try #require(stub.requests("POST", "/api/usage").first)
        #expect(request.jsonBody == ["category": "wakes", "count": 2])
        #expect(request.bearer == "Bearer sb-jwt")
    }
}
