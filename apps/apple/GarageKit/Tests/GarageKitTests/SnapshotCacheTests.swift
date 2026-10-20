import Foundation
import Testing
@testable import GarageKit

@Suite struct SnapshotCacheTests {
    /// What is saved loads back equal, the write leaves no temporary file beside it, and the default
    /// location is `Application Support/garage/vehicle_state.json`.
    @Test func snapshotCacheRoundTrips() throws {
        let dir = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garage/vehicle_state.json")
        let cache = FileSnapshotCache(url: url)
        #expect(cache.load() == nil)

        let state = try Fixture.state("vehicle_state_live")
        cache.save(state)
        #expect(cache.load() == state)

        var newer = state
        newer.soc = 34
        cache.save(newer)
        #expect(FileSnapshotCache(url: url).load() == newer)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["vehicle_state.json"])

        let standard = FileSnapshotCache.defaultURL
        #expect(standard.lastPathComponent == "vehicle_state.json")
        #expect(standard.deletingLastPathComponent().lastPathComponent == "garage")
        let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        #expect(standard.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == appSupport.standardizedFileURL)
    }
}
