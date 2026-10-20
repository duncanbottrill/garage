import Foundation
import Testing
@testable import GarageKit

@Suite struct SupabaseEnvironmentTests {
    /// Without a `Config.plist` in the bundle (unit tests, `swift test`), the environment variables are used.
    @Test func configFallsBackToEnvironment() throws {
        let config = try #require(SupabaseEnvironment.Config.load(
            bundle: Bundle(for: BundleMarker.self),
            environment: [
                "SUPABASE_URL": "https://example.supabase.co",
                "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test",
                "API_BASE_URL": "https://garage.example.com",
            ]
        ))
        #expect(config.supabaseURL == URL(string: "https://example.supabase.co"))
        #expect(config.publishableKey == "sb_publishable_test")
        #expect(config.apiBaseURL == URL(string: "https://garage.example.com"))
        #expect(SupabaseEnvironment.Config.load(bundle: Bundle(for: BundleMarker.self), environment: [:]) == nil)
    }
}

private final class BundleMarker {}
