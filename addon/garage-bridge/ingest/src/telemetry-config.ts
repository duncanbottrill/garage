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
  /** Clock used to stamp `confirmedAt`; defaults to `() => new Date()`. Overridable for tests. */
  clock?: () => Date;
}

export type EnsureResult =
  | { changed: false }
  | { changed: true; synced: true }
  | { changed: true; synced: false; error: string }
  | { skipped: "in_flight" };

const POLL_INTERVAL_MS = 15_000;
const POLL_TIMEOUT_MS = 10 * 60_000;
const MAX_POLL_ATTEMPTS = Math.ceil(POLL_TIMEOUT_MS / POLL_INTERVAL_MS);
const BACKOFF_POLL_ATTEMPTS = 4;
const INITIAL_BACKOFF_MS = 15 * 60_000;
const MAX_BACKOFF_MS = 6 * 3600_000;

interface BackoffState {
  hash: string;
  delayMs: number;
  until: number;
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

/**
 * Registers and confirms the Fleet Telemetry config through the local
 * `tesla-http-proxy`. Never calls Tesla directly, never logs the bearer
 * token, and counts every proxy round trip (POST, every poll, and an error
 * fetch) as one `data` usage unit each — Tesla bills these as data requests,
 * not commands.
 *
 * Bounded and non-overlapping: `ensure()` refuses to run a second attempt
 * while one is already in flight, and after a failure it backs off (15min,
 * doubling to a 6h cap, reset on success) before POSTing the same config
 * hash again — while backed off, a call only re-checks sync status with a
 * handful of bounded GETs instead of re-registering.
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
  let backoff: BackoffState | null = null;
  let tokenRetryAtMs: number | null = null;

  async function call(path: string, init: RequestInit): Promise<Response> {
    const res = dispatcher
      ? await fetchImpl(`${opts.proxyBase}${path}`, { ...init, dispatcher } as RequestInit)
      : await fetchImpl(`${opts.proxyBase}${path}`, init);
    await opts.sink.countUsage("data", 1);
    return res;
  }

  /** Calls `path`; on a 401, force-refreshes the bridge token once and retries that same call once. */
  async function callChecked(path: string, init: RequestInit): Promise<CallOutcome> {
    let res = await call(path, init);
    if (res.status === 401) {
      const fresh = await opts.token.get({ force: true });
      const headers = { ...(init.headers as Record<string, string>), authorization: `Bearer ${fresh.access_token}` };
      res = await call(path, { ...init, headers });
    }
    const text = await safeText(res);
    return { res, text };
  }

  function enterBackoff(hash: string, now: Date): void {
    const nowMs = now.getTime();
    if (backoff && backoff.hash === hash) {
      const delayMs = Math.min(backoff.delayMs * 2, MAX_BACKOFF_MS);
      backoff = { hash, delayMs, until: nowMs + delayMs };
    } else {
      backoff = { hash, delayMs: INITIAL_BACKOFF_MS, until: nowMs + INITIAL_BACKOFF_MS };
    }
  }

  async function authHeaders(): Promise<Record<string, string>> {
    const { access_token } = await opts.token.get();
    return { authorization: `Bearer ${access_token}`, "content-type": "application/json" };
  }

  /** While backed off for `hash`: only re-checks sync status, bounded to 4 GETs 15s apart. */
  async function pollOnly(hash: string, vehicle: ResolvedVehicle, now: Date): Promise<EnsureResult> {
    const headers = await authHeaders();

    for (let attempt = 0; attempt < BACKOFF_POLL_ATTEMPTS; attempt++) {
      const outcome = await callChecked(`/api/1/vehicles/${opts.vin}/fleet_telemetry_config`, { headers });
      if (!outcome.res.ok) {
        const message = `poll ${outcome.res.status}: ${outcome.text.slice(0, 300)}`;
        await opts.sink.setTelemetryConfig({ lastError: message });
        enterBackoff(hash, now);
        return { changed: true, synced: false, error: message };
      }

      const payload = extractPayload(parseJsonSafe(outcome.text));
      if (payload.synced === true) {
        const confirmedAt = clock().toISOString();
        await opts.sink.setTelemetryConfig({ hash, version: (vehicle.configVersion ?? 0) + 1, confirmedAt, lastError: null });
        backoff = null;
        return { changed: true, synced: true };
      }

      if (attempt < BACKOFF_POLL_ATTEMPTS - 1) await sleep(POLL_INTERVAL_MS);
    }

    enterBackoff(hash, now);
    return { changed: true, synced: false, error: "not yet synced (within backoff window)" };
  }

  async function registerAndPoll(hash: string, vehicle: ResolvedVehicle, mode: BudgetMode, ctx: { fqdn: string; caPem: string }, now: Date): Promise<EnsureResult> {
    const config = desiredConfig({ fqdn: ctx.fqdn, caPem: ctx.caPem, mode, now });
    const headers = await authHeaders();

    const postOutcome = await callChecked("/api/1/vehicles/fleet_telemetry_config", {
      method: "POST",
      headers,
      body: JSON.stringify({ vins: [opts.vin], config }),
    });

    if (!postOutcome.res.ok) {
      const message = `post ${postOutcome.res.status}: ${postOutcome.text.slice(0, 300)}`;
      await opts.sink.setTelemetryConfig({ lastError: message });
      enterBackoff(hash, now);
      return { changed: true, synced: false, error: message };
    }

    for (let attempt = 0; attempt < MAX_POLL_ATTEMPTS; attempt++) {
      const pollOutcome = await callChecked(`/api/1/vehicles/${opts.vin}/fleet_telemetry_config`, { headers });
      if (!pollOutcome.res.ok) {
        const message = `poll ${pollOutcome.res.status}: ${pollOutcome.text.slice(0, 300)}`;
        await opts.sink.setTelemetryConfig({ lastError: message });
        enterBackoff(hash, now);
        return { changed: true, synced: false, error: message };
      }

      const payload = extractPayload(parseJsonSafe(pollOutcome.text));
      if (payload.synced === true) {
        const confirmedAt = clock().toISOString();
        await opts.sink.setTelemetryConfig({ hash, version: (vehicle.configVersion ?? 0) + 1, confirmedAt, lastError: null });
        backoff = null;
        return { changed: true, synced: true };
      }
      if (attempt < MAX_POLL_ATTEMPTS - 1) await sleep(POLL_INTERVAL_MS);
    }

    const errOutcome = await callChecked(`/api/1/vehicles/${opts.vin}/fleet_telemetry_errors`, { headers });
    const message = firstErrorMessageFromText(errOutcome.text);
    await opts.sink.setTelemetryConfig({ lastError: message });
    enterBackoff(hash, now);
    return { changed: true, synced: false, error: message };
  }

  async function ensureInner(mode: BudgetMode, ctx: { fqdn: string; caPem: string }, now: Date): Promise<EnsureResult> {
    if (tokenRetryAtMs !== null) {
      if (now.getTime() < tokenRetryAtMs) {
        return { changed: true, synced: false, error: "token: waiting for retryAt" };
      }
      tokenRetryAtMs = null; // the window has passed; allow a fresh attempt
    }

    const vehicle: ResolvedVehicle | null = await opts.sink.resolveVehicle(opts.vin);
    if (!vehicle) throw new Error(`telemetry-config: vehicle ${opts.vin} not found`);

    const fields = cadenceFields(mode);
    const newHash = configHash({ hostname: ctx.fqdn, caPem: ctx.caPem, fields });

    if (vehicle.configHash === newHash && !isConfirmationStale(vehicle.confirmedAt, now)) {
      return { changed: false };
    }

    if (backoff && backoff.hash === newHash && now.getTime() < backoff.until) {
      return await pollOnly(newHash, vehicle, now);
    }

    try {
      return await registerAndPoll(newHash, vehicle, mode, ctx, now);
    } catch (err) {
      if (err instanceof BridgeTokenError) {
        const message = `token:${err.code}`;
        await opts.sink.setTelemetryConfig({ lastError: message });
        tokenRetryAtMs = err.retryAt ? new Date(err.retryAt).getTime() : null;
        return { changed: true, synced: false, error: message };
      }
      throw err;
    }
  }

  async function ensure(mode: BudgetMode, ctx: { fqdn: string; caPem: string }, now: Date = new Date()): Promise<EnsureResult> {
    if (inFlight) return { skipped: "in_flight" };
    inFlight = true;
    try {
      return await ensureInner(mode, ctx, now);
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
