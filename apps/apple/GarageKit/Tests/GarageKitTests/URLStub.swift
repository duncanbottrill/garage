import Foundation
import Network
import Synchronization

/// What a stubbed endpoint does with a request.
enum StubReply: Sendable {
    /// Answer with this status and body.
    case respond(status: Int, body: Data)
    /// Never answer, like a proxy that accepted the connection and went quiet.
    case hang

    static func json(_ status: Int, _ text: String) -> StubReply {
        .respond(status: status, body: Data(text.utf8))
    }
}

/// One request the stub saw, with its body read out of the upload stream.
struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data

    var path: String { url.path() }
    var bearer: String? { headers["Authorization"] }

    /// The body as a JSON object, for comparisons that do not depend on key order.
    var jsonBody: NSDictionary? {
        (try? JSONSerialization.jsonObject(with: body)) as? NSDictionary
    }
}

/// An in-process HTTP server for one test: a `URLSession` whose requests never leave the process.
///
/// Each stub routes by a unique host name, so tests running in parallel do not see each other's
/// requests. Handlers are matched on `"<METHOD> <path>"`; unmatched requests get a 599 and are recorded.
final class URLStub: Sendable {
    typealias Handler = @Sendable (RecordedRequest) async -> StubReply

    let host: String
    let session: URLSession
    private let handlers = Mutex<[String: Handler]>([:])
    private let recorded = Mutex<[RecordedRequest]>([])

    init() {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubRegistry.shared.withLock { $0[host] = self }
    }

    deinit {
        let host = host
        StubRegistry.shared.withLock { _ = $0.removeValue(forKey: host) }
    }

    /// `https://<unique host>` (with `port` when given).
    func baseURL(port: Int? = nil) -> URL {
        URL(string: "https://\(host)\(port.map { ":\($0)" } ?? "")")!
    }

    func on(_ method: String, _ path: String, _ handler: @escaping Handler) {
        handlers.withLock { $0["\(method) \(path)"] = handler }
    }

    /// Replies from `replies` in order, repeating the last one.
    func on(_ method: String, _ path: String, sequence replies: [StubReply]) {
        let index = Mutex(0)
        on(method, path) { _ in
            index.withLock { i in
                defer { i += 1 }
                return replies[min(i, replies.count - 1)]
            }
        }
    }

    var requests: [RecordedRequest] { recorded.withLock { $0 } }

    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    fileprivate func reply(to request: RecordedRequest) async -> StubReply {
        recorded.withLock { $0.append(request) }
        let handler = handlers.withLock { $0["\(request.method) \(request.path)"] }
        return await handler?(request) ?? .json(599, #"{"error":"no stub"}"#)
    }
}

private enum StubRegistry {
    static let shared = Mutex<[String: URLStub]>([:])
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private let work = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let url = request.url, let host = url.host(),
              let stub = StubRegistry.shared.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream)
        )
        let loader = Loader(protocol: self)
        let task = Task {
            switch await stub.reply(to: recorded) {
            case .hang:
                return
            case let .respond(status, body):
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                loader.deliver(response, body)
            }
        }
        work.withLock { $0 = task }
    }

    /// Carries the protocol instance into the reply task; URLProtocol's client is safe to call from any thread.
    private struct Loader: @unchecked Sendable {
        let `protocol`: StubURLProtocol

        func deliver(_ response: HTTPURLResponse, _ body: Data) {
            let client = `protocol`.client
            client?.urlProtocol(`protocol`, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(`protocol`, didLoad: body)
            client?.urlProtocolDidFinishLoading(`protocol`)
        }
    }

    override func stopLoading() {
        work.withLock { $0?.cancel() }
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A TCP listener on 127.0.0.1 that accepts connections and never sends a byte, so a TLS client
/// handshake against it can only end by timing out.
final class SilentListener: Sendable {
    private let listener: NWListener
    private final class Bag: Sendable {
        let connections = Mutex<[NWConnection]>([])
    }

    private let accepted = Bag()
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "SilentListener")
        let accepted = accepted
        listener.newConnectionHandler = { connection in
            accepted.connections.withLock { $0.append(connection) }
            connection.start(queue: queue)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func cancel() {
        listener.cancel()
        accepted.connections.withLock { connections in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
