import { createHash } from "node:crypto";
import { Agent } from "undici";
import type { BudgetMode } from "@garage/core";
import type { ResolvedVehicle, Sink } from "./supabase-sink";
import type { BridgeTokenClient } from "./bridge-token";

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

function scaleCadence(table: CadenceTable, factor: number): CadenceTable {
  const out: CadenceTable = {};
  for (const [name, c] of Object.entries(table)) {
    out[name] = {
      interval_seconds: Math.max(1, c.interval_seconds * factor),
      ...(c.minimum_delta !== undefined ? { minimum_delta: c.minimum_delta } : {}),
      ...(c.resend_interval_seconds !== undefined
        ? { resend_interval_seconds: Math.max(1, c.resend_interval_seconds * factor) }
        : {}),
    };
  }
  return out;
}

/**
 * The field cadence table for a budget mode: `normal` as specified, `reduced`
 * triples every interval/resend (min 1), `minimal` sextuples them and drops
 * `VehicleSpeed` (its `Location` lands on 60 — the plan's explicit override —
 * purely because 10 * 6 == 60, with no extra special-casing needed).
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

/** sha256 hex of the canonical (recursively key-sorted) JSON of `fields`. */
export function configHash(fields: unknown): string {
  return createHash("sha256").update(canonicalJson(fields)).digest("hex");
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

export interface TelemetryConfigManagerOptions {
  proxyBase: string;
  vin: string;
  token: BridgeTokenClient;
  sink: Sink;
  fetch?: typeof fetch;
  insecureTls?: boolean;
  sleep?: (ms: number) => Promise<void>;
}

export type EnsureResult =
  | { changed: false }
  | { changed: true; synced: true }
  | { changed: true; synced: false; error: string };

const POLL_INTERVAL_MS = 15_000;
const POLL_TIMEOUT_MS = 10 * 60_000;
const MAX_POLL_ATTEMPTS = Math.ceil(POLL_TIMEOUT_MS / POLL_INTERVAL_MS);

/**
 * Registers and confirms the Fleet Telemetry config through the local
 * `tesla-http-proxy`. Never calls Tesla directly, never logs the bearer
 * token, and counts every proxy round trip (`fleet_telemetry_config` POST,
 * its confirmation polls, and an error fetch) as one `data` usage unit each
 * — Tesla bills these as data requests, not commands.
 */
export function TelemetryConfigManager(opts: TelemetryConfigManagerOptions) {
  const fetchImpl = opts.fetch ?? globalThis.fetch;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const dispatcher = opts.insecureTls ? new Agent({ connect: { rejectUnauthorized: false } }) : undefined;

  async function call(path: string, init: RequestInit): Promise<Response> {
    const res = await fetchImpl(`${opts.proxyBase}${path}`, dispatcher ? ({ ...init, dispatcher } as RequestInit) : init);
    await opts.sink.countUsage("data", 1);
    return res;
  }

  async function ensure(mode: BudgetMode, ctx: { fqdn: string; caPem: string }, now: Date = new Date()): Promise<EnsureResult> {
    const vehicle: ResolvedVehicle | null = await opts.sink.resolveVehicle(opts.vin);
    if (!vehicle) throw new Error(`telemetry-config: vehicle ${opts.vin} not found`);

    const fields = cadenceFields(mode);
    const newHash = configHash(fields);
    if (vehicle.configHash === newHash) {
      return { changed: false };
    }

    const config = desiredConfig({ fqdn: ctx.fqdn, caPem: ctx.caPem, mode, now });
    const { access_token } = await opts.token.get();
    const authHeaders = { authorization: `Bearer ${access_token}`, "content-type": "application/json" };

    await call("/api/1/vehicles/fleet_telemetry_config", {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ vins: [opts.vin], config }),
    });

    for (let attempt = 0; attempt < MAX_POLL_ATTEMPTS; attempt++) {
      const res = await call(`/api/1/vehicles/${opts.vin}/fleet_telemetry_config`, { headers: authHeaders });
      const body = await safeJson(res);
      const payload = (body.response as Record<string, unknown> | undefined) ?? body;
      if (payload.synced === true) {
        await opts.sink.setTelemetryConfig({
          hash: newHash,
          version: (vehicle.configVersion ?? 0) + 1,
          confirmedAt: now.toISOString(),
          lastError: null,
        });
        return { changed: true, synced: true };
      }
      if (attempt < MAX_POLL_ATTEMPTS - 1) await sleep(POLL_INTERVAL_MS);
    }

    const errRes = await call(`/api/1/vehicles/${opts.vin}/fleet_telemetry_errors`, { headers: authHeaders });
    const message = await firstErrorMessage(errRes);
    await opts.sink.setTelemetryConfig({ lastError: message });
    return { changed: true, synced: false, error: message };
  }

  return { ensure };
}

async function firstErrorMessage(res: Response): Promise<string> {
  const body = await safeJson(res);
  const payload = (body.response as Record<string, unknown> | undefined) ?? body;
  const errors = payload.fleet_telemetry_errors;
  if (Array.isArray(errors) && errors.length > 0) {
    const first = errors[0] as Record<string, unknown>;
    if (first && typeof first === "object" && "name" in first) {
      return `${first.name}: ${first.body ?? ""}`.slice(0, 500);
    }
  }
  return JSON.stringify(body).slice(0, 500);
}

async function safeJson(res: Response): Promise<Record<string, unknown>> {
  try {
    return (await res.json()) as Record<string, unknown>;
  } catch {
    return {};
  }
}
