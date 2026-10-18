import { describe, it, expect, beforeAll, vi } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { encryptToken } from "@garage/core";

const KEY = Buffer.alloc(32, 1).toString("base64");
const fastSleep = () => Promise.resolve();

beforeAll(() => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet", TOKEN_ENC_KEY: KEY, CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
});

async function makeOwner(email: string) {
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email, password: "pass-1234", email_confirm: true });
  const id = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find((x) => x.email === email)!.id;
  return { admin, id };
}

describe("currentAccessToken lazy refresh", () => {
  it("refreshes a token expiring in 10 minutes", async () => {
    const { admin, id } = await makeOwner("lazy-e@test.local");
    await admin.from("tesla_credentials").upsert({ owner_id: id, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-E", KEY)).toString("hex"), access_token: "OLD-E", access_expires_at: new Date(Date.now() + 10 * 60_000).toISOString() });
    const { currentAccessToken } = await import("@/lib/credentials");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "NEW-E", refresh_token: "RT-E2", expires_in: 28800 }), { status: 200 }));
    const t = await currentAccessToken(id, { fetch: f as any, sleep: fastSleep });
    expect(f).toHaveBeenCalledTimes(1);
    expect(t?.token).toBe("NEW-E");
  });

  it("does not refresh a token expiring in 5 hours", async () => {
    const { admin, id } = await makeOwner("lazy-f@test.local");
    await admin.from("tesla_credentials").upsert({ owner_id: id, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-F", KEY)).toString("hex"), access_token: "FRESH-F", access_expires_at: new Date(Date.now() + 5 * 3600_000).toISOString() });
    const { currentAccessToken } = await import("@/lib/credentials");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "SHOULD-NOT-HAPPEN", refresh_token: "x", expires_in: 28800 }), { status: 200 }));
    const t = await currentAccessToken(id, { fetch: f as any, sleep: fastSleep });
    expect(f).not.toHaveBeenCalled();
    expect(t?.token).toBe("FRESH-F");
  });

  it("returns the stored token without calling Tesla when the row is locked by someone else", async () => {
    const { admin, id } = await makeOwner("lazy-g@test.local");
    const lockUntil = new Date(Date.now() + 60_000).toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: id, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-G", KEY)).toString("hex"), access_token: "STILL-G", access_expires_at: new Date(Date.now() + 10 * 60_000).toISOString(), refresh_lock_until: lockUntil });
    const { currentAccessToken } = await import("@/lib/credentials");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "SHOULD-NOT-HAPPEN", refresh_token: "x", expires_in: 28800 }), { status: 200 }));
    const t = await currentAccessToken(id, { fetch: f as any, sleep: fastSleep });
    expect(f).not.toHaveBeenCalled();
    expect(t?.token).toBe("STILL-G");
  });

  it("two concurrent calls for the same owner result in exactly one Tesla call", async () => {
    const { admin, id } = await makeOwner("lazy-h@test.local");
    await admin.from("tesla_credentials").upsert({ owner_id: id, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-H", KEY)).toString("hex"), access_token: "OLD-H", access_expires_at: new Date(Date.now() + 10 * 60_000).toISOString() });
    const { currentAccessToken } = await import("@/lib/credentials");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "NEW-H", refresh_token: "RT-H2", expires_in: 28800 }), { status: 200 }));
    const [a, b] = await Promise.all([
      currentAccessToken(id, { fetch: f as any, sleep: fastSleep }),
      currentAccessToken(id, { fetch: f as any, sleep: fastSleep }),
    ]);
    expect(f).toHaveBeenCalledTimes(1);
    expect(a?.token).toBeTruthy();
    expect(b?.token).toBeTruthy();
  });
});
