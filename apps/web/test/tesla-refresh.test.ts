import { describe, it, expect, beforeAll, afterAll, vi } from "vitest";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { encryptToken } from "@garage/core";
function failingUpdates(real: SupabaseClient, shouldFail: (owner: string, values: any) => boolean, counter: { n: number }): SupabaseClient {
  return new Proxy(real, { get(t, p, r) {
    if (p !== "from") return Reflect.get(t, p, r);
    return (table: string) => {
      const q: any = (t as any).from(table);
      if (table !== "tesla_credentials") return q;
      const origUpdate = q.update.bind(q);
      q.update = (values: any) => { const u: any = origUpdate(values); const origEq = u.eq.bind(u);
        u.eq = (col: string, val: string) => { if (shouldFail(val, values)) { counter.n++; return Promise.resolve({ data: null, error: { message: "simulated db failure" } }); } return origEq(col, val); };
        return u; };
      return q;
    };
  } }) as SupabaseClient;
}
// the lock claim/release only ever sets refresh_lock_until — never intercept those, so the
// atomic claim UPDATE keeps its real .or().select() chain and the lock is always released.
const isLockWrite = (values: any) => Object.keys(values).length === 1 && "refresh_lock_until" in values;
const KEY = Buffer.alloc(32, 1).toString("base64"); let ownerId = "";
// owners created by the backoff/fencing tests below; some of those scenarios intentionally
// leave a row due (or due-but-backed-off) at some point mid-test, so we clean them up here
// rather than letting them leak into another test file's unfiltered refreshAll() sweep.
const backoffOwners: string[] = [];
afterAll(async () => {
  if (!backoffOwners.length) return;
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.from("tesla_credentials").delete().in("owner_id", backoffOwners);
});
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
    const r1 = await refreshAll({ fetch: f as any, ownerId }); expect(r1.rotated).toContain(ownerId); expect(f).toHaveBeenCalledTimes(1);
    const r2 = await refreshAll({ fetch: f as any, ownerId }); expect(r2.rotated).not.toContain(ownerId); expect(f).toHaveBeenCalledTimes(1); // fresh token → skipped
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("tesla_credentials").select("access_token").eq("owner_id", ownerId).single(); expect(data?.access_token).toBe("A2");
  });
  it("records failures without throwing", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.from("tesla_credentials").update({ access_expires_at: new Date().toISOString() }).eq("owner_id", ownerId);
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const r = await refreshAll({ fetch: (async () => new Response("nope", { status: 401 })) as any, ownerId });
    expect(r.failed[0]?.owner_id).toBe(ownerId);
    const { data } = await admin.from("tesla_credentials").select("last_error").eq("owner_id", ownerId).single(); expect(data?.last_error).toMatch(/401/);
  });
  it("cron route needs the secret", async () => { const { GET } = await import("@/app/api/cron/tesla-refresh/route"); expect((await GET(new Request("http://g/api/cron/tesla-refresh"))).status).toBe(403); });
  it("retries the store after a successful Tesla rotation and keeps the new token", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    await admin.from("tesla_credentials").update({ refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-A", KEY)).toString("hex"), access_expires_at: new Date().toISOString(), last_error: null, refresh_failures: 0, next_refresh_at: null }).eq("owner_id", ownerId);
    const counter = { n: 0 }; let fails = 1; // first store attempt fails, second succeeds
    const client = failingUpdates(admin, (o, values) => o === ownerId && !isLockWrite(values) && fails-- > 0, counter);
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "A-retry", refresh_token: "RT-B", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, client, sleep: async () => {}, ownerId });
    expect(f).toHaveBeenCalledTimes(1); expect(counter.n).toBe(1); expect(r.rotated).toContain(ownerId);
    const { data } = await admin.from("tesla_credentials").select("access_token").eq("owner_id", ownerId).single(); expect(data?.access_token).toBe("A-retry");
  });
  it("isolates a row whose writes all fail and still processes the others", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const u2 = await admin.auth.admin.createUser({ email: "rot2@test.local", password: "pass-1234", email_confirm: true });
    const owner2 = u2.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find(x => x.email === "rot2@test.local")!.id;
    const due = new Date().toISOString();
    // Bulk upsert sends the union of keys across all rows, so an explicit refresh_failures/
    // next_refresh_at on one row and not the other would null out the NOT NULL
    // refresh_failures column on whichever row omits it — set both explicitly on every row.
    await admin.from("tesla_credentials").upsert([
      { owner_id: ownerId, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-X", KEY)).toString("hex"), access_token: "x", access_expires_at: due, refresh_failures: 0, next_refresh_at: null },
      { owner_id: owner2,  refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-Y", KEY)).toString("hex"), access_token: "y", access_expires_at: due, refresh_failures: 0, next_refresh_at: null },
    ]);
    const counter = { n: 0 }; const client = failingUpdates(admin, (o, values) => o === ownerId && !isLockWrite(values), counter);
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "A-new", refresh_token: "RT-new", expires_in: 28800 }), { status: 200 }));
    // Two separately-scoped calls (explicit ownerId each) rather than one unfiltered sweep, so
    // a due/locked row left behind by another test file can never leak into this assertion.
    const r1 = await refreshAll({ fetch: f as any, client, sleep: async () => {}, ownerId });
    const r2 = await refreshAll({ fetch: f as any, client, sleep: async () => {}, ownerId: owner2 });
    expect(r1.failed.find(x => x.owner_id === ownerId)?.error).toMatch(/rotated_unstored/);
    expect(r2.rotated).toContain(owner2);
    expect(counter.n).toBe(4); // 3 store attempts + 1 last_error attempt, all failed, none thrown
  });

  async function makeOwner(admin: SupabaseClient, email: string) {
    const u = await admin.auth.admin.createUser({ email, password: "pass-1234", email_confirm: true });
    return u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find((x) => x.email === email)!.id;
  }

  it("ownerId filter processes only that owner", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const ownerA = await makeOwner(admin, "lock-a@test.local");
    const ownerB = await makeOwner(admin, "lock-b@test.local");
    const due = new Date().toISOString();
    await admin.from("tesla_credentials").upsert([
      { owner_id: ownerA, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-A1", KEY)).toString("hex"), access_token: "a1", access_expires_at: due },
      { owner_id: ownerB, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-B1", KEY)).toString("hex"), access_token: "b1", access_expires_at: due },
    ]);
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "A-only", refresh_token: "RT-A2", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, ownerId: ownerA, sleep: async () => {} });
    expect(r.rotated).toEqual([ownerA]); expect(f).toHaveBeenCalledTimes(1);
    const { data: b } = await admin.from("tesla_credentials").select("access_token").eq("owner_id", ownerB).single();
    expect(b?.access_token).toBe("b1"); // untouched — never even considered
  });

  it("a row locked by someone else is reported as locked and Tesla is not called", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "lock-c@test.local");
    const due = new Date().toISOString();
    const lockUntil = new Date(Date.now() + 60_000).toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-C1", KEY)).toString("hex"), access_token: "c1", access_expires_at: due, refresh_lock_until: lockUntil });
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "should-not-happen", refresh_token: "x", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, ownerId: owner, sleep: async () => {} });
    expect(r.failed).toEqual([{ owner_id: owner, error: "locked" }]);
    expect(f).not.toHaveBeenCalled();
    const { data } = await admin.from("tesla_credentials").select("access_token, refresh_lock_until").eq("owner_id", owner).single();
    expect(data?.access_token).toBe("c1"); // not rotated
    expect(data?.refresh_lock_until).not.toBeNull(); // we never owned the lock, so we never clear it
  });

  it("releases the lock after a successful rotation", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "lock-d@test.local");
    const due = new Date().toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-D1", KEY)).toString("hex"), access_token: "d1", access_expires_at: due });
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "D2", refresh_token: "RT-D2", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, ownerId: owner, sleep: async () => {} });
    expect(r.rotated).toContain(owner);
    const { data } = await admin.from("tesla_credentials").select("refresh_lock_until").eq("owner_id", owner).single();
    expect(data?.refresh_lock_until).toBeNull();
  });

  it("releases the lock after a failed rotation", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "lock-e@test.local");
    const due = new Date().toISOString();
    // Reset refresh_failures/next_refresh_at explicitly: this test reuses a fixed owner email,
    // so on a second suite run (no `supabase db reset` in between) the row could still be
    // carrying backoff state left over from this same test's own previous run.
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-E1", KEY)).toString("hex"), access_token: "e1", access_expires_at: due, refresh_failures: 0, next_refresh_at: null });
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response("nope", { status: 401 }));
    const r = await refreshAll({ fetch: f as any, ownerId: owner, sleep: async () => {} });
    expect(r.failed.find((x) => x.owner_id === owner)?.error).toMatch(/401/);
    const { data } = await admin.from("tesla_credentials").select("refresh_lock_until").eq("owner_id", owner).single();
    expect(data?.refresh_lock_until).toBeNull();
  });

  it("store is fenced on the consumed refresh token, not the lock", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "fence-store@test.local"); backoffOwners.push(owner);
    const due = new Date().toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-FS1", KEY)).toString("hex"), access_token: "fs1", access_expires_at: due });
    // Simulate the lock expiring (or being force-cleared) out from under us: on the first store
    // attempt — identified by the update payload carrying access_token, which only the store
    // update does — clear refresh_lock_until on the real row BEFORE letting the real update run.
    // If the store were still fenced on refresh_lock_until this would make it match zero rows;
    // fenced on refresh_token_enc instead, the token we consumed hasn't changed, so it must
    // still land.
    let intercepted = false;
    const client = new Proxy(admin, { get(t, p, r) {
      if (p !== "from") return Reflect.get(t, p, r);
      return (table: string) => {
        const q: any = (t as any).from(table);
        if (table !== "tesla_credentials") return q;
        const origUpdate = q.update.bind(q);
        q.update = (values: any) => {
          const u: any = origUpdate(values);
          if (!intercepted && "access_token" in values) {
            intercepted = true;
            const origThen = u.then.bind(u);
            u.then = (resolve: any, reject: any) =>
              admin.from("tesla_credentials").update({ refresh_lock_until: null }).eq("owner_id", owner)
                .then(() => origThen(resolve, reject));
          }
          return u;
        };
        return q;
      };
    } }) as SupabaseClient;
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "FS2", refresh_token: "RT-FS2", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, client, sleep: async () => {}, ownerId: owner });
    expect(r.rotated).toContain(owner);
    const { data } = await admin.from("tesla_credentials").select("access_token").eq("owner_id", owner).single();
    expect(data?.access_token).toBe("FS2");
  });

  it("a failed rotation sets backoff and the next sweep skips the row", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "fence-backoff@test.local"); backoffOwners.push(owner);
    const due = new Date().toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-BK1", KEY)).toString("hex"), access_token: "bk1", access_expires_at: due });
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f1 = vi.fn(async () => new Response("nope", { status: 401 }));
    const r = await refreshAll({ fetch: f1 as any, client: admin, sleep: async () => {}, ownerId: owner });
    expect(r.failed.find((x) => x.owner_id === owner)?.error).toMatch(/refresh 401/);
    const { data } = await admin.from("tesla_credentials").select("refresh_failures, next_refresh_at").eq("owner_id", owner).single();
    expect(data?.refresh_failures).toBe(1);
    const nextAt = new Date(data!.next_refresh_at as string).getTime();
    expect(nextAt).toBeGreaterThan(Date.now());
    expect(nextAt).toBeLessThan(Date.now() + 3 * 60_000); // ~2 minutes out: 2^1 * 60_000ms
    const f2 = vi.fn(async () => new Response(JSON.stringify({ access_token: "should-not-happen", refresh_token: "x", expires_in: 28800 }), { status: 200 }));
    const r2 = await refreshAll({ fetch: f2 as any, client: admin, sleep: async () => {}, ownerId: owner });
    expect(f2).not.toHaveBeenCalled();
    expect(r2.skipped).toContain(owner);
  });

  it("a token_changed store outcome is reported without backoff or last_error", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "fence-token-changed@test.local"); backoffOwners.push(owner);
    const due = new Date().toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-TC1", KEY)).toString("hex"), access_token: "tc1", access_expires_at: due, refresh_failures: 0, next_refresh_at: null, last_error: null });
    // On the FIRST store update() (identified by the payload carrying access_token), simulate a
    // concurrent re-auth: rotate refresh_token_enc on the real row before letting the real
    // (token-fenced) update run. Its WHERE clause then matches zero rows, which is exactly the
    // token_changed case — no retry, no backoff, no last_error — and the re-authed value must survive.
    let intercepted = false;
    const storeAttempts = { n: 0 };
    const client = new Proxy(admin, { get(t, p, r) {
      if (p !== "from") return Reflect.get(t, p, r);
      return (table: string) => {
        const q: any = (t as any).from(table);
        if (table !== "tesla_credentials") return q;
        const origUpdate = q.update.bind(q);
        q.update = (values: any) => {
          const u: any = origUpdate(values);
          if ("access_token" in values) storeAttempts.n++;
          if (!intercepted && "access_token" in values) {
            intercepted = true;
            const origThen = u.then.bind(u);
            u.then = (resolve: any, reject: any) =>
              admin.from("tesla_credentials")
                .update({ refresh_token_enc: "\\x" + Buffer.from(encryptToken("RE-AUTHED", KEY)).toString("hex") })
                .eq("owner_id", owner)
                .then(() => origThen(resolve, reject));
          }
          return u;
        };
        return q;
      };
    } }) as SupabaseClient;
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "TC2", refresh_token: "RT-TC2", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, client, sleep: async () => {}, ownerId: owner });
    expect(r.failed).toContainEqual({ owner_id: owner, error: "token_changed" });
    expect(r.rotated).not.toContain(owner);
    expect(f).toHaveBeenCalledTimes(1);
    expect(storeAttempts.n).toBe(1); // token_changed stops immediately — no retry of the store update()
    const { data } = await admin.from("tesla_credentials").select("last_error, refresh_failures, next_refresh_at, refresh_lock_until, refresh_token_enc").eq("owner_id", owner).single();
    expect(data?.last_error).toBeNull();
    expect(data?.refresh_failures).toBe(0);
    expect(data?.next_refresh_at).toBeNull();
    expect(data?.refresh_lock_until).toBeNull();
    const hex = String(data!.refresh_token_enc).replace(/^\\x/, "");
    const { decryptToken } = await import("@garage/core");
    expect(decryptToken(new Uint8Array(Buffer.from(hex, "hex")), KEY)).toBe("RE-AUTHED");
  });

  it("a successful rotation resets backoff", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "fence-reset@test.local"); backoffOwners.push(owner);
    const past = new Date(Date.now() - 60_000).toISOString();
    const due = new Date().toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-RS1", KEY)).toString("hex"), access_token: "rs1", access_expires_at: due, refresh_failures: 3, next_refresh_at: past });
    const { refreshAll } = await import("@/lib/tesla-refresh");
    const f = vi.fn(async () => new Response(JSON.stringify({ access_token: "RS2", refresh_token: "RT-RS2", expires_in: 28800 }), { status: 200 }));
    const r = await refreshAll({ fetch: f as any, client: admin, sleep: async () => {}, ownerId: owner });
    expect(r.rotated).toContain(owner);
    const { data } = await admin.from("tesla_credentials").select("refresh_failures, next_refresh_at").eq("owner_id", owner).single();
    expect(data?.refresh_failures).toBe(0);
    expect(data?.next_refresh_at).toBeNull();
  });

  it("storeCredentials resets backoff", async () => {
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const owner = await makeOwner(admin, "storecreds-reset@test.local"); backoffOwners.push(owner);
    const future = new Date(Date.now() + 3600_000).toISOString();
    await admin.from("tesla_credentials").upsert({ owner_id: owner, refresh_token_enc: "\\x" + Buffer.from(encryptToken("RT-SC1", KEY)).toString("hex"), access_token: "sc1", access_expires_at: future, refresh_failures: 5, next_refresh_at: future, refresh_lock_until: future });
    const { storeCredentials } = await import("@/lib/tesla-auth");
    await storeCredentials(owner, { access_token: "A", refresh_token: "R", expires_in: 28800 });
    const { data } = await admin.from("tesla_credentials").select("refresh_failures, next_refresh_at, refresh_lock_until").eq("owner_id", owner).single();
    expect(data?.refresh_failures).toBe(0);
    expect(data?.next_refresh_at).toBeNull();
    expect(data?.refresh_lock_until).toBeNull();
  });
});
