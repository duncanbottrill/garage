import Foundation
import Synchronization
import Testing
@testable import GarageKit

/// A backend and a proxy, both stubbed, wired into a `CommandClient` the way the app wires them.
@MainActor
private struct Rig {
    let backend = URLStub()
    let proxy = URLStub()
    let usage: UsageReporter
    let client: CommandClient

    nonisolated static let vin = "VIN"
    nonisolated static let ok = StubReply.json(200, #"{"response":{"result":true,"reason":""}}"#)

    init(timeout: Duration = .seconds(10), usageAttempts: Int = 3) {
        let api = GarageAPI(baseURL: backend.baseURL(), session: backend.session, supabaseToken: { "sb-jwt" })
        let issued = Mutex(0)
        backend.on("GET", "/api/token") { _ in
            let n = issued.withLock { n in n += 1; return n }
            return .json(200, #"{"access_token":"tesla-\#(n)","expires_at":"2099-01-01T00:00:00Z"}"#)
        }
        backend.on("POST", "/api/usage") { _ in .json(200, #"{"ok":true}"#) }
        usage = UsageReporter(attempts: usageAttempts, retryDelay: .milliseconds(10)) { category, count in
            try await api.reportUsage(category, count: count)
        }
        let proxyURL = proxy.baseURL(port: 4443)
        client = CommandClient(
            proxyBaseURL: { proxyURL },
            tokens: TokenProvider(api: api),
            usage: usage,
            session: proxy.session,
            timeout: timeout
        )
    }

    func commandPath(_ name: String) -> String { "/api/1/vehicles/\(Self.vin)/command/\(name)" }

    func onCommand(_ name: String, _ replies: StubReply...) {
        proxy.on("POST", commandPath(name), sequence: replies)
    }

    func usageBodies() async -> [NSDictionary] {
        await usage.drain()
        return backend.requests("POST", "/api/usage").compactMap(\.jsonBody)
    }
}

@MainActor
@Suite struct CommandClientTests {
    @Test func sendsCommandWithBearerAndBody() async throws {
        let rig = Rig()
        rig.onCommand("set_charge_limit", Rig.ok)

        try await rig.client.send(.setChargeLimit(percent: 80), vin: Rig.vin)

        let request = try #require(rig.proxy.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "\(rig.proxy.baseURL(port: 4443).absoluteString)/api/1/vehicles/VIN/command/set_charge_limit")
        #expect(request.bearer == "Bearer tesla-1")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(String(decoding: request.body, as: UTF8.self) == #"{"percent":80}"#)
        // The backend saw the Supabase session token, never the Tesla one.
        #expect(rig.backend.requests("GET", "/api/token").first?.bearer == "Bearer sb-jwt")
        #expect(rig.client.pending.isEmpty)
    }

    @Test func refreshesTokenOnceOn401() async throws {
        let rig = Rig()
        let unauthorized = StubReply.json(401, #"{"response":null,"error":"invalid bearer token","error_description":""}"#)

        // 401, then a forced refresh, then the retry succeeds with the new token.
        rig.onCommand("door_lock", unauthorized, Rig.ok)
        try await rig.client.send(.doorLock, vin: Rig.vin)
        #expect(rig.proxy.requests("POST", rig.commandPath("door_lock")).map(\.bearer) == ["Bearer tesla-1", "Bearer tesla-2"])

        // A second 401 after the refresh surfaces .unauthorized; exactly two command requests, no loop.
        rig.onCommand("door_unlock", unauthorized)
        await #expect(throws: CommandError.unauthorized) { try await rig.client.send(.doorUnlock, vin: Rig.vin) }
        #expect(rig.proxy.requests("POST", rig.commandPath("door_unlock")).count == 2)
        #expect(rig.backend.requests("GET", "/api/token").count == 3)
        // Only the successful command was counted.
        #expect(await rig.usageBodies() == [["category": "commands", "count": 1]])
    }

    @Test func ignoresDuplicateTapWhileInFlight() async throws {
        let rig = Rig()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        rig.proxy.on("POST", rig.commandPath("door_lock")) { _ in
            for await _ in gate { break }
            return Rig.ok
        }

        let first = Task { try await rig.client.send(.doorLock, vin: Rig.vin) }
        while !rig.client.pending.contains("door_lock") { await Task.yield() }
        // The second tap returns at once, without throwing, while the first is in flight.
        #expect(try await rig.client.send(.doorLock, vin: Rig.vin) == false)
        #expect(rig.client.pending == ["door_lock"])
        open.yield()
        #expect(try await first.value == true)

        #expect(rig.proxy.requests("POST", rig.commandPath("door_lock")).count == 1)
        #expect(rig.client.pending.isEmpty)
        #expect(await rig.usageBodies().count == 1)
    }

    @Test func mapsResultFalseToRejected() async {
        let rig = Rig()
        rig.onCommand("charge_start", .json(200, #"{"response":{"result":false,"reason":"is_charging"}}"#))

        await #expect(throws: CommandError.rejected(reason: "is_charging")) {
            try await rig.client.send(.chargeStart, vin: Rig.vin)
        }
        #expect(await rig.usageBodies().isEmpty)
    }

    @Test func mapsKeyMissingAndVehicleUnavailable() async {
        let rig = Rig()
        rig.onCommand("door_lock", .json(200, #"{"response":{"result":false,"reason":"vehicle rejected request: your public key has not been paired with the vehicle"}}"#))
        rig.onCommand("door_unlock", .json(500, #"{"response":null,"error":"vehicle rejected request: your public key has not been paired with the vehicle","error_description":""}"#))
        rig.onCommand("flash_lights", .json(408, #"{"response":null,"error":"vehicle unavailable: vehicle is offline or asleep","error_description":""}"#))
        rig.onCommand("honk_horn", .json(200, #"{"response":{"result":false,"reason":"vehicle unavailable"}}"#))

        await #expect(throws: CommandError.keyMissing) { try await rig.client.send(.doorLock, vin: Rig.vin) }
        await #expect(throws: CommandError.keyMissing) { try await rig.client.send(.doorUnlock, vin: Rig.vin) }
        await #expect(throws: CommandError.asleep) { try await rig.client.send(.flashLights, vin: Rig.vin) }
        await #expect(throws: CommandError.asleep) { try await rig.client.send(.honkHorn, vin: Rig.vin) }
    }

    @Test func mapsNonJSONBodyToRejected() async {
        let rig = Rig()
        rig.onCommand("door_lock", .respond(status: 200, body: Data("<html><body>Bad Gateway</body></html>".utf8)))
        rig.onCommand("door_unlock", .respond(status: 500, body: Data("<html>oops</html>".utf8)))
        rig.onCommand("flash_lights", .respond(status: 502, body: Data()))

        let unexpected = CommandError.rejected(reason: "Proxy returned an unexpected response")
        await #expect(throws: unexpected) { try await rig.client.send(.doorLock, vin: Rig.vin) }
        await #expect(throws: unexpected) { try await rig.client.send(.doorUnlock, vin: Rig.vin) }
        // An empty gateway error means nothing is listening behind the tailnet forward.
        await #expect(throws: CommandError.unreachable) { try await rig.client.send(.flashLights, vin: Rig.vin) }
    }

    @Test func mapsTimeoutAfter10s() async {
        let rig = Rig(timeout: .milliseconds(200))
        rig.proxy.on("POST", rig.commandPath("honk_horn")) { _ in .hang }

        let started = ContinuousClock.now
        await #expect(throws: CommandError.timeout) { try await rig.client.send(.honkHorn, vin: Rig.vin) }

        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(rig.client.pending.isEmpty)
        #expect(await rig.usageBodies().isEmpty)
    }

    @Test func timesOutWhenTokenFetchHangs() async {
        let rig = Rig(timeout: .milliseconds(200))
        rig.backend.on("GET", "/api/token") { _ in .hang }
        rig.onCommand("door_lock", Rig.ok)

        let started = ContinuousClock.now
        await #expect(throws: CommandError.timeout) { try await rig.client.send(.doorLock, vin: Rig.vin) }

        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(rig.client.pending.isEmpty)
        #expect(rig.proxy.requests.isEmpty)
    }

    @Test func tokenUnavailableIsNotASignOut() async {
        let rig = Rig()
        rig.backend.on("GET", "/api/token") { _ in
            .json(503, #"{"error":"token_unavailable","retry_at":"2026-10-20T08:15:00Z"}"#)
        }

        let retryAt = Date(timeIntervalSince1970: 1_792_484_100)
        await #expect(throws: CommandError.tokenUnavailable(retryAt: retryAt)) {
            try await rig.client.send(.doorLock, vin: Rig.vin)
        }
        #expect(rig.proxy.requests.isEmpty)
        #expect(CommandError.tokenUnavailable(retryAt: nil).errorDescription == "Garage is renewing its Tesla access. Try again in a few minutes.")
        #expect(CommandError.clockTime(retryAt, timeZone: TimeZone(identifier: "Europe/London")!) == "09:15")
        let copy = CommandError.tokenUnavailable(retryAt: retryAt).errorDescription ?? ""
        #expect(copy.hasPrefix("Garage is renewing its Tesla access. Try again in a few minutes, after "))
        #expect(copy.hasSuffix("\(CommandError.clockTime(retryAt))."))
    }

    @Test func backendSessionRefusedIsSessionExpired() async {
        let rig = Rig()
        rig.backend.on("GET", "/api/token") { _ in .json(401, #"{"error":"unauthorized"}"#) }

        await #expect(throws: CommandError.sessionExpired) { try await rig.client.send(.doorLock, vin: Rig.vin) }
        #expect(CommandError.sessionExpired.errorDescription == "Your Garage sign-in has expired. Sign in again in More.")

        // No Tesla account is a Tesla problem, not a session one.
        rig.backend.on("GET", "/api/token") { _ in .json(404, #"{"error":"not_connected"}"#) }
        await #expect(throws: CommandError.unauthorized) { try await rig.client.send(.doorLock, vin: Rig.vin) }
        #expect(rig.proxy.requests.isEmpty)
    }

    @Test func mapsErrorEnvelopeOn2xx() async {
        let rig = Rig()
        rig.onCommand("door_lock", .json(200, #"{"response":null,"error":"vehicle rejected request: your public key has not been paired with the vehicle"}"#))
        rig.onCommand("door_unlock", .json(200, #"{"error":"vehicle unavailable: vehicle is offline or asleep"}"#))

        await #expect(throws: CommandError.keyMissing) { try await rig.client.send(.doorLock, vin: Rig.vin) }
        await #expect(throws: CommandError.asleep) { try await rig.client.send(.doorUnlock, vin: Rig.vin) }
    }

    @Test func usageDoesNotRetryClientErrors() async throws {
        let rig = Rig(usageAttempts: 3)
        rig.backend.on("POST", "/api/usage") { _ in .json(400, #"{"error":"bad_count"}"#) }
        rig.onCommand("door_lock", Rig.ok)

        try await rig.client.send(.doorLock, vin: Rig.vin)

        await rig.usage.drain()
        #expect(rig.backend.requests("POST", "/api/usage").count == 1)
        #expect(UsageReporter.isRetryable(APIError.rateLimited))
        #expect(UsageReporter.isRetryable(APIError.server(status: 503)))
        #expect(UsageReporter.isRetryable(URLError(.networkConnectionLost)))
        #expect(!UsageReporter.isRetryable(APIError.server(status: 404)))
    }

    @Test func defaultTimeoutIsTenSeconds() {
        #expect(CommandClient.defaultTimeout == .seconds(10))
    }

    @Test func noProxyURLIsUnreachable() async {
        let api = GarageAPI(baseURL: URL(string: "https://unused.test")!, session: URLStub().session, supabaseToken: { "sb-jwt" })
        let client = CommandClient(proxyBaseURL: { nil }, tokens: TokenProvider(api: api), usage: UsageReporter(api: api))

        await #expect(throws: CommandError.unreachable) { try await client.send(.doorLock, vin: Rig.vin) }
    }

    @Test func reportsUsageAfterSuccess() async throws {
        let rig = Rig()
        rig.onCommand("auto_conditioning_start", Rig.ok)

        try await rig.client.send(.autoConditioningStart, vin: Rig.vin)

        #expect(await rig.usageBodies() == [["category": "commands", "count": 1]])
        let usage = try #require(rig.backend.requests("POST", "/api/usage").first)
        #expect(String(decoding: usage.body, as: UTF8.self) == #"{"category":"commands","count":1}"#)
        #expect(usage.bearer == "Bearer sb-jwt")
    }

    @Test func usageFailureIsNotSurfaced() async throws {
        let rig = Rig(usageAttempts: 2)
        rig.backend.on("POST", "/api/usage") { _ in .json(500, #"{"error":"db down"}"#) }
        rig.onCommand("door_lock", Rig.ok)

        try await rig.client.send(.doorLock, vin: Rig.vin)

        await rig.usage.drain()
        #expect(rig.backend.requests("POST", "/api/usage").count == 2)
    }

    @Test func wakeReportsWakesCategory() async throws {
        let rig = Rig()
        rig.proxy.on("POST", "/api/1/vehicles/VIN/wake_up") { _ in
            .json(200, #"{"response":{"id":1,"vin":"VIN","state":"online"}}"#)
        }

        try await rig.client.wake(vin: Rig.vin)

        let wake = try #require(rig.proxy.requests("POST", "/api/1/vehicles/VIN/wake_up").first)
        #expect(wake.bearer == "Bearer tesla-1")
        #expect(await rig.usageBodies() == [["category": "wakes", "count": 1]])
    }

    @Test func commandNamesAndBodiesAreVerbatim() throws {
        func body(_ command: Command) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return String(decoding: try encoder.encode(command.body), as: UTF8.self)
        }
        let expected: [(Command, String, String)] = [
            (.doorLock, "door_lock", "{}"),
            (.doorUnlock, "door_unlock", "{}"),
            (.autoConditioningStart, "auto_conditioning_start", "{}"),
            (.autoConditioningStop, "auto_conditioning_stop", "{}"),
            (.setTemps(driver: 21.5, passenger: 21.5), "set_temps", #"{"driver_temp":21.5,"passenger_temp":21.5}"#),
            (.remoteSeatHeater(.passenger, level: 3), "remote_seat_heater_request", #"{"heater":1,"level":3}"#),
            (.setPreconditioningMax(on: true, manualOverride: true), "set_preconditioning_max", #"{"manual_override":true,"on":true}"#),
            (.chargePortDoorOpen, "charge_port_door_open", "{}"),
            (.chargePortDoorClose, "charge_port_door_close", "{}"),
            (.chargeStart, "charge_start", "{}"),
            (.chargeStop, "charge_stop", "{}"),
            (.setChargeLimit(percent: 80), "set_charge_limit", #"{"percent":80}"#),
            (.setScheduledCharging(enable: true, time: 1410), "set_scheduled_charging", #"{"enable":true,"time":1410}"#),
            (.actuateFrunk, "actuate_trunk", #"{"which_trunk":"front"}"#),
            (.flashLights, "flash_lights", "{}"),
            (.honkHorn, "honk_horn", "{}"),
        ]
        for (command, name, json) in expected {
            #expect(command.name == name)
            #expect(try body(command) == json, "\(name)")
        }
    }

    @Test func errorsHavePlainCopy() {
        let all: [CommandError] = [
            .unreachable, .unauthorized, .asleep, .keyMissing, .rejected(reason: "is_charging"), .timeout, .budgetBlocked,
            .tokenUnavailable(retryAt: nil), .tokenUnavailable(retryAt: Date()), .sessionExpired,
        ]
        for error in all {
            let copy = error.errorDescription ?? ""
            #expect(!copy.isEmpty)
            #expect(!copy.contains("!"))
        }
    }

    @Test func reachabilityUnreachableWhenHostRefuses() async {
        // A refusal settles the probe straight away, well before the (shortened) timeout.
        let reachability = ProxyReachability(target: { nil }, timeout: .milliseconds(500))

        let started = ContinuousClock.now
        let state = await reachability.probe(host: "127.0.0.1", port: 1)

        #expect(state == .unreachable)
        #expect(ContinuousClock.now - started < .milliseconds(250))
    }

    @Test func reachabilityTimesOut() async throws {
        // A listener that accepts TCP but never speaks TLS: the handshake can only end by the timeout.
        let listener = try SilentListener()
        let reachability = ProxyReachability(target: { nil }, timeout: .milliseconds(200))

        let started = ContinuousClock.now
        let state = await reachability.probe(host: "127.0.0.1", port: listener.port)

        #expect(state == .unreachable)
        #expect(ContinuousClock.now - started < .seconds(2))
        listener.cancel()
    }

    @Test func reachabilityPublishesUnknownWithoutProxyURL() async {
        let reachability = ProxyReachability(target: { nil })

        #expect(await reachability.check() == .unknown)
        #expect(reachability.state == .unknown)
    }
}

extension CommandClientTests {
    /// The caller giving up is a cancellation, not a rejected command.
    @Test func callerCancellationRethrowsCancellationError() async {
        let rig = Rig()
        rig.proxy.on("POST", rig.commandPath("honk_horn")) { _ in .hang }

        let send = Task { try await rig.client.send(.honkHorn, vin: Rig.vin) }
        #expect(await eventually { rig.proxy.requests.count == 1 })
        send.cancel()

        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(rig.client.pending.isEmpty)
        #expect(await rig.usageBodies().isEmpty)
    }

    /// A token that arrives after the send timed out must not send the command: the user was told it
    /// did not go through.
    @Test func lateTokenAfterTimeoutNeverPosts() async throws {
        let rig = Rig(timeout: .milliseconds(150))
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        rig.backend.on("GET", "/api/token") { _ in
            for await _ in gate { break }
            return .json(200, #"{"access_token":"late","expires_at":"2099-01-01T00:00:00Z"}"#)
        }
        rig.onCommand("door_unlock", Rig.ok)

        await #expect(throws: CommandError.timeout) { try await rig.client.send(.doorUnlock, vin: Rig.vin) }
        open.yield()
        open.finish()
        try await Task.sleep(for: .milliseconds(400))

        #expect(rig.proxy.requests.isEmpty, "the timed-out exchange posted after all")
        #expect(await rig.usageBodies().isEmpty)
    }
}
