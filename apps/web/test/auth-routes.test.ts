import { describe, it, expect, beforeAll } from "vitest";
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
});
