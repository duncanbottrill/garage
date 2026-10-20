import Foundation
import Network
import Observation
import Synchronization

/// Whether the bridge's command proxy can be reached over the tailnet right now.
///
/// A probe is a bare TLS handshake with the proxy (`NWConnection` with `NWParameters.tls`); it
/// never sends an HTTP request. Anything sent through the proxy is forwarded to Tesla and billed,
/// so a handshake is the only free way to tell that Tailscale is up and the bridge is listening.
@MainActor
@Observable
public final class ProxyReachability {
    public enum State: Sendable, Equatable {
        /// Not probed yet, or no proxy URL is known.
        case unknown
        /// The TLS handshake completed.
        case reachable
        /// The connection was refused, failed, could not route, or did not finish within the timeout.
        case unreachable
    }

    /// The latest result, published on the main actor.
    public private(set) var state: State = .unknown

    /// The handshake timeout.
    public nonisolated let timeout: Duration

    @ObservationIgnored private let target: @MainActor () -> URL?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - target: The proxy base URL to probe (`https://garage-bridge.<tailnet>.ts.net:4443`); read
    ///     on every probe so a newly published or overridden URL is picked up. Port defaults to 443.
    ///   - timeout: How long a handshake may take before it counts as unreachable.
    public init(target: @escaping @MainActor () -> URL?, timeout: Duration = .seconds(3)) {
        self.target = target
        self.timeout = timeout
    }

    /// Probes `target` now and publishes the result. `.unknown` when there is no proxy URL yet.
    @discardableResult
    public func check() async -> State {
        generation += 1
        let mine = generation
        let result: State
        if let url = target(), let host = url.host(), !host.isEmpty {
            result = await probe(host: host, port: UInt16(clamping: url.port ?? 443))
        } else {
            result = .unknown
        }
        // A `stop()` or a newer check while this one was in flight wins.
        if mine == generation { state = result }
        return result
    }

    /// Probes now and then every `interval` until ``stop()``. Calling it again restarts the loop.
    public func start(every interval: Duration = .seconds(20)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Ends the loop started by ``start(every:)``. The last published state is kept.
    public func stop() {
        loop?.cancel()
        loop = nil
        generation += 1
    }

    /// One TLS handshake with `host:port`, cancelled as soon as it settles. Sends no application data.
    public nonisolated func probe(host: String, port: UInt16) async -> State {
        guard let port = NWEndpoint.Port(rawValue: port), port.rawValue != 0 else { return .unreachable }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tls)
        let latch = ProbeLatch(connection: connection)
        let queue = DispatchQueue(label: "com.duncanbottrill.garage.reachability")
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                latch.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: latch.finish(.reachable)
                    // `.waiting` is how a refused or unroutable connection shows up; it would retry forever.
                    case .waiting, .failed, .cancelled: latch.finish(.unreachable)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + seconds) { latch.finish(.unreachable) }
            }
        } onCancel: {
            latch.finish(.unreachable)
        }
    }
}

/// Settles a probe exactly once, whichever of handshake, failure, timeout or cancellation comes first.
private final class ProbeLatch: Sendable {
    private struct Box {
        var continuation: CheckedContinuation<ProxyReachability.State, Never>?
        var result: ProxyReachability.State?
    }

    private let box = Mutex(Box())
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func install(_ continuation: CheckedContinuation<ProxyReachability.State, Never>) {
        let early = box.withLock { box -> ProxyReachability.State? in
            if let result = box.result { return result }
            box.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func finish(_ state: ProxyReachability.State) {
        let (first, continuation) = box.withLock { box -> (Bool, CheckedContinuation<ProxyReachability.State, Never>?) in
            guard box.result == nil else { return (false, nil) }
            box.result = state
            defer { box.continuation = nil }
            return (true, box.continuation)
        }
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: state)
    }
}
