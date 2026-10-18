import { describe, it, expect, beforeAll, beforeEach, vi, afterEach } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { encryptToken } from "@garage/core";
let jwt = "", ownerId = "", vehicleId = "";
beforeEach(async () => { const { _resetLimiterForTests } = await import("@/lib/ratelimit"); _resetLimiterForTests(); });
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.auth.admin.createUser({ email: "api@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
  const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!); const s = await c.auth.signInWithPassword({ email: "api@test.local", password: "pass-1234" });
  jwt = s.data.session!.access_token; ownerId = s.data.user!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x00", access_token: "TOK", access_expires_at: new Date(Date.now() + 4 * 3600_000).toISOString() });
  const { data: v } = await admin.from("vehicles").upsert({ owner_id: ownerId, vin: "VINAPI", tesla_vehicle_id: 42 }, { onConflict: "vin" }).select("id").single(); vehicleId = v!.id;
  await admin.from("vehicle_state").upsert({ vehicle_id: vehicleId, owner_id: ownerId }, { onConflict: "vehicle_id", ignoreDuplicates: true });
});
afterEach(() => vi.unstubAllGlobals());
const H = () => ({ authorization: `Bearer ${jwt}`, "content-type": "application/json" });
describe("api routes", () => {
  it("token requires auth and returns the stored token", async () => {
    const { GET } = await import("@/app/api/token/route");
    expect((await GET(new Request("http://g/api/token"))).status).toBe(401);
    const r = await GET(new Request("http://g/api/token", { headers: H() })); expect((await r.json()).access_token).toBe("TOK");
  });
  it("token refreshes a near-expiry token before returning it", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.auth.admin.createUser({ email: "api-near-expiry@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
    const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!);
    const s = await c.auth.signInWithPassword({ email: "api-near-expiry@test.local", password: "pass-1234" });
    const jwt2 = s.data.session!.access_token; const owner2 = s.data.user!.id;
    await admin.from("tesla_credentials").upsert({ owner_id: owner2, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-API", process.env.TOKEN_ENC_KEY!)).toString("hex"), access_token: "OLD-API", access_expires_at: new Date(Date.now() + 10 * 60_000).toISOString() });
    const real = globalThis.fetch;
    vi.stubGlobal("fetch", vi.fn(async (u: any, init?: any) => String(u).includes("fleet-auth.prd.vn.cloud.tesla.com")
      ? new Response(JSON.stringify({ access_token: "NEW-API", refresh_token: "RT-API2", expires_in: 28800 }), { status: 200 })
      : real(u, init)));
    const { GET } = await import("@/app/api/token/route");
    const r = await GET(new Request("http://g/api/token", { headers: { authorization: `Bearer ${jwt2}` } }));
    expect((await r.json()).access_token).toBe("NEW-API");
  });
  it("usage increments the ledger", async () => {
    const { POST } = await import("@/app/api/usage/route");
    await POST(new Request("http://g/api/usage", { method: "POST", headers: H(), body: JSON.stringify({ category: "commands", count: 3 }) }));
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "commands").single(); expect(Number(data?.count)).toBeGreaterThanOrEqual(3);
  });
  it("usage rejects a non-numeric count", async () => {
    const { POST } = await import("@/app/api/usage/route");
    const r = await POST(new Request("http://g/api/usage", { method: "POST", headers: H(), body: JSON.stringify({ category: "commands", count: "abc" }) }));
    expect(r.status).toBe(400); expect((await r.json()).error).toBe("bad_count");
  });
  it("usage clamps an out-of-range count to 100", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data: before } = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "wakes").maybeSingle();
    const { POST } = await import("@/app/api/usage/route");
    const r = await POST(new Request("http://g/api/usage", { method: "POST", headers: H(), body: JSON.stringify({ category: "wakes", count: 250 }) }));
    expect(r.status).toBe(200);
    const { data: after } = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "wakes").single();
    expect(Number(after?.count) - Number(before?.count ?? 0)).toBe(100);
  });
  it("vehicle-data fetches, maps, upserts and counts", async () => {
    const real = globalThis.fetch;
    vi.stubGlobal("fetch", vi.fn(async (u: any, init?: any) => String(u).startsWith("https://fleet.test")
      ? (String(u).includes("vehicle_data") ? new Response(JSON.stringify({ response: { state: "online", charge_state: { battery_level: 55 } } }), { status: 200 }) : new Response("{}", { status: 404 }))
      : real(u, init)));
    const { POST } = await import("@/app/api/vehicle-data/route");
    const r = await POST(new Request("http://g/api/vehicle-data", { method: "POST", headers: H(), body: JSON.stringify({ vehicle_id: vehicleId }) }));
    expect(r.status).toBe(200); expect((await r.json()).state.soc).toBe(55);
    const vehicleDataCall = (globalThis.fetch as any).mock.calls.find((c: any) => String(c[0]).includes("vehicle_data"));
    expect(String(vehicleDataCall?.[0])).toContain("/api/1/vehicles/VINAPI/vehicle_data");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("vehicle_state").select("soc").eq("vehicle_id", vehicleId).single(); expect(Number(data?.soc)).toBe(55);
  });
  it("vehicle-data maps 408 to asleep and never wakes", async () => {
    const real = globalThis.fetch;
    const f = vi.fn(async (u: any, init?: any) => String(u).startsWith("https://fleet.test")
      ? new Response(JSON.stringify({ error: "vehicle unavailable" }), { status: 408 })
      : real(u, init));
    vi.stubGlobal("fetch", f);
    const { POST } = await import("@/app/api/vehicle-data/route");
    const r = await POST(new Request("http://g/api/vehicle-data", { method: "POST", headers: H(), body: JSON.stringify({ vehicle_id: vehicleId }) }));
    expect(r.status).toBe(409); expect(f.mock.calls.some((c: any) => String(c[0]).includes("wake_up"))).toBe(false);
  });
  it("connection route returns health for the caller", async () => {
    const { GET } = await import("@/app/api/connection/route");
    expect((await GET(new Request("http://g/api/connection"))).status).toBe(401);
    const r = await GET(new Request("http://g/api/connection", { headers: H() })); const j = await r.json(); expect(j.connected).toBe(true); expect(j.access_token).toBeUndefined();
  });
  it("allow-list blocks users not listed", async () => {
    try {
      process.env.ALLOWED_OWNER_IDS = "00000000-0000-0000-0000-000000000000";
      const { GET } = await import("@/app/api/token/route");
      expect((await GET(new Request("http://g/api/token", { headers: H() }))).status).toBe(401);
    } finally {
      delete process.env.ALLOWED_OWNER_IDS;
    }
  });
  it("vehicle-data refuses when budget_mode is minimal", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.from("vehicles").update({ budget_mode: "minimal" }).eq("id", vehicleId);
    const { POST } = await import("@/app/api/vehicle-data/route");
    const r = await POST(new Request("http://g/api/vehicle-data", { method: "POST", headers: H(), body: JSON.stringify({ vehicle_id: vehicleId }) }));
    expect(r.status).toBe(429); expect((await r.json()).error).toBe("budget_minimal");
    await admin.from("vehicles").update({ budget_mode: "normal" }).eq("id", vehicleId);
  });
});
