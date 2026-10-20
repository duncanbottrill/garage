import Foundation
import Observation

/// The More screen's proxy URL override, kept in `UserDefaults` under ``key``.
///
/// An override only counts when it is an `https` URL with a host; anything else is ignored, so a
/// half-typed value can never point commands somewhere odd.
public enum ProxyOverride {
    /// The `UserDefaults` key holding the override's text.
    public static let key = "proxyBaseURLOverride"

    /// `text` as a proxy origin (trimmed), or nil unless it is `https` with a non-empty host and
    /// nothing else: no user info, query or fragment, and no path beyond "/". The result is rebuilt
    /// from the scheme, host and port alone, so it is always a bare origin.
    public static func validated(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = parts.port
        return origin.url
    }

    /// The saved override, when it is valid.
    public static func current(in defaults: UserDefaults = .standard) -> URL? {
        defaults.string(forKey: key).flatMap(validated)
    }

    /// Saves `url` as the override, or removes it when nil.
    public static func set(_ url: URL?, in defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.absoluteString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The proxy URL to use: a valid override wins over the bridge's `published` one.
    public static func resolve(published: URL?, in defaults: UserDefaults = .standard) -> URL? {
        current(in: defaults) ?? published
    }
}

/// Everything the More screen shows and does: the Tesla connection, the bridge, the budget, the
/// manual refresh, the proxy URL (with its override and probe), Tailscale, the account and About.
///
/// The view keeps the inputs (``state``, ``vehicle``, ``reachability``, the account) current from the
/// ``AppModel``; the model fetches the connection health itself and runs the refresh and the probe.
/// ``sections`` (and ``rows``) are plain values, so every rule is testable without a view.
@MainActor
@Observable
public final class MoreModel {
    /// The backend calls More makes. ``init(_:)`` takes them from a ``GarageAPI``.
    public struct API: Sendable {
        /// `GET /api/connection`.
        public var connection: @MainActor () async throws -> ConnectionHealth
        /// `POST /api/vehicle-data` for the car with this id.
        public var refreshVehicleData: @MainActor (UUID) async throws -> VehicleState

        public init(
            connection: @escaping @MainActor () async throws -> ConnectionHealth,
            refreshVehicleData: @escaping @MainActor (UUID) async throws -> VehicleState
        ) {
            self.connection = connection
            self.refreshVehicleData = refreshVehicleData
        }

        /// The calls on `api`.
        public init(_ api: GarageAPI) {
            self.init(connection: { try await api.connection() }, refreshVehicleData: { try await api.refreshVehicleData(vehicleID: $0) })
        }
    }

    /// One row of the list: an icon, a title, a detail line and a status colour.
    public struct Row: Sendable, Equatable, Identifiable {
        /// The rows, in the order they appear.
        public enum ID: Sendable, Hashable, CaseIterable {
            case connection, bridge, budget, refresh, proxy, tailscale, account, about
        }

        /// The trailing state: a coloured dot for the first three, a chevron or nothing for neutral.
        public enum Tone: Sendable, Equatable {
            /// `Tokens.Colors.charging`.
            case healthy
            /// `Tokens.Colors.warning`.
            case warning
            /// `Tokens.Colors.danger`; the detail line is drawn in it too.
            case failed
            /// No status to show.
            case neutral
        }

        public let id: ID
        public let icon: Icon.Name
        public let title: String
        public let detail: String
        public let tone: Tone
    }

    /// A titled group of rows.
    public struct Section: Sendable, Equatable, Identifiable {
        public let title: String
        public let rows: [Row]
        public var id: String { title }
    }

    /// Where the "Refresh now" read is.
    public enum RefreshPhase: Sendable, Equatable {
        case idle, refreshing, succeeded(Date), failed(String)
    }

    /// Where the proxy "Test" probe is.
    public enum ProxyTest: Sendable, Equatable {
        case idle, testing
        /// The probe of `url` (nil when there was nothing to probe) settled on `state`.
        case finished(ProxyReachability.State, url: URL?)
    }

    /// The app's version and build, for About.
    public struct AppVersion: Sendable, Equatable {
        public var version: String
        public var build: String

        public init(version: String, build: String) {
            self.version = version
            self.build = build
        }

        /// From the main bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
        public static var main: AppVersion {
            let info = Bundle.main.infoDictionary ?? [:]
            return AppVersion(
                version: info["CFBundleShortVersionString"] as? String ?? "—",
                build: info["CFBundleVersion"] as? String ?? "—"
            )
        }

        /// "0.1.0 (1)".
        public var text: String { "\(version) (\(build))" }
    }

    /// A third-party work the app ships or is built with, for About.
    public struct Licence: Sendable, Equatable, Identifiable {
        public let name: String
        public let licence: String
        /// The bundled notice in `Resources/LICENSES` (without `.txt`), or nil when none ships.
        public let file: String?
        public var id: String { name }

        public init(name: String, licence: String, file: String? = nil) {
            self.name = name
            self.licence = licence
            self.file = file
        }

        /// The bundled notice text, when there is one.
        public var text: String? {
            guard let file else { return nil }
            let bundle = GarageKit.resources
            let url = bundle.url(forResource: file, withExtension: "txt", subdirectory: "LICENSES")
                ?? bundle.url(forResource: file, withExtension: "txt")
            return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
    }

    /// The fonts, icons and libraries Garage uses, with their licences.
    public static let licences: [Licence] = [
        Licence(name: "Big Shoulders Display", licence: "SIL OFL 1.1", file: "BigShouldersDisplay-OFL"),
        Licence(name: "Instrument Sans", licence: "SIL OFL 1.1", file: "InstrumentSans-OFL"),
        Licence(name: "Lucide icons", licence: "ISC", file: "Lucide-LICENSE"),
        Licence(name: "supabase-swift", licence: "MIT", file: "supabase-swift-LICENSE"),
        // Used by the test targets only; nothing of it ships in the app.
        Licence(name: "swift-snapshot-testing", licence: "MIT"),
    ]

    // MARK: Inputs

    /// The car's latest row (bridge health, freshness for "Refresh now").
    public var state: VehicleState? {
        didSet { trackHeartbeat() }
    }
    /// The car (budget mode, published proxy URL, id for the refresh).
    public var vehicle: Vehicle?
    /// The live proxy probe's last result (Tailscale row).
    public var reachability: ProxyReachability.State = .unknown
    /// The account's email, when it has one.
    public var accountEmail: String?
    /// Whether the account can sign in with Apple; false offers "Link Apple ID".
    public var hasAppleIdentity = false

    // MARK: Outputs

    /// The last `GET /api/connection` answer, or nil before the first.
    public private(set) var connection: ConnectionHealth?
    /// Copy for a failed connection fetch, or nil.
    public private(set) var connectionError: String?
    /// The manual refresh.
    public private(set) var refreshPhase: RefreshPhase = .idle
    /// The proxy probe started from "Test".
    public private(set) var proxyTest: ProxyTest = .idle
    /// The app's version, for About.
    public let appVersion: AppVersion
    /// Called after the override is saved or cleared, so the live command client re-probes.
    @ObservationIgnored public var onProxyOverrideChange: (@MainActor () -> Void)?
    /// Called with the row a successful "Refresh now" read returned, so the store shows it at once.
    @ObservationIgnored public var onRefreshed: (@MainActor (VehicleState) -> Void)?

    @ObservationIgnored private let api: API
    @ObservationIgnored private let probe: @MainActor (URL) async -> ProxyReachability.State
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let tokenFailure: @MainActor () -> CommandError?
    @ObservationIgnored private let teslaRejected: @MainActor () -> Bool
    @ObservationIgnored private let timeZone: TimeZone
    /// Bumped on every override change, so ``effectiveProxyURL`` (read from defaults) is observed.
    private var overrideRevision = 0
    /// The bridge's last heartbeat seen in this session: check-in time and counters.
    @ObservationIgnored private var lastHeartbeat: Heartbeat?
    /// The dropped or patch-failure count rose between the last two heartbeats.
    private var bridgeCountsRose = false

    private struct Heartbeat: Equatable {
        var seenAt: Date
        var dropped: Int
        var failures: Int
    }

    /// - Parameters:
    ///   - api: The connection and refresh calls.
    ///   - probe: One reachability probe of a proxy URL (a TLS handshake, nothing billed).
    ///   - defaults: Where the proxy override lives (``ProxyOverride/key``).
    ///   - now: The clock for "rotated 4 min ago", the bridge window and the refresh rule.
    ///   - appVersion: The version shown in About.
    ///   - tokenFailure: The command client's last token failure (``CommandClient/tokenFailure``),
    ///     read whenever the rows are; it turns the Connection row red.
    ///   - teslaRejected: Whether Tesla refused the token after a refresh
    ///     (``CommandClient/teslaRejected``), read whenever the rows are; it offers "Reconnect Tesla".
    ///   - timeZone: For clock times ("rotated at 14:02").
    public init(
        api: API,
        probe: @escaping @MainActor (URL) async -> ProxyReachability.State,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() },
        appVersion: AppVersion = .main,
        tokenFailure: @escaping @MainActor () -> CommandError? = { nil },
        teslaRejected: @escaping @MainActor () -> Bool = { false },
        timeZone: TimeZone = .current
    ) {
        self.api = api
        self.probe = probe
        self.defaults = defaults
        self.now = now
        self.appVersion = appVersion
        self.tokenFailure = tokenFailure
        self.teslaRejected = teslaRejected
        self.timeZone = timeZone
    }

    // MARK: Connection

    /// Fetches `GET /api/connection`. A failure keeps the last answer and sets ``connectionError``.
    public func loadConnection() async {
        do {
            connection = try await api.connection()
            connectionError = nil
        } catch {
            connectionError = OnboardingFlow.message(for: error)
        }
    }

    /// Offer "Reconnect Tesla": the last rotation failed, no Tesla account is connected (per
    /// `/api/connection`, or because a send found no Tesla token), or Tesla refused the token after a
    /// refresh (the proxy's second 401).
    public var showsReconnect: Bool {
        if tokenFailure() == .unauthorized || teslaRejected() { return true }
        guard let connection else { return false }
        return !connection.connected || connection.lastError != nil
    }

    /// The Connection row's detail after Tesla refused the token (``CommandClient/teslaRejected``).
    public static let teslaRejectedDetail = "Tesla refused Garage's token · reconnect Tesla"

    /// The Connection row's detail for a token failure.
    public static func tokenFailureDetail(_ failure: CommandError) -> String {
        switch failure {
        case let .tokenUnavailable(retryAt?):
            "Renewing Tesla access · try again after \(CommandError.clockTime(retryAt))"
        case .tokenUnavailable(nil):
            "Renewing Tesla access · commands paused"
        case .sessionExpired:
            "Your Garage sign-in was refused"
        case .unauthorized:
            "No Tesla token · reconnect Tesla"
        default:
            "Garage couldn't get a Tesla token · try again later"
        }
    }

    // MARK: Refresh now

    /// Whether to offer "Refresh now": telemetry older than 10 min and the car not asleep (spec §4.6).
    public var showsRefreshNow: Bool {
        StatusModel(state: state, vehicle: vehicle, now: now(), reachability: reachability).showsRefreshNow
    }

    /// One billed `vehicle_data` read. 409 reads as "The car is asleep", the budget refusal as
    /// "Manual refresh is paused to stay in budget".
    public func refreshNow() async {
        guard let id = vehicle?.id, refreshPhase != .refreshing else { return }
        refreshPhase = .refreshing
        do {
            let refreshed = try await api.refreshVehicleData(id)
            refreshPhase = .succeeded(now())
            onRefreshed?(refreshed)
        } catch APIError.asleep {
            refreshPhase = .failed("The car is asleep")
        } catch APIError.budgetMinimal {
            refreshPhase = .failed("Manual refresh is paused to stay in budget")
        } catch {
            refreshPhase = .failed(OnboardingFlow.message(for: error))
        }
    }

    // MARK: Proxy URL

    /// The bridge's published proxy URL (`vehicles.proxy_base_url`), or nil.
    public var publishedProxyURL: URL? { vehicle?.proxyBaseURL }

    /// The saved override, when valid.
    public var proxyOverride: URL? {
        _ = overrideRevision
        return ProxyOverride.current(in: defaults)
    }

    /// The URL commands and probes use: the override when set, else the published one.
    public var effectiveProxyURL: URL? { proxyOverride ?? publishedProxyURL }

    /// True while a valid override is in use.
    public var isUsingOverride: Bool { proxyOverride != nil }

    /// Saves `text` as the override. Returns false (and saves nothing) unless it is https with a host.
    @discardableResult
    public func saveProxyOverride(_ text: String) -> Bool {
        guard let url = ProxyOverride.validated(text) else { return false }
        ProxyOverride.set(url, in: defaults)
        overrideChanged()
        return true
    }

    /// Removes the override, going back to the published URL.
    public func clearProxyOverride() {
        ProxyOverride.set(nil, in: defaults)
        overrideChanged()
    }

    /// "Test": probes what is typed, or the URL in use when nothing is typed. Nothing is saved.
    ///
    /// - Non-empty and valid (``ProxyOverride/validated(_:)``): probes `candidate`.
    /// - Non-empty and invalid: probes nothing and returns false (the view says why).
    /// - Empty: probes ``effectiveProxyURL``; `.unknown` when there is none.
    /// - Returns: false only when `candidate` was rejected.
    @discardableResult
    public func testProxy(candidate: String) async -> Bool {
        let typed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: URL?
        if typed.isEmpty {
            target = effectiveProxyURL
        } else if let url = ProxyOverride.validated(typed) {
            target = url
        } else {
            return false
        }
        guard let target else {
            proxyTest = .finished(.unknown, url: nil)
            return true
        }
        proxyTest = .testing
        proxyTest = .finished(await probe(target), url: target)
        return true
    }

    private func overrideChanged() {
        overrideRevision &+= 1
        proxyTest = .idle
        onProxyOverrideChange?()
    }

    // MARK: Rows

    /// The list, grouped: Tesla, Car, Network, Account, About.
    public var sections: [Section] {
        let at = now()
        var car = [bridgeRow(at), budgetRow]
        if showsRefreshNow { car.append(refreshRow(at)) }
        return [
            Section(title: "Tesla", rows: [connectionRow(at)]),
            Section(title: "Car", rows: car),
            Section(title: "Network", rows: [proxyRow, tailscaleRow]),
            Section(title: "Account", rows: [accountRow]),
            Section(title: "About", rows: [aboutRow]),
        ]
    }

    /// Every row, in order.
    public var rows: [Row] { sections.flatMap(\.rows) }

    /// The row with `id`, or nil when it is hidden (only "Refresh now" hides).
    public func row(_ id: Row.ID) -> Row? {
        rows.first { $0.id == id }
    }

    private func connectionRow(_ at: Date) -> Row {
        let make = { (detail: String, tone: Row.Tone) in
            Row(id: .connection, icon: .key, title: "Connection", detail: detail, tone: tone)
        }
        if let lastError = connection?.lastError { return make(lastError, .failed) }
        if connection?.connected == false { return make("Not connected to Tesla", .failed) }
        // A send could not get a Tesla token: red, whatever the last health check said.
        if let failure = tokenFailure() { return make(Self.tokenFailureDetail(failure), .failed) }
        if teslaRejected() { return make(Self.teslaRejectedDetail, .failed) }
        guard let connection else {
            return connectionError.map { make($0, .warning) } ?? make("Checking…", .neutral)
        }
        if connection.rotating { return make("Connected · rotating token", .healthy) }
        guard let rotated = connection.rotatedAt else { return make("Connected", .healthy) }
        return make("Connected · token rotated \(Self.when(rotated, now: at, timeZone: timeZone))", .healthy)
    }

    private func bridgeRow(_ at: Date) -> Row {
        let make = { (detail: String, tone: Row.Tone) in
            Row(id: .bridge, icon: .server, title: "Bridge", detail: detail, tone: tone)
        }
        guard let seen = state?.bridgeSeenAt else { return make("No check-in yet", .neutral) }
        let health = state?.bridgeHealth
        var parts = ["Seen \(Self.when(seen, now: at, timeZone: timeZone))"]
        if let connectivity = health?.connectivity, !connectivity.isEmpty {
            parts.append(connectivity.replacingOccurrences(of: "_", with: " ").lowercased().capitalizedFirst)
        }
        parts.append("\(health?.dropped ?? 0) dropped")
        let failures = health?.patchFailures ?? 0
        parts.append(failures == 1 ? "1 patch failure" : "\(failures) patch failures")
        let detail = parts.joined(separator: " · ")

        guard Freshness.bridge(seenAt: seen, now: at) else { return make(detail, .failed) }
        let carConnected = health?.connectivity.map { $0.uppercased() == "CONNECTED" } ?? true
        // The counters are totals since the bridge started: only a rise is news.
        return make(detail, carConnected && !bridgeCountsRose ? .healthy : .warning)
    }

    /// Compares each new heartbeat (a new check-in time or new counters) with the previous one seen in
    /// this session. The first one seen has nothing to compare with, so old totals read green.
    private func trackHeartbeat() {
        guard let seen = state?.bridgeSeenAt else { return }
        let health = state?.bridgeHealth
        let beat = Heartbeat(seenAt: seen, dropped: health?.dropped ?? 0, failures: health?.patchFailures ?? 0)
        guard beat != lastHeartbeat else { return }
        if let last = lastHeartbeat {
            bridgeCountsRose = beat.dropped > last.dropped || beat.failures > last.failures
        } else {
            bridgeCountsRose = false
        }
        lastHeartbeat = beat
    }

    private var budgetRow: Row {
        let mode = vehicle?.budgetMode ?? .normal
        let (detail, tone): (String, Row.Tone) = switch mode {
        case .normal: ("Normal update rate", .healthy)
        case .reduced: ("Reduced update rate to stay in budget", .warning)
        case .minimal: ("Minimal updates: budget nearly used", .failed)
        }
        return Row(id: .budget, icon: .gauge, title: "Budget", detail: detail, tone: tone)
    }

    private func refreshRow(_ at: Date) -> Row {
        let (detail, tone): (String, Row.Tone) = switch refreshPhase {
        case .idle: ("One read from the car, counted in the budget", .neutral)
        case .refreshing: ("Refreshing…", .neutral)
        case let .succeeded(date): ("Requested \(Self.when(date, now: at, timeZone: timeZone))", .healthy)
        case let .failed(message): (message, .failed)
        }
        return Row(id: .refresh, icon: .refreshCw, title: "Refresh now", detail: detail, tone: tone)
    }

    private var proxyRow: Row {
        let detail = effectiveProxyURL?.absoluteString ?? "Not published yet"
        // The dot speaks for the URL in use only, not for a typed candidate that was tested.
        var tone = Row.Tone.neutral
        if case let .finished(state, url?) = proxyTest, url == effectiveProxyURL {
            tone = switch state {
            case .reachable: .healthy
            case .unreachable: .failed
            case .unknown: .neutral
            }
        }
        return Row(id: .proxy, icon: .link, title: "Proxy URL", detail: detail, tone: tone)
    }

    private var tailscaleRow: Row {
        let (detail, tone): (String, Row.Tone) = switch reachability {
        case .reachable: ("Bridge reachable over the tailnet", .healthy)
        case .unreachable: (StatusModel.message(for: .tailscaleOff, timeZone: timeZone), .failed)
        case .unknown: ("Not checked yet", .neutral)
        }
        return Row(id: .tailscale, icon: .network, title: "Tailscale", detail: detail, tone: tone)
    }

    private var accountRow: Row {
        let who = accountEmail ?? "Signed in"
        let apple = hasAppleIdentity ? "Apple ID linked" : "Apple ID not linked"
        return Row(id: .account, icon: .user, title: "Account", detail: "\(who) · \(apple)", tone: .neutral)
    }

    private var aboutRow: Row {
        Row(id: .about, icon: .info, title: "Garage", detail: "Version \(appVersion.text)", tone: .neutral)
    }

    /// Copy rule: relative only under an hour ("just now", "4 min ago"), then a clock time
    /// ("at 14:02"), with the date when it is more than a day old or on an earlier day ("19 Oct 14:02").
    static func when(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        default:
            let stamp = TimeText.stamp(date, now: now, timeZone: timeZone)
            return TimeText.needsDate(date, now: now, timeZone: timeZone) ? stamp : "at \(stamp)"
        }
    }
}

private extension String {
    /// The first character uppercased: "connected" → "Connected".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
