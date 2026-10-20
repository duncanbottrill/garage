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
/// filtered `vehicle_id=eq.<id>`, on channel `vehicle_state:<id>`. The Supabase client rejoins the
/// channel itself after a socket drop; this feed reports those transitions as events.
public struct SupabaseRealtimeFeed: RealtimeFeed {
    let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func events(for vehicleID: UUID) -> AsyncStream<RealtimeFeedEvent> {
        let realtime = client.realtimeV2
        let id = vehicleID.uuidString.lowercased()
        let channel = realtime.channel("vehicle_state:\(id)")
        // Streams must be registered before subscribing.
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "vehicle_state",
            filter: .eq("vehicle_id", value: id)
        )
        let statuses = channel.statusChange

        return AsyncStream { continuation in
            let task = Task {
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
            continuation.onTermination = { _ in
                task.cancel()
                Task { await realtime.removeChannel(channel) }
            }
        }
    }

    private static let logger = Logger(subsystem: "com.duncanbottrill.garage", category: "RealtimeFeed")
}
