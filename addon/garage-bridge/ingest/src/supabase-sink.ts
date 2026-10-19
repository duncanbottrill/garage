import type { SupabaseClient } from "@supabase/supabase-js";
import type { UsageCategory } from "@garage/core";
import type { SignalRow } from "./state";

export interface SupabaseSinkOptions {
  vehicleId: string;
  ownerId: string;
}

export interface ResolvedVehicle {
  vehicleId: string;
  ownerId: string;
  budgetMode: string;
  configHash: string | null;
  configVersion: number;
}

export interface TelemetryConfigFields {
  hash?: string | null;
  version?: number;
  confirmedAt?: string | null;
  lastError?: string | null;
}

export interface Sink {
  ensureStateRow(): Promise<void>;
  insertSignals(rows: SignalRow[]): Promise<void>;
  mergeState(patch: Record<string, unknown>): Promise<void>;
  heartbeat(health: Record<string, unknown>): Promise<void>;
  countUsage(category: UsageCategory, n?: number): Promise<void>;
  countSignals(n: number): Promise<void>;
  resolveVehicle(vin: string): Promise<ResolvedVehicle | null>;
  setTelemetryConfig(fields: TelemetryConfigFields): Promise<void>;
}

/**
 * All Supabase I/O for the bridge, scoped to one vehicle. `resolveVehicle`
 * looks a VIN up by querying `vehicles` directly (it doesn't depend on the
 * instance's bound ids) and, as a side effect, updates the ids every other
 * method closes over — so a sink can be constructed with placeholder ids
 * before the vehicle row is known, and `resolveVehicle` fills them in.
 */
export function SupabaseSink(client: SupabaseClient, initial: SupabaseSinkOptions): Sink {
  let vehicleId = initial.vehicleId;
  let ownerId = initial.ownerId;

  async function ensureStateRow(): Promise<void> {
    const { error } = await client
      .from("vehicle_state")
      .upsert({ vehicle_id: vehicleId, owner_id: ownerId }, { onConflict: "vehicle_id", ignoreDuplicates: true });
    if (error) throw error;
  }

  async function insertSignals(rows: SignalRow[]): Promise<void> {
    if (rows.length === 0) return;
    const { error } = await client
      .from("signals")
      .upsert(rows, { onConflict: "vehicle_id,name,recorded_at", ignoreDuplicates: true });
    if (error) throw error;
  }

  async function mergeState(patch: Record<string, unknown>): Promise<void> {
    const cleaned = stripNulls(patch);
    const { error } = await client.rpc("merge_vehicle_state", { p_vehicle: vehicleId, p_patch: cleaned });
    if (error) throw error;
  }

  async function heartbeat(health: Record<string, unknown>): Promise<void> {
    await mergeState({ bridge_seen_at: new Date().toISOString(), bridge_health: health });
  }

  async function countUsage(category: UsageCategory, n = 1): Promise<void> {
    if (n <= 0) return;
    const { error } = await client.rpc("increment_usage", { p_owner: ownerId, p_category: category, p_count: n });
    if (error) throw error;
  }

  async function countSignals(n: number): Promise<void> {
    await countUsage("signals", n);
  }

  async function resolveVehicle(vin: string): Promise<ResolvedVehicle | null> {
    const { data, error } = await client
      .from("vehicles")
      .select("id, owner_id, budget_mode, telemetry_config_hash, telemetry_config_version")
      .eq("vin", vin)
      .maybeSingle();
    if (error) throw error;
    if (!data) return null;

    vehicleId = data.id;
    ownerId = data.owner_id;

    return {
      vehicleId: data.id,
      ownerId: data.owner_id,
      budgetMode: data.budget_mode,
      configHash: data.telemetry_config_hash,
      configVersion: data.telemetry_config_version,
    };
  }

  async function setTelemetryConfig(fields: TelemetryConfigFields): Promise<void> {
    const patch: Record<string, unknown> = {};
    if ("hash" in fields) patch.telemetry_config_hash = fields.hash;
    if ("version" in fields) patch.telemetry_config_version = fields.version;
    if ("confirmedAt" in fields) patch.telemetry_confirmed_at = fields.confirmedAt;
    if ("lastError" in fields) patch.telemetry_last_error = fields.lastError;
    if (Object.keys(patch).length === 0) return;

    const { error } = await client.from("vehicles").update(patch).eq("id", vehicleId);
    if (error) throw error;
  }

  return {
    ensureStateRow,
    insertSignals,
    mergeState,
    heartbeat,
    countUsage,
    countSignals,
    resolveVehicle,
    setTelemetryConfig,
  };
}

/**
 * Drops `null` values (recursively) from a state patch before it's sent to
 * `merge_vehicle_state`. The RPC already treats a JSON null as "omit, don't
 * null" server-side, but the sink never sends one in the first place.
 */
function stripNulls(patch: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(patch)) {
    if (value === null || value === undefined) continue;
    if (typeof value === "object" && !Array.isArray(value)) {
      out[key] = stripNulls(value as Record<string, unknown>);
    } else {
      out[key] = value;
    }
  }
  return out;
}
