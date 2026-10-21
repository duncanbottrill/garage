import { describe, it, expect, beforeAll } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { admin, userClient } from "./helpers";

describe("row level security", () => {
  let a: Awaited<ReturnType<typeof userClient>>, b: typeof a;
  let vehicleId: string;
  beforeAll(async () => {
    a = await userClient("a@test.local"); b = await userClient("b@test.local");
    const { data: v } = await admin.from("vehicles").insert({ owner_id: a.id, vin: "VINAAAA", display_name: "A car" }).select("id").single();
    vehicleId = v!.id;
  });
  it("owner reads own vehicle", async () => {
    const { data } = await a.client.from("vehicles").select("vin");
    expect(data?.map(v => v.vin)).toContain("VINAAAA");
  });
  it("other user sees nothing", async () => {
    const { data } = await b.client.from("vehicles").select("vin");
    expect(data).toEqual([]);
  });
  it("users cannot read tesla_credentials", async () => {
    await admin.from("tesla_credentials").insert({ owner_id: a.id, refresh_token_enc: "\\x00" });
    const { data } = await a.client.from("tesla_credentials").select("*");
    expect(data).toEqual([]);
  });
  it("get_tesla_connection shows only the caller's row and never tokens", async () => {
    const { data: a1 } = await a.client.rpc("get_tesla_connection"); expect(a1?.[0]?.connected).toBe(true); expect(JSON.stringify(a1)).not.toMatch(/token/);
    const { data: b1 } = await b.client.rpc("get_tesla_connection"); expect(b1?.[0]?.connected).toBe(false);
  });
  it("increment_usage is service-only", async () => {
    const { error } = await a.client.rpc("increment_usage", { p_owner: a.id, p_category: "commands", p_count: 1 });
    expect(error).not.toBeNull();
    const { error: e2 } = await admin.rpc("increment_usage", { p_owner: a.id, p_category: "commands", p_count: 1 });
    expect(e2).toBeNull();
  });
  it("anon cannot read the current month's signals partition directly", async () => {
    const now = new Date();
    const partition = `signals_${now.getUTCFullYear()}${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
    const anon = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
    const { data, error } = await anon.from(partition).select("*");
    if (error) expect(error).not.toBeNull();
    else expect(data).toEqual([]);
  });
  it("other user cannot read a signals row for user A's vehicle via the parent table", async () => {
    const recordedAt = new Date().toISOString();
    await admin.from("signals").insert({ vehicle_id: vehicleId, owner_id: a.id, name: "rls_test_signal", value_num: 1, recorded_at: recordedAt });
    const { data } = await b.client.from("signals").select("*").eq("vehicle_id", vehicleId);
    expect(data).toEqual([]);
  });
  it("signals_default exists and absorbs out-of-range rows", async () => {
    // PostgREST doesn't expose partition leaves as their own resources, so we
    // can't select from signals_default directly over the API — but if the
    // default partition didn't exist, this insert (recorded_at far outside
    // every monthly range) would fail with "no partition of relation found".
    const recordedAt = "2099-01-01T00:00:00Z";
    const { error } = await admin.from("signals").insert({ vehicle_id: vehicleId, owner_id: a.id, name: "rls_default_partition_test", value_num: 1, recorded_at: recordedAt });
    expect(error).toBeNull();
    const { data } = await admin.from("signals").select("name").eq("name", "rls_default_partition_test").eq("recorded_at", recordedAt);
    expect(data?.length).toBe(1);
    await admin.from("signals").delete().eq("name", "rls_default_partition_test").eq("recorded_at", recordedAt);
  });
  it("merge_vehicle_state merges jsonb and overwrites scalars", async () => {
    const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
    await admin.from("vehicle_state").upsert({ vehicle_id: v!.id, owner_id: a.id, soc: 50, tpms_bar: { fl: 2.9, fr: 2.9 } });
    const { error } = await admin.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { soc: 51, tpms_bar: { rl: 2.8 }, nonsense: 1, owner_id: b.id } });
    expect(error).toBeNull();
    const { data: s } = await admin.from("vehicle_state").select("soc, tpms_bar, owner_id").eq("vehicle_id", v!.id).single();
    expect(Number(s?.soc)).toBe(51); expect(s?.tpms_bar).toEqual({ fl: 2.9, fr: 2.9, rl: 2.8 }); expect(s?.owner_id).toBe(a.id);
  });
  it("merge_vehicle_state treats a JSON null as omit, not set-to-null", async () => {
    const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
    await admin.from("vehicle_state").upsert({ vehicle_id: v!.id, owner_id: a.id, soc: 51 });
    const { error } = await admin.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { soc: null } });
    expect(error).toBeNull();
    const { data: s } = await admin.from("vehicle_state").select("soc").eq("vehicle_id", v!.id).single();
    expect(Number(s?.soc)).toBe(51);
  });
  it("merge_vehicle_state p_clear nulls known columns, ignores unknown and protected keys, and a patched key keeps its value", async () => {
    const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
    await admin.from("vehicle_state").upsert({ vehicle_id: v!.id, owner_id: a.id, soc: 51, scheduled_charge_at: "2026-10-22T01:00:00Z", charge_amps: 16 });
    const { error } = await admin.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { charge_amps: 32 }, p_clear: ["scheduled_charge_at", "charge_amps", "owner_id", "updated_at", "nonsense"] });
    expect(error).toBeNull();
    const { data: s } = await admin.from("vehicle_state").select("soc, scheduled_charge_at, charge_amps, owner_id, updated_at").eq("vehicle_id", v!.id).single();
    expect(Number(s?.soc)).toBe(51); expect(s?.scheduled_charge_at).toBeNull(); expect(Number(s?.charge_amps)).toBe(32); expect(s?.owner_id).toBe(a.id); expect(s?.updated_at).not.toBeNull();
  });
  it("merge_vehicle_state still accepts the two-argument call (p_clear defaults to empty)", async () => {
    const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
    await admin.from("vehicle_state").upsert({ vehicle_id: v!.id, owner_id: a.id, scheduled_charge_at: "2026-10-22T01:00:00Z" });
    const { error } = await admin.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { soc: 52 } });
    expect(error).toBeNull();
    const { data: s } = await admin.from("vehicle_state").select("soc, scheduled_charge_at").eq("vehicle_id", v!.id).single();
    expect(Number(s?.soc)).toBe(52); expect(s?.scheduled_charge_at).not.toBeNull();
  });
  it("merge_vehicle_state rejects a non-object patch", async () => {
    const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
    const { error } = await admin.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: ["soc"] });
    expect(error).not.toBeNull();
  });
  it("merge_vehicle_state is service-only", async () => {
    const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
    const { error } = await a.client.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { soc: 1 } }); expect(error).not.toBeNull();
  });
  it("vehicles.owner_id is immutable", async () => {
    const { error } = await admin.from("vehicles").update({ owner_id: b.id }).eq("vin", "VINAAAA");
    expect(error?.message).toMatch(/immutable/);
  });
  it("ensure_signals_partitions secures a far-future partition: anon is denied, other users see nothing, the owner reads it via the parent", async () => {
    const { error: rpcError } = await admin.rpc("ensure_signals_partitions", { p_months_ahead: 20 });
    expect(rpcError).toBeNull();

    const now = new Date();
    const far = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 19, 1));
    const partitionName = "signals_" + far.toISOString().slice(0, 7).replace("-", "");
    const recordedAt = new Date(Date.UTC(far.getUTCFullYear(), far.getUTCMonth(), 2)).toISOString();

    await admin.from("signals").insert({ vehicle_id: vehicleId, owner_id: a.id, name: "Soc", value_num: 1, recorded_at: recordedAt });
    try {
      const anon = createClient(process.env.SUPABASE_URL ?? "http://127.0.0.1:54321", process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
      const { data: anonData, error: anonError } = await anon.from(partitionName).select("*");
      expect(anonError).not.toBeNull();
      expect(anonData ?? []).toHaveLength(0);

      const { data: bData } = await b.client.from("signals").select("*").eq("vehicle_id", vehicleId).eq("recorded_at", recordedAt);
      expect(bData).toEqual([]);

      const { data: aData } = await a.client.from("signals").select("*").eq("vehicle_id", vehicleId).eq("recorded_at", recordedAt);
      expect(aData?.length).toBe(1);
    } finally {
      await admin.from("signals").delete().eq("vehicle_id", vehicleId).eq("name", "Soc").eq("recorded_at", recordedAt);
    }
  });
});
