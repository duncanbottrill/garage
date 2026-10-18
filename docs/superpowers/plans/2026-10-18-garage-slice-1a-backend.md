# Garage Slice 1A — Backend (Supabase + core package + Vercel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the system of record and the Tesla token custody so that a car can be connected, a Tesla access token can be served to trusted clients, and vehicle state can be written and read, with every billable call counted.

**Architecture:** A pnpm monorepo. `supabase/` holds the schema with RLS. `packages/core` holds Tesla types, the Fleet API client and the mapper from Tesla payloads to our `vehicle_state` row, shared by the Vercel app and (later) the Home Assistant add-on. `apps/web` is a Next.js App Router app on Vercel at `garage.duncanbottrill.com` serving the Tesla public key, the OAuth flow, token refresh and budget crons, and three authenticated API routes.

**Tech Stack:** Node 22, pnpm 9, TypeScript 5.6 strict, Next.js 15 (App Router, route handlers), Supabase (Postgres 15, supabase-js v2, Supabase CLI for local), vitest, `@noble/ciphers` for token encryption, `@upstash/ratelimit`, Vercel Cron.

**Companion plans:** 1B (Home Assistant add-on) and 1C (Apple app) consume what this plan produces. Spec: `docs/superpowers/specs/2026-10-18-garage-slice-1-foundation-and-status-design.md`.

## Global Constraints

- Tesla region EU: Fleet API base `https://fleet-api.prd.eu.vehicle-command.com`; auth base `https://auth.tesla.com/oauth2/v3`; audience = Fleet API base.
- Tesla client ID `3f7843f7-ba1d-4091-9e6b-a41acfe7ef5c`; client secret only in Vercel env `TESLA_CLIENT_SECRET` and local `.env.local`, never committed.
- Registered domain `garage.duncanbottrill.com`; redirect URI `https://garage.duncanbottrill.com/auth/callback`; public key at `/.well-known/appspecific/com.tesla.3p.public-key.pem`.
- Scopes: `openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds vehicle_location`.
- Units stored metric: km, °C, kW, bar. Money as integer minor units + currency.
- RLS enabled on every table from the first migration; policies scope by `owner_id = auth.uid()`; service role bypasses.
- Realtime publication includes `vehicle_state` only.
- Exactly one process rotates Tesla refresh tokens: the Vercel cron. Nothing else calls the Tesla token endpoint with `grant_type=refresh_token`.
- Every billable Tesla call increments `api_usage` (categories: `signals`, `commands`, `data`, `wakes`).
- Budget thresholds: 70% of `budget_monthly_usd` → `reduced`; 90% → `minimal`; never automatic wakes.
- Spec deviation recorded here: refresh tokens are encrypted application-side with XChaCha20-Poly1305 (`@noble/ciphers`) under env `TOKEN_ENC_KEY` (32 bytes, base64) rather than pgsodium, because Supabase is retiring pgsodium in favour of Vault. Same property: only the service role plus the key can read the token.
- Commits: conventional prefixes (`feat:`, `test:`, `chore:`, `docs:`), each task ends in a commit, attribution line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## File structure

```
garage/
  package.json                      pnpm workspace root, scripts: test, lint, typecheck
  pnpm-workspace.yaml
  tsconfig.base.json
  .gitignore  .env.example  .nvmrc
  supabase/
    config.toml                     (supabase init)
    migrations/0001_schema.sql      tables, partitions, RLS, realtime publication
    migrations/0002_functions.sql   increment_usage(), set_budget_mode(), touch helpers
    tests/rls.test.ts               owner isolation via supabase-js against local stack
  packages/core/
    package.json  tsconfig.json
    src/index.ts                    re-exports
    src/types.ts                    VehicleStateRow, Signal, BudgetMode, Tesla payload types
    src/tesla/client.ts             FleetClient: fetch wrapper (base URL, bearer, JSON, error typing)
    src/tesla/map-vehicle-data.ts   vehicleDataToState(payload) → Partial<VehicleStateRow>
    src/tesla/map-telemetry.ts      telemetrySignalToState(name, value, at) → Partial<VehicleStateRow>
    src/budget.ts                   projectMonthSpend(), budgetModeFor()
    src/crypto.ts                   encryptToken()/decryptToken()
    test/*.test.ts
  packages/tokens/
    tokens.json                     design tokens (colour, type, radius, spacing)
    src/generate.ts                 → dist/tokens.css and dist/Tokens.swift
    test/generate.test.ts
  apps/web/
    package.json  next.config.ts  vercel.json  tsconfig.json
    public/.well-known/appspecific/com.tesla.3p.public-key.pem
    src/lib/env.ts                  typed env access
    src/lib/supabase.ts             service client + user-from-JWT helper
    src/lib/ratelimit.ts            Upstash limiter
    src/lib/pkce.ts                 verifier/challenge/state
    src/app/auth/start/route.ts
    src/app/auth/callback/route.ts
    src/app/api/token/route.ts
    src/app/api/usage/route.ts
    src/app/api/vehicle-data/route.ts
    src/app/api/cron/tesla-refresh/route.ts
    src/app/api/cron/budget/route.ts
    src/app/api/health/route.ts
    scripts/register-partner.ts     one-time partner_accounts registration
    scripts/keygen.sh               P-256 key pair
    test/*.test.ts
```

---
### Task 1: Monorepo scaffold

**Files:**
- Create: `package.json`, `pnpm-workspace.yaml`, `tsconfig.base.json`, `.gitignore`, `.nvmrc`, `.env.example`, `vitest.workspace.ts`

**Interfaces:**
- Produces: workspace commands `pnpm test`, `pnpm typecheck` that every later task runs.

- [ ] **Step 1: Create the workspace files**

`package.json`:
```json
{
  "name": "garage",
  "private": true,
  "packageManager": "pnpm@9.12.0",
  "engines": { "node": ">=22" },
  "scripts": {
    "test": "vitest run",
    "typecheck": "pnpm -r --parallel typecheck",
    "build": "pnpm -r build"
  },
  "devDependencies": {
    "typescript": "^5.6.3",
    "vitest": "^2.1.3",
    "@types/node": "^22.7.5"
  }
}
```

`pnpm-workspace.yaml`:
```yaml
packages:
  - "apps/*"
  - "packages/*"
  - "supabase"
```

`tsconfig.base.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "types": ["node"]
  }
}
```

`vitest.workspace.ts`:
```ts
export default ["packages/*", "apps/*", "supabase"];
```

`.nvmrc`: `22`

`.gitignore`:
```
node_modules
dist
.next
.vercel
.env
.env.local
*.pem.key
supabase/.branches
supabase/.temp
.DS_Store
```

`.env.example`:
```
# Tesla
TESLA_CLIENT_ID=3f7843f7-ba1d-4091-9e6b-a41acfe7ef5c
TESLA_CLIENT_SECRET=
TESLA_REDIRECT_URI=https://garage.duncanbottrill.com/auth/callback
TESLA_FLEET_BASE=https://fleet-api.prd.eu.vehicle-command.com
# Supabase
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
# App
TOKEN_ENC_KEY=            # 32 random bytes, base64: openssl rand -base64 32
CRON_SECRET=              # openssl rand -hex 32
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
APP_RETURN_URL=garage://connected
```

- [ ] **Step 2: Install and verify**

Run: `cd /Users/duncanbottrill/garage && corepack enable && pnpm install && pnpm test`
Expected: install succeeds; vitest reports "No test files found" and exits 0 (or exit 1 with that message — either is fine at this point; later tasks add tests).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "chore: pnpm workspace scaffold

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Supabase schema with RLS

**Files:**
- Create: `supabase/config.toml` (via CLI), `supabase/migrations/0001_schema.sql`, `supabase/migrations/0002_functions.sql`, `supabase/package.json`, `supabase/tests/rls.test.ts`, `supabase/tests/helpers.ts`

**Interfaces:**
- Produces: tables `vehicles`, `vehicle_state`, `signals`, `drives`, `charges`, `places`, `api_usage`, `tesla_credentials`; SQL functions `increment_usage(p_owner uuid, p_category text, p_count bigint)` and `set_budget_mode(p_vehicle uuid, p_mode text)`; Realtime on `vehicle_state`.

- [ ] **Step 1: Initialise Supabase locally**

Run: `cd /Users/duncanbottrill/garage && brew install supabase/tap/supabase 2>/dev/null || true; supabase init`
Expected: `supabase/config.toml` created. (Docker Desktop must be running for later steps.)

- [ ] **Step 2: Write the schema migration**

`supabase/migrations/0001_schema.sql`:
```sql
create extension if not exists pgcrypto;

create table vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  vin text not null unique,
  tesla_vehicle_id bigint,
  display_name text not null default 'Model Y',
  model text, trim text, pack_kwh numeric,
  telemetry_config_version int not null default 0,
  telemetry_confirmed_at timestamptz,
  budget_mode text not null default 'normal' check (budget_mode in ('normal','reduced','minimal')),
  created_at timestamptz not null default now()
);

create table vehicle_state (
  vehicle_id uuid primary key references vehicles(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  soc numeric, range_km numeric, charge_state text, charger_power_kw numeric, charge_limit_soc int,
  charge_port_open boolean, scheduled_charge_at timestamptz, charge_at timestamptz,
  inside_c numeric, outside_c numeric, hvac_on boolean, climate_keeper text, climate_at timestamptz,
  lat numeric, lng numeric, heading numeric, speed_kph numeric, gear text, odometer_km numeric, location_at timestamptz,
  locked boolean, doors jsonb, windows jsonb, frunk_open boolean, trunk_open boolean, body_at timestamptz,
  tpms_bar jsonb, sentry boolean,
  sleep_state text, software_version text, bridge_seen_at timestamptz, bridge_health jsonb,
  updated_at timestamptz not null default now()
);

create table signals (
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  owner_id uuid not null,
  name text not null,
  value_num numeric, value_text text, value_json jsonb,
  recorded_at timestamptz not null,
  primary key (vehicle_id, name, recorded_at)
) partition by range (recorded_at);

-- partitions for the next 14 months; a later cron extends them
do $$
declare d date := date_trunc('month', now())::date; i int;
begin
  for i in 0..13 loop
    execute format('create table if not exists signals_%s partition of signals for values from (%L) to (%L)',
      to_char(d + (i||' month')::interval, 'YYYYMM'), d + (i||' month')::interval, d + ((i+1)||' month')::interval);
  end loop;
end $$;

create table places (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null, lat numeric not null, lng numeric not null,
  radius_m int not null default 150, kind text not null default 'other' check (kind in ('home','work','other'))
);

create table drives (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  owner_id uuid not null,
  started_at timestamptz not null, ended_at timestamptz,
  start_lat numeric, start_lng numeric, end_lat numeric, end_lng numeric,
  start_place_id uuid references places(id), end_place_id uuid references places(id),
  start_odometer_km numeric, end_odometer_km numeric, distance_km numeric,
  start_soc numeric, end_soc numeric, energy_kwh numeric, wh_per_km numeric, max_speed_kph numeric,
  inside_c_start numeric, outside_c_start numeric,
  created_at timestamptz not null default now()
);

create table charges (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  owner_id uuid not null,
  started_at timestamptz not null, ended_at timestamptz,
  lat numeric, lng numeric, place_id uuid references places(id),
  start_soc numeric, end_soc numeric, energy_added_kwh numeric, energy_drawn_kwh numeric,
  peak_power_kw numeric, charger_type text check (charger_type in ('ac','dc_supercharger','dc_other')),
  cost_minor int, currency text not null default 'GBP', tariff_id uuid,
  created_at timestamptz not null default now()
);

create table api_usage (
  owner_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('signals','commands','data','wakes')),
  month date not null,
  count bigint not null default 0,
  primary key (owner_id, category, month)
);

create table tesla_credentials (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  refresh_token_enc bytea not null,
  access_token text,
  access_expires_at timestamptz,
  rotated_at timestamptz not null default now(),
  last_error text
);

-- RLS
alter table vehicles enable row level security;
alter table vehicle_state enable row level security;
alter table signals enable row level security;
alter table places enable row level security;
alter table drives enable row level security;
alter table charges enable row level security;
alter table api_usage enable row level security;
alter table tesla_credentials enable row level security;

create policy owner_all on vehicles      for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy owner_read on vehicle_state for select using (owner_id = auth.uid());
create policy owner_read on signals       for select using (owner_id = auth.uid());
create policy owner_all on places        for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy owner_read on drives        for select using (owner_id = auth.uid());
create policy owner_read on charges       for select using (owner_id = auth.uid());
create policy owner_read on api_usage     for select using (owner_id = auth.uid());
-- tesla_credentials: no user policies at all; service role only.

-- Realtime
alter publication supabase_realtime add table vehicle_state;
```

- [ ] **Step 3: Write the functions migration**

`supabase/migrations/0002_functions.sql`:
```sql
create or replace function increment_usage(p_owner uuid, p_category text, p_count bigint default 1)
returns void language sql security definer set search_path = public as $$
  insert into api_usage(owner_id, category, month, count)
  values (p_owner, p_category, date_trunc('month', now())::date, p_count)
  on conflict (owner_id, category, month) do update set count = api_usage.count + excluded.count;
$$;

create or replace function set_budget_mode(p_vehicle uuid, p_mode text)
returns void language sql security definer set search_path = public as $$
  update vehicles set budget_mode = p_mode where id = p_vehicle;
$$;

revoke execute on function increment_usage(uuid, text, bigint) from public, anon, authenticated;
revoke execute on function set_budget_mode(uuid, text) from public, anon, authenticated;
```

- [ ] **Step 4: Write the RLS test**

`supabase/package.json`:
```json
{ "name": "@garage/supabase", "private": true, "type": "module",
  "scripts": { "test": "vitest run", "typecheck": "tsc --noEmit -p ." },
  "devDependencies": { "@supabase/supabase-js": "^2.45.4", "vitest": "^2.1.3", "typescript": "^5.6.3" } }
```
Add `supabase/tsconfig.json`: `{ "extends": "../tsconfig.base.json", "include": ["tests"] }`.

`supabase/tests/helpers.ts`:
```ts
import { createClient } from "@supabase/supabase-js";
const url = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const anon = process.env.SUPABASE_ANON_KEY!;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY!;
export const admin = createClient(url, service, { auth: { persistSession: false } });
export async function userClient(email: string) {
  const { data, error } = await admin.auth.admin.createUser({ email, password: "pass-1234", email_confirm: true });
  if (error && !/already/.test(error.message)) throw error;
  const c = createClient(url, anon, { auth: { persistSession: false } });
  const s = await c.auth.signInWithPassword({ email, password: "pass-1234" });
  if (s.error) throw s.error;
  return { client: c, id: s.data.user!.id };
}
```

`supabase/tests/rls.test.ts`:
```ts
import { describe, it, expect, beforeAll } from "vitest";
import { admin, userClient } from "./helpers";

describe("row level security", () => {
  let a: Awaited<ReturnType<typeof userClient>>, b: typeof a;
  beforeAll(async () => {
    a = await userClient("a@test.local"); b = await userClient("b@test.local");
    await admin.from("vehicles").insert({ owner_id: a.id, vin: "VINAAAA", display_name: "A car" });
  });
  it("owner reads own vehicle", async () => {
    const { data } = await a.client.from("vehicles").select("vin");
    expect(data?.map(v => v.vin)).toContain("VINAAAA");
  });
  it("other user sees nothing", async () => {
    const { data } = await b.client.from("vehicles").select("vin");
    expect(data).toEqual([]);
  });
  it("users cannot read tesla_credentials", async () => {
    await admin.from("tesla_credentials").insert({ owner_id: a.id, refresh_token_enc: "\\x00" });
    const { data } = await a.client.from("tesla_credentials").select("*");
    expect(data).toEqual([]);
  });
  it("increment_usage is service-only", async () => {
    const { error } = await a.client.rpc("increment_usage", { p_owner: a.id, p_category: "commands", p_count: 1 });
    expect(error).not.toBeNull();
    const { error: e2 } = await admin.rpc("increment_usage", { p_owner: a.id, p_category: "commands", p_count: 1 });
    expect(e2).toBeNull();
  });
});
```

- [ ] **Step 5: Run the stack and the tests (expect failure first)**

Run: `cd /Users/duncanbottrill/garage && supabase start && supabase status -o env > supabase/.env.local`
Then: `set -a; source supabase/.env.local; set +a; export SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=$ANON_KEY SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY; pnpm --filter @garage/supabase test`
Expected before `supabase db reset`: FAIL (relation "vehicles" does not exist).

- [ ] **Step 6: Apply migrations and re-run**

Run: `supabase db reset && pnpm --filter @garage/supabase test`
Expected: 4 passed.

- [ ] **Step 7: Commit**

```bash
git add supabase && git commit -m "feat(db): slice 1 schema, RLS, usage functions, realtime

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 3: `@garage/core` — types, crypto, budget

**Files:**
- Create: `packages/core/package.json`, `packages/core/tsconfig.json`, `packages/core/src/index.ts`, `packages/core/src/types.ts`, `packages/core/src/crypto.ts`, `packages/core/src/budget.ts`, `packages/core/test/crypto.test.ts`, `packages/core/test/budget.test.ts`

**Interfaces:**
- Produces:
  - `type BudgetMode = 'normal' | 'reduced' | 'minimal'`
  - `interface VehicleStateRow` (mirrors `vehicle_state` columns, all optional except `vehicle_id`, `owner_id`)
  - `type UsageCategory = 'signals' | 'commands' | 'data' | 'wakes'`
  - `encryptToken(plain: string, keyB64: string): Uint8Array` / `decryptToken(cipher: Uint8Array, keyB64: string): string`
  - `PRICES_USD_PER_UNIT`, `costUsd(counts: Record<UsageCategory, number>): number`, `projectMonthSpend(counts, now: Date): number`, `budgetModeFor(projectedUsd: number, budgetUsd: number): BudgetMode`

- [ ] **Step 1: Package files**

`packages/core/package.json`:
```json
{ "name": "@garage/core", "version": "0.0.1", "private": true, "type": "module",
  "exports": { ".": "./src/index.ts" },
  "scripts": { "test": "vitest run", "typecheck": "tsc --noEmit -p ." },
  "dependencies": { "@noble/ciphers": "^1.0.0" },
  "devDependencies": { "vitest": "^2.1.3", "typescript": "^5.6.3" } }
```
`packages/core/tsconfig.json`: `{ "extends": "../../tsconfig.base.json", "include": ["src", "test"] }`

`packages/core/src/types.ts`:
```ts
export type BudgetMode = "normal" | "reduced" | "minimal";
export type UsageCategory = "signals" | "commands" | "data" | "wakes";

export interface VehicleStateRow {
  vehicle_id: string; owner_id: string;
  soc?: number | null; range_km?: number | null; charge_state?: string | null; charger_power_kw?: number | null;
  charge_limit_soc?: number | null; charge_port_open?: boolean | null; scheduled_charge_at?: string | null; charge_at?: string | null;
  inside_c?: number | null; outside_c?: number | null; hvac_on?: boolean | null; climate_keeper?: string | null; climate_at?: string | null;
  lat?: number | null; lng?: number | null; heading?: number | null; speed_kph?: number | null; gear?: string | null; odometer_km?: number | null; location_at?: string | null;
  locked?: boolean | null; doors?: Record<string, boolean> | null; windows?: Record<string, boolean> | null; frunk_open?: boolean | null; trunk_open?: boolean | null; body_at?: string | null;
  tpms_bar?: Record<string, number> | null; sentry?: boolean | null;
  sleep_state?: string | null; software_version?: string | null; bridge_seen_at?: string | null; bridge_health?: Record<string, unknown> | null;
  updated_at?: string;
}
```

`packages/core/src/crypto.ts`:
```ts
import { xchacha20poly1305 } from "@noble/ciphers/chacha";
import { randomBytes } from "@noble/ciphers/webcrypto";

const key = (b64: string) => { const k = Buffer.from(b64, "base64"); if (k.length !== 32) throw new Error("TOKEN_ENC_KEY must be 32 bytes"); return new Uint8Array(k); };

export function encryptToken(plain: string, keyB64: string): Uint8Array {
  const nonce = randomBytes(24);
  const ct = xchacha20poly1305(key(keyB64), nonce).encrypt(new TextEncoder().encode(plain));
  const out = new Uint8Array(24 + ct.length); out.set(nonce); out.set(ct, 24); return out;
}
export function decryptToken(cipher: Uint8Array, keyB64: string): string {
  const nonce = cipher.slice(0, 24), ct = cipher.slice(24);
  return new TextDecoder().decode(xchacha20poly1305(key(keyB64), nonce).decrypt(ct));
}
```

`packages/core/src/budget.ts`:
```ts
import type { BudgetMode, UsageCategory } from "./types";
export const PRICES_USD_PER_UNIT: Record<UsageCategory, number> = { signals: 1 / 150_000, commands: 1 / 1_000, data: 1 / 500, wakes: 1 / 50 };
export function costUsd(counts: Partial<Record<UsageCategory, number>>): number {
  return (Object.keys(PRICES_USD_PER_UNIT) as UsageCategory[]).reduce((s, k) => s + (counts[k] ?? 0) * PRICES_USD_PER_UNIT[k], 0);
}
export function projectMonthSpend(counts: Partial<Record<UsageCategory, number>>, now: Date): number {
  const day = now.getUTCDate();
  const daysInMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate();
  return costUsd(counts) * (daysInMonth / Math.max(day, 1));
}
export function budgetModeFor(projectedUsd: number, budgetUsd: number): BudgetMode {
  const r = projectedUsd / budgetUsd;
  return r >= 0.9 ? "minimal" : r >= 0.7 ? "reduced" : "normal";
}
```

`packages/core/src/index.ts`:
```ts
export * from "./types"; export * from "./crypto"; export * from "./budget";
```

- [ ] **Step 2: Tests**

`packages/core/test/crypto.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { encryptToken, decryptToken } from "../src/crypto";
const KEY = Buffer.alloc(32, 7).toString("base64");
describe("token crypto", () => {
  it("round-trips", () => { expect(decryptToken(encryptToken("rt_abc", KEY), KEY)).toBe("rt_abc"); });
  it("uses a fresh nonce", () => { expect(Buffer.from(encryptToken("x", KEY))).not.toEqual(Buffer.from(encryptToken("x", KEY))); });
  it("rejects a wrong key", () => { expect(() => decryptToken(encryptToken("x", KEY), Buffer.alloc(32, 8).toString("base64"))).toThrow(); });
  it("rejects short keys", () => { expect(() => encryptToken("x", "c2hvcnQ=")).toThrow(/32 bytes/); });
});
```

`packages/core/test/budget.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { costUsd, projectMonthSpend, budgetModeFor } from "../src/budget";
describe("budget", () => {
  it("prices per Tesla table", () => { expect(costUsd({ signals: 150_000, commands: 1_000, data: 500, wakes: 50 })).toBeCloseTo(4, 6); });
  it("projects linearly across the month", () => {
    const d = new Date(Date.UTC(2026, 9, 10)); // 10 Oct, 31-day month
    expect(projectMonthSpend({ commands: 1_000 }, d)).toBeCloseTo(3.1, 6);
  });
  it("maps thresholds", () => {
    expect(budgetModeFor(6.9, 10)).toBe("normal"); expect(budgetModeFor(7, 10)).toBe("reduced"); expect(budgetModeFor(9, 10)).toBe("minimal");
  });
});
```

- [ ] **Step 3: Run (fail), install, run (pass)**

Run: `pnpm install && pnpm --filter @garage/core test`
Expected: 7 passed.

- [ ] **Step 4: Commit**

```bash
git add packages/core pnpm-lock.yaml && git commit -m "feat(core): types, token crypto, budget maths

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `@garage/core` — Fleet API client and state mappers

**Files:**
- Create: `packages/core/src/tesla/client.ts`, `packages/core/src/tesla/map-vehicle-data.ts`, `packages/core/src/tesla/map-telemetry.ts`, `packages/core/test/client.test.ts`, `packages/core/test/map-vehicle-data.test.ts`, `packages/core/test/map-telemetry.test.ts`, `packages/core/test/fixtures/vehicle_data.json`
- Modify: `packages/core/src/index.ts`

**Interfaces:**
- Produces:
  - `class FleetClient { constructor(opts: { baseUrl: string; token: string; fetch?: typeof fetch }); get<T>(path): Promise<T>; post<T>(path, body?): Promise<T>; }` throwing `FleetError { status: number; code?: string; body: unknown }`
  - `vehicleDataToState(payload: VehicleDataResponse, at: Date): Partial<VehicleStateRow>`
  - `telemetrySignalToState(name: string, value: unknown, at: Date): Partial<VehicleStateRow>` (unknown names → `{}`)
  - Unit helpers: `milesToKm`, `fToC` (Fleet `vehicle_data` reports °C already; telemetry temps are °C; range in miles → km), `psiToBar`

- [ ] **Step 1: Client**

`packages/core/src/tesla/client.ts`:
```ts
export class FleetError extends Error {
  constructor(public status: number, public body: unknown, public code?: string) { super(`Fleet API ${status}${code ? " " + code : ""}`); }
}
export class FleetClient {
  private f: typeof fetch;
  constructor(private opts: { baseUrl: string; token: string; fetch?: typeof fetch }) { this.f = opts.fetch ?? fetch; }
  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const r = await this.f(this.opts.baseUrl + path, {
      method, headers: { authorization: `Bearer ${this.opts.token}`, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text(); let json: any = null; try { json = text ? JSON.parse(text) : null; } catch { json = text; }
    if (!r.ok) throw new FleetError(r.status, json, json?.error ?? json?.error_description);
    return (json?.response ?? json) as T;
  }
  get<T>(path: string) { return this.call<T>("GET", path); }
  post<T>(path: string, body?: unknown) { return this.call<T>("POST", path, body); }
}
```

- [ ] **Step 2: Mappers**

`packages/core/src/tesla/map-vehicle-data.ts`:
```ts
import type { VehicleStateRow } from "../types";
export const milesToKm = (mi: number) => mi * 1.609344;
export const psiToBar = (psi: number) => psi * 0.0689476;
export interface VehicleDataResponse {
  state?: string; vehicle_state?: any; charge_state?: any; climate_state?: any; drive_state?: any;
}
export function vehicleDataToState(p: VehicleDataResponse, at: Date): Partial<VehicleStateRow> {
  const iso = at.toISOString(); const cs = p.charge_state ?? {}, cl = p.climate_state ?? {}, ds = p.drive_state ?? {}, vs = p.vehicle_state ?? {};
  const out: Partial<VehicleStateRow> = { updated_at: iso };
  if (cs.battery_level != null) { out.soc = cs.battery_level; out.charge_at = iso; }
  if (cs.battery_range != null) out.range_km = milesToKm(cs.battery_range);
  if (cs.charging_state != null) out.charge_state = String(cs.charging_state).toLowerCase();
  if (cs.charger_power != null) out.charger_power_kw = cs.charger_power;
  if (cs.charge_limit_soc != null) out.charge_limit_soc = cs.charge_limit_soc;
  if (cs.charge_port_door_open != null) out.charge_port_open = !!cs.charge_port_door_open;
  if (cl.inside_temp != null) { out.inside_c = cl.inside_temp; out.climate_at = iso; }
  if (cl.outside_temp != null) out.outside_c = cl.outside_temp;
  if (cl.is_climate_on != null) out.hvac_on = !!cl.is_climate_on;
  if (cl.climate_keeper_mode != null) out.climate_keeper = cl.climate_keeper_mode;
  if (ds.latitude != null && ds.longitude != null) { out.lat = ds.latitude; out.lng = ds.longitude; out.location_at = iso; }
  if (ds.heading != null) out.heading = ds.heading;
  if (ds.speed != null) out.speed_kph = milesToKm(ds.speed); else if (ds.shift_state != null) out.speed_kph = 0;
  if (ds.shift_state !== undefined) out.gear = ds.shift_state ?? "P";
  if (vs.odometer != null) out.odometer_km = milesToKm(vs.odometer);
  if (vs.locked != null) { out.locked = !!vs.locked; out.body_at = iso; }
  if (vs.df != null) out.doors = { fl: !!vs.df, fr: !!vs.pf, rl: !!vs.dr, rr: !!vs.pr };
  if (vs.fd_window != null) out.windows = { fl: !!vs.fd_window, fr: !!vs.fp_window, rl: !!vs.rd_window, rr: !!vs.rp_window };
  if (vs.ft != null) out.frunk_open = !!vs.ft; if (vs.rt != null) out.trunk_open = !!vs.rt;
  if (vs.tpms_pressure_fl != null) out.tpms_bar = { fl: vs.tpms_pressure_fl, fr: vs.tpms_pressure_fr, rl: vs.tpms_pressure_rl, rr: vs.tpms_pressure_rr };
  if (vs.sentry_mode != null) out.sentry = !!vs.sentry_mode;
  if (vs.car_version != null) out.software_version = String(vs.car_version).split(" ")[0];
  if (p.state != null) out.sleep_state = p.state; // 'online' | 'asleep' | 'offline'
  return out;
}
```

`packages/core/src/tesla/map-telemetry.ts`:
```ts
import type { VehicleStateRow } from "../types";
import { milesToKm, psiToBar } from "./map-vehicle-data";
const num = (v: unknown) => (typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" && !isNaN(+v) ? +v : null);
const bool = (v: unknown) => (typeof v === "boolean" ? v : v === "true" ? true : v === "false" ? false : null);
export function telemetrySignalToState(name: string, value: unknown, at: Date): Partial<VehicleStateRow> {
  const iso = at.toISOString(); const n = num(value), b = bool(value);
  switch (name) {
    case "Soc": case "BatteryLevel": return n == null ? {} : { soc: n, charge_at: iso };
    case "EstBatteryRange": case "IdealBatteryRange": return n == null ? {} : { range_km: milesToKm(n) };
    case "ChargeState": case "DetailedChargeState": return { charge_state: String(value).replace(/^DetailedChargeState/, "").toLowerCase() };
    case "ACChargingPower": case "DCChargingPower": case "ChargerPower": return n == null ? {} : { charger_power_kw: n };
    case "ChargeLimitSoc": return n == null ? {} : { charge_limit_soc: n };
    case "ChargePortDoorOpen": return b == null ? {} : { charge_port_open: b };
    case "ScheduledChargingStartTime": return n == null ? {} : { scheduled_charge_at: new Date(n * 1000).toISOString() };
    case "InsideTemp": return n == null ? {} : { inside_c: n, climate_at: iso };
    case "OutsideTemp": return n == null ? {} : { outside_c: n };
    case "HvacPower": return { hvac_on: value === "HvacPowerStateOn" || value === true };
    case "ClimateKeeperMode": return { climate_keeper: String(value) };
    case "Location": { const v: any = value; return v && v.latitude != null ? { lat: v.latitude, lng: v.longitude, location_at: iso } : {}; }
    case "VehicleSpeed": return n == null ? {} : { speed_kph: milesToKm(n) };
    case "Odometer": return n == null ? {} : { odometer_km: milesToKm(n) };
    case "Gear": return { gear: String(value).replace(/^ShiftState/, "") || "P" };
    case "Locked": return b == null ? {} : { locked: b, body_at: iso };
    case "SentryMode": return { sentry: value === true || /On$/.test(String(value)) };
    case "TpmsPressureFl": case "TpmsPressureFr": case "TpmsPressureRl": case "TpmsPressureRr": {
      if (n == null) return {}; const k = name.slice(-2).toLowerCase(); return { tpms_bar: { [k]: n } as any }; // bar already in telemetry
    }
    case "SoftwareUpdateVersion": return { software_version: String(value) };
    default: return {};
  }
}
```
Append to `packages/core/src/index.ts`:
```ts
export * from "./tesla/client"; export * from "./tesla/map-vehicle-data"; export * from "./tesla/map-telemetry";
```

- [ ] **Step 3: Tests**

`packages/core/test/fixtures/vehicle_data.json` (trimmed real shape):
```json
{ "state": "online",
  "charge_state": { "battery_level": 72, "battery_range": 214.3, "charging_state": "Stopped", "charger_power": 0, "charge_limit_soc": 80, "charge_port_door_open": true },
  "climate_state": { "inside_temp": 19.2, "outside_temp": 11.0, "is_climate_on": false, "climate_keeper_mode": "off" },
  "drive_state": { "latitude": 51.5013, "longitude": -0.1419, "heading": 182, "speed": null, "shift_state": null },
  "vehicle_state": { "odometer": 5227.4, "locked": true, "df": 0, "pf": 0, "dr": 0, "pr": 0, "ft": 0, "rt": 0,
    "fd_window": 0, "fp_window": 0, "rd_window": 0, "rp_window": 0,
    "tpms_pressure_fl": 2.9, "tpms_pressure_fr": 2.9, "tpms_pressure_rl": 2.85, "tpms_pressure_rr": 2.9, "sentry_mode": false, "car_version": "2026.32.5 abc123" } }
```

`packages/core/test/map-vehicle-data.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import fx from "./fixtures/vehicle_data.json";
import { vehicleDataToState } from "../src/tesla/map-vehicle-data";
const at = new Date("2026-10-18T15:00:00Z");
describe("vehicleDataToState", () => {
  it("maps charge, climate, position, body", () => {
    const s = vehicleDataToState(fx as any, at);
    expect(s.soc).toBe(72); expect(s.range_km).toBeCloseTo(344.9, 1); expect(s.charge_state).toBe("stopped");
    expect(s.inside_c).toBe(19.2); expect(s.lat).toBe(51.5013); expect(s.gear).toBe("P"); expect(s.speed_kph).toBe(0);
    expect(s.odometer_km).toBeCloseTo(8412.6, 1); expect(s.locked).toBe(true); expect(s.software_version).toBe("2026.32.5");
    expect(s.sleep_state).toBe("online"); expect(s.charge_at).toBe(at.toISOString());
  });
  it("omits missing groups", () => { expect(vehicleDataToState({ state: "asleep" }, at)).toEqual({ updated_at: at.toISOString(), sleep_state: "asleep" }); });
});
```

`packages/core/test/map-telemetry.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { telemetrySignalToState as m } from "../src/tesla/map-telemetry";
const at = new Date("2026-10-18T15:00:00Z"), iso = at.toISOString();
describe("telemetrySignalToState", () => {
  it("Soc", () => expect(m("Soc", 72.4, at)).toEqual({ soc: 72.4, charge_at: iso }));
  it("range miles→km", () => expect(m("EstBatteryRange", "100", at).range_km).toBeCloseTo(160.93, 2));
  it("Location", () => expect(m("Location", { latitude: 1, longitude: 2 }, at)).toEqual({ lat: 1, lng: 2, location_at: iso }));
  it("Gear strips prefix", () => expect(m("Gear", "ShiftStateD", at)).toEqual({ gear: "D" }));
  it("DetailedChargeState", () => expect(m("DetailedChargeState", "DetailedChargeStateCharging", at)).toEqual({ charge_state: "charging" }));
  it("unknown → {}", () => expect(m("Nonsense", 1, at)).toEqual({}));
  it("bad numbers → {}", () => expect(m("Soc", "n/a", at)).toEqual({}));
});
```

`packages/core/test/client.test.ts`:
```ts
import { describe, it, expect, vi } from "vitest";
import { FleetClient, FleetError } from "../src/tesla/client";
const mk = (status: number, body: unknown) => vi.fn(async () => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }));
describe("FleetClient", () => {
  it("unwraps response envelope and sends bearer", async () => {
    const f = mk(200, { response: { ok: 1 } });
    const c = new FleetClient({ baseUrl: "https://x", token: "T", fetch: f as any });
    expect(await c.get("/a")).toEqual({ ok: 1 });
    expect((f.mock.calls[0] as any)[1].headers.authorization).toBe("Bearer T");
  });
  it("throws FleetError with status and code", async () => {
    const c = new FleetClient({ baseUrl: "https://x", token: "T", fetch: mk(408, { error: "vehicle unavailable" }) as any });
    await expect(c.post("/b", {})).rejects.toMatchObject({ status: 408, code: "vehicle unavailable" } satisfies Partial<FleetError>);
  });
});
```

- [ ] **Step 4: Run**

Run: `pnpm --filter @garage/core test`
Expected: 18 passed (7 from Task 3 + 11 new).

- [ ] **Step 5: Commit**

```bash
git add packages/core && git commit -m "feat(core): Fleet client and vehicle_data/telemetry → state mappers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 5: `@garage/tokens` — design tokens and generators

**Files:**
- Create: `packages/tokens/package.json`, `packages/tokens/tsconfig.json`, `packages/tokens/tokens.json`, `packages/tokens/src/generate.ts`, `packages/tokens/test/generate.test.ts`

**Interfaces:**
- Produces: `tokens.json` (single source), `generateCss(tokens): string`, `generateSwift(tokens): string`, build output `dist/tokens.css` and `dist/Tokens.swift` (Plan 1C copies the Swift file into GarageKit; the dashboard in slice 2 imports the CSS).

- [ ] **Step 1: Tokens file** (values from Figma 04 style guide)

`packages/tokens/tokens.json`:
```json
{
  "color": {
    "background": "#0B0F14", "mapGround": "#0D1218", "roadMinor": "#19212A", "roadMajor": "#233040", "water": "#0A1A26",
    "glass": "#0F151C", "ink": "#EAF0F6", "muted": "#7D8A99", "accent": "#4FE3FF", "charging": "#3DDC97", "warning": "#FFB020", "danger": "#F26D6D"
  },
  "opacity": { "glass": 0.86, "glassStrong": 0.9, "hairline": 0.08, "accentFill": 0.14, "accentStroke": 0.5 },
  "radius": { "sheet": 28, "pill": 22, "control": 18, "tile": 16, "dock": 30 },
  "space": { "xs": 4, "s": 8, "m": 12, "l": 16, "xl": 20, "xxl": 24, "xxxl": 32 },
  "blur": { "glass": 24, "dock": 28 },
  "type": {
    "display": { "family": "Big Shoulders Display", "weight": 600 },
    "ui": { "family": "Instrument Sans", "weight": 400 },
    "uiMedium": { "family": "Instrument Sans", "weight": 500 },
    "scale": {
      "numeralHero":  { "role": "display", "size": 84, "lineHeight": 0.84, "tracking": -0.02 },
      "numeralL":     { "role": "display", "size": 34, "lineHeight": 0.9,  "tracking": 0 },
      "numeralM":     { "role": "display", "size": 30, "lineHeight": 1.0,  "tracking": 0 },
      "numeralS":     { "role": "display", "size": 22, "lineHeight": 0.9,  "tracking": 0 },
      "title":        { "role": "uiMedium", "size": 17, "lineHeight": 1.3, "tracking": 0 },
      "body":         { "role": "ui",       "size": 14, "lineHeight": 1.4, "tracking": 0 },
      "caption":      { "role": "ui",       "size": 12, "lineHeight": 1.3, "tracking": 0 },
      "label":        { "role": "uiMedium", "size": 11, "lineHeight": 1.3, "tracking": 0.12 },
      "labelS":       { "role": "uiMedium", "size": 10, "lineHeight": 1.3, "tracking": 0.12 }
    }
  }
}
```

- [ ] **Step 2: Generator**

`packages/tokens/package.json`:
```json
{ "name": "@garage/tokens", "version": "0.0.1", "private": true, "type": "module",
  "scripts": { "build": "tsx src/generate.ts", "test": "vitest run", "typecheck": "tsc --noEmit -p ." },
  "devDependencies": { "tsx": "^4.19.1", "vitest": "^2.1.3", "typescript": "^5.6.3" } }
```
`packages/tokens/tsconfig.json`: `{ "extends": "../../tsconfig.base.json", "include": ["src", "test"] }`

`packages/tokens/src/generate.ts`:
```ts
import { mkdirSync, writeFileSync } from "node:fs";
import tokens from "../tokens.json" with { type: "json" };
type Tokens = typeof tokens;
const kebab = (s: string) => s.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase());

export function generateCss(t: Tokens): string {
  const lines: string[] = [":root {"];
  for (const [k, v] of Object.entries(t.color)) lines.push(`  --color-${kebab(k)}: ${v};`);
  for (const [k, v] of Object.entries(t.opacity)) lines.push(`  --opacity-${kebab(k)}: ${v};`);
  for (const [k, v] of Object.entries(t.radius)) lines.push(`  --radius-${kebab(k)}: ${v}px;`);
  for (const [k, v] of Object.entries(t.space)) lines.push(`  --space-${k}: ${v}px;`);
  for (const [k, v] of Object.entries(t.blur)) lines.push(`  --blur-${kebab(k)}: ${v}px;`);
  lines.push(`  --font-display: "${t.type.display.family}";`, `  --font-ui: "${t.type.ui.family}";`);
  for (const [k, s] of Object.entries(t.type.scale)) {
    const role = (t.type as any)[s.role];
    lines.push(`  --type-${kebab(k)}: ${role.weight} ${s.size}px/${s.lineHeight} "${role.family}";`, `  --tracking-${kebab(k)}: ${s.tracking}em;`);
  }
  lines.push("}"); return lines.join("\n") + "\n";
}

export function generateSwift(t: Tokens): string {
  const hex = (h: string) => { const n = parseInt(h.slice(1), 16); return `Color(red: ${((n >> 16) & 255) / 255}, green: ${((n >> 8) & 255) / 255}, blue: ${(n & 255) / 255})`; };
  const out: string[] = ["// Generated by @garage/tokens. Do not edit.", "import SwiftUI", "", "public enum Tokens {", "  public enum Colors {"];
  for (const [k, v] of Object.entries(t.color)) out.push(`    public static let ${k} = ${hex(v)}`);
  out.push("  }", "  public enum Opacity {"); for (const [k, v] of Object.entries(t.opacity)) out.push(`    public static let ${k}: Double = ${v}`);
  out.push("  }", "  public enum Radius {"); for (const [k, v] of Object.entries(t.radius)) out.push(`    public static let ${k}: CGFloat = ${v}`);
  out.push("  }", "  public enum Space {"); for (const [k, v] of Object.entries(t.space)) out.push(`    public static let ${k}: CGFloat = ${v}`);
  out.push("  }", "  public enum Blur {"); for (const [k, v] of Object.entries(t.blur)) out.push(`    public static let ${k}: CGFloat = ${v}`);
  out.push("  }", "  public struct TextStyle { public let family: String; public let weight: Font.Weight; public let size: CGFloat; public let lineHeight: CGFloat; public let tracking: CGFloat }", "  public enum Type {");
  const w = (n: number) => (n >= 600 ? ".semibold" : n >= 500 ? ".medium" : ".regular");
  for (const [k, s] of Object.entries(t.type.scale)) { const role = (t.type as any)[s.role]; out.push(`    public static let ${k} = TextStyle(family: "${role.family}", weight: ${w(role.weight)}, size: ${s.size}, lineHeight: ${s.lineHeight}, tracking: ${s.tracking})`); }
  out.push("  }", "}", ""); return out.join("\n");
}

if (process.argv[1]?.endsWith("generate.ts")) {
  mkdirSync(new URL("../dist/", import.meta.url), { recursive: true });
  writeFileSync(new URL("../dist/tokens.css", import.meta.url), generateCss(tokens));
  writeFileSync(new URL("../dist/Tokens.swift", import.meta.url), generateSwift(tokens));
  console.log("tokens written");
}
```

- [ ] **Step 3: Test**

`packages/tokens/test/generate.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import tokens from "../tokens.json" with { type: "json" };
import { generateCss, generateSwift } from "../src/generate";
describe("token generators", () => {
  it("css has every colour and the hero type", () => {
    const css = generateCss(tokens);
    expect(css).toContain("--color-accent: #4FE3FF;"); expect(css).toContain('--type-numeral-hero: 600 84px/0.84 "Big Shoulders Display";'); expect(css).toContain("--radius-sheet: 28px;");
  });
  it("swift compiles-looking output", () => {
    const s = generateSwift(tokens);
    expect(s).toContain("public static let accent = Color(red:"); expect(s).toContain('numeralHero = TextStyle(family: "Big Shoulders Display", weight: .semibold, size: 84');
  });
});
```

- [ ] **Step 4: Run and build**

Run: `pnpm install && pnpm --filter @garage/tokens test && pnpm --filter @garage/tokens build && head -5 packages/tokens/dist/Tokens.swift`
Expected: 2 passed; `tokens written`; Swift header printed.

- [ ] **Step 5: Commit**

```bash
git add packages/tokens pnpm-lock.yaml && git commit -m "feat(tokens): design tokens with CSS and Swift generators

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `apps/web` scaffold — env, Supabase helpers, rate limit, health, public key

**Files:**
- Create: `apps/web/package.json`, `apps/web/next.config.ts`, `apps/web/tsconfig.json`, `apps/web/vercel.json`, `apps/web/vitest.config.ts`, `apps/web/src/lib/env.ts`, `apps/web/src/lib/supabase.ts`, `apps/web/src/lib/ratelimit.ts`, `apps/web/src/app/api/health/route.ts`, `apps/web/src/app/layout.tsx`, `apps/web/src/app/page.tsx`, `apps/web/public/.well-known/appspecific/.gitkeep`, `apps/web/test/env.test.ts`, `apps/web/test/health.test.ts`

**Interfaces:**
- Produces:
  - `env()` → typed object `{ TESLA_CLIENT_ID, TESLA_CLIENT_SECRET, TESLA_REDIRECT_URI, TESLA_FLEET_BASE, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, TOKEN_ENC_KEY, CRON_SECRET, UPSTASH_REDIS_REST_URL?, UPSTASH_REDIS_REST_TOKEN?, APP_RETURN_URL }`, throws listing missing names.
  - `serviceClient()` → supabase-js client with service role.
  - `userFromRequest(req: Request)` → `{ id: string } | null` from `Authorization: Bearer <supabase jwt>`.
  - `limit(key: string, req: Request)` → `{ ok: boolean }` (10 req/min per user per key; passes when Upstash env is absent, so local dev works).
  - `requireCron(req)` → boolean (header `authorization: Bearer ${CRON_SECRET}`).

- [ ] **Step 1: App files**

`apps/web/package.json`:
```json
{ "name": "@garage/web", "private": true, "type": "module",
  "scripts": { "dev": "next dev -p 3000", "build": "next build", "start": "next start", "test": "vitest run", "typecheck": "tsc --noEmit -p ." },
  "dependencies": { "next": "15.0.3", "react": "19.0.0-rc-66855b96-20241106", "react-dom": "19.0.0-rc-66855b96-20241106",
    "@supabase/supabase-js": "^2.45.4", "@upstash/ratelimit": "^2.0.3", "@upstash/redis": "^1.34.3", "@garage/core": "workspace:*" },
  "devDependencies": { "typescript": "^5.6.3", "vitest": "^2.1.3", "@types/node": "^22.7.5", "@types/react": "^18.3.12" } }
```
`apps/web/next.config.ts`: `export default { transpilePackages: ["@garage/core"] };`
`apps/web/tsconfig.json`:
```json
{ "extends": "../../tsconfig.base.json", "compilerOptions": { "jsx": "preserve", "lib": ["dom", "ES2022"], "plugins": [{ "name": "next" }], "paths": { "@/*": ["./src/*"] }, "noEmit": true, "allowJs": true, "incremental": true }, "include": ["next-env.d.ts", "src", "test", "scripts"], "exclude": ["node_modules"] }
```
`apps/web/vitest.config.ts`: `export default { test: { environment: "node" }, resolve: { alias: { "@": new URL("./src", import.meta.url).pathname } } };`
`apps/web/vercel.json`:
```json
{ "crons": [ { "path": "/api/cron/tesla-refresh", "schedule": "0 */4 * * *" }, { "path": "/api/cron/budget", "schedule": "15 6 * * *" } ],
  "headers": [ { "source": "/.well-known/appspecific/(.*)", "headers": [ { "key": "Content-Type", "value": "application/x-pem-file" }, { "key": "Cache-Control", "value": "public, max-age=3600" } ] } ] }
```
`apps/web/src/app/layout.tsx`: `export default function L({ children }: { children: React.ReactNode }) { return <html lang="en"><body style={{ background: "#0B0F14", color: "#EAF0F6", fontFamily: "system-ui" }}>{children}</body></html>; }`
`apps/web/src/app/page.tsx`: `export default function P() { return <main style={{ padding: 40 }}><p>garage</p></main>; }`

`apps/web/src/lib/env.ts`:
```ts
const REQUIRED = ["TESLA_CLIENT_ID","TESLA_CLIENT_SECRET","TESLA_REDIRECT_URI","TESLA_FLEET_BASE","SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TOKEN_ENC_KEY","CRON_SECRET","APP_RETURN_URL"] as const;
const OPTIONAL = ["UPSTASH_REDIS_REST_URL","UPSTASH_REDIS_REST_TOKEN"] as const;
type Env = Record<(typeof REQUIRED)[number], string> & Partial<Record<(typeof OPTIONAL)[number], string>>;
export function env(source: NodeJS.ProcessEnv = process.env): Env {
  const missing = REQUIRED.filter((k) => !source[k]);
  if (missing.length) throw new Error("Missing env: " + missing.join(", "));
  const out: any = {}; for (const k of [...REQUIRED, ...OPTIONAL]) out[k] = source[k]; return out as Env;
}
```

`apps/web/src/lib/supabase.ts`:
```ts
import { createClient } from "@supabase/supabase-js";
import { env } from "./env";
export function serviceClient() { const e = env(); return createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } }); }
export async function userFromRequest(req: Request): Promise<{ id: string } | null> {
  const h = req.headers.get("authorization") ?? ""; const jwt = h.startsWith("Bearer ") ? h.slice(7) : null; if (!jwt) return null;
  const e = env(); const c = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { data, error } = await c.auth.getUser(jwt); if (error || !data.user) return null; return { id: data.user.id };
}
export function requireCron(req: Request) { return req.headers.get("authorization") === `Bearer ${env().CRON_SECRET}`; }
```

`apps/web/src/lib/ratelimit.ts`:
```ts
import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";
import { env } from "./env";
let rl: Ratelimit | null | undefined;
function limiter() {
  if (rl !== undefined) return rl; const e = env();
  rl = e.UPSTASH_REDIS_REST_URL && e.UPSTASH_REDIS_REST_TOKEN
    ? new Ratelimit({ redis: new Redis({ url: e.UPSTASH_REDIS_REST_URL, token: e.UPSTASH_REDIS_REST_TOKEN }), limiter: Ratelimit.slidingWindow(10, "1 m"), prefix: "garage" }) : null;
  return rl;
}
export async function limit(key: string, userId: string): Promise<{ ok: boolean }> {
  const l = limiter(); if (!l) return { ok: true }; const r = await l.limit(`${key}:${userId}`); return { ok: r.success };
}
```

`apps/web/src/app/api/health/route.ts`:
```ts
export const dynamic = "force-dynamic";
export function GET() { return Response.json({ ok: true, service: "garage-web", at: new Date().toISOString() }); }
```

- [ ] **Step 2: Tests**

`apps/web/test/env.test.ts`:
```ts
import { describe, it, expect } from "vitest";
import { env } from "@/lib/env";
describe("env", () => {
  it("lists missing names", () => { expect(() => env({} as any)).toThrow(/TESLA_CLIENT_ID.*CRON_SECRET/s); });
  it("returns values when present", () => {
    const src = Object.fromEntries(["TESLA_CLIENT_ID","TESLA_CLIENT_SECRET","TESLA_REDIRECT_URI","TESLA_FLEET_BASE","SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TOKEN_ENC_KEY","CRON_SECRET","APP_RETURN_URL"].map(k => [k, "x"]));
    expect(env(src as any).TESLA_CLIENT_ID).toBe("x");
  });
});
```
`apps/web/test/health.test.ts`:
```ts
import { it, expect } from "vitest";
import { GET } from "@/app/api/health/route";
it("health responds", async () => { const r = GET(); expect(r.status).toBe(200); expect((await r.json()).ok).toBe(true); });
```

- [ ] **Step 3: Install, test, build**

Run: `pnpm install && pnpm --filter @garage/web test && pnpm --filter @garage/web build`
Expected: 3 passed; Next build succeeds with routes `/`, `/api/health`.

- [ ] **Step 4: Commit**

```bash
git add apps/web pnpm-lock.yaml && git commit -m "feat(web): Next.js scaffold, env, Supabase helpers, rate limit, health

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 7: Tesla OAuth — PKCE, `/auth/start`, `/auth/callback`

**Files:**
- Create: `apps/web/src/lib/pkce.ts`, `apps/web/src/lib/tesla-auth.ts`, `apps/web/src/app/auth/start/route.ts`, `apps/web/src/app/auth/callback/route.ts`, `apps/web/test/pkce.test.ts`, `apps/web/test/tesla-auth.test.ts`, `apps/web/test/auth-routes.test.ts`
- Modify: `supabase/migrations/0003_oauth_state.sql` (new table `oauth_states`)

**Interfaces:**
- Consumes: `env()`, `serviceClient()`, `userFromRequest()`, `encryptToken()` from `@garage/core`.
- Produces:
  - `createPkce()` → `{ verifier: string; challenge: string }` (S256, 64-char verifier, base64url)
  - `exchangeCode({ code, verifier, fetch? })` → `{ access_token, refresh_token, expires_in }`
  - `storeCredentials(ownerId, tokens)` writes `tesla_credentials` (encrypted refresh, plain access + expiry)
  - Table `oauth_states(state text pk, owner_id uuid, verifier text, created_at timestamptz)`
  - `GET /auth/start` (Supabase JWT required) → 302 to Tesla authorize URL
  - `GET /auth/callback?code&state` → 302 to `APP_RETURN_URL?ok=1` or `?error=<reason>`

- [ ] **Step 1: Migration**

`supabase/migrations/0003_oauth_state.sql`:
```sql
create table oauth_states (
  state text primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  verifier text not null,
  created_at timestamptz not null default now()
);
alter table oauth_states enable row level security; -- service role only
```
Run: `supabase db reset` → applied.

- [ ] **Step 2: PKCE helper and test**

`apps/web/src/lib/pkce.ts`:
```ts
import { createHash, randomBytes } from "node:crypto";
const b64url = (b: Buffer) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export function createPkce() { const verifier = b64url(randomBytes(48)); const challenge = b64url(createHash("sha256").update(verifier).digest()); return { verifier, challenge }; }
export function newState() { return b64url(randomBytes(24)); }
```
`apps/web/test/pkce.test.ts`:
```ts
import { it, expect } from "vitest"; import { createHash } from "node:crypto"; import { createPkce } from "@/lib/pkce";
it("challenge is S256 of verifier", () => {
  const { verifier, challenge } = createPkce();
  expect(verifier).toMatch(/^[A-Za-z0-9_-]{64}$/);
  expect(challenge).toBe(createHash("sha256").update(verifier).digest("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
});
```

- [ ] **Step 3: Tesla auth helper and test**

`apps/web/src/lib/tesla-auth.ts`:
```ts
import { encryptToken } from "@garage/core";
import { env } from "./env"; import { serviceClient } from "./supabase";
export const AUTH_BASE = "https://auth.tesla.com/oauth2/v3";
export const SCOPES = "openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds vehicle_location";
export function authorizeUrl(challenge: string, state: string) {
  const e = env(); const u = new URL(AUTH_BASE + "/authorize");
  u.search = new URLSearchParams({ response_type: "code", client_id: e.TESLA_CLIENT_ID, redirect_uri: e.TESLA_REDIRECT_URI, scope: SCOPES, state, code_challenge: challenge, code_challenge_method: "S256", locale: "en-GB", prompt: "login" }).toString();
  return u.toString();
}
export interface TokenSet { access_token: string; refresh_token: string; expires_in: number }
export async function exchangeCode(o: { code: string; verifier: string; fetch?: typeof fetch }): Promise<TokenSet> {
  const e = env(); const f = o.fetch ?? fetch;
  const r = await f(AUTH_BASE + "/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", client_id: e.TESLA_CLIENT_ID, client_secret: e.TESLA_CLIENT_SECRET, code: o.code, code_verifier: o.verifier, redirect_uri: e.TESLA_REDIRECT_URI, audience: e.TESLA_FLEET_BASE }) });
  if (!r.ok) throw new Error(`token exchange ${r.status}: ${await r.text()}`);
  return r.json();
}
export async function storeCredentials(ownerId: string, t: TokenSet) {
  const e = env(); const sb = serviceClient();
  const { error } = await sb.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x" + Buffer.from(encryptToken(t.refresh_token, e.TOKEN_ENC_KEY)).toString("hex"),
    access_token: t.access_token, access_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(), rotated_at: new Date().toISOString(), last_error: null });
  if (error) throw error;
}
```
`apps/web/test/tesla-auth.test.ts` (unit, env stubbed, no network):
```ts
import { describe, it, expect, vi, beforeAll } from "vitest";
beforeAll(() => { for (const [k, v] of Object.entries({ TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/auth/callback", TESLA_FLEET_BASE: "https://fleet", SUPABASE_URL: "http://x", SUPABASE_ANON_KEY: "a", SUPABASE_SERVICE_ROLE_KEY: "s", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://connected" })) process.env[k] = v; });
describe("tesla auth", () => {
  it("authorize url carries PKCE and scopes", async () => {
    const { authorizeUrl } = await import("@/lib/tesla-auth"); const u = new URL(authorizeUrl("CH", "ST"));
    expect(u.searchParams.get("code_challenge")).toBe("CH"); expect(u.searchParams.get("state")).toBe("ST"); expect(u.searchParams.get("scope")).toContain("vehicle_cmds");
  });
  it("exchangeCode posts form with verifier and audience", async () => {
    const { exchangeCode } = await import("@/lib/tesla-auth");
    const f = vi.fn(async (_u: any, init: any) => { const p = new URLSearchParams(init.body); expect(p.get("code_verifier")).toBe("V"); expect(p.get("audience")).toBe("https://fleet"); return new Response(JSON.stringify({ access_token: "A", refresh_token: "R", expires_in: 28800 }), { status: 200 }); });
    expect((await exchangeCode({ code: "C", verifier: "V", fetch: f as any })).refresh_token).toBe("R");
  });
});
```

- [ ] **Step 4: Routes**

`apps/web/src/app/auth/start/route.ts`:
```ts
import { createPkce, newState } from "@/lib/pkce"; import { authorizeUrl } from "@/lib/tesla-auth"; import { serviceClient, userFromRequest } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export async function GET(req: Request) {
  const user = await userFromRequest(req); if (!user) return new Response("unauthorized", { status: 401 });
  const { verifier, challenge } = createPkce(); const state = newState();
  const { error } = await serviceClient().from("oauth_states").insert({ state, owner_id: user.id, verifier }); if (error) return new Response("state store failed", { status: 500 });
  return Response.redirect(authorizeUrl(challenge, state), 302);
}
```
`apps/web/src/app/auth/callback/route.ts`:
```ts
import { env } from "@/lib/env"; import { serviceClient } from "@/lib/supabase"; import { exchangeCode, storeCredentials } from "@/lib/tesla-auth";
export const dynamic = "force-dynamic";
const back = (q: string) => Response.redirect(env().APP_RETURN_URL + "?" + q, 302);
export async function GET(req: Request) {
  const u = new URL(req.url); const code = u.searchParams.get("code"), state = u.searchParams.get("state");
  if (!code || !state) return back("error=missing_params");
  const sb = serviceClient();
  const { data: row } = await sb.from("oauth_states").select("owner_id, verifier, created_at").eq("state", state).maybeSingle();
  await sb.from("oauth_states").delete().eq("state", state);
  if (!row || Date.now() - new Date(row.created_at).getTime() > 10 * 60_000) return back("error=bad_state");
  try { await storeCredentials(row.owner_id, await exchangeCode({ code, verifier: row.verifier })); return back("ok=1"); }
  catch (e: any) { return back("error=" + encodeURIComponent(String(e?.message ?? e).slice(0, 120))); }
}
```

- [ ] **Step 5: Route test against local Supabase**

`apps/web/test/auth-routes.test.ts` (requires `supabase start`; the env exported in Task 2 Step 5 plus the stub values above):
```ts
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
```

- [ ] **Step 6: Run**

Run: `pnpm --filter @garage/web test`
Expected: 8 passed (3 earlier + 1 pkce + 2 tesla-auth + 3 routes; the route tests need the local stack env exported).

- [ ] **Step 7: Commit**

```bash
git add apps/web supabase/migrations/0003_oauth_state.sql && git commit -m "feat(web): Tesla OAuth with PKCE, encrypted credential storage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Token refresh cron (single rotator)

**Files:**
- Create: `apps/web/src/lib/tesla-refresh.ts`, `apps/web/src/app/api/cron/tesla-refresh/route.ts`, `apps/web/test/tesla-refresh.test.ts`

**Interfaces:**
- Consumes: `decryptToken`/`encryptToken`, `serviceClient()`, `requireCron()`, `AUTH_BASE`.
- Produces: `refreshAll({ fetch?, now? })` → `{ rotated: string[]; failed: Array<{ owner_id: string; error: string }> }`; `GET /api/cron/tesla-refresh` (cron secret) → JSON of that result.

- [ ] **Step 1: Implementation**

`apps/web/src/lib/tesla-refresh.ts`:
```ts
import { decryptToken, encryptToken } from "@garage/core";
import { env } from "./env"; import { serviceClient } from "./supabase"; import { AUTH_BASE } from "./tesla-auth";
export async function refreshAll(o: { fetch?: typeof fetch; now?: Date } = {}) {
  const e = env(); const f = o.fetch ?? fetch; const now = o.now ?? new Date(); const sb = serviceClient();
  const rotated: string[] = [], failed: { owner_id: string; error: string }[] = [];
  const { data: rows, error } = await sb.from("tesla_credentials").select("owner_id, refresh_token_enc, access_expires_at"); if (error) throw error;
  for (const row of rows ?? []) {
    // refresh when less than 3h of access remains (cron runs every 4h; access lasts 8h)
    const expMs = row.access_expires_at ? new Date(row.access_expires_at).getTime() : 0;
    if (expMs - now.getTime() > 3 * 3600_000) continue;
    try {
      const rt = decryptToken(hexToBytes(row.refresh_token_enc), e.TOKEN_ENC_KEY);
      const r = await f(AUTH_BASE + "/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "refresh_token", client_id: e.TESLA_CLIENT_ID, refresh_token: rt }) });
      if (!r.ok) throw new Error(`refresh ${r.status}: ${(await r.text()).slice(0, 200)}`);
      const t = await r.json() as { access_token: string; refresh_token: string; expires_in: number };
      const { error: ue } = await sb.from("tesla_credentials").update({ refresh_token_enc: "\\x" + Buffer.from(encryptToken(t.refresh_token, e.TOKEN_ENC_KEY)).toString("hex"),
        access_token: t.access_token, access_expires_at: new Date(now.getTime() + t.expires_in * 1000).toISOString(), rotated_at: now.toISOString(), last_error: null }).eq("owner_id", row.owner_id);
      if (ue) throw ue; rotated.push(row.owner_id);
    } catch (err: any) {
      failed.push({ owner_id: row.owner_id, error: String(err?.message ?? err) });
      await sb.from("tesla_credentials").update({ last_error: String(err?.message ?? err).slice(0, 500) }).eq("owner_id", row.owner_id);
    }
  }
  return { rotated, failed };
}
function hexToBytes(v: unknown): Uint8Array {
  // supabase-js returns bytea as "\\x..." hex string
  const s = String(v); const hex = s.startsWith("\\x") ? s.slice(2) : s; return new Uint8Array(Buffer.from(hex, "hex"));
}
```
`apps/web/src/app/api/cron/tesla-refresh/route.ts`:
```ts
import { requireCron } from "@/lib/supabase"; import { refreshAll } from "@/lib/tesla-refresh";
export const dynamic = "force-dynamic"; export const maxDuration = 60;
export async function GET(req: Request) { if (!requireCron(req)) return new Response("forbidden", { status: 403 }); return Response.json(await refreshAll()); }
```

- [ ] **Step 2: Test (local Supabase; Tesla mocked)**

`apps/web/test/tesla-refresh.test.ts`:
```ts
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
```

- [ ] **Step 3: Run**

Run: `pnpm --filter @garage/web test`
Expected: 11 passed.

- [ ] **Step 4: Commit**

```bash
git add apps/web && git commit -m "feat(web): single-rotator Tesla token refresh cron

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 9: Authenticated API — `/api/token`, `/api/usage`, `/api/vehicle-data`

**Files:**
- Create: `apps/web/src/lib/credentials.ts`, `apps/web/src/app/api/token/route.ts`, `apps/web/src/app/api/usage/route.ts`, `apps/web/src/app/api/vehicle-data/route.ts`, `apps/web/test/api-routes.test.ts`

**Interfaces:**
- Consumes: `userFromRequest`, `limit`, `serviceClient`, `FleetClient`, `vehicleDataToState`, SQL `increment_usage`.
- Produces (all require `Authorization: Bearer <supabase jwt>`):
  - `GET /api/token` → `{ access_token: string; expires_at: string }` or 404 `{ error: "not_connected" }`
  - `POST /api/usage` body `{ category: 'commands'|'wakes'; count?: number }` → `{ ok: true }`
  - `POST /api/vehicle-data` body `{ vehicle_id: string }` → `{ state: Partial<VehicleStateRow> }`; counts one `data`; 409 `{ error: "asleep" }` if Tesla says the car is unavailable (never wakes)
  - `currentAccessToken(ownerId)` → `{ token: string; expiresAt: string } | null`

- [ ] **Step 1: Shared credential read**

`apps/web/src/lib/credentials.ts`:
```ts
import { serviceClient } from "./supabase";
export async function currentAccessToken(ownerId: string) {
  const { data } = await serviceClient().from("tesla_credentials").select("access_token, access_expires_at").eq("owner_id", ownerId).maybeSingle();
  if (!data?.access_token || !data.access_expires_at || new Date(data.access_expires_at).getTime() < Date.now() + 60_000) return null;
  return { token: data.access_token, expiresAt: data.access_expires_at };
}
```

- [ ] **Step 2: Routes**

`apps/web/src/app/api/token/route.ts`:
```ts
import { userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic";
export async function GET(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("token", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const t = await currentAccessToken(u.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  return Response.json({ access_token: t.token, expires_at: t.expiresAt }, { headers: { "cache-control": "no-store" } });
}
```
`apps/web/src/app/api/usage/route.ts`:
```ts
import { serviceClient, userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit";
export const dynamic = "force-dynamic";
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("usage", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const b = await req.json().catch(() => ({})); const count = Math.min(Math.max(Number(b.count ?? 1), 1), 100);
  if (b.category !== "commands" && b.category !== "wakes") return Response.json({ error: "bad_category" }, { status: 400 });
  const { error } = await serviceClient().rpc("increment_usage", { p_owner: u.id, p_category: b.category, p_count: count }); if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ ok: true });
}
```
`apps/web/src/app/api/vehicle-data/route.ts`:
```ts
import { FleetClient, FleetError, vehicleDataToState } from "@garage/core";
import { env } from "@/lib/env"; import { serviceClient, userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("vehicle-data", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const { vehicle_id } = await req.json().catch(() => ({})); const sb = serviceClient();
  const { data: v } = await sb.from("vehicles").select("id, tesla_vehicle_id").eq("id", vehicle_id).eq("owner_id", u.id).maybeSingle();
  if (!v?.tesla_vehicle_id) return Response.json({ error: "no_vehicle" }, { status: 404 });
  const t = await currentAccessToken(u.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  const fleet = new FleetClient({ baseUrl: env().TESLA_FLEET_BASE, token: t.token });
  await sb.rpc("increment_usage", { p_owner: u.id, p_category: "data", p_count: 1 });
  try {
    const payload = await fleet.get<any>(`/api/1/vehicles/${v.tesla_vehicle_id}/vehicle_data?endpoints=${encodeURIComponent("charge_state;climate_state;drive_state;vehicle_state")}`);
    const state = vehicleDataToState(payload, new Date());
    await sb.from("vehicle_state").upsert({ vehicle_id: v.id, owner_id: u.id, ...state });
    return Response.json({ state });
  } catch (e) {
    if (e instanceof FleetError && e.status === 408) return Response.json({ error: "asleep" }, { status: 409 });
    return Response.json({ error: e instanceof Error ? e.message : "fleet_error" }, { status: 502 });
  }
}
```

- [ ] **Step 3: Tests** (local Supabase; Fleet mocked via `vi.stubGlobal("fetch", …)` for the vehicle-data case)

`apps/web/test/api-routes.test.ts`:
```ts
import { describe, it, expect, beforeAll, vi, afterEach } from "vitest";
import { createClient } from "@supabase/supabase-js";
let jwt = "", ownerId = "", vehicleId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  await admin.auth.admin.createUser({ email: "api@test.local", password: "pass-1234", email_confirm: true }).catch(() => {});
  const c = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!); const s = await c.auth.signInWithPassword({ email: "api@test.local", password: "pass-1234" });
  jwt = s.data.session!.access_token; ownerId = s.data.user!.id;
  await admin.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x00", access_token: "TOK", access_expires_at: new Date(Date.now() + 3600_000).toISOString() });
  const { data: v } = await admin.from("vehicles").upsert({ owner_id: ownerId, vin: "VINAPI", tesla_vehicle_id: 42 }, { onConflict: "vin" }).select("id").single(); vehicleId = v!.id;
});
afterEach(() => vi.unstubAllGlobals());
const H = { authorization: `Bearer ${jwt}`, "content-type": "application/json" };
describe("api routes", () => {
  it("token requires auth and returns the stored token", async () => {
    const { GET } = await import("@/app/api/token/route");
    expect((await GET(new Request("http://g/api/token"))).status).toBe(401);
    const r = await GET(new Request("http://g/api/token", { headers: H })); expect((await r.json()).access_token).toBe("TOK");
  });
  it("usage increments the ledger", async () => {
    const { POST } = await import("@/app/api/usage/route");
    await POST(new Request("http://g/api/usage", { method: "POST", headers: H, body: JSON.stringify({ category: "commands", count: 3 }) }));
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("api_usage").select("count").eq("owner_id", ownerId).eq("category", "commands").single(); expect(Number(data?.count)).toBeGreaterThanOrEqual(3);
  });
  it("vehicle-data fetches, maps, upserts and counts", async () => {
    vi.stubGlobal("fetch", vi.fn(async (u: string) => u.includes("vehicle_data") ? new Response(JSON.stringify({ response: { state: "online", charge_state: { battery_level: 55 } } }), { status: 200 }) : new Response("{}", { status: 404 })));
    const { POST } = await import("@/app/api/vehicle-data/route");
    const r = await POST(new Request("http://g/api/vehicle-data", { method: "POST", headers: H, body: JSON.stringify({ vehicle_id: vehicleId }) }));
    expect(r.status).toBe(200); expect((await r.json()).state.soc).toBe(55);
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("vehicle_state").select("soc").eq("vehicle_id", vehicleId).single(); expect(Number(data?.soc)).toBe(55);
  });
  it("vehicle-data maps 408 to asleep and never wakes", async () => {
    const f = vi.fn(async () => new Response(JSON.stringify({ error: "vehicle unavailable" }), { status: 408 })); vi.stubGlobal("fetch", f);
    const { POST } = await import("@/app/api/vehicle-data/route");
    const r = await POST(new Request("http://g/api/vehicle-data", { method: "POST", headers: H, body: JSON.stringify({ vehicle_id: vehicleId }) }));
    expect(r.status).toBe(409); expect(f.mock.calls.some((c: any) => String(c[0]).includes("wake_up"))).toBe(false);
  });
});
```
Note: `userFromRequest` calls Supabase over the real local network, so the stubbed `fetch` must let non-Fleet URLs through. Adjust the stub in the two vehicle-data tests to delegate: capture `const real = globalThis.fetch` before stubbing and `return real(u, init)` when `!String(u).startsWith("https://fleet.test")`.

- [ ] **Step 4: Run**

Run: `pnpm --filter @garage/web test`
Expected: 15 passed.

- [ ] **Step 5: Commit**

```bash
git add apps/web && git commit -m "feat(web): token, usage and manual vehicle-data routes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Budget cron

**Files:**
- Create: `apps/web/src/lib/budget-cron.ts`, `apps/web/src/app/api/cron/budget/route.ts`, `apps/web/test/budget-cron.test.ts`

**Interfaces:**
- Consumes: `projectMonthSpend`, `budgetModeFor`, SQL `set_budget_mode`.
- Produces: `runBudget({ now?, budgetUsd? })` → `Array<{ vehicle_id; owner_id; projected_usd; mode }>`; `GET /api/cron/budget` (cron secret). Budget default 10 USD (the free credit); Plan 1B's add-on reads `vehicles.budget_mode` to set its telemetry cadence.

- [ ] **Step 1: Implementation**

`apps/web/src/lib/budget-cron.ts`:
```ts
import { projectMonthSpend, budgetModeFor, type UsageCategory } from "@garage/core";
import { serviceClient } from "./supabase";
export async function runBudget(o: { now?: Date; budgetUsd?: number } = {}) {
  const now = o.now ?? new Date(), budget = o.budgetUsd ?? 10, sb = serviceClient();
  const month = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);
  const { data: usage, error } = await sb.from("api_usage").select("owner_id, category, count").eq("month", month); if (error) throw error;
  const byOwner = new Map<string, Partial<Record<UsageCategory, number>>>();
  for (const r of usage ?? []) { const m = byOwner.get(r.owner_id) ?? {}; m[r.category as UsageCategory] = Number(r.count); byOwner.set(r.owner_id, m); }
  const { data: vehicles } = await sb.from("vehicles").select("id, owner_id, budget_mode"); const out = [];
  for (const v of vehicles ?? []) {
    const projected = projectMonthSpend(byOwner.get(v.owner_id) ?? {}, now); const mode = budgetModeFor(projected, budget);
    if (mode !== v.budget_mode) await sb.rpc("set_budget_mode", { p_vehicle: v.id, p_mode: mode });
    out.push({ vehicle_id: v.id, owner_id: v.owner_id, projected_usd: +projected.toFixed(4), mode });
  }
  return out;
}
```
`apps/web/src/app/api/cron/budget/route.ts`:
```ts
import { requireCron } from "@/lib/supabase"; import { runBudget } from "@/lib/budget-cron";
export const dynamic = "force-dynamic";
export async function GET(req: Request) { if (!requireCron(req)) return new Response("forbidden", { status: 403 }); return Response.json(await runBudget()); }
```

- [ ] **Step 2: Test**

`apps/web/test/budget-cron.test.ts`:
```ts
import { describe, it, expect, beforeAll } from "vitest";
import { createClient } from "@supabase/supabase-js";
let ownerId = "", vehicleId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email: "budget@test.local", password: "pass-1234", email_confirm: true }); ownerId = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find(x => x.email === "budget@test.local")!.id;
  const { data: v } = await admin.from("vehicles").upsert({ owner_id: ownerId, vin: "VINBUDGET" }, { onConflict: "vin" }).select("id").single(); vehicleId = v!.id;
  await admin.from("api_usage").delete().eq("owner_id", ownerId);
  await admin.rpc("increment_usage", { p_owner: ownerId, p_category: "wakes", p_count: 200 }); // $4 so far
});
describe("budget cron", () => {
  it("projects and flips to reduced", async () => {
    const { runBudget } = await import("@/lib/budget-cron");
    const now = new Date(); now.setUTCDate(15); // ~2x projection → ~$8 of $10 → reduced
    const r = (await runBudget({ now })).find(x => x.vehicle_id === vehicleId)!; expect(r.mode).toBe("reduced");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("vehicles").select("budget_mode").eq("id", vehicleId).single(); expect(data?.budget_mode).toBe("reduced");
  });
  it("returns to normal when spend is low", async () => {
    const { runBudget } = await import("@/lib/budget-cron");
    const r = (await runBudget({ now: new Date(), budgetUsd: 1000 })).find(x => x.vehicle_id === vehicleId)!; expect(r.mode).toBe("normal");
  });
});
```

- [ ] **Step 3: Run**

Run: `pnpm --filter @garage/web test`
Expected: 17 passed.

- [ ] **Step 4: Commit**

```bash
git add apps/web && git commit -m "feat(web): budget projection cron sets vehicles.budget_mode

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: One-time scripts — key pair and partner registration

**Files:**
- Create: `apps/web/scripts/keygen.sh`, `apps/web/scripts/register-partner.ts`, `apps/web/public/.well-known/appspecific/com.tesla.3p.public-key.pem` (output of keygen, committed), `docs/runbooks/tesla-setup.md`

**Interfaces:**
- Produces: `com.tesla.3p.public-key.pem` served at the well-known path; private key at `~/.garage/private-key.pem` (never in repo, `.gitignore` already excludes `*.pem.key`; this script writes outside the repo); partner account registered for `garage.duncanbottrill.com` in the EU region.

- [ ] **Step 1: Key generation script**

`apps/web/scripts/keygen.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="${HOME}/.garage"; mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
PRIV="$OUT_DIR/private-key.pem"; PUB="$(dirname "$0")/../public/.well-known/appspecific/com.tesla.3p.public-key.pem"
if [ -f "$PRIV" ]; then echo "private key already exists at $PRIV — refusing to overwrite"; exit 1; fi
openssl ecparam -name prime256v1 -genkey -noout -out "$PRIV"; chmod 600 "$PRIV"
openssl ec -in "$PRIV" -pubout -out "$PUB"
echo "private key: $PRIV (back this up to your password manager)"; echo "public key:  $PUB (commit this)"
```
Run: `chmod +x apps/web/scripts/keygen.sh && apps/web/scripts/keygen.sh && openssl ec -pubin -in apps/web/public/.well-known/appspecific/com.tesla.3p.public-key.pem -text -noout | head -2`
Expected: `Public-Key: (256 bit)`.

- [ ] **Step 2: Partner registration script**

`apps/web/scripts/register-partner.ts` (run with `pnpm --filter @garage/web exec tsx scripts/register-partner.ts` after the public key is live on the domain):
```ts
import { env } from "../src/lib/env";
const e = env(); const AUTH = "https://auth.tesla.com/oauth2/v3/token";
const tok = await fetch(AUTH, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ grant_type: "client_credentials", client_id: e.TESLA_CLIENT_ID, client_secret: e.TESLA_CLIENT_SECRET, scope: "openid vehicle_device_data vehicle_cmds vehicle_charging_cmds", audience: e.TESLA_FLEET_BASE }) });
if (!tok.ok) throw new Error("partner token failed: " + (await tok.text()));
const { access_token } = await tok.json();
const reg = await fetch(e.TESLA_FLEET_BASE + "/api/1/partner_accounts", { method: "POST", headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json" }, body: JSON.stringify({ domain: new URL(e.TESLA_REDIRECT_URI).host }) });
console.log(reg.status, await reg.text());
const check = await fetch(e.TESLA_FLEET_BASE + "/api/1/partner_accounts/public_key?domain=" + new URL(e.TESLA_REDIRECT_URI).host, { headers: { authorization: `Bearer ${access_token}` } });
console.log("public key check:", check.status, await check.text());
```
Add `tsx` to `apps/web` devDependencies (`"tsx": "^4.19.1"`).

- [ ] **Step 3: Runbook**

`docs/runbooks/tesla-setup.md`:
```markdown
# Tesla setup runbook (one-time, Duncan)
1. `apps/web/scripts/keygen.sh` → commit the public key; store `~/.garage/private-key.pem` in 1Password.
2. Deploy `apps/web` (Task 12) and confirm `curl https://garage.duncanbottrill.com/.well-known/appspecific/com.tesla.3p.public-key.pem` returns the PEM.
3. `.env.local` with TESLA_CLIENT_SECRET etc., then `pnpm --filter @garage/web exec tsx scripts/register-partner.ts` → expect 200 and the public key echoed back.
4. Pair the key: at the car, on the phone with the Tesla app, open `https://tesla.com/_ak/garage.duncanbottrill.com` and approve.
5. Connect the account: from the app's onboarding (Plan 1C), or temporarily by calling `/auth/start` with a Supabase JWT.
```

- [ ] **Step 4: Commit**

```bash
git add apps/web/scripts apps/web/public apps/web/package.json pnpm-lock.yaml docs/runbooks && git commit -m "feat: key generation and partner registration scripts, Tesla runbook

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Deploy to Vercel and verify end to end

**Files:**
- Modify: Vercel project `car-backend` settings (root directory `apps/web`, framework Next.js, env vars), via the Vercel MCP or dashboard. Nothing new in the repo except `README.md`.

**Interfaces:**
- Produces: live `https://garage.duncanbottrill.com` serving the public key, `/api/health`, auth routes and crons; Supabase hosted project with migrations applied; env vars set.

- [ ] **Step 1: Hosted Supabase**

Run: `supabase projects create garage --org-id <org> --region eu-west-2 --db-password <pw>` (or use the existing org via the Supabase MCP), then `supabase link --project-ref <ref> && supabase db push`.
Expected: three migrations applied; `supabase migration list` shows them as remote.

- [ ] **Step 2: Vercel project settings and env**

Set on project `car-backend` (team `duncan-bottrills-projects`): root directory `apps/web`; install command `pnpm install --frozen-lockfile`; build command `pnpm --filter @garage/web build`; Node 22. Environment variables (production): every key in `.env.example`, with real values (`TOKEN_ENC_KEY` from `openssl rand -base64 32`, `CRON_SECRET` from `openssl rand -hex 32`, Upstash from a new free Redis database). Connect the GitHub repo `duncanbottrill/garage` (create it private with `gh repo create duncanbottrill/garage --private --source . --push`).

- [ ] **Step 3: Deploy and verify**

Run:
```bash
curl -sS https://garage.duncanbottrill.com/api/health
curl -sSI https://garage.duncanbottrill.com/.well-known/appspecific/com.tesla.3p.public-key.pem | grep -i content-type
curl -sS -o /dev/null -w "%{http_code}\n" https://garage.duncanbottrill.com/auth/start
curl -sS -o /dev/null -w "%{http_code}\n" -H "authorization: Bearer $CRON_SECRET" https://garage.duncanbottrill.com/api/cron/tesla-refresh
```
Expected: `{"ok":true,...}`; `content-type: application/x-pem-file`; `401`; `200` with `{"rotated":[],"failed":[]}`.

- [ ] **Step 4: Register the partner account** (runbook step 3) and confirm the public-key check returns your PEM.

- [ ] **Step 5: README and commit**

`README.md`: one paragraph on what Garage is, the layout from the spec's section 13, `pnpm install && supabase start && pnpm test` to run everything locally, link to the spec and runbook.

```bash
git add README.md && git commit -m "docs: README with local setup

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" && git push
```

---

## Self-review against the spec

- **Spec coverage.** §4.1 auth and single rotator → Tasks 7, 8. §4.2 key → Task 11. §4.3 commands → served by Plan 1B's proxy; the token the app needs comes from Task 9. §4.4 telemetry config → Plan 1B (needs `vehicles.telemetry_config_version`, present in Task 2). §4.5 ledger and budget → Tasks 2, 9, 10. §4.6 manual refresh → Task 9. §6 data model → Task 2 (+ `oauth_states` in Task 7). §7 routes → Tasks 6–10. §9 tokens → Task 5. §11 security (RLS, service-only functions, JWT on routes, rate limits, no secrets) → Tasks 2, 6, 9. §12 testing for web and db → every task. §16 open items: Funnel check and telemetry fixture belong to Plan 1B; bundle id to Plan 1C.
- **Not in this plan by design.** `signals` writes, `vehicle_state` streaming updates and `bridge_seen_at` heartbeat (Plan 1B); all UI (Plan 1C); partition-extension cron (needed before month 14; add to Plan 2 as a Vercel cron using the same `do $$` block).
- **Type consistency.** `VehicleStateRow` columns match migration 0001; `UsageCategory` matches the `api_usage` check constraint; `BudgetMode` matches `vehicles.budget_mode`; `increment_usage(p_owner, p_category, p_count)` and `set_budget_mode(p_vehicle, p_mode)` are called with those exact parameter names in Tasks 9 and 10.
- **Placeholders.** None; every step has its code and command.
### Task 13: On-demand token refresh with a claim lock (Vercel Hobby crons are daily)

**Why:** Vercel Hobby only allows daily cron schedules, so `/api/cron/tesla-refresh` now runs once a day (06:15 UTC) and cannot keep an 8-hour Tesla access token fresh on its own. The app and the add-on fetch the access token through `GET /api/token`, so that route must refresh on demand when the token is near expiry, while keeping the global rule: **exactly one rotation at a time per owner** (Tesla refresh tokens are single-use; a concurrent double refresh can invalidate the whole token family).

**Files:**
- Create: `supabase/migrations/0004_refresh_lock.sql`
- Modify: `apps/web/src/lib/tesla-refresh.ts` (add `ownerId` filter + lock claim), `apps/web/src/lib/credentials.ts` (lazy refresh), `apps/web/src/app/api/token/route.ts` (no change expected), `apps/web/test/tesla-refresh.test.ts`, `apps/web/test/api-routes.test.ts`
- Create: `apps/web/test/lazy-refresh.test.ts`

**Interfaces:**
- Consumes: `refreshAll({ fetch?, now?, client?, sleep? })` from Task 8; `currentAccessToken(ownerId)` from Task 9.
- Produces:
  - Column `tesla_credentials.refresh_lock_until timestamptz`.
  - `refreshAll(o)` gains `ownerId?: string` (process only that row) and `force?: boolean` (ignore the 3 h window). Before calling Tesla for a row it must **claim** the lock atomically: `update tesla_credentials set refresh_lock_until = now() + interval '90 seconds' where owner_id = $1 and (refresh_lock_until is null or refresh_lock_until < now()) returning owner_id` — implemented via supabase-js as `.update({ refresh_lock_until: <iso now+90s> }).eq("owner_id", id).or("refresh_lock_until.is.null,refresh_lock_until.lt." + <iso now>).select("owner_id")`; if zero rows come back, the row is skipped with `failed` entry `{ owner_id, error: "locked" }` (not a real failure; callers treat it as "someone else is refreshing"). After the row's attempt (success or failure) release by setting `refresh_lock_until = null`.
  - `currentAccessToken(ownerId, o?: { refreshIfStale?: boolean; fetch?; now?; client? })`: if the stored token expires within **30 minutes** (or is missing) and `refreshIfStale` is true (default **true**), call `refreshAll({ ownerId, force: true, ... })`. If the result says `locked`, wait 1.5 s (injectable `sleep`) and re-read the row up to 3 times. Return the freshest stored token that is valid for ≥60 s, else `null`.
  - `GET /api/token` keeps its contract; it simply benefits from the lazy refresh.

**Steps:**
1. Migration 0004: `alter table tesla_credentials add column refresh_lock_until timestamptz;` and `supabase db reset`.
2. Tests first (RED), then implementation (GREEN):
   - `tesla-refresh.test.ts`: (a) `ownerId` filter processes only that owner; (b) a row whose `refresh_lock_until` is in the future is reported as `locked` and Tesla is **not** called; (c) after a successful rotation `refresh_lock_until` is null again; (d) after a failed rotation the lock is also released.
   - `lazy-refresh.test.ts`: (e) with a token expiring in 10 minutes, `currentAccessToken(owner)` calls the (mocked) Tesla endpoint once and returns the new token; (f) with a token expiring in 5 hours it does not call Tesla; (g) when the row is locked by someone else and the stored token is still valid ≥60 s, it returns the stored token without calling Tesla; (h) two concurrent `currentAccessToken` calls for the same owner result in exactly one Tesla call (use `Promise.all` with the same mocked fetch counting invocations; the second must observe the lock or the freshly stored token).
   - `api-routes.test.ts`: existing `/api/token` test must still pass; add one assertion that `/api/token` returns the refreshed token when the seeded token is near expiry (seed 10 min, mock Tesla, expect the new value).
3. Run the whole web suite (expect 21 + 9 = 30 passed), typecheck, build.
4. Commit: `feat(web): on-demand token refresh with per-owner claim lock` with the standard trailer.
