import { describe, it, expect, beforeAll } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { hashSecret } from "@/lib/bridge-auth";
let ownerId = ""; let secret = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", ADMIN_SECRET: "adm", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email: "bridge@test.local", password: "pass-1234", email_confirm: true });
  ownerId = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find(x => x.email === "bridge@test.local")!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x00", access_token: "BRIDGE-TOK", access_expires_at: new Date(Date.now() + 4 * 3600_000).toISOString() });
});
describe("bridge token", () => {
  it("admin mints a secret once and stores only its hash", async () => {
    const { POST } = await import("@/app/api/admin/bridge-secret/route");
    const r = await POST(new Request("http://g/api/admin/bridge-secret", { method: "POST", headers: { authorization: "Bearer adm", "content-type": "application/json" }, body: JSON.stringify({ owner_id: ownerId }) }));
    expect(r.status).toBe(200); const body = await r.json(); secret = body.secret; expect(secret).toMatch(/^gbs_[A-Za-z0-9_-]{48}$/);
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("bridge_secrets").select("secret_hash").eq("owner_id", ownerId).single();
    expect(data?.secret_hash).toBe(hashSecret(secret)); expect(data?.secret_hash).not.toContain(secret.slice(4, 20));
  });
  it("admin route refuses without the admin secret", async () => {
    const { POST } = await import("@/app/api/admin/bridge-secret/route");
    expect((await POST(new Request("http://g/x", { method: "POST", body: "{}" }))).status).toBe(403);
  });
  it("admin route refuses the cron secret — it is not the admin secret", async () => {
    const { POST } = await import("@/app/api/admin/bridge-secret/route");
    const r = await POST(new Request("http://g/x", { method: "POST", headers: { authorization: "Bearer c", "content-type": "application/json" }, body: JSON.stringify({ owner_id: ownerId }) }));
    expect(r.status).toBe(403);
  });
  it("bridge token route returns the token for a valid secret", async () => {
    const { GET } = await import("@/app/api/bridge/token/route");
    const r = await GET(new Request("http://g/api/bridge/token", { headers: { "x-bridge-secret": secret } }));
    expect(r.status).toBe(200); expect((await r.json()).access_token).toBe("BRIDGE-TOK");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("bridge_secrets").select("last_used_at").eq("owner_id", ownerId).single(); expect(data?.last_used_at).not.toBeNull();
  });
  it("bridge token route rejects a wrong or missing secret", async () => {
    const { GET } = await import("@/app/api/bridge/token/route");
    expect((await GET(new Request("http://g/api/bridge/token"))).status).toBe(401);
    expect((await GET(new Request("http://g/api/bridge/token", { headers: { "x-bridge-secret": "gbs_wrong" } }))).status).toBe(401);
  });
  it("re-minting rotates: the old secret stops working", async () => {
    const { POST } = await import("@/app/api/admin/bridge-secret/route");
    await POST(new Request("http://g/x", { method: "POST", headers: { authorization: "Bearer adm", "content-type": "application/json" }, body: JSON.stringify({ owner_id: ownerId }) }));
    const { GET } = await import("@/app/api/bridge/token/route");
    expect((await GET(new Request("http://g/api/bridge/token", { headers: { "x-bridge-secret": secret } }))).status).toBe(401);
  });
});
