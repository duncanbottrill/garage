export interface BridgeHealthPayload {
  received: number;
  flushed: number;
  dropped: number;
  patch_failures: number;
  last_event_at: string | null;
  connectivity: string | null;
  active_alerts: string[];
  last_error: string | null;
}

/**
 * In-memory counters/state for the bridge's `bridge_health` jsonb column.
 * Pure bookkeeping — no I/O; the consumer calls these methods as events are
 * processed and periodically reads `payload()` to persist a snapshot.
 */
export class Health {
  private receivedCount = 0;
  private flushedCount = 0;
  private droppedCount = 0;
  private patchFailureCount = 0;
  private lastEventAt: string | null = null;
  private connectivityStatus: string | null = null;
  private readonly activeAlerts = new Set<string>();
  private lastErrorMessage: string | null = null;

  received(): void {
    this.receivedCount++;
  }

  flushed(n: number): void {
    this.flushedCount += n;
  }

  dropped(n: number): void {
    this.droppedCount += n;
  }

  patchFailed(err: unknown): void {
    this.patchFailureCount++;
    this.lastErrorMessage = err instanceof Error ? err.message : String(err);
  }

  connectivity(status: string): void {
    this.connectivityStatus = status;
  }

  alert(name: string, active: boolean): void {
    if (active) this.activeAlerts.add(name);
    else this.activeAlerts.delete(name);
  }

  eventAt(date: Date): void {
    this.lastEventAt = date.toISOString();
  }

  payload(): BridgeHealthPayload {
    return {
      received: this.receivedCount,
      flushed: this.flushedCount,
      dropped: this.droppedCount,
      patch_failures: this.patchFailureCount,
      last_event_at: this.lastEventAt,
      connectivity: this.connectivityStatus,
      active_alerts: Array.from(this.activeAlerts),
      last_error: this.lastErrorMessage,
    };
  }
}
