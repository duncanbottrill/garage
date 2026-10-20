import Foundation
import Testing
@testable import GarageKit

/// Cold start: Status renders from the cached snapshot before any network. The 3 s acceptance is
/// checked on device; here the in-process part (read the cache, open the store, build the screen's
/// model) must stay far below it.
@MainActor @Suite struct ColdStartTests {
    @Test func coldStartRendersFromCacheUnder3s() throws {
        let dir = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garage/vehicle_state.json")
        FileSnapshotCache(url: url).save(try Fixture.state("vehicle_state_live"))
        let fetcher = CountingFetcher()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let store = VehicleStore(feed: IdleFeed(), fetcher: fetcher, cache: FileSnapshotCache(url: url))
            let status = StatusModel(state: store.state, vehicle: store.vehicle, now: Date(), reachability: .unknown)
            #expect(status.socText == "34")
            #expect(status.lockState == .locked)
            #expect(status.coordinate != nil)
        }

        #expect(elapsed < .milliseconds(50), "cache load + StatusModel took \(elapsed)")
        #expect(fetcher.calls == 0, "nothing waits on the network")
    }
}

private final class CountingFetcher: VehicleRowFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    func fetchVehicle() async throws -> Vehicle? {
        lock.withLock { _calls += 1 }
        return nil
    }

    func fetchState(vehicleID: UUID) async throws -> VehicleState? {
        lock.withLock { _calls += 1 }
        return nil
    }
}
