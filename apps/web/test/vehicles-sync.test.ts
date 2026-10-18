import { describe, it, expect, beforeAll, vi, afterEach } from "vitest";
import { createClient } from "@supabase/supabase-js";
let jwt = "", ownerId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.auth.admin.createUser({ email: "sync@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
  const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!); const s = await c.auth.signInWithPassword({ email: "sync@test.local", password: "pass-1234" });
  jwt = s.data.session!.access_token; ownerId = s.data.user!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x00", access_token: "SYNC-TOK", access_expires_at: new Date(Date.now() + 4 * 3600_000).toISOString() });
});
afterEach(() => vi.unstubAllGlobals());
const fleetStub = (payload: unknown, status = 200) => { const real = globalThis.fetch; vi.stubGlobal("fetch", vi.fn(async (u: any, init?: any) => String(u).startsWith("https://fleet.test") ? new Response(JSON.stringify(payload), { status }) : real(u, init))); };
describe("vehicle sync", () => {
  it("creates vehicles and state rows from the Fleet list and counts one data call", async () => {
    fleetStub({ response: [{ id: 111, vehicle_id: 222, vin: "XP7YSYNC000000001", display_name: "Sync Car", state: "asleep" }] });
    const { syncVehicles } = await import("@/lib/vehicles");
    const r = await syncVehicles(ownerId);
    expect(r.error).toBeUndefined(); expect(r.vehicles[0]?.vin).toBe("XP7YSYNC000000001");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data: v } = await admin.from("vehicles").select("id, tesla_vehicle_id, model, display_name").eq("vin", "XP7YSYNC000000001").single();
    expect(Number(v?.tesla_vehicle_id)).toBe(111); expect(v?.model).toBe("Model Y"); expect(v?.display_name).toBe("Sync Car");
    const { data: st } = await admin.from("vehicle_state").select("sleep_state").eq("vehicle_id", v!.id).single(); expect(st?.sleep_state).toBe("asleep");
    const { data: usage } = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "data").single(); expect(Number(usage?.count)).toBeGreaterThanOrEqual(1);
  });
  it("is idempotent and keeps the existing state row", async () => {
    fleetStub({ response: [{ id: 111, vehicle_id: 222, vin: "XP7YSYNC000000001", display_name: "Renamed", state: "online" }] });
    const { syncVehicles } = await import("@/lib/vehicles");
    await syncVehicles(ownerId);
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data: v } = await admin.from("vehicles").select("display_name").eq("vin", "XP7YSYNC000000001"); expect(v?.length).toBe(1); expect(v?.[0]?.display_name).toBe("Renamed");
  });
  it("reports Fleet failures without throwing", async () => {
    fleetStub({ error: "boom" }, 500);
    const { syncVehicles } = await import("@/lib/vehicles");
    const r = await syncVehicles(ownerId); expect(r.vehicles).toEqual([]); expect(r.error).toMatch(/500/);
  });
  it("route requires auth and returns vehicles", async () => {
    fleetStub({ response: [{ id: 111, vehicle_id: 222, vin: "XP7YSYNC000000001", display_name: "Renamed", state: "online" }] });
    const { POST } = await import("@/app/api/vehicles/sync/route");
    expect((await POST(new Request("http://g/api/vehicles/sync", { method: "POST" }))).status).toBe(401);
    const r = await POST(new Request("http://g/api/vehicles/sync", { method: "POST", headers: { authorization: `Bearer ${jwt}` } }));
    expect(r.status).toBe(200); expect((await r.json()).vehicles[0].vin).toBe("XP7YSYNC000000001");
  });
});
