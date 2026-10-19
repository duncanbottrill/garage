export interface BridgeHealthPayload {
  received: number;
  flushed: number;
  dropped: number;
  patch_failures: number;
  last_event_at: string | null;
  connectivity: string | null;
  active_alerts: string[];
  last_error: string | null;
  last_vehicle_error: string | null;
  last_mqtt_error: string | null;
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
  private lastVehicleErrorMessage: string | null = null;
  private lastMqttErrorMessage: string | null = null;

  received(): void {
    this.receivedCount++;
  }

  flushed(n: number): void {
    this.flushedCount += n;
  }

  /** Sets the dropped-row count to the batcher's own cumulative total (not a delta). */
  setDropped(n: number): void {
    this.droppedCount = n;
  }

  patchFailed(err: unknown): void {
    this.patchFailureCount++;
    this.lastErrorMessage = err instanceof Error ? err.message : String(err);
  }

  /** Records a vehicle-reported `errors/<name>` event without counting it as a patch failure. */
  vehicleError(name: string, body: string): void {
    this.lastVehicleErrorMessage = `${name}: ${body}`;
  }

  /** Records an MQTT transport-level status error, distinct from a state-patch failure. */
  mqttError(message: string): void {
    this.lastMqttErrorMessage = message;
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
      last_vehicle_error: this.lastVehicleErrorMessage,
      last_mqtt_error: this.lastMqttErrorMessage,
    };
  }
}
