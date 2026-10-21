import Foundation
import os

/// The usage counts the backend has not acknowledged yet, as kept between launches: counts not yet
/// in a batch, and the batches formed (each sent under its own id until `/api/usage` answers).
public struct PendingUsage: Codable, Equatable, Sendable {
    public var counts: [UsageCategory: Int]
    public var batches: [UsageReporter.Batch]

    public static let empty = PendingUsage(counts: [:], batches: [])

    public init(counts: [UsageCategory: Int], batches: [UsageReporter.Batch]) {
        self.counts = counts
        self.batches = batches
    }

    public var isEmpty: Bool { counts.isEmpty && batches.isEmpty }
}

/// Where ``UsageReporter`` keeps ``PendingUsage`` so a kill or a suspension loses no counts.
public protocol UsageStore: Sendable {
    /// What was saved, or nil when nothing was (or it cannot be read).
    func load() -> PendingUsage?
    /// Replaces what is saved; ``PendingUsage/empty`` removes it.
    func save(_ usage: PendingUsage)
}

/// A ``UsageStore`` backed by one JSON file, by default `Application Support/garage/usage.json`
/// next to the vehicle snapshot. Writes are atomic.
public struct FileUsageStore: UsageStore {
    /// `Application Support/garage/usage.json` in the user domain (the app container when sandboxed).
    public static var defaultURL: URL {
        FileSnapshotCache.defaultURL.deletingLastPathComponent().appendingPathComponent("usage.json")
    }

    public let url: URL

    public init(url: URL = FileUsageStore.defaultURL) {
        self.url = url
    }

    public func load() -> PendingUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try GarageJSON.decoder.decode(PendingUsage.self, from: data)
        } catch {
            Self.logger.error("Discarding unreadable usage ledger at \(url.path, privacy: .public): \(error)")
            return nil
        }
    }

    public func save(_ usage: PendingUsage) {
        guard !usage.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            let data = try GarageJSON.encoder.encode(usage)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch {
            Self.logger.error("Could not save the usage ledger to \(url.path, privacy: .public): \(error)")
        }
    }

    private static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "usage")
}

/// A ``UsageStore`` held in memory, for tests.
public final class InMemoryUsageStore: UsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PendingUsage?
    private var saveCount = 0

    public init(_ usage: PendingUsage? = nil) {
        stored = usage
    }

    /// What the last ``save(_:)`` left: nil before any save or after saving ``PendingUsage/empty``.
    public var saved: PendingUsage? { lock.withLock { stored } }
    /// How many times ``save(_:)`` was called.
    public var saves: Int { lock.withLock { saveCount } }

    public func load() -> PendingUsage? {
        lock.withLock { stored }
    }

    public func save(_ usage: PendingUsage) {
        lock.withLock {
            stored = usage.isEmpty ? nil : usage
            saveCount += 1
        }
    }
}
