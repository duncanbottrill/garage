import AuthenticationServices
import Foundation
import Observation
import os
import Supabase

/// The app's root object: the Supabase client, the vehicle store, the command client and the
/// onboarding flow, plus the account actions (sign in, link Apple ID, sign out).
///
/// Create one at launch, call ``launch()`` once, and forward every opened URL to ``handle(url:)``.
@MainActor
@Observable
public final class AppModel {
    /// The Supabase project and API endpoints.
    @ObservationIgnored public let environment: SupabaseEnvironment
    /// The Garage backend, authenticated with the Supabase session.
    @ObservationIgnored public let api: GarageAPI
    /// Decides which onboarding step to show; ``OnboardingFlow/Step/done`` means the app proper.
    @ObservationIgnored public let flow: OnboardingFlow

    /// The car's live state. Replaced on sign-out, so read it from here rather than keeping a reference.
    public private(set) var vehicleStore: VehicleStore
    /// Sends commands through the bridge's proxy. Replaced on sign-out (its Tesla token goes with it).
    public private(set) var commandClient: CommandClient
    /// The signed-in Supabase user, or nil when signed out.
    public private(set) var user: User?
    /// True while a sign-in, Tesla connection or vehicle choice is running.
    public private(set) var isWorking = false

    /// The Supabase client the app shares.
    public var client: SupabaseClient { environment.client }
    /// The account's email, when it has one (Apple may give a private relay address).
    public var accountEmail: String? { user?.email }
    /// Whether the account can sign in with Apple. When false, More offers "Link Apple ID".
    public var hasAppleIdentity: Bool { Self.hasAppleIdentity(user) }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: FileSnapshotCache
    @ObservationIgnored private let appleAuthorizer = AppleAuthorizer()
    @ObservationIgnored private let webAuthenticator = WebAuthenticator()
    /// The nonce for the Sign in with Apple button's request, between `onRequest` and `onCompletion`.
    @ObservationIgnored private var pendingNonce: AppleNonce?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var reachabilityRunning = false
    /// Set when the onboarding vehicle check re-read the rows during the current ``refresh()``, so the
    /// foreground re-read is not done twice.
    @ObservationIgnored private var refetchedDuringEvaluation = false
    /// Backs ``moreModel``.
    @ObservationIgnored private var more: MoreModel?
    /// Ends the Supabase session on this device (`signOut(scope: .local)`); injectable for tests.
    @ObservationIgnored private let endSession: @MainActor () async -> Void
    /// Makes the vehicle store (at launch and after sign-out); injectable for tests.
    @ObservationIgnored private let storeFactory: @MainActor () -> VehicleStore
    /// The session proxy requests go through; nil for the command client's default.
    @ObservationIgnored private let proxySession: URLSession?

    /// The app's model on the shared environment (`Config.plist`).
    public convenience init() {
        self.init(environment: .shared)
    }

    /// - Parameters:
    ///   - environment: The Supabase project and API.
    ///   - defaults: Where the chosen vehicle and onboarding completion are kept.
    ///   - cache: The snapshot cache the store opens on, cleared on sign-out.
    public convenience init(environment: SupabaseEnvironment, defaults: UserDefaults = .standard, cache: FileSnapshotCache = FileSnapshotCache()) {
        self.init(environment: environment, defaults: defaults, cache: cache, checks: nil, endSession: nil)
    }

    /// The designated init; tests replace the onboarding checks, the session ending, the backend,
    /// the vehicle store and the proxy's URL session.
    init(
        environment: SupabaseEnvironment,
        defaults: UserDefaults,
        cache: FileSnapshotCache,
        checks: OnboardingFlow.Checks?,
        endSession: (@MainActor () async -> Void)?,
        api: GarageAPI? = nil,
        makeStore: (@MainActor () -> VehicleStore)? = nil,
        proxySession: URLSession? = nil
    ) {
        let owner = WeakModel()
        self.environment = environment
        self.defaults = defaults
        self.cache = cache
        self.api = api ?? GarageAPI(environment: environment)
        storeFactory = makeStore ?? { Self.makeStore(environment: environment, cache: cache, defaults: defaults) }
        self.proxySession = proxySession
        vehicleStore = storeFactory()
        commandClient = Self.makeCommandClient(api: self.api, owner: owner, session: proxySession)
        user = environment.client.auth.currentUser
        // A session and a finished onboarding on this device: open on Status (and its cached snapshot)
        // straight away; the first evaluation moves elsewhere only if something has changed.
        let resume = environment.client.auth.currentSession.map { OnboardingFlow.hasCompleted(by: $0.user.id, in: defaults) } ?? false
        flow = OnboardingFlow(step: resume ? .done : .signIn, checks: checks ?? Self.checks(owner: owner), defaults: defaults)
        let client = environment.client
        self.endSession = endSession ?? {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                // The local session is removed before the network call, so this is only the server side.
                AppModel.logger.error("Sign-out request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        owner.model = self
        // Landing on sign-in by any route (no session, a refused one) drops the previous account's
        // car, cache and choices, exactly as an explicit sign-out does.
        flow.onSignedOut = { [weak self] refused in
            guard let self else { return }
            if refused { await self.endSession() }
            self.resetAfterSignOut()
        }
    }

    // MARK: Proxy

    /// The proxy URL commands and the reachability probe use: the More override
    /// (``ProxyOverride/key``, when it is https with a host) over the bridge's published URL.
    public var proxyBaseURL: URL? {
        Self.proxyBaseURL(published: vehicleStore.vehicle?.proxyBaseURL, defaults: defaults)
    }

    /// The precedence ``proxyBaseURL`` applies: a valid override in `defaults`, else `published`.
    static func proxyBaseURL(published: URL?, defaults: UserDefaults) -> URL? {
        ProxyOverride.resolve(published: published, in: defaults)
    }

    /// Re-probes the proxy now, after the More override was saved or cleared, so Status and the
    /// sheets stop showing the old URL's reachability.
    public func proxyOverrideChanged() {
        Task { await commandClient.reachabilityMonitor.check() }
    }

    /// The More screen's model, made on first use and kept (with its connection health, refresh and
    /// probe results) across tab switches; dropped on sign-out with the rest of the account's state.
    public var moreModel: MoreModel {
        if let more { return more }
        let made = makeMoreModel()
        more = made
        return made
    }

    /// The More screen's model on this app's backend, defaults and proxy probe.
    private func makeMoreModel() -> MoreModel {
        let api = api
        let more = MoreModel(
            api: MoreModel.API(api),
            probe: { [weak self] url in
                guard let monitor = self?.commandClient.reachabilityMonitor, let host = url.host(), !host.isEmpty else { return .unknown }
                return await monitor.probe(host: host, port: UInt16(clamping: url.port ?? 443))
            },
            defaults: defaults,
            // Read live, so the Connection row turns red as soon as a send's token fetch fails.
            tokenFailure: { [weak self] in self?.commandClient.tokenFailure },
            // And offers "Reconnect Tesla" as soon as Tesla refuses the token after a refresh.
            teslaRejected: { [weak self] in self?.commandClient.teslaRejected ?? false }
        )
        more.onProxyOverrideChange = { [weak self] in self?.proxyOverrideChanged() }
        // The billed read's answer is the newest row there is: show it without waiting for Realtime.
        more.onRefreshed = { [weak self] in self?.vehicleStore.apply(state: $0) }
        return more
    }

    /// "Reconnect Tesla" (More): back to onboarding's Connect step; the app shows onboarding until
    /// the Tesla sign-in completes and the next evaluation lands on done again.
    public func reconnectTesla() {
        flow.reset(to: .connectTesla)
    }

    // MARK: Lifecycle

    /// Starts following auth changes and runs the first onboarding evaluation. Call once, at launch.
    public func launch() async {
        observeAuth()
        await refresh()
    }

    /// Re-runs the onboarding checks, then, on Status, starts the proxy probe loop and the vehicle
    /// store if it is not following the car yet (the launch check ran offline, so nothing started it).
    /// The store needs only Supabase, so it is started even when a Garage backend check failed.
    ///
    /// When the store is already following the car (the app is back in the foreground), the vehicle and
    /// its `vehicle_state` row are re-read over PostgREST (free): Realtime may have missed updates while
    /// the app was suspended, and the channel can take a while to notice.
    public func refresh() async {
        refetchedDuringEvaluation = false
        await flow.evaluate()
        startMonitoringIfDone()
        guard flow.step == .done else { return }
        if !vehicleStore.isStarted {
            await vehicleStore.start()
        } else if !refetchedDuringEvaluation {
            await vehicleStore.refetch()
        }
    }

    /// Call when the app goes to the background: writes the snapshot the store is holding back, so the
    /// next cold start opens on the newest row, and sends the usage counts waiting for their window.
    public func didEnterBackground() {
        vehicleStore.flushCache()
        commandClient.flushUsage()
    }

    /// Handles a URL opened by the app (`onOpenURL`). `garage://connected` re-evaluates onboarding.
    public func handle(url: URL) {
        Task { await handleCallback(url) }
    }

    // MARK: Sign in

    /// For the Sign in with Apple button's `onRequest`: email scope and a fresh hashed nonce.
    public func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AppleNonce.random()
        pendingNonce = nonce
        AppleCredential.prepare(request, nonce: nonce)
    }

    /// For the Sign in with Apple button's `onCompletion`: signs in to Supabase with the ID token.
    public func completeAppleSignIn(_ result: Result<ASAuthorization, any Error>) async {
        let nonce = pendingNonce
        pendingNonce = nil
        switch result {
        case .success(let authorization):
            await perform {
                guard let nonce else { throw AppleSignInError.missingNonce }
                try await self.signInToSupabase(idToken: AppleCredential.idToken(from: authorization), nonce: nonce)
            }
        case .failure(let error):
            if !AppleCredential.isCancellation(error) { flow.report(error) }
        }
    }

    /// Sign in with Apple without the button: shows the Apple sheet, then signs in to Supabase with
    /// `signInWithIdToken(credentials: .init(provider: .apple, idToken:, nonce:))`.
    public func signInWithApple() async {
        await perform {
            let nonce = AppleNonce.random()
            let idToken = try await self.appleAuthorizer.idToken(nonce: nonce)
            try await self.signInToSupabase(idToken: idToken, nonce: nonce)
        }
    }

    /// Email and password sign-in, for the owner's bootstrap account (until Apple ID is linked to it).
    public func signIn(email: String, password: String) async {
        await perform {
            let session = try await self.client.auth.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            self.user = session.user
            await self.refresh()
        }
    }

    /// Links an Apple ID to the signed-in account (from More), so the next sign-in can use Apple.
    ///
    /// Runs Sign in with Apple natively, then `linkIdentityWithIdToken` with the ID token and nonce.
    /// Needs "Manual linking" enabled in Supabase Auth.
    /// - Throws: `ASAuthorizationError` (`.canceled` when the sheet is dismissed) or a Supabase `AuthError`.
    public func linkApple() async throws {
        let nonce = AppleNonce.random()
        let idToken = try await appleAuthorizer.idToken(nonce: nonce)
        let session = try await client.auth.linkIdentityWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce.raw)
        )
        user = (try? await client.auth.user()) ?? session.user
    }

    /// Signs out of this device only (the owner's other devices stay signed in), clears the snapshot
    /// cache (it holds the car's location), forgets the chosen vehicle and returns to the sign-in step.
    public func signOut() async {
        await endSession()
        resetAfterSignOut()
    }

    // MARK: Tesla

    /// Opens the Tesla sign-in (`POST /auth/start`) in `ASWebAuthenticationSession`; the backend
    /// redirects to `garage://connected`, which re-evaluates onboarding.
    public func connectTesla() async {
        await perform {
            let url = try await self.api.authStart()
            do {
                let callback = try await self.webAuthenticator.authenticate(url: url, callbackURLScheme: "garage")
                await self.handleCallback(callback)
            } catch where WebAuthenticator.isCancellation(error) {
                return
            }
        }
    }

    // MARK: Vehicle

    /// Imports the Tesla account's cars (`POST /api/vehicles/sync`) for the vehicle step. The rows are
    /// for picking only: the store fetches the full row once one is chosen.
    public func loadVehicleChoices() async throws -> VehicleSync {
        try await api.vehicleSync()
    }

    /// Makes `vehicle` the car Garage shows (`UserDefaults` `selectedVehicleID`), restarts the store on
    /// it and moves onboarding on.
    public func choose(_ vehicle: Vehicle) async {
        await perform {
            VehicleSelection.set(vehicle.id, in: self.defaults)
            await self.vehicleStore.start()
            await self.refresh()
        }
    }

    // MARK: Internals

    /// `flow.handle(url:)` evaluates once itself (and keeps a callback `error` on screen), so no second refresh.
    private func handleCallback(_ url: URL) async {
        guard await flow.handle(url: url) else { return }
        startMonitoringIfDone()
    }

    private func startMonitoringIfDone() {
        guard flow.step == .done, !reachabilityRunning else { return }
        reachabilityRunning = true
        commandClient.reachabilityMonitor.start()
    }

    private func signInToSupabase(idToken: String, nonce: AppleNonce) async throws {
        let session = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce.raw)
        )
        user = session.user
        await refresh()
    }

    /// Runs an action with ``isWorking`` set, reporting a failure (other than a cancelled Apple sheet)
    /// on the current step.
    private func perform(_ action: @MainActor () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            if !AppleCredential.isCancellation(error) { flow.report(error) }
        }
    }

    private func observeAuth() {
        guard authTask == nil else { return }
        let changes = client.auth.authStateChanges
        authTask = Task { [weak self] in
            for await (event, session) in changes {
                guard let self else { return }
                switch event {
                case .signedOut:
                    if self.user != nil || self.flow.step != .signIn { self.resetAfterSignOut() }
                default:
                    self.user = session?.user
                }
            }
        }
    }

    /// Drops everything that belongs to the signed-out account. Safe to call more than once.
    private func resetAfterSignOut() {
        vehicleStore.stop()
        commandClient.reachabilityMonitor.stop()
        reachabilityRunning = false
        cache.clear()
        VehicleSelection.set(nil, in: defaults)
        // The override points at this account's bridge; the next account starts on its published URL.
        ProxyOverride.set(nil, in: defaults)
        OnboardingFlow.resetCompletion(in: defaults)
        more = nil
        // Fresh instances: the store's in-memory state and the client's cached Tesla token go too.
        let owner = WeakModel()
        owner.model = self
        vehicleStore = storeFactory()
        commandClient = Self.makeCommandClient(api: api, owner: owner, session: proxySession)
        user = nil
        flow.reset()
    }

    private static func makeStore(environment: SupabaseEnvironment, cache: FileSnapshotCache, defaults: UserDefaults) -> VehicleStore {
        let defaultsBox = UncheckedDefaults(defaults)
        return VehicleStore(
            feed: SupabaseRealtimeFeed(client: environment.client),
            fetcher: SupabaseRowFetcher(client: environment.client) { VehicleSelection.current(in: defaultsBox.defaults) },
            cache: cache
        )
    }

    private static func makeCommandClient(api: GarageAPI, owner: WeakModel, session: URLSession?) -> CommandClient {
        // Read per send and per probe, so a newly published URL or a changed override is picked up.
        let proxyBaseURL: @MainActor () -> URL? = { owner.model?.proxyBaseURL }
        guard let session else { return CommandClient(api: api, proxyBaseURL: proxyBaseURL) }
        return CommandClient(proxyBaseURL: proxyBaseURL, tokens: TokenProvider(api: api), usage: UsageReporter(api: api), session: session)
    }

    private static func checks(owner: WeakModel) -> OnboardingFlow.Checks {
        OnboardingFlow.Checks(
            sessionUserID: {
                guard let model = owner.model else { return nil }
                do {
                    return try await model.client.auth.session.user.id
                } catch AuthError.sessionMissing {
                    return nil
                }
            },
            isTeslaConnected: {
                guard let model = owner.model else { return false }
                return try await model.api.connection().connected
            },
            vehicle: {
                guard let model = owner.model else { return nil }
                let defaultsBox = UncheckedDefaults(model.defaults)
                let fetcher = SupabaseRowFetcher(client: model.client) { VehicleSelection.current(in: defaultsBox.defaults) }
                let found = try await onboardingVehicle(store: model.vehicleStore, proxyState: model.flow.proxyState) {
                    try await fetcher.fetchVehicle()
                }
                if found.refetched { model.refetchedDuringEvaluation = true }
                return found.vehicle
            },
            proxyReachability: {
                guard let model = owner.model else { return .unknown }
                return await model.commandClient.reachabilityMonitor.check()
            }
        )
    }

    /// Onboarding's vehicle check (steps 3 and 4).
    ///
    /// - No car in memory: `fetch` decides (it throws, so a network failure never reads as "no
    ///   vehicle"), and a car found starts `store`.
    /// - A car in memory whose proxy URL is missing, or whose probe has not answered (`proxyState` is
    ///   `.unknown`): the vehicles row is read again (PostgREST, free), since the bridge may have
    ///   published its URL after launch and `vehicles` is not in Realtime. This is what lets the
    ///   Tailscale step's "Check again" advance without a relaunch.
    /// - Otherwise the car in memory, with no read.
    ///
    /// - Returns: The car, and whether the rows were re-read.
    static func onboardingVehicle(
        store: VehicleStore,
        proxyState: ProxyReachability.State,
        fetch: @MainActor () async throws -> Vehicle?
    ) async throws -> (vehicle: Vehicle?, refetched: Bool) {
        if let vehicle = store.vehicle {
            guard vehicle.proxyBaseURL == nil || proxyState == .unknown else { return (vehicle, false) }
            if store.isStarted { await store.refetch() } else { await store.start() }
            return (store.vehicle ?? vehicle, true)
        }
        guard let found = try await fetch() else { return (nil, false) }
        await store.start()
        return (store.vehicle ?? found, false)
    }

    static func hasAppleIdentity(_ user: User?) -> Bool {
        user?.identities?.contains { $0.provider == "apple" } ?? false
    }

    fileprivate static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "AppModel")
}

/// Lets closures made during `init` reach the model without a retain cycle.
@MainActor
private final class WeakModel {
    weak var model: AppModel?
}

/// `UserDefaults` is documented as thread-safe; this carries one into a `@Sendable` closure.
private struct UncheckedDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}
