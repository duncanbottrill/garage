import { describe, it, expect, beforeAll, vi } from "vitest";
import { createClient } from "@supabase/supabase-js";
let jwt = ""; let ownerId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/auth/callback", TESLA_FLEET_BASE: "https://fleet", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://connected" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
  await admin.auth.admin.createUser({ email: "auth@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
  const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
  const s = await c.auth.signInWithPassword({ email: "auth@test.local", password: "pass-1234" }); jwt = s.data.session!.access_token; ownerId = s.data.user!.id;
});
describe("auth routes", () => {
  it("start requires a user", async () => { const { GET } = await import("@/app/auth/start/route"); expect((await GET(new Request("http://g/auth/start"))).status).toBe(401); });
  it("start redirects to Tesla and stores state", async () => {
    const { GET } = await import("@/app/auth/start/route");
    const r = await GET(new Request("http://g/auth/start", { headers: { authorization: `Bearer ${jwt}` } }));
    expect(r.status).toBe(302); const loc = new URL(r.headers.get("location")!); expect(loc.host).toBe("auth.tesla.com");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("oauth_states").select("owner_id").eq("state", loc.searchParams.get("state")!).single(); expect(data?.owner_id).toBe(ownerId);
  });
  it("callback rejects unknown state", async () => {
    const { GET } = await import("@/app/auth/callback/route");
    const r = await GET(new Request("http://g/auth/callback?code=x&state=nope")); expect(r.headers.get("location")).toContain("error=bad_state");
  });
  it("callback consumes the state even when Tesla sends no code (consent denied)", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.from("oauth_states").insert({ state: "denied-state", owner_id: ownerId, verifier: "v" });
    const { GET } = await import("@/app/auth/callback/route");
    const r = await GET(new Request("http://g/auth/callback?state=denied-state&error=access_denied"));
    expect(r.headers.get("location")).toContain("error=access_denied");
    const { data } = await admin.from("oauth_states").select("state").eq("state", "denied-state");
    expect(data).toEqual([]);
  });
  it("callback state cannot be replayed", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.from("oauth_states").insert({ state: "replay-state", owner_id: ownerId, verifier: "v" });
    const real = globalThis.fetch;
    vi.stubGlobal("fetch", vi.fn(async (u: any, init?: any) => String(u).includes("fleet-auth.prd.vn.cloud.tesla.com")
      ? new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 })
      : real(u, init)));
    const { GET } = await import("@/app/auth/callback/route");
    await GET(new Request("http://g/auth/callback?code=x&state=replay-state"));
    const r2 = await GET(new Request("http://g/auth/callback?code=x&state=replay-state"));
    vi.unstubAllGlobals();
    expect(r2.headers.get("location")).toContain("error=bad_state");
  });
});
