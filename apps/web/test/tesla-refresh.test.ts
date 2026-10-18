import { describe, it, expect, beforeAll, vi } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { encryptToken } from "@garage/core";
const KEY = Buffer.alloc(32, 1).toString("base64"); let ownerId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet", TOKEN_ENC_KEY: KEY, CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email: "rot@test.local", password: "pass-1234", email_confirm: true }); ownerId = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find(x => x.email === "rot@test.local")!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT1", KEY)).toString("hex"), access_token: "old", access_expires_at: new Date(Date.now() + 3600_000).toISOString() });
});
describe("refreshAll", () => {
  it("rotates once and stores the new pair", async () => {
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async (_u: any, init: any) => { expect(new URLSearchParams(init.body).get("refresh_token")).toBe("RT1"); return new Response(JSON.stringify({ access_token: "A2", refresh_token: "RT2", expires_in: 28800 }), { status: 200 }); });
    const r1 = await refreshAll({ fetch: f as any }); expect(r1.rotated).toContain(ownerId); expect(f).toHaveBeenCalledTimes(1);
    const r2 = await refreshAll({ fetch: f as any }); expect(r2.rotated).not.toContain(ownerId); expect(f).toHaveBeenCalledTimes(1); // fresh token → skipped
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("tesla_credentials").select("access_token").eq("owner_id", ownerId).single(); expect(data?.access_token).toBe("A2");
  });
  it("records failures without throwing", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.from("tesla_credentials").update({ access_expires_at: new Date().toISOString() }).eq("owner_id", ownerId);
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const r = await refreshAll({ fetch: (async () => new Response("nope", { status: 401 })) as any });
    expect(r.failed[0]?.owner_id).toBe(ownerId);
    const { data } = await admin.from("tesla_credentials").select("last_error").eq("owner_id", ownerId).single(); expect(data?.last_error).toMatch(/401/);
  });
  it("cron route needs the secret", async () => { const { GET } = await import("@/app/api/cron/tesla-refresh/route"); expect((await GET(new Request("http://g/api/cron/tesla-refresh"))).status).toBe(403); });
});
