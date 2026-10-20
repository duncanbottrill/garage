import Foundation
import Supabase
import Testing
@testable import GarageKit

/// Loads the JSON fixtures bundled with the test target. These are real rows (scrubbed) or cut-down copies.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "json"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    /// The fixture decoded the way the app decodes a PostgREST row.
    static func state(_ name: String) throws -> VehicleState {
        try GarageJSON.decoder.decode(VehicleState.self, from: data(name))
    }

    /// The fixture as a Realtime `record` payload.
    static func row(_ name: String) throws -> [String: AnyJSON] {
        try JSONDecoder().decode([String: AnyJSON].self, from: data(name))
    }

    /// A fresh, empty directory under the test process's temporary directory.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarageKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Seconds since 1970 for a fixture timestamp, compared with a millisecond tolerance.
func expectDate(_ date: Date?, _ epoch: TimeInterval, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let date else {
        Issue.record("expected a date at \(epoch), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(date.timeIntervalSince1970 - epoch) < 0.0005, sourceLocation: sourceLocation)
}
