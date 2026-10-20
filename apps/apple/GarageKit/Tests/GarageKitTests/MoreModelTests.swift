import Foundation
import Testing
@testable import GarageKit

/// Records what the More model asked the backend and the proxy probe.
@MainActor
private final class FakeBackend {
    var health = ConnectionHealth(connected: true)
    var connectionError: (any Error)?
    var refreshError: (any Error)?
    var refreshed: [UUID] = []
    var probed: [URL] = []
    var probeResult: ProxyReachability.State = .reachable

    var api: MoreModel.API {
        MoreModel.API(
            connection: { [unowned self] in
                if let connectionError { throw connectionError }
                return health
            },
            refreshVehicleData: { [unowned self] id in
                refreshed.append(id)
                if let refreshError { throw refreshError }
                return VehicleState()
            }
        )
    }
}

@MainActor @Suite struct MoreModelTests {
    /// 2026-10-20 14:30:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_792_506_600)
    private let published = URL(string: "https://garage-bridge.tail068c8f.ts.net:4443")!
    private let vehicle: Vehicle

    init() {
        vehicle = Vehicle(
            id: UUID(uuidString: "7C1F0A0E-8A43-4D43-9A39-2F1B6F5D1E11")!,
            vin: "LRWYGCEK0PC123456",
            displayName: "Model Y",
            proxyBaseURL: URL(string: "https://garage-bridge.tail068c8f.ts.net:4443")!
        )
    }

    private func makeModel(_ backend: FakeBackend, defaults: UserDefaults = freshDefaults()) -> MoreModel {
        let model = MoreModel(
            api: backend.api,
            probe: { [unowned backend] url in
                backend.probed.append(url)
                return backend.probeResult
            },
            defaults: defaults,
            now: { Self.now }
        )
        model.vehicle = vehicle
        return model
    }

    /// A row whose telemetry is `age` seconds old, for an awake car whose bridge checked in just now.
    private func state(age: TimeInterval) -> VehicleState {
        var state = VehicleState.awake()
        let stamp = Self.now.addingTimeInterval(-age)
        state.chargeAt = stamp
        state.climateAt = stamp
        state.locationAt = stamp
        state.bodyAt = stamp
        state.bridgeSeenAt = Self.now.addingTimeInterval(-10)
        return state
    }

    @Test func connectionRowRedWhenLastError() async throws {
        let backend = FakeBackend()
        backend.health = ConnectionHealth(connected: true, rotatedAt: Self.now.addingTimeInterval(-2 * 3600))
        let model = makeModel(backend)

        await model.loadConnection()
        let healthy = try #require(model.row(.connection))
        #expect(healthy.tone == .healthy)
        #expect(healthy.detail == "Connected · token rotated 2 h ago")
        #expect(!model.showsReconnect)

        backend.health = ConnectionHealth(
            connected: true,
            rotatedAt: Self.now.addingTimeInterval(-26 * 3600),
            lastError: "Tesla refused the refresh token (invalid_grant)",
            refreshFailures: 3
        )
        await model.loadConnection()
        let failed = try #require(model.row(.connection))
        #expect(failed.tone == .failed)
        #expect(failed.detail == "Tesla refused the refresh token (invalid_grant)")
        #expect(model.showsReconnect)
    }

    @Test func refreshRowHiddenWhenFresh() async throws {
        let backend = FakeBackend()
        let model = makeModel(backend)

        model.state = state(age: 20)
        #expect(!model.showsRefreshNow)
        #expect(model.row(.refresh) == nil)

        model.state = state(age: 2 * 3600)
        #expect(model.showsRefreshNow)
        #expect(model.row(.refresh) != nil)

        // An asleep car is never offered a refresh: the read would only bounce off it.
        var asleep = state(age: 2 * 3600)
        asleep.sleepState = "asleep"
        model.state = asleep
        #expect(model.row(.refresh) == nil)

        model.state = state(age: 2 * 3600)
        backend.refreshError = APIError.asleep
        await model.refreshNow()
        #expect(backend.refreshed == [vehicle.id])
        #expect(model.row(.refresh)?.detail == "The car is asleep")
        #expect(model.row(.refresh)?.tone == .failed)

        backend.refreshError = APIError.budgetMinimal
        await model.refreshNow()
        #expect(model.row(.refresh)?.detail == "Manual refresh is paused to stay in budget")
    }

    @Test func proxyOverrideWinsOverPublished() async throws {
        let backend = FakeBackend()
        let defaults = freshDefaults()
        var changes = 0
        let model = makeModel(backend, defaults: defaults)
        model.onProxyOverrideChange = { changes += 1 }

        #expect(model.effectiveProxyURL == published)
        #expect(model.row(.proxy)?.detail == published.absoluteString)

        let override = "https://garage-bridge.other.ts.net:4443"
        #expect(model.saveProxyOverride(" \(override) "))
        #expect(defaults.string(forKey: ProxyOverride.key) == override)
        #expect(model.effectiveProxyURL == URL(string: override))
        #expect(model.isUsingOverride)
        #expect(model.row(.proxy)?.detail == override)
        #expect(changes == 1)

        // Not https, or no host: refused, and the saved override stays.
        #expect(!model.saveProxyOverride("http://garage-bridge.other.ts.net"))
        #expect(!model.saveProxyOverride("https://"))
        #expect(model.effectiveProxyURL == URL(string: override))
        #expect(changes == 1)

        await model.testProxy()
        #expect(backend.probed == [URL(string: override)!])
        #expect(model.proxyTest == .finished(.reachable))

        model.clearProxyOverride()
        #expect(defaults.string(forKey: ProxyOverride.key) == nil)
        #expect(model.effectiveProxyURL == published)
        #expect(!model.isUsingOverride)
        #expect(changes == 2)
    }
}

/// A private, empty defaults domain per test.
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "MoreModelTests-\(UUID().uuidString)")!
}
