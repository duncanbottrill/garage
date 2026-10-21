import { describe, it, expect, beforeAll } from "vitest";
import { createClient } from "@supabase/supabase-js";
let jwt = "", ownerId = "";
const admin = () => createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  delete process.env.UPSTASH_REDIS_REST_URL;
  await admin().auth.admin.createUser({ email: "usage@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
  const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!); const s = await c.auth.signInWithPassword({ email: "usage@test.local", password: "pass-1234" });
  jwt = s.data.session!.access_token; ownerId = s.data.user!.id;
});
const post = async (body: unknown, auth = `Bearer ${jwt}`) => {
  const { POST } = await import("@/app/api/usage/route");
  return POST(new Request("http://g/api/usage", { method: "POST", headers: { authorization: auth, "content-type": "application/json" }, body: JSON.stringify(body) }));
};
const commands = async () => { const { data } = await admin().from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "commands").maybeSingle(); return Number(data?.count ?? 0); };
describe("usage route", () => {
  it("requires auth", async () => { expect((await post({ category: "commands" }, "Bearer nope")).status).toBe(401); });
  it("counts a report without an id every time", async () => {
    const before = await commands();
    expect((await post({ category: "commands", count: 2 })).status).toBe(200);
    expect((await post({ category: "commands", count: 2 })).status).toBe(200);
    expect(await commands()).toBe(before + 4);
  });
  it("counts a report_id once, however often it is sent", async () => {
    const before = await commands();
    const report_id = "7f0a1c2e-9b3d-4e5f-8a6b-1c2d3e4f5a6b";
    const first = await post({ category: "commands", count: 3, report_id }); expect(first.status).toBe(200); expect((await first.json()).counted).toBe(true);
    const again = await post({ category: "commands", count: 3, report_id }); expect(again.status).toBe(200); expect((await again.json()).counted).toBe(false);
    expect(await commands()).toBe(before + 3);
    const { data } = await admin().from("usage_reports").select("category, count").eq("owner_id", ownerId).eq("report_id", report_id).single();
    expect(data).toEqual({ category: "commands", count: 3 });
  });
  it("rejects a malformed report_id", async () => {
    expect((await post({ category: "commands", report_id: "not-a-uuid" })).status).toBe(400);
    expect((await post({ category: "commands", report_id: 12 })).status).toBe(400);
  });
  it("still rejects bad counts and categories", async () => {
    expect((await post({ category: "commands", count: 1.5 })).status).toBe(400);
    expect((await post({ category: "data" })).status).toBe(400);
  });
});
