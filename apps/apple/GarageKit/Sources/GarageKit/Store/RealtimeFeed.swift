import Foundation
import os
import Supabase

/// What a ``RealtimeFeed`` reports about one car's `vehicle_state` row.
public enum RealtimeFeedEvent: Sendable, Equatable {
    /// The channel joined (first time or after a drop): updates flow from now on.
    case subscribed
    /// The channel left the subscribed state (socket drop, server close); updates may be missed until
    /// the next `.subscribed`.
    case disconnected
    /// The new row from a Postgres UPDATE, column → value.
    case row([String: AnyJSON])
}

/// A live stream of changes to one car's `vehicle_state` row. Injected into ``VehicleStore`` so tests
/// can replay events without a network.
public protocol RealtimeFeed: Sendable {
    /// Starts listening for `vehicleID`. The stream stays open until the consuming task is cancelled,
    /// which also tears the subscription down.
    func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent>
}

/// ``RealtimeFeed`` over Supabase Realtime: `postgres_changes` UPDATE on `public.vehicle_state`
/// filtered `vehicle_id=eq.<id>`. The Supabase client rejoins the channel itself after a socket drop;
/// this feed reports those transitions as events.
///
/// Each ``events(for:)`` call joins its own channel, topic `vehicle_state:<id>:<uuid>`.
/// `RealtimeClientV2.channel(_:)` hands back an existing channel for a reused topic, and removing a
/// channel is asynchronous (it awaits the server's unsubscribe). With a fixed topic, a quick
/// stop/start, which is common when offline, could attach to the dying channel and never receive
/// anything. The topic name does not affect `postgres_changes` routing; the filter does that. The feed
/// also remembers the pending removal, and the next subscription waits for it, so at most one channel
/// per feed is ever joined.
public struct SupabaseRealtimeFeed: RealtimeFeed {
    let client: SupabaseClient
    private let removal = PendingRemoval()

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        let realtime = client.realtimeV2
        let id = vehicleID.uuidString.lowercased()
        let topic = "vehicle_state:\(id):\(UUID().uuidString.lowercased())"
        let previousRemoval = removal.current
        let joined = ChannelBox()

        return AsyncStream { continuation in
            let task = Task {
                await previousRemoval?.value
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                let channel = realtime.channel(topic)
                joined.set(channel)
                // Streams must be registered before subscribing.
                let updates = channel.postgresChange(
                    UpdateAction.self,
                    schema: "public",
                    table: "vehicle_state",
                    filter: .eq("vehicle_id", value: id)
                )
                let statuses = channel.statusChange

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await update in updates {
                            continuation.yield(.row(update.record))
                        }
                    }
                    group.addTask {
                        var subscribed = false
                        for await status in statuses {
                            switch status {
                            case .subscribed:
                                subscribed = true
                                continuation.yield(.subscribed)
                            case .unsubscribed, .subscribing, .unsubscribing:
                                if subscribed {
                                    subscribed = false
                                    continuation.yield(.disconnected)
                                }
                            }
                        }
                    }
                    group.addTask {
                        // The client retries a join with backoff internally; if it gives up, try again later.
                        while !Task.isCancelled {
                            do {
                                try await channel.subscribeWithError()
                                return
                            } catch {
                                if Task.isCancelled { return }
                                Self.logger.error("Realtime subscribe failed, retrying in 30 s: \(error)")
                                try? await Task.sleep(for: .seconds(30))
                            }
                        }
                    }
                    await group.waitForAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { [removal] _ in
                task.cancel()
                // Recorded synchronously, so an events(for:) call right after this sees it and waits.
                removal.set(Task {
                    await task.value
                    if let channel = joined.channel {
                        await realtime.removeChannel(channel)
                    }
                })
            }
        }
    }

    private static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "RealtimeFeed")
}

/// The most recent channel teardown of a feed, shared by its copies.
private final class PendingRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var current: Task<Void, Never>? { lock.withLock { task } }

    func set(_ newValue: Task<Void, Never>) {
        lock.withLock { task = newValue }
    }
}

/// The channel a subscription joined, for its teardown.
private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RealtimeChannelV2?

    var channel: RealtimeChannelV2? { lock.withLock { stored } }

    func set(_ channel: RealtimeChannelV2) {
        lock.withLock { stored = channel }
    }
}
