import Foundation
import Observation

/// Sends signed vehicle commands through the bridge's `tesla-http-proxy` over the tailnet.
///
/// The app never talks to Tesla directly: it POSTs to the proxy on the owner's home bridge, which
/// signs the command with the car's virtual key. The proxy needs a Tesla bearer token, which comes
/// from ``TokenProvider`` (the Garage backend), never from Tesla.
///
/// Rules, per command:
/// - One in flight per command ``Command/name``: a second tap while the first is pending is ignored
///   and its `send` returns without throwing (no second request, no second usage report).
/// - The whole exchange (token, request, one retry) is bounded by ``defaultTimeout`` (10 s).
/// - A 401 from the proxy forces one token refresh and one retry; a second 401 is ``CommandError/unauthorized``.
/// - Each success is reported to the usage ledger (`commands`, or `wakes` for ``wake(vin:)``) in the
///   background; failures to report are logged by ``UsageReporter``, not surfaced.
/// - Nothing here wakes the car on its own: ``CommandError/asleep`` goes back to the caller, which
///   asks the user before calling ``wake(vin:)``.
@MainActor
@Observable
public final class CommandClient {
    /// The command timeout the app uses.
    public static let defaultTimeout: Duration = .seconds(10)

    /// Names of the commands in flight (``Command/name``, or `"wake_up"`), for pending markers in the UI.
    public private(set) var pending: Set<String> = []

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
    /// Returns without doing anything while the same command is already in flight.
    /// - Throws: ``CommandError``.
    public func send(_ command: Command, vin: String) async throws {
        try await run(key: command.name, path: "api/1/vehicles/\(vin)/command/\(command.name)", body: command.body, kind: .command)
    }

    /// Wakes the car (`wake_up`) and counts one wake. Call only after the user has confirmed: a wake is
    /// billed at 20× a command, and Garage never wakes the car on its own.
    /// - Throws: ``CommandError``.
    public func wake(vin: String) async throws {
        try await run(key: "wake_up", path: "api/1/vehicles/\(vin)/wake_up", body: [:], kind: .wake)
    }

    // MARK: Exchange

    private func run(key: String, path: String, body: [String: AnyCodable], kind: ProxyExchange.Kind) async throws {
        guard !pending.contains(key) else { return }
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
        try await exchange.run()
        usage.record(kind == .wake ? .wakes : .commands)
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

    static let unexpectedResponse = "Proxy returned an unexpected response"

    let url: URL
    let body: Data
    let kind: Kind
    let tokens: TokenProvider
    let session: URLSession
    let timeout: Duration

    /// Performs the exchange within `timeout`, or throws ``CommandError/timeout``.
    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await exchange() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
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

    private func token(forceRefresh: Bool) async throws -> String {
        do {
            return try await tokens.current(forceRefresh: forceRefresh)
        } catch let error as APIError {
            switch error {
            case .budgetMinimal: throw CommandError.budgetBlocked
            case .unauthorized, .notConnected, .tokenUnavailable: throw CommandError.unauthorized
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
        if (200..<300).contains(status) {
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
        let message = [json["error"], json["error_description"], response?["reason"]]
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
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
