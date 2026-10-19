import { createHash } from "node:crypto";
import { Agent, fetch as undiciFetch } from "undici";
import type { BudgetMode } from "@garage/core";
import type { ResolvedVehicle, Sink } from "./supabase-sink";
import { BridgeTokenError, type BridgeTokenClient } from "./bridge-token";

export interface FieldCadence {
  interval_seconds: number;
  minimum_delta?: number;
  resend_interval_seconds?: number;
}

export type CadenceTable = Record<string, FieldCadence>;

// Plan's "Cadence by budget mode" table, `normal` tier. 32 fields: the plan's
// own prose summary says "31" but its literal field-by-field listing (with
// FdWindow/FpWindow/RdWindow/RpWindow and TpmsPressureFl/Fr/Rl/Rr each
// expanding to 4 named fields) enumerates 32 — see task-4-report.md concerns.
const NORMAL_CADENCE: CadenceTable = {
  Location: { interval_seconds: 10 },
  VehicleSpeed: { interval_seconds: 10 },
  Soc: { interval_seconds: 60, minimum_delta: 0.5 },
  BatteryLevel: { interval_seconds: 60 },
  EstBatteryRange: { interval_seconds: 60, minimum_delta: 1 },
  ChargeState: { interval_seconds: 10 },
  DetailedChargeState: { interval_seconds: 10 },
  ACChargingPower: { interval_seconds: 30 },
  DCChargingPower: { interval_seconds: 30 },
  ChargeAmps: { interval_seconds: 30 },
  ChargeLimitSoc: { interval_seconds: 60 },
  ChargePortDoorOpen: { interval_seconds: 10 },
  ScheduledChargingStartTime: { interval_seconds: 300 },
  InsideTemp: { interval_seconds: 60, minimum_delta: 0.5 },
  OutsideTemp: { interval_seconds: 60, minimum_delta: 0.5 },
  HvacPower: { interval_seconds: 10 },
  ClimateKeeperMode: { interval_seconds: 60 },
  Odometer: { interval_seconds: 60, minimum_delta: 0.1 },
  Gear: { interval_seconds: 1, resend_interval_seconds: 3600 },
  Locked: { interval_seconds: 1, resend_interval_seconds: 3600 },
  DoorState: { interval_seconds: 1, resend_interval_seconds: 3600 },
  FdWindow: { interval_seconds: 5 },
  FpWindow: { interval_seconds: 5 },
  RdWindow: { interval_seconds: 5 },
  RpWindow: { interval_seconds: 5 },
  TpmsPressureFl: { interval_seconds: 300 },
  TpmsPressureFr: { interval_seconds: 300 },
  TpmsPressureRl: { interval_seconds: 300 },
  TpmsPressureRr: { interval_seconds: 300 },
  SentryMode: { interval_seconds: 10 },
  VehicleName: { interval_seconds: 3600 },
  SoftwareUpdateVersion: { interval_seconds: 3600 },
};

/**
 * Scales `interval_seconds` by `factor` (min 1). `resend_interval_seconds` is
 * deliberately left untouched by budget mode — it's a "re-send even if
 * unchanged" ceiling, not a sampling rate, and scaling it out to multiple
 * hours under `minimal` would mean a stuck door/gear/lock value could go
 * that long without a confirming resend. `minimum_delta` is never scaled.
 */
function scaleCadence(table: CadenceTable, factor: number): CadenceTable {
  const out: CadenceTable = {};
  for (const [name, c] of Object.entries(table)) {
    out[name] = {
      interval_seconds: Math.max(1, c.interval_seconds * factor),
      ...(c.minimum_delta !== undefined ? { minimum_delta: c.minimum_delta } : {}),
      ...(c.resend_interval_seconds !== undefined ? { resend_interval_seconds: c.resend_interval_seconds } : {}),
    };
  }
  return out;
}

/**
 * The field cadence table for a budget mode: `normal` as specified, `reduced`
 * triples every interval (min 1), `minimal` sextuples them and drops
 * `VehicleSpeed` (its `Location` lands on 60 — the plan's explicit override —
 * purely because 10 * 6 == 60, with no extra special-casing needed).
 * `resend_interval_seconds` is never scaled (see `scaleCadence`).
 */
export function cadenceFields(mode: BudgetMode): CadenceTable {
  if (mode === "normal") return { ...NORMAL_CADENCE };
  if (mode === "reduced") return scaleCadence(NORMAL_CADENCE, 3);

  const minimal = scaleCadence(NORMAL_CADENCE, 6);
  delete minimal.VehicleSpeed;
  return minimal;
}

export interface DesiredConfigInput {
  fqdn: string;
  caPem: string;
  mode: BudgetMode;
  now?: Date;
}

export interface TelemetryConfigBody {
  hostname: string;
  port: number;
  ca: string;
  fields: CadenceTable;
  alert_types: string[];
  exp: number;
}

const CONFIG_TTL_SECONDS = 180 * 24 * 3600;
const CONFIRM_STALE_MS = 150 * 24 * 3600 * 1000;

export function desiredConfig({ fqdn, caPem, mode, now = new Date() }: DesiredConfigInput): TelemetryConfigBody {
  return {
    hostname: fqdn,
    port: 443,
    ca: caPem,
    fields: cadenceFields(mode),
    alert_types: ["service"],
    exp: Math.floor(now.getTime() / 1000) + CONFIG_TTL_SECONDS,
  };
}

export interface ConfigHashInput {
  hostname: string;
  caPem: string;
  fields: unknown;
}

/**
 * sha256 hex of the canonical (recursively key-sorted) JSON of
 * `{ hostname, ca_sha256, fields }`. Hashing the hostname and a hash of the
 * CA chain alongside the cadence fields means a tailnet FQDN change or a
 * rotated CA — not just a cadence/budget-mode change — also re-registers.
 */
export function configHash(input: ConfigHashInput): string {
  const ca_sha256 = createHash("sha256").update(input.caPem).digest("hex");
  return createHash("sha256")
    .update(canonicalJson({ hostname: input.hostname, ca_sha256, fields: input.fields }))
    .digest("hex");
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const obj = value as Record<string, unknown>;
  const entries = Object.keys(obj)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`);
  return `{${entries.join(",")}}`;
}

/** True when `confirmedAt` is missing or older than 150 days (the config's `exp` is 180 days). */
function isConfirmationStale(confirmedAt: string | null | undefined, now: Date): boolean {
  if (!confirmedAt) return true;
  const confirmedMs = new Date(confirmedAt).getTime();
  if (Number.isNaN(confirmedMs)) return true;
  return now.getTime() - confirmedMs > CONFIRM_STALE_MS;
}

export interface TelemetryConfigManagerOptions {
  proxyBase: string;
  vin: string;
  token: BridgeTokenClient;
  sink: Sink;
  fetch?: typeof fetch;
  insecureTls?: boolean;
  sleep?: (ms: number) => Promise<void>;
  /**
   * Clock used both to stamp `confirmedAt` and, on the no-longer-synced
   * paths, to anchor the *next* backoff/poll deadline. Defaults to
   * `() => new Date()` (real wall-clock). Using this instead of the `now`
   * argument passed into `ensure()` for those deadlines matters in
   * production: a registration that polls for the better part of 10 minutes
   * must not have its next backoff window computed from the stale
   * entry-time `now`, or the window is silently "eaten" by however long the
   * polling itself took. Tests pin `clock()` to track whatever `now` they
   * pass to a given `ensure()` call, which keeps the gating comparisons
   * (driven by `now`) and the scheduling (driven by `clock()`) consistent
   * and fully deterministic.
   */
  clock?: () => Date;
}

/**
 * Every reason `ensure()` can return without having changed anything.
 * `current`/`in_flight`/`token_wait`/`post_backoff`/`poll_backoff` are
 * routine — "nothing to do right now" — and the caller logs them at debug.
 * `post_failed`/`not_synced`/`token_error` are genuine problems worth
 * operator visibility.
 */
export type EnsureReason =
  | "current"
  | "in_flight"
  | "token_wait"
  | "post_backoff"
  | "post_failed"
  | "poll_backoff"
  | "not_synced"
  | "token_error";

export type EnsureResult = { changed: true } | { changed: false; reason: EnsureReason };

const POLL_INTERVAL_MS = 15_000;
const POLL_TIMEOUT_MS = 10 * 60_000;
const MAX_POLL_ATTEMPTS = Math.ceil(POLL_TIMEOUT_MS / POLL_INTERVAL_MS); // 40, bounds the post-accept run
const BACKOFF_POLL_ATTEMPTS = 4; // bounds a later, separate poll-only run
const INITIAL_POST_BACKOFF_MS = 15 * 60_000;
const MAX_POST_BACKOFF_MS = 6 * 3600_000;
const INITIAL_POLL_DELAY_MS = 5 * 60_000;
const MAX_POLL_DELAY_MS = 60 * 60_000;

/**
 * Per-manager registration state. Held in memory ONLY (never persisted
 * beyond `vehicles.telemetry_config_hash` / `telemetry_config_version` /
 * `telemetry_confirmed_at`, which `setTelemetryConfig` writes on success).
 * A process restart loses `reg`: the next `ensure()` call sees `reg ===
 * null` and POSTs once immediately, even if a previous process instance was
 * already mid-backoff or mid-poll for the same config. That's accepted —
 * Tesla's fleet_telemetry_config POST is idempotent for an identical config,
 * so a redundant extra POST after a restart is harmless, and far better
 * than a restart permanently wedging registration behind in-memory backoff
 * state that no longer exists anywhere.
 */
interface RegState {
  hash: string;
  postAccepted: boolean;
  postAttempts: number;
  nextPostAt: number;
  nextPollAt: number;
  pollDelayMs: number;
}

interface CallOutcome {
  res: Response;
  text: string;
}

function assertInsecureTlsAllowed(proxyBase: string): void {
  let host: string;
  try {
    host = new URL(proxyBase).hostname;
  } catch {
    throw new Error(`telemetry-config: invalid proxyBase ${JSON.stringify(proxyBase)}`);
  }
  if (host !== "127.0.0.1" && host !== "localhost") {
    throw new Error(`telemetry-config: insecureTls may only be used with a proxyBase on 127.0.0.1 or localhost (got ${host})`);
  }
}

function parseJsonSafe(text: string): Record<string, unknown> {
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function extractPayload(body: Record<string, unknown>): Record<string, unknown> {
  return (body.response as Record<string, unknown> | undefined) ?? body;
}

function firstErrorMessageFromText(text: string): string {
  const payload = extractPayload(parseJsonSafe(text));
  const errors = payload.fleet_telemetry_errors;
  if (Array.isArray(errors) && errors.length > 0) {
    const first = errors[0] as Record<string, unknown>;
    if (first && typeof first === "object" && "name" in first) {
      return `${first.name}: ${first.body ?? ""}`.slice(0, 500);
    }
  }
  return text.slice(0, 500);
}

function sameFieldKeySet(ours: CadenceTable, theirs: unknown): boolean {
  if (!theirs || typeof theirs !== "object") return false;
  const oursKeys = Object.keys(ours).sort();
  const theirsKeys = Object.keys(theirs as Record<string, unknown>).sort();
  if (oursKeys.length !== theirsKeys.length) return false;
  return oursKeys.every((k, i) => k === theirsKeys[i]);
}

/**
 * True when a poll's `synced: true` should be trusted as confirmation of
 * OUR desired config, not of some other config the vehicle happens to have
 * already synced (e.g. a stale one from before a POST failure, or another
 * bridge's). The response MUST carry a `config` object whose `hostname` and
 * `fields` key set match ours: a missing or `null` config proves nothing
 * about what the car is actually streaming, so it never confirms.
 */
function configMatches(responseConfig: unknown, fqdn: string, fields: CadenceTable): boolean {
  if (!responseConfig || typeof responseConfig !== "object") return false;
  const cfg = responseConfig as Record<string, unknown>;
  if (cfg.hostname !== fqdn) return false;
  return sameFieldKeySet(fields, cfg.fields);
}

/**
 * A poll payload counts as synced only when Tesla says `synced: true`, the
 * reported config is ours (see `configMatches`), and the virtual key is not
 * reported as unpaired (`key_paired: false` means the car will not stream
 * whatever config it holds).
 */
function isOurConfigSynced(payload: Record<string, unknown>, fqdn: string, fields: CadenceTable): boolean {
  if (payload.synced !== true) return false;
  if (payload.key_paired === false) return false;
  return configMatches(payload.config, fqdn, fields);
}

const SKIP_REASONS = ["missing_key", "unsupported_hardware", "unsupported_firmware", "max_configs"] as const;

/**
 * Tesla answers a fleet_telemetry_config POST with HTTP 200 even when it
 * did not apply the config to a VIN, listing it under
 * `response.skipped_vehicles.<reason>` instead (e.g. `missing_key` when the
 * virtual key is not paired). Returns `skipped:<reason>` when our VIN was
 * skipped (or `skipped:not_updated` when `updated_vehicles` is explicitly 0
 * without naming a reason), otherwise null (accepted).
 */
function postSkipReason(text: string, vin: string): string | null {
  const payload = extractPayload(parseJsonSafe(text));
  const skipped = payload.skipped_vehicles;
  if (skipped && typeof skipped === "object") {
    const lists = skipped as Record<string, unknown>;
    for (const reason of SKIP_REASONS) {
      const list = lists[reason];
      if (Array.isArray(list) && list.includes(vin)) return `skipped:${reason}`;
    }
    for (const [reason, list] of Object.entries(lists)) {
      if (Array.isArray(list) && list.includes(vin)) return `skipped:${reason}`;
    }
  }
  if (payload.updated_vehicles === 0) return "skipped:not_updated";
  return null;
}

/**
 * Registers and confirms the Fleet Telemetry config through the local
 * `tesla-http-proxy`. Never calls Tesla directly, never logs the bearer
 * token, and counts every proxy round trip (POST, every poll, every 401
 * retry, and an error fetch) as one `data` usage unit each — Tesla bills
 * these as data requests, not commands.
 *
 * Bounded and non-overlapping: `ensure()` refuses to run a second attempt
 * while one is already in flight. A POST that fails backs off (15min,
 * doubling to a 6h cap) before POSTing the same config hash again; while
 * backed off, a call makes no HTTP calls at all. Once a POST is accepted,
 * the same call polls up to 40 times (15s apart, ~10min) for confirmation;
 * if that run doesn't confirm, later calls poll only when a separate,
 * independently-doubling poll delay (5min, up to 60min) has elapsed, and
 * then only up to 4 times per call.
 */
export function TelemetryConfigManager(opts: TelemetryConfigManagerOptions) {
  if (opts.insecureTls) assertInsecureTlsAllowed(opts.proxyBase);

  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const clock = opts.clock ?? (() => new Date());
  const dispatcher = opts.insecureTls ? new Agent({ connect: { rejectUnauthorized: false } }) : undefined;
  // Never pass a dispatcher to globalThis.fetch: only undici's own fetch
  // export accepts one reliably. opts.fetch (test injection) always wins
  // when provided; in production, insecureTls selects undici's fetch.
  const fetchImpl = opts.fetch ?? (opts.insecureTls ? (undiciFetch as unknown as typeof fetch) : globalThis.fetch);

  let inFlight = false;
  let reg: RegState | null = null;
  let tokenRetryAtMs: number | null = null;

  async function call(path: string, init: RequestInit): Promise<Response> {
    const res = dispatcher
      ? await fetchImpl(`${opts.proxyBase}${path}`, { ...init, dispatcher } as RequestInit)
      : await fetchImpl(`${opts.proxyBase}${path}`, init);
    await opts.sink.countUsage("data", 1);
    return res;
  }

  /**
   * Builds the `Authorization` header fresh from `token.get()` on every
   * call (never reuses a header snapshot across multiple proxy calls). On a
   * 401, force-refreshes the bridge token once and retries that same call
   * once. A second 401 after the forced refresh is NOT thrown: it's handed
   * back to the caller like any other non-2xx response, so it flows through
   * the normal error paths instead of escaping as an unhandled rejection —
   * a POST's `!res.ok` branch stores `post 401: …` and starts the usual
   * backoff, and a poll's caller treats it as not-synced (see `runPolls`).
   * This is distinct from the bridge-token service itself being
   * unavailable, which surfaces as `BridgeTokenError` instead.
   */
  async function callChecked(path: string, init: RequestInit): Promise<CallOutcome> {
    const baseHeaders = (init.headers as Record<string, string> | undefined) ?? {};

    const first = await opts.token.get();
    let res = await call(path, { ...init, headers: { ...baseHeaders, authorization: `Bearer ${first.access_token}` } });

    if (res.status === 401) {
      const refreshed = await opts.token.get({ force: true });
      res = await call(path, { ...init, headers: { ...baseHeaders, authorization: `Bearer ${refreshed.access_token}` } });
    }

    const text = await safeText(res);
    return { res, text };
  }

  /**
   * Advances `reg`'s poll schedule (doubling `pollDelayMs`, capped) using
   * `clock()` — not the `now` the caller passed to `ensure()` — so a long
   * run's own elapsed time can't eat into the next window. Always called
   * BEFORE the corresponding `setTelemetryConfig` error write, so a failing
   * Supabase write can never skip the backoff. Returns the fresh timestamp
   * so callers that also need it (e.g. for `tokenRetryAtMs`) don't call
   * `clock()` twice.
   */
  function scheduleNextPoll(): number {
    const current = reg!; // the post-accepted branch always sets `reg` before polling
    const freshNow = clock().getTime();
    reg = {
      ...current,
      nextPollAt: freshNow + current.pollDelayMs,
      pollDelayMs: Math.min(current.pollDelayMs * 2, MAX_POLL_DELAY_MS),
    };
    return freshNow;
  }

  /**
   * Runs up to `maxAttempts` polls, 15s apart, for `hash`. Confirms and
   * clears `reg` the moment a poll reports a trustworthy `synced: true`
   * (see `isOurConfigSynced`). `isFirstRun` (the run immediately following an
   * accepted POST, within the same `ensure()` call) also fetches
   * `fleet_telemetry_errors` once the attempts are exhausted.
   *
   * A poll that comes back 401 even after `callChecked`'s own forced-refresh
   * retry means auth is genuinely broken, not just "not yet synced" — so the
   * run stops immediately (burning the remaining attempts would only repeat
   * the same failure) and, beyond the usual not-synced bookkeeping, sets
   * `tokenRetryAtMs` so the *next* `ensure()` tick waits instead of
   * hammering the proxy again right away.
   */
  async function runPolls(
    hash: string,
    fields: CadenceTable,
    vehicle: ResolvedVehicle,
    ctx: { fqdn: string; caPem: string },
    maxAttempts: number,
    isFirstRun: boolean,
  ): Promise<EnsureResult> {
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const outcome = await callChecked(`/api/1/vehicles/${opts.vin}/fleet_telemetry_config`, {});

      if (outcome.res.status === 401) {
        const freshNow = scheduleNextPoll(); // reg updated before the error write (see scheduleNextPoll)
        tokenRetryAtMs = freshNow + 5 * 60_000;
        await opts.sink.setTelemetryConfig({ lastError: "auth:401" });
        return { changed: false, reason: "not_synced" };
      }

      const payload = extractPayload(parseJsonSafe(outcome.text));
      if (outcome.res.ok && isOurConfigSynced(payload, ctx.fqdn, fields)) {
        const confirmedAt = clock().toISOString();
        await opts.sink.setTelemetryConfig({ hash, version: (vehicle.configVersion ?? 0) + 1, confirmedAt, lastError: null });
        reg = null;
        return { changed: true };
      }

      if (attempt < maxAttempts - 1) await sleep(POLL_INTERVAL_MS);
    }

    if (isFirstRun) {
      const errOutcome = await callChecked(`/api/1/vehicles/${opts.vin}/fleet_telemetry_errors`, {});
      const message = firstErrorMessageFromText(errOutcome.text);
      scheduleNextPoll(); // reg updated before the error write
      await opts.sink.setTelemetryConfig({ lastError: message });
      return { changed: false, reason: "not_synced" };
    }

    scheduleNextPoll();
    return { changed: false, reason: "not_synced" };
  }

  async function runStateMachine(
    hash: string,
    fields: CadenceTable,
    vehicle: ResolvedVehicle,
    mode: BudgetMode,
    ctx: { fqdn: string; caPem: string },
    now: number,
  ): Promise<EnsureResult> {
    if (!reg || !reg.postAccepted) {
      if (reg && now < reg.nextPostAt) {
        return { changed: false, reason: "post_backoff" };
      }

      const config = desiredConfig({ fqdn: ctx.fqdn, caPem: ctx.caPem, mode, now: new Date(now) });
      const postOutcome = await callChecked("/api/1/vehicles/fleet_telemetry_config", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ vins: [opts.vin], config }),
      });

      // A 2xx POST that skipped our VIN (e.g. `missing_key`: the virtual
      // key is not paired yet) is a failure too: the car never got the
      // config, so polling would either spin or confirm something stale.
      const skipReason = postOutcome.res.ok ? postSkipReason(postOutcome.text, opts.vin) : null;

      if (!postOutcome.res.ok || skipReason !== null) {
        // A double-401 (after callChecked's own forced-refresh retry) lands
        // here too, now that callChecked never throws: it's just another
        // non-2xx POST outcome, stored and backed off like any other.
        const postAttempts = (reg?.postAttempts ?? 0) + 1;
        const message = skipReason ?? `post ${postOutcome.res.status}: ${postOutcome.text.slice(0, 300)}`;
        const freshNow = clock().getTime();
        const nextPostAt = freshNow + Math.min(INITIAL_POST_BACKOFF_MS * 2 ** (postAttempts - 1), MAX_POST_BACKOFF_MS);
        // reg (backoff state) is updated BEFORE the setTelemetryConfig write:
        // a failing Supabase write must never be able to skip the backoff.
        reg = { hash, postAccepted: false, postAttempts, nextPostAt, nextPollAt: 0, pollDelayMs: 0 };
        await opts.sink.setTelemetryConfig({ lastError: message });
        return { changed: false, reason: "post_failed" };
      }

      reg = { hash, postAccepted: true, postAttempts: 0, nextPostAt: 0, nextPollAt: now, pollDelayMs: INITIAL_POLL_DELAY_MS };
      return await runPolls(hash, fields, vehicle, ctx, MAX_POLL_ATTEMPTS, true);
    }

    if (now < reg.nextPollAt) {
      return { changed: false, reason: "poll_backoff" };
    }

    return await runPolls(hash, fields, vehicle, ctx, BACKOFF_POLL_ATTEMPTS, false);
  }

  async function ensure(mode: BudgetMode, ctx: { fqdn: string; caPem: string }, now: number = Date.now()): Promise<EnsureResult> {
    const vehicle: ResolvedVehicle | null = await opts.sink.resolveVehicle(opts.vin);
    if (!vehicle) throw new Error(`telemetry-config: vehicle ${opts.vin} not found`);

    const fields = cadenceFields(mode);
    const hash = configHash({ hostname: ctx.fqdn, caPem: ctx.caPem, fields });

    if (vehicle.configHash === hash && !isConfirmationStale(vehicle.confirmedAt, new Date(now))) {
      return { changed: false, reason: "current" };
    }

    if (inFlight) return { changed: false, reason: "in_flight" };

    if (tokenRetryAtMs !== null) {
      if (now < tokenRetryAtMs) return { changed: false, reason: "token_wait" };
      tokenRetryAtMs = null; // the window has passed; allow a fresh attempt
    }

    // A new desired config (hostname/CA/budget-mode change) supersedes any
    // backoff or poll schedule held for the old one.
    if (reg && reg.hash !== hash) reg = null;

    inFlight = true;
    try {
      return await runStateMachine(hash, fields, vehicle, mode, ctx, now);
    } catch (err) {
      if (err instanceof BridgeTokenError) {
        // tokenRetryAtMs (backoff state) is set BEFORE the setTelemetryConfig
        // write, for the same reason as the post/poll paths. The fallback
        // uses clock(), not the `now` ensure() was entered with, and also
        // covers a `retryAt` that fails Date.parse (NaN) — not just a
        // missing one.
        const parsedRetryAt = err.retryAt ? Date.parse(err.retryAt) : NaN;
        tokenRetryAtMs = Number.isNaN(parsedRetryAt) ? clock().getTime() + 5 * 60_000 : parsedRetryAt;
        const message = `token:${err.code}`;
        await opts.sink.setTelemetryConfig({ lastError: message });
        return { changed: false, reason: "token_error" };
      }
      throw err;
    } finally {
      inFlight = false;
    }
  }

  return { ensure };
}

async function safeText(res: Response): Promise<string> {
  try {
    return await res.text();
  } catch {
    return "";
  }
}
