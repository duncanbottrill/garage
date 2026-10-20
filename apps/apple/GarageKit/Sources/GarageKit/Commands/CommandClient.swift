import Foundation
import Observation
import Synchronization

/// Sends signed vehicle commands through the bridge's `tesla-http-proxy` over the tailnet.
///
/// The app never talks to Tesla directly: it POSTs to the proxy on the owner's home bridge, which
/// signs the command with the car's virtual key. The proxy needs a Tesla bearer token, which comes
/// from ``TokenProvider`` (the Garage backend), never from Tesla.
///
/// Rules, per command:
/// - One in flight per command ``Command/name``: a second tap while the first is pending is ignored
///   and its `send` returns `false` without throwing (no second request, no second usage report).
/// - The whole exchange (token, request, one retry) is bounded by ``defaultTimeout`` (10 s): `send`
///   throws ``CommandError/timeout`` at the deadline even if the token fetch or the proxy never answers.
/// - A 401 from the proxy forces one token refresh and one retry; a second 401 is ``CommandError/unauthorized``.
/// - Each success is reported to the usage ledger (`commands`, or `wakes` for ``wake(vin:)``) in the
///   background; failures to report are logged by ``UsageReporter``, not surfaced.
/// - Nothing here wakes the car on its own: ``CommandError/asleep`` goes back to the caller, which
///   asks the user before calling ``wake(vin:)``.
/// - A failed token fetch is published as ``tokenFailure`` (More's Connection row turns red) until a
///   send succeeds. It is never a reason to sign out.
/// - The caller cancelling a send gets `CancellationError`; once a send has timed out or been
///   cancelled, nothing more is posted for it, even if its token arrives later.
@MainActor
@Observable
public final class CommandClient {
    /// The command timeout the app uses.
    public static let defaultTimeout: Duration = .seconds(10)

    /// Names of the commands in flight (``Command/name``, or `"wake_up"`), for pending markers in the UI.
    public private(set) var pending: Set<String> = []

    /// The last token failure a send ran into (`/api/token` refused the session, is renewing, or has no
    /// Tesla account), until a send succeeds; nil when the last token fetch worked.
    public private(set) var tokenFailure: CommandError?

    /// The proxy's reachability, as last published by ``reachabilityMonitor``.
    public var reachability: ProxyReachability.State { reachabilityMonitor.state }

    /// Probes the proxy over the tailnet. The app starts its loop (`start(every:)`) while in the foreground.
    @ObservationIgnored public let reachabilityMonitor: ProxyReachability

    @ObservationIgnored private let proxyBaseURL: @MainActor () -> URL?
    @ObservationIgnored private let tokens: TokenProvider
    @ObservationIgnored private let usage: UsageReporter
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let timeout: Duration

    /// - Parameters:
    ///   - proxyBaseURL: The proxy origin (`Vehicle.proxyBaseURL`, or the More override), read per send.
    ///   - tokens: Tesla tokens for the proxy's `Authorization` header.
    ///   - usage: Where successful commands and wakes are counted.
    ///   - session: The session proxy requests go through.
    ///   - timeout: The bound on one whole send, retry included (tests shorten it).
    ///   - reachability: The proxy monitor; by default one probing `proxyBaseURL`.
    public init(
        proxyBaseURL: @escaping @MainActor () -> URL?,
        tokens: TokenProvider,
        usage: UsageReporter,
        session: URLSession = URLSession(configuration: .ephemeral),
        timeout: Duration = CommandClient.defaultTimeout,
        reachability: ProxyReachability? = nil
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.tokens = tokens
        self.usage = usage
        self.session = session
        self.timeout = timeout
        reachabilityMonitor = reachability ?? ProxyReachability(target: proxyBaseURL)
    }

    /// A client wired to the Garage backend: tokens and usage through `api`.
    public convenience init(api: GarageAPI, proxyBaseURL: @escaping @MainActor () -> URL?) {
        self.init(proxyBaseURL: proxyBaseURL, tokens: TokenProvider(api: api), usage: UsageReporter(api: api))
    }

    /// Sends `command` to the car with this VIN and counts it in the usage ledger on success.
    ///
    /// - Returns: `true` when the command was sent and carried out; `false` when it was ignored because
    ///   the same command is already in flight.
    /// - Throws: ``CommandError``, or `CancellationError` when the calling task is cancelled.
    @discardableResult
    public func send(_ command: Command, vin: String) async throws -> Bool {
        try await run(key: command.name, path: "api/1/vehicles/\(vin)/command/\(command.name)", body: command.body, kind: .command)
    }

    /// Wakes the car (`wake_up`) and counts one wake. Call only after the user has confirmed: a wake is
    /// billed at 20× a command, and Garage never wakes the car on its own.
    /// - Returns: `false` when a wake is already in flight (nothing sent), `true` otherwise.
    /// - Throws: ``CommandError``, or `CancellationError` when the calling task is cancelled.
    @discardableResult
    public func wake(vin: String) async throws -> Bool {
        try await run(key: "wake_up", path: "api/1/vehicles/\(vin)/wake_up", body: [:], kind: .wake)
    }

    // MARK: Exchange

    private func run(key: String, path: String, body: [String: AnyCodable], kind: ProxyExchange.Kind) async throws -> Bool {
        guard !pending.contains(key) else { return false }
        pending.insert(key)
        defer { pending.remove(key) }

        guard let base = proxyBaseURL() else { throw CommandError.unreachable }
        let exchange = ProxyExchange(
            url: base.appending(path: path),
            body: try Self.encode(body),
            kind: kind,
            tokens: tokens,
            session: session,
            timeout: timeout
        )
        do {
            try await exchange.run()
        } catch let failure as ProxyExchange.TokenFailure {
            if failure.marksConnection { tokenFailure = failure.error }
            throw failure.error
        } catch let error as CommandError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CommandError.rejected(reason: "Unexpected error: \(error.localizedDescription)")
        }
        tokenFailure = nil
        usage.record(kind == .wake ? .wakes : .commands)
        return true
    }

    private static func encode(_ body: [String: AnyCodable]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(body)
    }
}

/// One proxy request, its single 401 retry and the mapping of the answer to ``CommandError``.
/// Runs off the main actor.
struct ProxyExchange: Sendable {
    enum Kind: Sendable { case command, wake }

    /// A ``CommandError`` that came from fetching the Tesla token, not from the proxy.
    struct TokenFailure: Error {
        let error: CommandError

        /// Whether it says something about the Tesla connection (More's red row). No internet, a spent
        /// budget or a timeout are reported elsewhere.
        var marksConnection: Bool {
            switch error {
            case .unreachable, .budgetBlocked, .timeout: false
            default: true
            }
        }
    }

    static let unexpectedResponse = "Proxy returned an unexpected response"

    let url: URL
    let body: Data
    let kind: Kind
    let tokens: TokenProvider
    let session: URLSession
    let timeout: Duration

    /// Performs the exchange within `timeout`, or throws ``CommandError/timeout`` at the deadline.
    ///
    /// The exchange runs in an unstructured task raced against a timer, and whichever settles first
    /// resumes the caller; the loser is cancelled but not awaited. (A task group would wait for every
    /// child, so a stalled token fetch, which waiters cannot cancel, would hold `send` past the deadline.)
    func run() async throws {
        let race = Race()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                race.install(continuation)
                let work = Task {
                    do {
                        try await exchange()
                        race.finish(.success(()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    race.finish(.failure(CommandError.timeout))
                }
                race.onFinish {
                    work.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the caller exactly once, with whichever of the exchange, the timer or cancellation
    /// settles first, then runs the clean-up (cancelling the other tasks).
    private final class Race: Sendable {
        private struct Box {
            var continuation: CheckedContinuation<Void, any Error>?
            var result: Result<Void, any Error>?
            var cleanup: (@Sendable () -> Void)?
        }

        private let box = Mutex(Box())

        func install(_ continuation: CheckedContinuation<Void, any Error>) {
            let early = box.withLock { box -> Result<Void, any Error>? in
                if let result = box.result { return result }
                box.continuation = continuation
                return nil
            }
            if let early { continuation.resume(with: early) }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let settled = box.withLock { box -> Bool in
                if box.result != nil { return true }
                box.cleanup = cleanup
                return false
            }
            if settled { cleanup() }
        }

        func finish(_ result: Result<Void, any Error>) {
            let (continuation, cleanup) = box.withLock { box -> (CheckedContinuation<Void, any Error>?, (@Sendable () -> Void)?) in
                guard box.result == nil else { return (nil, nil) }
                box.result = result
                defer {
                    box.continuation = nil
                    box.cleanup = nil
                }
                return (box.continuation, box.cleanup)
            }
            cleanup?()
            continuation?.resume(with: result)
        }
    }

    private func exchange() async throws {
        var (status, data) = try await post(token: try await token(forceRefresh: false))
        if status == 401 {
            (status, data) = try await post(token: try await token(forceRefresh: true))
            if status == 401 { throw CommandError.unauthorized }
        }
        try Self.interpret(status: status, data: data, kind: kind)
    }

    /// The token, or a ``TokenFailure``. Checks for cancellation after the fetch: a token that arrives
    /// after the send timed out (the fetch is shared and cannot be cancelled) must not be used.
    private func token(forceRefresh: Bool) async throws -> String {
        let token: String
        do {
            token = try await fetchToken(forceRefresh: forceRefresh)
        } catch let error as CommandError {
            throw TokenFailure(error: error)
        }
        try Task.checkCancellation()
        return token
    }

    private func fetchToken(forceRefresh: Bool) async throws -> String {
        do {
            return try await tokens.current(forceRefresh: forceRefresh)
        } catch let error as APIError {
            switch error {
            case .budgetMinimal: throw CommandError.budgetBlocked
            // The backend refused the Supabase session itself: signing in again fixes it, Tesla is fine.
            case .unauthorized: throw CommandError.sessionExpired
            // No Tesla account linked: the user has to reconnect Tesla.
            case .notConnected: throw CommandError.unauthorized
            // Rotation is failing or in progress; it recovers on its own. Never a sign-out.
            case let .tokenUnavailable(retryAt): throw CommandError.tokenUnavailable(retryAt: retryAt)
            case .rateLimited: throw CommandError.rejected(reason: "too many requests in a short time")
            case .asleep, .server: throw CommandError.rejected(reason: "the Garage server couldn't provide a Tesla token")
            }
        } catch is URLError {
            throw CommandError.unreachable
        }
    }

    private func post(token: String) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CommandError.timeout
            default: throw CommandError.unreachable
            }
        }
    }

    /// Maps the proxy's answer. Success is `{"response":{"result":true}}` for a command and any
    /// `{"response":{…}}` object for `wake_up`.
    static func interpret(status: Int, data: Data, kind: Kind) throws {
        switch status {
        case 408: throw CommandError.asleep // Tesla's "vehicle unavailable"
        case 401: throw CommandError.unauthorized
        case 402: throw CommandError.budgetBlocked // Tesla billing limit reached
        default: break
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // An empty or HTML gateway error means nothing is answering behind the tailnet forward.
            if [502, 503, 504].contains(status) { throw CommandError.unreachable }
            throw CommandError.rejected(reason: unexpectedResponse)
        }
        let response = json["response"] as? [String: Any]
        let message = [json["error"], json["error_description"], response?["reason"]]
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
        if (200..<300).contains(status) {
            // A 2xx that carries an error envelope instead of a response is still a failure.
            if response == nil, json["error"] is String, !message.isEmpty { throw classify(reason: message) }
            switch kind {
            case .wake:
                guard response != nil else { throw CommandError.rejected(reason: unexpectedResponse) }
                return
            case .command:
                guard let result = response?["result"] as? Bool else { throw CommandError.rejected(reason: unexpectedResponse) }
                if result { return }
                throw classify(reason: response?["reason"] as? String ?? "")
            }
        }
        if status == 429 {
            throw CommandError.rejected(reason: "Tesla is limiting requests right now")
        }
        throw classify(reason: message.isEmpty ? unexpectedResponse : message)
    }

    /// Reads a Tesla or proxy reason: unavailable means asleep/offline, anything about a key means the
    /// virtual key is not paired, and the rest is passed on as the rejection reason.
    static func classify(reason: String) -> CommandError {
        let lowered = reason.lowercased()
        if lowered.contains("vehicle unavailable") || lowered.contains("offline or asleep") { return .asleep }
        if lowered.contains("key") { return .keyMissing }
        return .rejected(reason: reason.isEmpty ? "no reason given" : reason)
    }
}
