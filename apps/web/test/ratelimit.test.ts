import { it, expect, beforeAll } from "vitest";
beforeAll(() => { Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", SUPABASE_URL: "http://x", SUPABASE_ANON_KEY: "a", SUPABASE_SERVICE_ROLE_KEY: "s", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" }); delete process.env.UPSTASH_REDIS_REST_URL; });
it("in-memory fallback enforces per-minute and per-day", async () => {
  const { limit } = await import("@/lib/ratelimit");
  for (let i = 0; i < 2; i++) expect((await limit("t", "u1", { perMinute: 2, perDay: 3 })).ok).toBe(true);
  expect((await limit("t", "u1", { perMinute: 2, perDay: 3 })).ok).toBe(false);
  expect((await limit("t", "u2", { perMinute: 2, perDay: 3 })).ok).toBe(true); // per user
});
