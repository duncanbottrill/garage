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
});
