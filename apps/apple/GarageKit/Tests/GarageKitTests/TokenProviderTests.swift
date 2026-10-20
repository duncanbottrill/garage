import Foundation
import Synchronization
import Testing
@testable import GarageKit

@Suite struct TokenProviderTests {
    let stub = URLStub()

    func provider(now: @escaping @Sendable () -> Date = Date.init) -> TokenProvider {
        let api = GarageAPI(baseURL: stub.baseURL(), session: stub.session, supabaseToken: { "sb-jwt" })
        return TokenProvider(api: api, now: now)
    }

    /// Hands out `tesla-1`, `tesla-2`, … each expiring at `expiresAt`.
    func serveTokens(expiresAt: String) {
        let issued = Mutex(0)
        stub.on("GET", "/api/token") { _ in
            let n = issued.withLock { n in n += 1; return n }
            return .json(200, #"{"access_token":"tesla-\#(n)","expires_at":"\#(expiresAt)"}"#)
        }
    }

    @Test func tokenProviderCachesUntilExpiry() async throws {
        serveTokens(expiresAt: "2026-10-20T08:00:00Z")
        let expiry = Date(timeIntervalSince1970: 1_792_483_200) // 2026-10-20T08:00:00Z
        let clock = Mutex(expiry.addingTimeInterval(-3600))
        let tokens = provider(now: { clock.withLock { $0 } })

        #expect(try await tokens.current() == "tesla-1")
        #expect(try await tokens.current() == "tesla-1")
        #expect(stub.requests("GET", "/api/token").count == 1)

        // Inside the 60 s margin before expiry the cached token is no longer handed out.
        clock.withLock { $0 = expiry.addingTimeInterval(-59) }
        #expect(try await tokens.current() == "tesla-2")
        #expect(stub.requests("GET", "/api/token").count == 2)
    }

    @Test func tokenProviderForceRefreshBypassesCache() async throws {
        serveTokens(expiresAt: "2099-01-01T00:00:00Z")
        let tokens = provider()

        #expect(try await tokens.current() == "tesla-1")
        #expect(try await tokens.current(forceRefresh: true) == "tesla-2")
        #expect(try await tokens.current() == "tesla-2")
        #expect(stub.requests("GET", "/api/token").count == 2)
    }

    @Test func tokenProviderCoalescesConcurrentFetches() async throws {
        serveTokens(expiresAt: "2099-01-01T00:00:00Z")
        let tokens = provider()

        async let a = tokens.current()
        async let b = tokens.current()
        let both = try await [a, b]

        #expect(both == ["tesla-1", "tesla-1"])
        #expect(stub.requests("GET", "/api/token").count == 1)
    }
}
