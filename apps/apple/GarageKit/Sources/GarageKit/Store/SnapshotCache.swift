import Foundation
import os

/// Keeps the last known ``VehicleState`` across launches so the app opens on real numbers before
/// any network round trip.
public protocol SnapshotCache: Sendable {
    /// The saved snapshot, or nil when there is none (or it cannot be read).
    func load() -> VehicleState?
    /// Replaces the saved snapshot.
    func save(_ state: VehicleState)
}

/// A ``SnapshotCache`` backed by one JSON file, by default `Application Support/garage/vehicle_state.json`.
///
/// Writes are atomic (`Data.WritingOptions.atomic` writes a temporary file and renames it over the
/// old one), so a crash mid-write leaves the previous snapshot intact. Dates are stored losslessly.
public struct FileSnapshotCache: SnapshotCache {
    /// `Application Support/garage/vehicle_state.json` in the user domain (the app container when sandboxed).
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("garage", isDirectory: true).appendingPathComponent("vehicle_state.json")
    }

    /// The file this cache reads and writes.
    public let url: URL

    public init(url: URL = FileSnapshotCache.defaultURL) {
        self.url = url
    }

    public func load() -> VehicleState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try GarageJSON.decoder.decode(VehicleState.self, from: data)
        } catch {
            Self.logger.error("Discarding unreadable snapshot at \(url.path, privacy: .public): \(error)")
            return nil
        }
    }

    public func save(_ state: VehicleState) {
        do {
            let data = try GarageJSON.encoder.encode(state)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            // Readable after first unlock, so a background refresh can still open on the snapshot.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch {
            Self.logger.error("Could not save snapshot to \(url.path, privacy: .public): \(error)")
        }
    }

    /// Deletes the saved snapshot (for example on sign-out: it holds the car's location).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "SnapshotCache")
}

/// A ``SnapshotCache`` held in memory, for previews and tests.
public final class InMemorySnapshotCache: SnapshotCache, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: VehicleState?

    public init(_ state: VehicleState? = nil) {
        stored = state
    }

    public func load() -> VehicleState? {
        lock.withLock { stored }
    }

    public func save(_ state: VehicleState) {
        lock.withLock { stored = state }
    }
}
