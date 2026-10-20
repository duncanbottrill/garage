import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { SupabaseSink } from "../src/supabase-sink";
import type { SignalRow } from "../src/state";

const VIN = `SINKTEST${Date.now().toString(36).toUpperCase().slice(-9)}`;

let admin: SupabaseClient;
let ownerId: string;
let vehicleId: string;

// These tests hit a real (local) Supabase instance and have no mock
// fallback, so they only run when SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY
// are set (e.g. via `supabase start` locally). CI's `test` job does not
// start Supabase, so this suite is skipped there — both the hooks and the
// cases, since skipIf gates the whole describe block including beforeAll.
const hasSupabaseEnv = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);

describe.skipIf(!hasSupabaseEnv)("SupabaseSink", () => {
  beforeAll(async () => {
    admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);

    const email = `ingest-sink-${Date.now()}@test.local`;
    const created = await admin.auth.admin.createUser({ email, password: "pass-1234", email_confirm: true });
    ownerId = created.data.user!.id;

    const { data: vehicle, error } = await admin
      .from("vehicles")
      .insert({ owner_id: ownerId, vin: VIN, display_name: "Sink Test Car" })
      .select("id")
      .single();
    if (error) throw error;
    vehicleId = vehicle!.id;
  });

  afterAll(async () => {
    await admin.from("vehicles").delete().eq("id", vehicleId);
    await admin.auth.admin.deleteUser(ownerId);
  });

  it("ensureStateRow creates the vehicle_state row and is idempotent", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });

    await sink.ensureStateRow();
    await sink.ensureStateRow();

    const { data, error } = await admin.from("vehicle_state").select("vehicle_id, owner_id").eq("vehicle_id", vehicleId);
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(data![0]).toEqual({ vehicle_id: vehicleId, owner_id: ownerId });
  });

  it("insertSignals ignores duplicate (vehicle_id, name, recorded_at) rows without throwing", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });
    const recordedAt = new Date("2026-10-19T08:00:00.000Z").toISOString();
    const row: SignalRow = {
      vehicle_id: vehicleId,
      owner_id: ownerId,
      name: "Soc",
      value_num: 72.5,
      value_text: null,
      value_json: null,
      recorded_at: recordedAt,
    };

    await expect(sink.insertSignals([row])).resolves.not.toThrow();
    // Same primary key again, with a different value — must not throw, and must not create a second row.
    await expect(sink.insertSignals([{ ...row, value_num: 99 }])).resolves.not.toThrow();

    const { data, error } = await admin
      .from("signals")
      .select("value_num")
      .eq("vehicle_id", vehicleId)
      .eq("name", "Soc")
      .eq("recorded_at", recordedAt);
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
    expect(Number(data![0]!.value_num)).toBe(72.5);
  });

  it("mergeState lands a patch onto vehicle_state", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });
    await sink.ensureStateRow();

    await sink.mergeState({ soc: 41 });

    const { data, error } = await admin.from("vehicle_state").select("soc").eq("vehicle_id", vehicleId).single();
    expect(error).toBeNull();
    expect(Number(data?.soc)).toBe(41);
  });

  it("mergeState strips null values instead of sending them to the RPC", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });
    await sink.ensureStateRow();
    await sink.mergeState({ soc: 55 });

    // A null here must leave the existing value (55) alone, not null it out.
    await sink.mergeState({ soc: null as unknown as number, inside_c: 21 });

    const { data, error } = await admin.from("vehicle_state").select("soc, inside_c").eq("vehicle_id", vehicleId).single();
    expect(error).toBeNull();
    expect(Number(data?.soc)).toBe(55);
    expect(Number(data?.inside_c)).toBe(21);
  });

  it("heartbeat sets bridge_seen_at and bridge_health", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });
    await sink.ensureStateRow();

    const before = Date.now();
    await sink.heartbeat({ received: 10, flushed: 8, dropped: 0, patch_failures: 0, last_event_at: null, connectivity: "online", active_alerts: [], last_error: null });

    const { data, error } = await admin.from("vehicle_state").select("bridge_seen_at, bridge_health").eq("vehicle_id", vehicleId).single();
    expect(error).toBeNull();
    expect(new Date(data!.bridge_seen_at as string).getTime()).toBeGreaterThanOrEqual(before - 1000);
    expect((data!.bridge_health as Record<string, unknown>).received).toBe(10);
  });

  it("countSignals(50) increments the signals usage ledger for the owner", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });
    const month = new Date().toISOString().slice(0, 7) + "-01";

    const before = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "signals").eq("month", month).maybeSingle();
    const beforeCount = Number(before.data?.count ?? 0);

    await sink.countSignals(50);

    const after = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "signals").eq("month", month).single();
    expect(Number(after.data?.count)).toBe(beforeCount + 50);
  });

  it("resolveVehicle finds the vehicle by VIN and rebinds the sink's ids", async () => {
    const sink = SupabaseSink(admin, { vehicleId: "placeholder", ownerId: "placeholder" });

    const resolved = await sink.resolveVehicle(VIN);
    expect(resolved).not.toBeNull();
    expect(resolved!.vehicleId).toBe(vehicleId);
    expect(resolved!.ownerId).toBe(ownerId);
    expect(resolved!.budgetMode).toBe("normal");
    expect(resolved!.confirmedAt).toBeNull();

    // Now bound to the real ids, not the placeholder.
    await expect(sink.ensureStateRow()).resolves.not.toThrow();
  });

  it("resolveVehicle returns null for an unknown VIN", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });
    const resolved = await sink.resolveVehicle("UNKNOWNVIN00000001");
    expect(resolved).toBeNull();
  });

  it("setTelemetryConfig writes hash/version/confirmedAt/lastError onto vehicles", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });

    await sink.setTelemetryConfig({ hash: "abc123", version: 1, confirmedAt: "2026-10-19T08:00:00.000Z", lastError: null });

    const { data, error } = await admin
      .from("vehicles")
      .select("telemetry_config_hash, telemetry_config_version, telemetry_confirmed_at, telemetry_last_error")
      .eq("id", vehicleId)
      .single();
    expect(error).toBeNull();
    expect(data?.telemetry_config_hash).toBe("abc123");
    expect(data?.telemetry_config_version).toBe(1);
    expect(data?.telemetry_last_error).toBeNull();

    // A partial update (lastError only) must not clobber hash/version.
    await sink.setTelemetryConfig({ lastError: "boom" });
    const { data: after } = await admin
      .from("vehicles")
      .select("telemetry_config_hash, telemetry_config_version, telemetry_last_error")
      .eq("id", vehicleId)
      .single();
    expect(after?.telemetry_config_hash).toBe("abc123");
    expect(after?.telemetry_config_version).toBe(1);
    expect(after?.telemetry_last_error).toBe("boom");
  });

  it("setProxyBaseUrl writes and clears vehicles.proxy_base_url", async () => {
    const sink = SupabaseSink(admin, { vehicleId, ownerId });

    await sink.setProxyBaseUrl("https://garage-bridge.tail068c8f.ts.net:4443");
    const { data, error } = await admin.from("vehicles").select("proxy_base_url").eq("id", vehicleId).single();
    expect(error).toBeNull();
    expect(data?.proxy_base_url).toBe("https://garage-bridge.tail068c8f.ts.net:4443");

    await sink.setProxyBaseUrl(null);
    const { data: cleared } = await admin.from("vehicles").select("proxy_base_url").eq("id", vehicleId).single();
    expect(cleared?.proxy_base_url).toBeNull();
  });
});
