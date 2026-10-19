import { telemetrySignalToState, type VehicleStateRow } from "@garage/core";

export type BridgeEvent =
  | { kind: "field"; vin: string; name: string; value: unknown; at: Date }
  | { kind: "connectivity"; vin: string; status: "CONNECTED" | "DISCONNECTED" | "UNKNOWN"; at: Date }
  | { kind: "alert"; vin: string; name: string; active: boolean; at: Date }
  | { kind: "error"; vin: string; name: string; body: string; at: Date };

export interface SignalRow {
  vehicle_id: string;
  owner_id: string;
  name: string;
  value_num: number | null;
  value_text: string | null;
  value_json: Record<string, unknown> | null;
  recorded_at: string;
}

type FieldEvent = Extract<BridgeEvent, { kind: "field" }>;

/** Maps a decoded field event onto a `vehicle_signals`-style row. */
export function toSignalRow(ev: FieldEvent, vehicleId: string, ownerId: string): SignalRow {
  const { name, value, at } = ev;

  let value_num: number | null = null;
  let value_text: string | null = null;
  let value_json: Record<string, unknown> | null = null;

  if (typeof value === "number" && Number.isFinite(value)) {
    value_num = value;
  } else if (typeof value === "boolean") {
    value_text = value ? "true" : "false";
  } else if (typeof value === "string") {
    value_text = value;
  } else if (value !== null && typeof value === "object") {
    value_json = value as Record<string, unknown>;
  }

  return {
    vehicle_id: vehicleId,
    owner_id: ownerId,
    name,
    value_num,
    value_text,
    value_json,
    recorded_at: at.toISOString(),
  };
}

/**
 * Maps a BridgeEvent onto a partial `vehicle_state` patch. Field events defer
 * to `@garage/core`'s telemetry mapper (on the already-decoded value);
 * connectivity toggles `sleep_state`; alerts and errors go to health instead
 * and contribute no state patch.
 */
export function toStatePatch(ev: BridgeEvent): Partial<VehicleStateRow> {
  switch (ev.kind) {
    case "field":
      return telemetrySignalToState(ev.name, ev.value, ev.at);
    case "connectivity":
      if (ev.status === "CONNECTED") return { sleep_state: "online" };
      if (ev.status === "DISCONNECTED") return { sleep_state: "asleep" };
      return {};
    case "alert":
    case "error":
      return {};
  }
}
