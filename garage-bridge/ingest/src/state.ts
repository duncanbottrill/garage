import { telemetrySignalClears, telemetrySignalToState, type VehicleStateRow } from "@garage/core";

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

const isFiniteNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/**
 * Drops individual keys that would be wrong or rejected by
 * `merge_vehicle_state` (a Postgres cast error fails the WHOLE patch), so
 * one bad value never costs the good ones beside it:
 * - any top-level number that is not finite (NaN/±Infinity);
 * - `lat`/`lng` unless both are finite and within [-90, 90] / [-180, 180] —
 *   then `lat`, `lng` and `location_at` are dropped together, so a half
 *   location is never written;
 * - `charge_limit_soc` unless it is an integer in [0, 100] (an `int` column);
 * - non-finite `tpms_bar` entries (and `tpms_bar` itself if none remain).
 */
export function sanitizeStatePatch(patch: Partial<VehicleStateRow>): Partial<VehicleStateRow> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(patch)) {
    if (typeof value === "number" && !Number.isFinite(value)) continue;
    out[key] = value;
  }

  if ("lat" in out || "lng" in out) {
    const { lat, lng } = out;
    const valid = isFiniteNumber(lat) && isFiniteNumber(lng) && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
    if (!valid) {
      delete out.lat;
      delete out.lng;
      delete out.location_at;
    }
  }

  if ("charge_limit_soc" in out) {
    const v = out.charge_limit_soc;
    if (!isFiniteNumber(v) || !Number.isInteger(v) || v < 0 || v > 100) delete out.charge_limit_soc;
  }

  if ("tpms_bar" in out) {
    const tpms = out.tpms_bar;
    if (tpms && typeof tpms === "object" && !Array.isArray(tpms)) {
      const kept = Object.fromEntries(Object.entries(tpms as Record<string, unknown>).filter(([, v]) => isFiniteNumber(v)));
      if (Object.keys(kept).length > 0) out.tpms_bar = kept;
      else delete out.tpms_bar;
    } else {
      delete out.tpms_bar;
    }
  }

  return out as Partial<VehicleStateRow>;
}

/**
 * Maps a BridgeEvent onto a partial `vehicle_state` patch. Field events defer
 * to `@garage/core`'s telemetry mapper (on the already-decoded value),
 * then `sanitizeStatePatch` drops any key with an invalid value;
 * connectivity toggles `sleep_state`; alerts and errors go to health instead
 * and contribute no state patch.
 */
export function toStatePatch(ev: BridgeEvent): Partial<VehicleStateRow> {
  switch (ev.kind) {
    case "field":
      // `invalid` decodes to null: no information, so no state change
      // (never a "null" string, all-doors-closed, or `false`).
      if (ev.value == null) return {};
      return sanitizeStatePatch(telemetrySignalToState(ev.name, ev.value, ev.at));
    case "connectivity":
      if (ev.status === "CONNECTED") return { sleep_state: "online" };
      if (ev.status === "DISCONNECTED") return { sleep_state: "asleep" };
      return {};
    case "alert":
    case "error":
      return {};
  }
}

/**
 * `vehicle_state` keys to set to NULL for this event: a field event decoded
 * from `invalid` names the keys `@garage/core` says that absence clears
 * (today only `ScheduledChargingStartTime` → `scheduled_charge_at`, so a
 * cancelled scheduled charge does not keep showing its old time). Every
 * other event clears nothing; `toStatePatch` still supplies the values.
 */
export function toStateClears(ev: BridgeEvent): string[] {
  if (ev.kind !== "field" || ev.value != null) return [];
  return telemetrySignalClears(ev.name);
}
