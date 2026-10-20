import Foundation
import Supabase

/// The app's Supabase client and backend endpoints, built once from `Config.plist`.
public final class SupabaseEnvironment: Sendable {
    /// Public configuration: the project URL, the publishable key (safe to ship) and the Vercel API.
    public struct Config: Sendable, Equatable {
        public var supabaseURL: URL
        public var publishableKey: String
        public var apiBaseURL: URL

        public init(supabaseURL: URL, publishableKey: String, apiBaseURL: URL) {
            self.supabaseURL = supabaseURL
            self.publishableKey = publishableKey
            self.apiBaseURL = apiBaseURL
        }

        static let keys = ["SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "API_BASE_URL"]

        /// Reads `Config.plist` from `bundle`; when the bundle has no such plist (unit tests, `swift test`)
        /// falls back to environment variables of the same names. Nil when neither has all three values.
        public static func load(
            bundle: Bundle = .main,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Config? {
            if let url = bundle.url(forResource: "Config", withExtension: "plist"),
               let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return Config(values: plist.compactMapValues { $0 as? String })
            }
            return Config(values: environment)
        }

        init?(values: [String: String]) {
            guard let url = values["SUPABASE_URL"].flatMap(URL.init(string:)),
                  let key = values["SUPABASE_PUBLISHABLE_KEY"], !key.isEmpty,
                  let api = values["API_BASE_URL"].flatMap(URL.init(string:))
            else { return nil }
            self.init(supabaseURL: url, publishableKey: key, apiBaseURL: api)
        }
    }

    /// The environment from the app's `Config.plist` (or the environment variables). Traps with a
    /// clear message when neither is configured: the app cannot do anything without a backend.
    public static let shared: SupabaseEnvironment = {
        guard let config = Config.load() else {
            preconditionFailure("GarageKit: no Config.plist in the main bundle and no \(Config.keys.joined(separator: "/")) environment variables")
        }
        return SupabaseEnvironment(config: config)
    }()

    public let config: Config
    /// The one Supabase client (Auth, PostgREST, Realtime) the app shares.
    public let client: SupabaseClient

    public init(config: Config) {
        self.config = config
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
    }

    /// An environment whose sessions live in `authStorage` instead of the keychain (tests).
    init(config: Config, authStorage: any AuthLocalStorage) {
        self.config = config
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(auth: .init(storage: authStorage, emitLocalSessionAsInitialSession: true))
        )
    }
}
