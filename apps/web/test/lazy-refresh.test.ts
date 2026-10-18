import { describe, it, expect, beforeAll, afterAll, vi } from "vitest";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { encryptToken } from "@garage/core";

const KEY = Buffer.alloc(32, 1).toString("base64");
const fastSleep = () => Promise.resolve();
const createdOwners: string[] = [];

beforeAll(() => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet", TOKEN_ENC_KEY: KEY, CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
});

afterAll(async () => {
  // Some of the scenarios below intentionally leave a row locked or mid-flight at some point
  // during the test; make sure none of them are still due/locked afterwards so they can't leak
  // into another test file's unfiltered refreshAll() call, and so the suite stays green on a
  // second run without a `supabase db reset` in between.
  if (!createdOwners.length) return;
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.from("tesla_credentials").delete().in("owner_id", createdOwners);
});

async function makeOwner(email: string) {
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email, password: "pass-1234", email_confirm: true });
  const id = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find((x) => x.email === email)!.id;
  createdOwners.push(id);
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
    // Deterministic even though both callers race for the lock: the loser either observes
    // "locked" and polls for the winner's fresh row, or — if it claims after the winner has
    // already released — re-checks the claimed row's staleness inside the lock and skips.
    const [a, b] = await Promise.all([
      currentAccessToken(id, { fetch: f as any, sleep: fastSleep }),
      currentAccessToken(id, { fetch: f as any, sleep: fastSleep }),
    ]);
    expect(f).toHaveBeenCalledTimes(1);
    expect(a?.token).toBe("NEW-H");
    expect(b?.token).toBe("NEW-H");
    const usedTokens = f.mock.calls.map((c: any) => new URLSearchParams(c[1].body).get("refresh_token"));
    expect(new Set(usedTokens).size).toBe(usedTokens.length); // every Tesla call carried a distinct refresh token
  });

  it("claim-after-release: a caller whose pre-claim view was taken before the other rotated does not double-rotate", async () => {
    const { admin, id } = await makeOwner("lazy-j@test.local");
    const staleExpiresAt = new Date(Date.now() + 10 * 60_000).toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: id, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-J1", KEY)).toString("hex"), access_token: "OLD-J", access_expires_at: staleExpiresAt });
    const f = vi.fn(async (_u: any, init: any) => {
      const rt = new URLSearchParams(init.body).get("refresh_token");
      return new Response(JSON.stringify({ access_token: rt === "RT-J1" ? "NEW-J" : "SHOULD-NOT-HAPPEN", refresh_token: rt === "RT-J1" ? "RT-J2" : "x", expires_in: 28800 }), { status: 200 });
    });
    const { currentAccessToken } = await import("@/lib/credentials");

    // Caller A runs to completion first: rotates RT-J1 -> RT-J2 and releases the lock.
    const a = await currentAccessToken(id, { fetch: f as any, sleep: fastSleep, client: admin });
    expect(a?.token).toBe("NEW-J");

    // Caller B's pre-claim view was captured before A ran (stale, 10 minutes left, the old
    // refresh token). Simulate this by making the FIRST two reads against tesla_credentials
    // on B's client return that stale snapshot, while leaving every write (including the
    // claim UPDATE...RETURNING) hitting the real, already-rotated row. With the fix, B's claim
    // still succeeds (A released the lock), but the re-check inside the lock sees the claimed
    // row is fresh and skips instead of rotating again with A's already-consumed token.
    const staleSnapshot = { owner_id: id, access_token: "OLD-J", access_expires_at: staleExpiresAt };
    let staleSelectsLeft = 2;
    const bClient = new Proxy(admin, {
      get(t, p, r) {
        if (p !== "from") return Reflect.get(t, p, r);
        return (table: string) => {
          const q: any = (admin as any).from(table);
          if (table !== "tesla_credentials") return q;
          const origSelect = q.select.bind(q);
          q.select = (cols: string) => {
            if (staleSelectsLeft > 0) {
              staleSelectsLeft--;
              const stub: any = { eq: () => stub, maybeSingle: async () => ({ data: staleSnapshot, error: null }) };
              stub.then = (resolve: any) => resolve({ data: [staleSnapshot], error: null });
              return stub;
            }
            return origSelect(cols);
          };
          return q;
        };
      },
    }) as SupabaseClient;

    const b = await currentAccessToken(id, { fetch: f as any, sleep: fastSleep, client: bClient });

    expect(f).toHaveBeenCalledTimes(1); // Tesla called exactly once across A and B
    expect(a?.token).toBe("NEW-J");
    expect(b?.token).toBe("NEW-J"); // both results equal the new token
    const usedTokens = f.mock.calls.map((c: any) => new URLSearchParams(c[1].body).get("refresh_token"));
    expect(new Set(usedTokens).size).toBe(usedTokens.length); // every Tesla call carried a distinct refresh token
  });

  it("reclaims an expired lock and completes the rotation", async () => {
    const { admin, id } = await makeOwner("lazy-i@test.local");
    const pastLock = new Date(Date.now() - 5 * 60_000).toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: id, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-I", KEY)).toString("hex"), access_token: "OLD-I", access_expires_at: new Date(Date.now() + 10 * 60_000).toISOString(), refresh_lock_until: pastLock });
    const { currentAccessToken } = await import("@/lib/credentials");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "NEW-I", refresh_token: "RT-I2", expires_in: 28800 }), { status: 200 }));
    const t = await currentAccessToken(id, { fetch: f as any, sleep: fastSleep });
    expect(f).toHaveBeenCalledTimes(1);
    expect(t?.token).toBe("NEW-I");
    const { data } = await admin.from("tesla_credentials").select("refresh_lock_until").eq("owner_id", id).single();
    expect(data?.refresh_lock_until).toBeNull();
  });
});
