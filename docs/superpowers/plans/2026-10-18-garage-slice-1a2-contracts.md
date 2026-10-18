# Garage Slice 1A.2 — Contract Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the nine contract gaps the slice 1A final review found so the Home Assistant add-on (Plan 1B) and the Apple app (Plan 1C) can build against a stable backend.

**Architecture:** Same monorepo and conventions as Plan 1A (`docs/superpowers/plans/2026-10-18-garage-slice-1a-backend.md`). Changes land in `apps/web` (routes and libs), `packages/core` (mappers), and `supabase/migrations` (0006+). Every task keeps the existing test style: vitest against the local Supabase stack for anything touching the database, mocked `fetch` for Tesla.

**Tech Stack:** unchanged — Node 22, pnpm, TypeScript strict, Next.js 15.5, supabase-js v2, vitest, `@noble/ciphers`, `@upstash/ratelimit`.

**Branch:** `slice-1a2-contracts` from `main` (merge commit 5a01fa7).

## Global Constraints

- All of Plan 1A's Global Constraints still apply (metric units, RLS on every table, service-only SQL functions, single rotation at a time per owner, no automatic wakes, conventional commits with trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
- Tesla hosts: Fleet base from env `TESLA_FLEET_BASE` = `https://fleet-api.prd.eu.vn.cloud.tesla.com`; all `/token` calls to `https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token` (`TOKEN_URL` in `apps/web/src/lib/tesla-auth.ts`); authorize at `https://auth.tesla.com/oauth2/v3/authorize`.
- Fleet API vehicle paths use the **VIN**, not the numeric id: `/api/1/vehicles/{vin}/...`.
- Live data on the hosted project: owner `37b3272b-7899-45cf-8956-a156313b12cb`, vehicle `e821390b-f84c-4cd4-a125-9f2f3188e45f`, VIN `XP7YHCEL2SB594335`. Migrations must be additive and safe to apply to that project.
- jsonb shape for doors and windows is **driver/passenger**, not left/right: keys `driver_front`, `passenger_front`, `driver_rear`, `passenger_rear` (booleans, `true` = open). Fleet `vehicle_data` fields: `df`→driver_front, `pf`→passenger_front, `dr`→driver_rear, `pr`→passenger_rear; windows `fd_window`/`fp_window`/`rd_window`/`rp_window` likewise. TPMS keeps `fl/fr/rl/rr` (wheel positions are physical).
- Local test env: `export SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=$(supabase status -o json 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).ANON_KEY))') SUPABASE_SERVICE_ROLE_KEY=$(supabase status -o json 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).SERVICE_ROLE_KEY))')` and `supabase db reset` after adding a migration. Current counts: supabase 7, core 21, tokens 5, web 36.

---

## File structure

```
supabase/migrations/
  0006_bridge_secrets.sql          bridge_secrets table (service-only)
  0007_tesla_connection.sql        get_tesla_connection() for the app's token-health row
  0008_charge_amps.sql             vehicle_state.charge_amps
  0009_merge_vehicle_state.sql     merge_vehicle_state(p_vehicle, p_patch) deep-merge RPC
  0010_signals_partition_job.sql   ensure_signals_partitions() + pg_cron schedule
  0011_refresh_backoff.sql         tesla_credentials.refresh_failures, next_refresh_at
apps/web/src/lib/
  bridge-auth.ts                   hashSecret(), bridgeOwnerFromRequest(req)
  vehicles.ts                      syncVehicles(ownerId, opts)
  tesla-refresh.ts                 (modify) token-fenced store, backoff
  ratelimit.ts                     (modify) in-memory fallback, named limits
  supabase.ts                      (modify) owner allow-list in userFromRequest
apps/web/src/app/
  api/bridge/token/route.ts        GET, bridge-secret auth
  api/admin/bridge-secret/route.ts POST, cron-secret guarded, mints a bridge secret
  auth/start/route.ts              (modify) POST → { url }
  auth/callback/route.ts           (modify) best-effort vehicle sync after store
  api/vehicles/sync/route.ts       POST, JWT
  api/connection/route.ts          GET, JWT → token health
  api/vehicle-data/route.ts        (modify) VIN path, merge RPC, budget_mode check, tighter limit
packages/core/src/tesla/
  map-vehicle-data.ts              (modify) driver/passenger doors+windows
  map-telemetry.ts                 (modify) DoorState, windows, ChargeAmps; same keys
docs/
  superpowers/specs/...design.md   (modify) §4.1, §8 onboarding, §10
  runbooks/tesla-setup.md          (modify) bridge secret + sign-up lockdown steps
README.md                          (create) owed by Plan 1A Task 12
```

---

### Task 1: Bridge token access

**Files:**
- Create: `supabase/migrations/0006_bridge_secrets.sql`, `apps/web/src/lib/bridge-auth.ts`, `apps/web/src/app/api/bridge/token/route.ts`, `apps/web/src/app/api/admin/bridge-secret/route.ts`, `apps/web/test/bridge-token.test.ts`

**Interfaces:**
- Consumes: `currentAccessToken(ownerId)` from `apps/web/src/lib/credentials.ts`; `requireCron(req)`; `limit(key, userId)`.
- Produces:
  - Table `bridge_secrets(owner_id uuid pk, secret_hash text not null, created_at timestamptz, last_used_at timestamptz)`; RLS on, no user policies.
  - `hashSecret(secret: string): string` — hex SHA-256.
  - `bridgeOwnerFromRequest(req: Request): Promise<{ id: string } | null>` — reads header `x-bridge-secret`, looks up `bridge_secrets` by hash, updates `last_used_at`, returns the owner.
  - `GET /api/bridge/token` with header `x-bridge-secret` → `{ access_token, expires_at }` (same shape as `/api/token`) or 401/404/429.
  - `POST /api/admin/bridge-secret` body `{ owner_id }` (cron secret) → `{ owner_id, secret }`; the plaintext (`gbs_` + 48 base64url chars) is returned exactly once and only its hash is stored; calling again rotates it.

- [ ] **Step 1: Migration**

`supabase/migrations/0006_bridge_secrets.sql`:
```sql
create table bridge_secrets (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  secret_hash text not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table bridge_secrets enable row level security; -- service role only
```
Run `supabase db reset`.

- [ ] **Step 2: Tests first**

`apps/web/test/bridge-token.test.ts`:
```ts
import { describe, it, expect, beforeAll } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { hashSecret } from "@/lib/bridge-auth";
let ownerId = ""; let secret = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email: "bridge@test.local", password: "pass-1234", email_confirm: true });
  ownerId = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find(x => x.email === "bridge@test.local")!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x00", access_token: "BRIDGE-TOK", access_expires_at: new Date(Date.now() + 4 * 3600_000).toISOString() });
});
describe("bridge token", () => {
  it("admin mints a secret once and stores only its hash", async () => {
    const { POST } = await import("@/app/api/admin/bridge-secret/route");
    const r = await POST(new Request("http://g/api/admin/bridge-secret", { method: "POST", headers: { authorization: "Bearer c", "content-type": "application/json" }, body: JSON.stringify({ owner_id: ownerId }) }));
    expect(r.status).toBe(200); const body = await r.json(); secret = body.secret; expect(secret).toMatch(/^gbs_[A-Za-z0-9_-]{48}$/);
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("bridge_secrets").select("secret_hash").eq("owner_id", ownerId).single();
    expect(data?.secret_hash).toBe(hashSecret(secret)); expect(data?.secret_hash).not.toContain(secret.slice(4, 20));
  });
  it("admin route refuses without the cron secret", async () => {
    const { POST } = await import("@/app/api/admin/bridge-secret/route");
    expect((await POST(new Request("http://g/x", { method: "POST", body: "{}" }))).status).toBe(403);
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
    await POST(new Request("http://g/x", { method: "POST", headers: { authorization: "Bearer c", "content-type": "application/json" }, body: JSON.stringify({ owner_id: ownerId }) }));
    const { GET } = await import("@/app/api/bridge/token/route");
    expect((await GET(new Request("http://g/api/bridge/token", { headers: { "x-bridge-secret": secret } }))).status).toBe(401);
  });
});
```
Run: `pnpm --filter @garage/web test test/bridge-token.test.ts` → FAIL (modules not found).

- [ ] **Step 3: Implementation**

`apps/web/src/lib/bridge-auth.ts`:
```ts
import { createHash, randomBytes } from "node:crypto";
import { serviceClient } from "./supabase";
export function hashSecret(secret: string) { return createHash("sha256").update(secret).digest("hex"); }
export function newBridgeSecret() { return "gbs_" + randomBytes(36).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "").slice(0, 48); }
export async function bridgeOwnerFromRequest(req: Request): Promise<{ id: string } | null> {
  const secret = req.headers.get("x-bridge-secret"); if (!secret || !secret.startsWith("gbs_")) return null;
  const sb = serviceClient();
  const { data } = await sb.from("bridge_secrets").select("owner_id").eq("secret_hash", hashSecret(secret)).maybeSingle();
  if (!data) return null;
  await sb.from("bridge_secrets").update({ last_used_at: new Date().toISOString() }).eq("owner_id", data.owner_id);
  return { id: data.owner_id };
}
```
`apps/web/src/app/api/admin/bridge-secret/route.ts`:
```ts
import { requireCron, serviceClient } from "@/lib/supabase"; import { hashSecret, newBridgeSecret } from "@/lib/bridge-auth";
export const dynamic = "force-dynamic";
export async function POST(req: Request) {
  if (!requireCron(req)) return new Response("forbidden", { status: 403 });
  const b = await req.json().catch(() => ({})); const owner = String(b.owner_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(owner)) return Response.json({ error: "bad_owner" }, { status: 400 });
  const secret = newBridgeSecret();
  const { error } = await serviceClient().from("bridge_secrets").upsert({ owner_id: owner, secret_hash: hashSecret(secret), created_at: new Date().toISOString(), last_used_at: null });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ owner_id: owner, secret }, { headers: { "cache-control": "no-store" } });
}
```
`apps/web/src/app/api/bridge/token/route.ts`:
```ts
import { bridgeOwnerFromRequest } from "@/lib/bridge-auth"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function GET(req: Request) {
  const o = await bridgeOwnerFromRequest(req); if (!o) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("bridge-token", o.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const t = await currentAccessToken(o.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  return Response.json({ access_token: t.token, expires_at: t.expiresAt }, { headers: { "cache-control": "no-store" } });
}
```

- [ ] **Step 4: Run** `pnpm --filter @garage/web test` → 41 passed; typecheck; build.

- [ ] **Step 5: Commit** `feat(web): bridge token access with hashed per-owner secrets`

---

### Task 2: Browser-safe `/auth/start`

**Files:**
- Modify: `apps/web/src/app/auth/start/route.ts`, `apps/web/test/auth-routes.test.ts`

**Interfaces:**
- Produces: `POST /auth/start` (Supabase JWT) → `200 { url: string }`; `GET /auth/start` → `405`. The app opens `url` in `ASWebAuthenticationSession`; the callback is unchanged.

- [ ] **Step 1: Update the tests** in `apps/web/test/auth-routes.test.ts`: replace the two `start` tests with
```ts
it("start requires a user", async () => { const { POST } = await import("@/app/auth/start/route"); expect((await POST(new Request("http://g/auth/start", { method: "POST" }))).status).toBe(401); });
it("start returns the Tesla url as JSON and stores state", async () => {
  const { POST, GET } = await import("@/app/auth/start/route");
  expect((await GET()).status).toBe(405);
  const r = await POST(new Request("http://g/auth/start", { method: "POST", headers: { authorization: `Bearer ${jwt}` } }));
  expect(r.status).toBe(200); const { url } = await r.json(); const loc = new URL(url); expect(loc.host).toBe("auth.tesla.com");
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const { data } = await admin.from("oauth_states").select("owner_id").eq("state", loc.searchParams.get("state")!).single(); expect(data?.owner_id).toBe(ownerId);
});
```
Run → FAIL (POST not exported).

- [ ] **Step 2: Route**

`apps/web/src/app/auth/start/route.ts`:
```ts
import { createPkce, newState } from "@/lib/pkce"; import { authorizeUrl } from "@/lib/tesla-auth"; import { serviceClient, userFromRequest } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export function GET() { return new Response("use POST", { status: 405, headers: { allow: "POST" } }); }
export async function POST(req: Request) {
  const user = await userFromRequest(req); if (!user) return Response.json({ error: "unauthorized" }, { status: 401 });
  const { verifier, challenge } = createPkce(); const state = newState();
  const { error } = await serviceClient().from("oauth_states").insert({ state, owner_id: user.id, verifier }); if (error) return Response.json({ error: "state_store_failed" }, { status: 500 });
  return Response.json({ url: authorizeUrl(challenge, state) }, { headers: { "cache-control": "no-store" } });
}
```

- [ ] **Step 3: Run** web suite → 41 passed. **Commit** `fix(web): POST /auth/start returns the Tesla url for in-app browser sessions`

---
### Task 3: Vehicle discovery and VIN paths

**Files:**
- Create: `apps/web/src/lib/vehicles.ts`, `apps/web/src/app/api/vehicles/sync/route.ts`, `apps/web/test/vehicles-sync.test.ts`
- Modify: `apps/web/src/app/auth/callback/route.ts` (best-effort sync after store), `apps/web/src/app/api/vehicle-data/route.ts` (VIN path), `apps/web/test/api-routes.test.ts` (URL assertion)

**Interfaces:**
- Consumes: `FleetClient` from `@garage/core`; `currentAccessToken`; SQL `increment_usage`.
- Produces:
  - `syncVehicles(ownerId: string, o?: { fetch?: typeof fetch; client?: SupabaseClient }): Promise<{ vehicles: Array<{ id: string; vin: string; display_name: string }>; error?: string }>` — calls Fleet `GET /api/1/vehicles`, counts one `data` usage, upserts `vehicles` on `vin` (sets `owner_id`, `tesla_vehicle_id`, `display_name`, `model` from the VIN's 4th character: `Y`→"Model Y", `3`→"Model 3", `S`→"Model S", `X`→"Model X", `C`→"Cybertruck"), inserts a `vehicle_state` row per vehicle if missing (`sleep_state` from the list's `state`). Never throws for Fleet errors; returns `{ vehicles: [], error }`.
  - `POST /api/vehicles/sync` (JWT, limit key `vehicles-sync`) → `{ vehicles }` or `{ vehicles: [], error }` with 502.
  - `/api/vehicle-data` calls `/api/1/vehicles/${vin}/vehicle_data?...` and selects `vin` instead of `tesla_vehicle_id`.

- [ ] **Step 1: Tests first**

`apps/web/test/vehicles-sync.test.ts`:
```ts
import { describe, it, expect, beforeAll, vi, afterEach } from "vitest";
import { createClient } from "@supabase/supabase-js";
let jwt = "", ownerId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.auth.admin.createUser({ email: "sync@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
  const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!); const s = await c.auth.signInWithPassword({ email: "sync@test.local", password: "pass-1234" });
  jwt = s.data.session!.access_token; ownerId = s.data.user!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x00", access_token: "SYNC-TOK", access_expires_at: new Date(Date.now() + 4 * 3600_000).toISOString() });
});
afterEach(() => vi.unstubAllGlobals());
const fleetStub = (payload: unknown, status = 200) => { const real = globalThis.fetch; vi.stubGlobal("fetch", vi.fn(async (u: any, init?: any) => String(u).startsWith("https://fleet.test") ? new Response(JSON.stringify(payload), { status }) : real(u, init))); };
describe("vehicle sync", () => {
  it("creates vehicles and state rows from the Fleet list and counts one data call", async () => {
    fleetStub({ response: [{ id: 111, vehicle_id: 222, vin: "XP7YSYNC000000001", display_name: "Sync Car", state: "asleep" }] });
    const { syncVehicles } = await import("@/lib/vehicles");
    const r = await syncVehicles(ownerId);
    expect(r.error).toBeUndefined(); expect(r.vehicles[0]?.vin).toBe("XP7YSYNC000000001");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data: v } = await admin.from("vehicles").select("id, tesla_vehicle_id, model, display_name").eq("vin", "XP7YSYNC000000001").single();
    expect(Number(v?.tesla_vehicle_id)).toBe(111); expect(v?.model).toBe("Model Y"); expect(v?.display_name).toBe("Sync Car");
    const { data: st } = await admin.from("vehicle_state").select("sleep_state").eq("vehicle_id", v!.id).single(); expect(st?.sleep_state).toBe("asleep");
    const { data: usage } = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "data").single(); expect(Number(usage?.count)).toBeGreaterThanOrEqual(1);
  });
  it("is idempotent and keeps the existing state row", async () => {
    fleetStub({ response: [{ id: 111, vehicle_id: 222, vin: "XP7YSYNC000000001", display_name: "Renamed", state: "online" }] });
    const { syncVehicles } = await import("@/lib/vehicles");
    await syncVehicles(ownerId);
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data: v } = await admin.from("vehicles").select("display_name").eq("vin", "XP7YSYNC000000001"); expect(v?.length).toBe(1); expect(v?.[0]?.display_name).toBe("Renamed");
  });
  it("reports Fleet failures without throwing", async () => {
    fleetStub({ error: "boom" }, 500);
    const { syncVehicles } = await import("@/lib/vehicles");
    const r = await syncVehicles(ownerId); expect(r.vehicles).toEqual([]); expect(r.error).toMatch(/500/);
  });
  it("route requires auth and returns vehicles", async () => {
    fleetStub({ response: [{ id: 111, vehicle_id: 222, vin: "XP7YSYNC000000001", display_name: "Renamed", state: "online" }] });
    const { POST } = await import("@/app/api/vehicles/sync/route");
    expect((await POST(new Request("http://g/api/vehicles/sync", { method: "POST" }))).status).toBe(401);
    const r = await POST(new Request("http://g/api/vehicles/sync", { method: "POST", headers: { authorization: `Bearer ${jwt}` } }));
    expect(r.status).toBe(200); expect((await r.json()).vehicles[0].vin).toBe("XP7YSYNC000000001");
  });
});
```
In `apps/web/test/api-routes.test.ts`, the vehicle-data test's seeded vehicle must have a `vin` (it does: `VINAPI`); add to the success test: `expect(String((globalThis.fetch as any).mock.calls[0][0])).toContain("/api/1/vehicles/VINAPI/vehicle_data")`.
Run → FAIL.

- [ ] **Step 2: Implementation**

`apps/web/src/lib/vehicles.ts`:
```ts
import { FleetClient } from "@garage/core";
import type { SupabaseClient } from "@supabase/supabase-js";
import { env } from "./env"; import { serviceClient } from "./supabase"; import { currentAccessToken } from "./credentials";
const MODEL_BY_VIN_CHAR: Record<string, string> = { Y: "Model Y", "3": "Model 3", S: "Model S", X: "Model X", C: "Cybertruck" };
export async function syncVehicles(ownerId: string, o: { fetch?: typeof fetch; client?: SupabaseClient } = {}) {
  const sb = o.client ?? serviceClient();
  const t = await currentAccessToken(ownerId, { client: sb, fetch: o.fetch }); if (!t) return { vehicles: [], error: "not_connected" };
  const fleet = new FleetClient({ baseUrl: env().TESLA_FLEET_BASE, token: t.token, fetch: o.fetch });
  await sb.rpc("increment_usage", { p_owner: ownerId, p_category: "data", p_count: 1 });
  let list: Array<{ id: number; vin: string; display_name: string; state?: string }>;
  try { list = await fleet.get("/api/1/vehicles"); } catch (e: any) { return { vehicles: [], error: String(e?.message ?? e) }; }
  const out: Array<{ id: string; vin: string; display_name: string }> = [];
  for (const v of list ?? []) {
    const model = MODEL_BY_VIN_CHAR[v.vin?.[3] ?? ""] ?? null;
    const { data: row, error } = await sb.from("vehicles").upsert({ owner_id: ownerId, vin: v.vin, tesla_vehicle_id: v.id, display_name: v.display_name || "Tesla", model }, { onConflict: "vin" }).select("id, vin, display_name").single();
    if (error || !row) { console.error("vehicles upsert failed", error?.message); continue; }
    await sb.from("vehicle_state").upsert({ vehicle_id: row.id, owner_id: ownerId, sleep_state: v.state ?? null }, { onConflict: "vehicle_id", ignoreDuplicates: true });
    out.push(row);
  }
  return { vehicles: out };
}
```
`apps/web/src/app/api/vehicles/sync/route.ts`:
```ts
import { userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { syncVehicles } from "@/lib/vehicles";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("vehicles-sync", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const r = await syncVehicles(u.id); return Response.json(r, { status: r.error ? 502 : 200 });
}
```
Callback: after `await storeCredentials(...)` add `try { await syncVehicles(row.owner_id); } catch (e) { console.error("vehicle sync after connect failed", e); }` before `return back("ok=1")`.
`/api/vehicle-data`: select `id, vin` and use `` `/api/1/vehicles/${v.vin}/vehicle_data?...` ``; return 404 `no_vehicle` when `!v?.vin`.

- [ ] **Step 3: Run** web suite → 45 passed; typecheck; build. **Commit** `feat(web): vehicle discovery after connect and VIN-based Fleet paths`

---

### Task 4: Token health for the app

**Files:**
- Create: `supabase/migrations/0007_tesla_connection.sql`, `apps/web/src/app/api/connection/route.ts`
- Modify: `supabase/tests/rls.test.ts`, `apps/web/test/api-routes.test.ts`

**Interfaces:**
- Produces: SQL `get_tesla_connection()` (security definer, `authenticated` may execute) returning one row `{ connected boolean, rotated_at, last_error, access_expires_at, rotating boolean }` for `auth.uid()`; `GET /api/connection` (JWT) → that row as JSON with `connected:false` when no credentials.

- [ ] **Step 1: Migration**

`supabase/migrations/0007_tesla_connection.sql`:
```sql
create or replace function public.get_tesla_connection()
returns table (connected boolean, rotated_at timestamptz, last_error text, access_expires_at timestamptz, rotating boolean)
language sql security definer set search_path = public stable as $$
  select true, c.rotated_at, c.last_error, c.access_expires_at, (c.refresh_lock_until is not null and c.refresh_lock_until > now())
  from tesla_credentials c where c.owner_id = auth.uid()
  union all
  select false, null, null, null, false where not exists (select 1 from tesla_credentials where owner_id = auth.uid())
  limit 1;
$$;
revoke execute on function public.get_tesla_connection() from public, anon;
grant execute on function public.get_tesla_connection() to authenticated;
```

- [ ] **Step 2: Tests** — in `supabase/tests/rls.test.ts` add:
```ts
it("get_tesla_connection shows only the caller's row and never tokens", async () => {
  const { data: a1 } = await a.client.rpc("get_tesla_connection"); expect(a1?.[0]?.connected).toBe(true); expect(JSON.stringify(a1)).not.toMatch(/token/);
  const { data: b1 } = await b.client.rpc("get_tesla_connection"); expect(b1?.[0]?.connected).toBe(false);
});
```
(user A already has a `tesla_credentials` row from the earlier test.) In `apps/web/test/api-routes.test.ts` add:
```ts
it("connection route returns health for the caller", async () => {
  const { GET } = await import("@/app/api/connection/route");
  expect((await GET(new Request("http://g/api/connection"))).status).toBe(401);
  const r = await GET(new Request("http://g/api/connection", { headers: H() })); const j = await r.json(); expect(j.connected).toBe(true); expect(j.access_token).toBeUndefined();
});
```
Route:
```ts
import { userFromRequest, serviceClient } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export async function GET(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  const { data, error } = await serviceClient().from("tesla_credentials").select("rotated_at, last_error, access_expires_at, refresh_lock_until").eq("owner_id", u.id).maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ connected: false, rotated_at: null, last_error: null, access_expires_at: null, rotating: false });
  return Response.json({ connected: true, rotated_at: data.rotated_at, last_error: data.last_error, access_expires_at: data.access_expires_at, rotating: !!data.refresh_lock_until && new Date(data.refresh_lock_until).getTime() > Date.now() }, { headers: { "cache-control": "no-store" } });
}
```
(The route uses the service client with an explicit owner filter; the SQL function serves the app's direct supabase-js path. Both exist so 1C can pick either.)

- [ ] **Step 3: Run** `supabase db reset`; supabase suite → 8; web suite → 46; typecheck; build. **Commit** `feat: token health via get_tesla_connection() and /api/connection`

---
### Task 5: Driver/passenger door mapping, missing telemetry signals, charge_amps

**Files:**
- Create: `supabase/migrations/0008_charge_amps.sql`
- Modify: `packages/core/src/types.ts` (`charge_amps?: number | null`), `packages/core/src/tesla/map-vehicle-data.ts`, `packages/core/src/tesla/map-telemetry.ts`, `packages/core/test/map-vehicle-data.test.ts`, `packages/core/test/map-telemetry.test.ts`, `packages/core/test/fixtures/vehicle_data.json`

**Interfaces:**
- Produces: `doors` and `windows` jsonb use keys `driver_front | passenger_front | driver_rear | passenger_rear` (boolean open). New column `vehicle_state.charge_amps numeric`. Telemetry mappings added: `DoorState` (object `{ DriverFront: bool, PassengerFront, DriverRear, PassengerRear, TrunkFront, TrunkRear }` or a string list such as `"DriverFront|TrunkRear"`), `FdWindow/FpWindow/RdWindow/RpWindow` (values `WindowStateOpened|Closed|PartiallyOpen` → open when not Closed), `ChargeAmps` → `charge_amps`, `TpmsPressure*` unchanged.

- [ ] **Step 1: Migration** `0008_charge_amps.sql`: `alter table vehicle_state add column charge_amps numeric;` then `supabase db reset`.

- [ ] **Step 2: Tests first** — in `map-vehicle-data.test.ts` change the body expectations to:
```ts
expect(s.doors).toEqual({ driver_front: false, passenger_front: false, driver_rear: false, passenger_rear: false });
expect(s.windows).toEqual({ driver_front: false, passenger_front: false, driver_rear: false, passenger_rear: false });
```
and add a case with `df: 1, rp_window: 1` → `doors.driver_front === true`, `windows.passenger_rear === true`. In `map-telemetry.test.ts` add:
```ts
it("DoorState object", () => expect(m("DoorState", { DriverFront: true, PassengerFront: false, DriverRear: false, PassengerRear: false, TrunkFront: true, TrunkRear: false }, at)).toEqual({ doors: { driver_front: true, passenger_front: false, driver_rear: false, passenger_rear: false }, frunk_open: true, trunk_open: false, body_at: iso }));
it("DoorState string list", () => expect(m("DoorState", "PassengerRear|TrunkRear", at).doors?.passenger_rear).toBe(true));
it("window signal", () => expect(m("FpWindow", "WindowStatePartiallyOpen", at)).toEqual({ windows: { passenger_front: true } }));
it("ChargeAmps", () => expect(m("ChargeAmps", "16", at)).toEqual({ charge_amps: 16 }));
```
Run core tests → FAIL.

- [ ] **Step 3: Implementation**

`map-vehicle-data.ts` lines 26-27 become:
```ts
if (vs.df != null) out.doors = { driver_front: !!vs.df, passenger_front: !!vs.pf, driver_rear: !!vs.dr, passenger_rear: !!vs.pr };
if (vs.fd_window != null) out.windows = { driver_front: !!vs.fd_window, passenger_front: !!vs.fp_window, driver_rear: !!vs.rd_window, passenger_rear: !!vs.rp_window };
if (cs.charge_amps != null) out.charge_amps = cs.charge_amps;
```
`map-telemetry.ts` add cases:
```ts
case "DoorState": {
  const open = (k: string) => typeof value === "object" && value !== null ? !!(value as any)[k] : String(value).split("|").includes(k);
  return { doors: { driver_front: open("DriverFront"), passenger_front: open("PassengerFront"), driver_rear: open("DriverRear"), passenger_rear: open("PassengerRear") }, frunk_open: open("TrunkFront"), trunk_open: open("TrunkRear"), body_at: iso };
}
case "FdWindow": case "FpWindow": case "RdWindow": case "RpWindow": {
  const key = ({ Fd: "driver_front", Fp: "passenger_front", Rd: "driver_rear", Rp: "passenger_rear" } as const)[name.slice(0, 2) as "Fd" | "Fp" | "Rd" | "Rp"];
  return { windows: { [key]: value !== "WindowStateClosed" && value !== false } as any };
}
case "ChargeAmps": return n == null ? {} : { charge_amps: n };
```
Add `charge_amps?: number | null;` to `VehicleStateRow` in `types.ts`.

- [ ] **Step 4: Run** core → 26 passed; web suite unaffected. **Commit** `feat(core): driver/passenger door and window mapping, DoorState/window/ChargeAmps telemetry`

---

### Task 6: `merge_vehicle_state` deep-merge RPC

**Files:**
- Create: `supabase/migrations/0009_merge_vehicle_state.sql`
- Modify: `supabase/tests/rls.test.ts` (merge tests), `apps/web/src/app/api/vehicle-data/route.ts` (use the RPC instead of upsert)

**Interfaces:**
- Produces: SQL `merge_vehicle_state(p_vehicle uuid, p_patch jsonb) returns void` (security definer; `anon`/`authenticated` revoked). Scalar keys in `p_patch` overwrite; jsonb keys `doors`, `windows`, `tpms_bar`, `bridge_health` are shallow-merged object-wise (patch keys win); `updated_at` is set to `now()`; unknown keys are ignored; raises if the vehicle has no state row. This is the only write path Plan 1B's ingest and `/api/vehicle-data` use for `vehicle_state`.

- [ ] **Step 1: Migration**
```sql
create or replace function public.merge_vehicle_state(p_vehicle uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare cur jsonb; merged jsonb; k text; cols text; known jsonb := '{}'::jsonb;
begin
  select to_jsonb(v) into cur from vehicle_state v where v.vehicle_id = p_vehicle for update;
  if cur is null then raise exception 'merge_vehicle_state: no vehicle_state row for %', p_vehicle; end if;
  -- keep only known columns from the patch, never allow vehicle_id/owner_id to change
  for k in select column_name from information_schema.columns where table_schema = 'public' and table_name = 'vehicle_state' and column_name not in ('vehicle_id','owner_id') loop
    if p_patch ? k then known := known || jsonb_build_object(k, p_patch -> k); end if;
  end loop;
  merged := cur || known;
  foreach k in array array['doors','windows','tpms_bar','bridge_health'] loop
    if known ? k and jsonb_typeof(cur -> k) = 'object' and jsonb_typeof(known -> k) = 'object' then
      merged := jsonb_set(merged, array[k], (cur -> k) || (known -> k));
    end if;
  end loop;
  merged := merged || jsonb_build_object('updated_at', now());
  select string_agg(format('%I = r.%I', column_name, column_name), ', ') into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'vehicle_state' and column_name not in ('vehicle_id','owner_id');
  execute format('update vehicle_state v set %s from jsonb_populate_record(null::vehicle_state, $1) r where v.vehicle_id = $2', cols) using merged, p_vehicle;
end $$;
revoke execute on function public.merge_vehicle_state(uuid, jsonb) from public, anon, authenticated;
```

- [ ] **Step 2: Tests** in `supabase/tests/rls.test.ts` (admin client; user A's vehicle `VINAAAA` exists from the first test; create its state row in the test):
```ts
it("merge_vehicle_state merges jsonb and overwrites scalars", async () => {
  const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
  await admin.from("vehicle_state").upsert({ vehicle_id: v!.id, owner_id: a.id, soc: 50, tpms_bar: { fl: 2.9, fr: 2.9 } });
  await admin.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { soc: 51, tpms_bar: { rl: 2.8 }, nonsense: 1, owner_id: b.id } });
  const { data: s } = await admin.from("vehicle_state").select("soc, tpms_bar, owner_id").eq("vehicle_id", v!.id).single();
  expect(Number(s?.soc)).toBe(51); expect(s?.tpms_bar).toEqual({ fl: 2.9, fr: 2.9, rl: 2.8 }); expect(s?.owner_id).toBe(a.id);
});
it("merge_vehicle_state is service-only", async () => {
  const { data: v } = await admin.from("vehicles").select("id").eq("vin", "VINAAAA").single();
  const { error } = await a.client.rpc("merge_vehicle_state", { p_vehicle: v!.id, p_patch: { soc: 1 } }); expect(error).not.toBeNull();
});
```
`/api/vehicle-data`: replace the upsert with `const { error: mergeError } = await sb.rpc("merge_vehicle_state", { p_vehicle: v.id, p_patch: state });` keeping the 500 `state_write_failed` on error. The api-routes test that reads `soc` back still passes.

- [ ] **Step 3: Run** `supabase db reset`; supabase → 10; web → 46. **Commit** `feat(db): merge_vehicle_state deep-merge RPC; vehicle-data uses it`

---

### Task 7: Partition extension job

**Files:**
- Create: `supabase/migrations/0010_signals_partition_job.sql`
- Modify: `supabase/tests/rls.test.ts`

**Interfaces:**
- Produces: SQL `ensure_signals_partitions(p_months_ahead int default 14) returns int` (number created; each new partition secured via `secure_signals_partition`); a `pg_cron` job `signals-partitions` at `0 3 1 * *` calling it. `pg_cron` is available on hosted Supabase and in the local CLI stack; if `create extension pg_cron` fails locally, the migration still succeeds because the schedule is wrapped in a `do` block that catches `undefined_table`/`undefined_function` and raises a notice.

- [ ] **Step 1: Migration**
```sql
create or replace function public.ensure_signals_partitions(p_months_ahead int default 14)
returns int language plpgsql security definer set search_path = public as $$
declare d date := date_trunc('month', now())::date; i int; nm text; created int := 0;
begin
  for i in 0..p_months_ahead loop
    nm := 'signals_' || to_char(d + (i||' month')::interval, 'YYYYMM');
    if not exists (select 1 from pg_class where relname = nm) then
      execute format('create table %I partition of signals for values from (%L) to (%L)', nm, d + (i||' month')::interval, d + ((i+1)||' month')::interval);
      perform public.secure_signals_partition(nm);
      created := created + 1;
    end if;
  end loop;
  return created;
end $$;
revoke execute on function public.ensure_signals_partitions(int) from public, anon, authenticated;

create extension if not exists pg_cron;
do $$ begin
  perform cron.unschedule('signals-partitions') from cron.job where jobname = 'signals-partitions';
  perform cron.schedule('signals-partitions', '0 3 1 * *', $job$ select public.ensure_signals_partitions(); $job$);
exception when undefined_table or undefined_function or insufficient_privilege then
  raise notice 'pg_cron not available here; schedule signals-partitions manually';
end $$;
```

- [ ] **Step 2: Test** in `rls.test.ts`:
```ts
it("ensure_signals_partitions creates and secures missing months", async () => {
  const { data: n } = await admin.rpc("ensure_signals_partitions", { p_months_ahead: 20 }); expect(Number(n)).toBeGreaterThanOrEqual(6);
  const far = new Date(); far.setUTCMonth(far.getUTCMonth() + 19); const name = "signals_" + far.toISOString().slice(0, 7).replace("-", "");
  const anon = createClient(process.env.SUPABASE_URL ?? "http://127.0.0.1:54321", process.env.SUPABASE_ANON_KEY!);
  const { data, error } = await anon.from(name).select("*"); expect((data ?? []).length).toBe(0); // denied or empty, never rows
});
```
(import `createClient` at the top if not already.)

- [ ] **Step 3: Run** `supabase db reset`; supabase → 11. **Commit** `feat(db): monthly signals partition job with pg_cron`

---

### Task 8: Rotation store fencing and backoff

**Files:**
- Create: `supabase/migrations/0011_refresh_backoff.sql`
- Modify: `apps/web/src/lib/tesla-refresh.ts`, `apps/web/test/tesla-refresh.test.ts`

**Interfaces:**
- Produces: columns `tesla_credentials.refresh_failures int not null default 0`, `next_refresh_at timestamptz`. `refreshAll`: (a) the store UPDATE is fenced on `refresh_token_enc` equal to the claimed ciphertext (the token we consumed) instead of on the lock, so a late store after lock expiry still lands and a concurrent re-auth is never overwritten; (b) candidates with `next_refresh_at > now` are skipped (reported in `skipped`); (c) on failure `refresh_failures += 1` and `next_refresh_at = now + min(2^failures minutes, 6 h)`; on success both reset. `currentAccessToken` unchanged.

- [ ] **Step 1: Migration** `0011_refresh_backoff.sql`: `alter table tesla_credentials add column refresh_failures int not null default 0, add column next_refresh_at timestamptz;` then `supabase db reset`.

- [ ] **Step 2: Tests** in `tesla-refresh.test.ts` (scoped by `ownerId`, own seeded rows, cleaned in `afterAll`):
```ts
it("store is fenced on the consumed refresh token, not the lock", async () => {
  // seed due row; wrap client so the FIRST store attempt clears refresh_lock_until (simulating lock expiry) before the update runs; assert the store still succeeds and rotated contains the owner
});
it("a failed rotation sets backoff and the next sweep skips the row", async () => {
  // Tesla mock returns 401 → failed; read refresh_failures === 1 and next_refresh_at > now; call refreshAll again with Tesla mock counting → not called, owner in skipped
});
it("a successful rotation resets backoff", async () => {
  // set refresh_failures=3,next_refresh_at=past; Tesla 200 → refresh_failures 0, next_refresh_at null
});
```
Write these three tests out in full (the comments above describe the arrangement; the assertions are: `r.rotated` contains owner; `data.refresh_failures === 1 && new Date(data.next_refresh_at) > new Date()`; second `f` call count unchanged and `r2.skipped` contains owner; after success `refresh_failures === 0 && next_refresh_at === null`). Use the `failingUpdates`-style Proxy from the existing file to simulate the lock being cleared: intercept the first `update(updatePayload)` call, run `admin.from("tesla_credentials").update({ refresh_lock_until: null }).eq("owner_id", ownerId)` first, then delegate.
Run → FAIL.

- [ ] **Step 3: Implementation** in `tesla-refresh.ts`:
  - Candidate select adds `next_refresh_at`; skip when `next_refresh_at && new Date(next_refresh_at) > claimNow` (push to `skipped`).
  - Store update: `.eq("owner_id", row.owner_id).eq("refresh_token_enc", claimedRow.refresh_token_enc as string)` (remove the `refresh_lock_until` fence); `updatePayload` adds `refresh_failures: 0, next_refresh_at: null`.
  - In the `catch`, the `last_error` update also sets `refresh_failures` to `(current + 1)` and `next_refresh_at`: read `refresh_failures` in the claim select (`.select("owner_id, refresh_token_enc, access_expires_at, refresh_failures")`), compute `const n = (claimedRow.refresh_failures ?? 0) + 1; const backoffMs = Math.min(2 ** n * 60_000, 6 * 3600_000);`.
  - `lock_lost` message becomes `token_changed: refresh_token_enc no longer matches the consumed token` (meaning someone re-authed or rotated concurrently; do not treat as unstored-loss since the new token in the row is valid for whoever wrote it).

- [ ] **Step 4: Run** web suite → 49; typecheck; build. **Commit** `fix(web): fence rotation store on the consumed token; exponential backoff on failed refreshes`

---

### Task 9: Access lockdown and rate limits

**Files:**
- Modify: `apps/web/src/lib/env.ts` (OPTIONAL `ALLOWED_OWNER_IDS`), `apps/web/src/lib/supabase.ts`, `apps/web/src/lib/ratelimit.ts`, `apps/web/src/app/api/vehicle-data/route.ts`, `apps/web/test/env.test.ts`, `apps/web/test/api-routes.test.ts`
- Create: `apps/web/test/ratelimit.test.ts`

**Interfaces:**
- Produces:
  - `userFromRequest` rejects (returns null) any user whose id is not in `ALLOWED_OWNER_IDS` when that env var is set (comma-separated UUIDs). Unset = allow all (local dev, tests).
  - `limit(key, userId, opts?: { perMinute?: number; perDay?: number })`: Upstash when configured; otherwise an in-process sliding window (`Map<string, number[]>`) so production is never unlimited; both paths honour `perMinute` (default 10) and `perDay` (default none).
  - `/api/vehicle-data`: `limit("vehicle-data", u.id, { perMinute: 2, perDay: 40 })`, and when the vehicle's `budget_mode === "minimal"` return 429 `{ error: "budget_minimal" }` without calling Tesla.

- [ ] **Step 1: Tests**
`ratelimit.test.ts`:
```ts
import { it, expect, beforeAll } from "vitest";
beforeAll(() => { Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", SUPABASE_URL: "http://x", SUPABASE_ANON_KEY: "a", SUPABASE_SERVICE_ROLE_KEY: "s", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" }); delete process.env.UPSTASH_REDIS_REST_URL; });
it("in-memory fallback enforces per-minute and per-day", async () => {
  const { limit } = await import("@/lib/ratelimit");
  for (let i = 0; i < 2; i++) expect((await limit("t", "u1", { perMinute: 2, perDay: 3 })).ok).toBe(true);
  expect((await limit("t", "u1", { perMinute: 2, perDay: 3 })).ok).toBe(false);
  expect((await limit("t", "u2", { perMinute: 2, perDay: 3 })).ok).toBe(true); // per user
});
```
`env.test.ts`: add that `ALLOWED_OWNER_IDS` is optional (env() with it unset still returns). `api-routes.test.ts`: add
```ts
it("allow-list blocks users not listed", async () => {
  process.env.ALLOWED_OWNER_IDS = "00000000-0000-0000-0000-000000000000";
  const { GET } = await import("@/app/api/token/route");
  expect((await GET(new Request("http://g/api/token", { headers: H() }))).status).toBe(401);
  delete process.env.ALLOWED_OWNER_IDS;
});
it("vehicle-data refuses when budget_mode is minimal", async () => {
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.from("vehicles").update({ budget_mode: "minimal" }).eq("id", vehicleId);
  const { POST } = await import("@/app/api/vehicle-data/route");
  const r = await POST(new Request("http://g/api/vehicle-data", { method: "POST", headers: H(), body: JSON.stringify({ vehicle_id: vehicleId }) }));
  expect(r.status).toBe(429); expect((await r.json()).error).toBe("budget_minimal");
  await admin.from("vehicles").update({ budget_mode: "normal" }).eq("id", vehicleId);
});
```
Note the existing vehicle-data tests call the route more than twice per minute in one file; give those tests distinct limiter keys by passing a fresh user? Simpler: the in-memory limiter must be resettable: export `_resetLimiterForTests()` and call it in that file's `beforeEach`.

- [ ] **Step 2: Implementation**
`env.ts`: add `"ALLOWED_OWNER_IDS"` to OPTIONAL. `supabase.ts` `userFromRequest`: after resolving the user, `const allow = process.env.ALLOWED_OWNER_IDS?.split(",").map(s => s.trim()).filter(Boolean); if (allow && allow.length && !allow.includes(data.user.id)) return null;`.
`ratelimit.ts`:
```ts
import { Ratelimit } from "@upstash/ratelimit"; import { Redis } from "@upstash/redis"; import { env } from "./env";
type Opts = { perMinute?: number; perDay?: number };
let redis: Redis | null | undefined; const upstash = new Map<string, Ratelimit>(); const mem = new Map<string, number[]>();
function redisClient() { if (redis !== undefined) return redis; const e = env(); redis = e.UPSTASH_REDIS_REST_URL && e.UPSTASH_REDIS_REST_TOKEN ? new Redis({ url: e.UPSTASH_REDIS_REST_URL, token: e.UPSTASH_REDIS_REST_TOKEN }) : null; return redis; }
function upstashLimiter(name: string, n: number, window: "1 m" | "1 d") { const k = `${name}:${window}`; let l = upstash.get(k); if (!l) { l = new Ratelimit({ redis: redisClient()!, limiter: Ratelimit.slidingWindow(n, window), prefix: `garage:${k}` }); upstash.set(k, l); } return l; }
function memAllow(key: string, n: number, windowMs: number, now: number) { const arr = (mem.get(key) ?? []).filter(t => now - t < windowMs); if (arr.length >= n) { mem.set(key, arr); return false; } arr.push(now); mem.set(key, arr); return true; }
export async function limit(key: string, userId: string, o: Opts = {}): Promise<{ ok: boolean }> {
  const perMinute = o.perMinute ?? 10, perDay = o.perDay; const id = `${key}:${userId}`;
  if (redisClient()) {
    const m = await upstashLimiter(key, perMinute, "1 m").limit(id); if (!m.success) return { ok: false };
    if (perDay) { const d = await upstashLimiter(key, perDay, "1 d").limit(id); if (!d.success) return { ok: false }; }
    return { ok: true };
  }
  const now = Date.now();
  if (!memAllow(id + ":m", perMinute, 60_000, now)) return { ok: false };
  if (perDay && !memAllow(id + ":d", perDay, 86_400_000, now)) return { ok: false };
  return { ok: true };
}
export function _resetLimiterForTests() { mem.clear(); }
```
`/api/vehicle-data`: select `id, vin, budget_mode`; after the ownership check, `if (v.budget_mode === "minimal") return Response.json({ error: "budget_minimal" }, { status: 429 });`; use `limit("vehicle-data", u.id, { perMinute: 2, perDay: 40 })`.

- [ ] **Step 3: Run** web suite → 53; typecheck; build. **Commit** `feat(web): owner allow-list, in-memory rate-limit fallback, vehicle-data budget guard`

---

### Task 10: Docs, env, deploy, README

**Files:**
- Modify: `docs/superpowers/specs/2026-10-18-garage-slice-1-foundation-and-status-design.md` (§3.1 bridge token path, §4.1 "one rotator" wording → "one rotation at a time per owner, via the claim lock; the cron and on-demand paths both use `refreshAll`", §8 onboarding step 2 uses `POST /auth/start`, §10 add token health route), `docs/runbooks/tesla-setup.md` (steps: mint bridge secret with `POST /api/admin/bridge-secret`, set `ALLOWED_OWNER_IDS`, disable email sign-ups in the Supabase dashboard under Authentication → Providers → Email)
- Create: `README.md`

**Steps:**
- [ ] Apply migrations 0006–0014 to the hosted project through the Supabase connector (controller does this; order matters).
- [ ] Set Vercel env `ALLOWED_OWNER_IDS=37b3272b-7899-45cf-8956-a156313b12cb` and `ADMIN_SECRET=<generated>` (production + preview).
- [ ] Merge to main via PR, deploy, verify: `POST /auth/start` → 401 unauth; `GET /api/connection` with the bootstrap JWT → `connected: true`; `GET /api/bridge/token` → 401 without a secret; mint a bridge secret for the owner via the admin route and confirm `GET /api/bridge/token` → 200 (store the secret in `~/.garage/vercel-secrets.env` as `BRIDGE_SECRET=`, for Plan 1B's add-on options).
- [ ] README: what Garage is, repo layout, local setup (`pnpm install`, `colima start`, `supabase start`, env export line, `pnpm test`), links to spec, plans and runbook.
- [ ] Commit `docs: 1A.2 spec amendments, runbook, README`.

---

## Self-review

- **Coverage of the nine findings:** I-1 → Task 1; I-2 → Task 2; I-3 → Task 3; I-4 → Task 4; I-8 → Task 5; I-9 → Task 6 (+ mapper signals in Task 5); I-10 → Task 7; I-11 → Task 8; I-12 → Task 9. Docs/env/deploy → Task 10.
- **Type consistency:** `limit(key, userId, opts)` is backward compatible with every existing call; `VehicleStateRow` gains `charge_amps`; door/window keys are identical in both mappers and in the spec constraint above; `merge_vehicle_state` is the single state write path for `/api/vehicle-data` and Plan 1B.
- **Placeholders:** Task 8 Step 2 describes three tests by arrangement and assertion rather than full code; the implementer must write them out in full before implementation (the assertions are specified).
- **Not in this plan:** Sign in with Apple itself (Plan 1C), the add-on (Plan 1B), budget projection by elapsed hours and the remaining deferred minors from the 1A final review.
