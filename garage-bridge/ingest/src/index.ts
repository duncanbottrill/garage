import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";
import type { BudgetMode } from "@garage/core";
import { loadOptions, type LogLevel } from "./options";
import { startMqttSource, type MqttSource } from "./mqtt-source";
import { toSignalRow, toStatePatch, type BridgeEvent, type SignalRow } from "./state";
import { Batcher } from "./batcher";
import { Health } from "./health";
import { SupabaseSink, type Sink } from "./supabase-sink";
import { BridgeToken } from "./bridge-token";
import { TelemetryConfigManager, type EnsureResult } from "./telemetry-config";
import { readFqdn } from "./fqdn";

const LEVELS: readonly LogLevel[] = ["trace", "debug", "info", "warning", "error"];
const NESTED_PATCH_KEYS = new Set(["doors", "windows", "tpms_bar", "bridge_health"]);

// Ensure-result reasons that mean "nothing to do right now, business as
// usual" — logged at debug. Anything else (post_failed/not_synced/
// token_error) is a real problem worth operator visibility, logged louder.
const ROUTINE_ENSURE_REASONS = new Set(["current", "in_flight", "token_wait", "post_backoff", "poll_backoff"]);

const VEHICLE_POLL_MS = 30_000;
const FLUSH_INTERVAL_MS = 2_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const BUDGET_POLL_MS = 5 * 60_000;
// One-shot retry after a telemetry-config ensure that was skipped (inputs not
// ready yet) or threw, so a first boot registers within seconds of the TLS
// material appearing rather than at the next 5-minute budget poll.
const TELEMETRY_RETRY_MS = 30_000;
// Consecutive fast retries allowed after attempts that THREW (e.g. the
// bridge-token endpoint unreachable); after that the 5-minute budget poll
// takes over until an attempt returns without throwing. Not-ready skips are
// not capped.
const TELEMETRY_MAX_THROW_RETRIES = 5;
const FORCE_FLUSH_AHEAD_MS = 2_500; // > Batcher's default maxAgeMs, well under maxBufferMs
const MAX_PATCH_ATTEMPTS = 3; // consecutive mergeState failures before a pending patch is dropped

export type Logger = (level: LogLevel, msg: string, extra?: Record<string, unknown>) => void;

/** Logs single-line JSON with ts/level, before `log_level` filtering is known. Never a secret/token. */
const bootLogger: Logger = (level, msg, extra) =>
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...extra }));

function makeLogger(minLevel: LogLevel): Logger {
  const minIdx = LEVELS.indexOf(minLevel);
  return (level, msg, extra) => {
    if (LEVELS.indexOf(level) < minIdx) return;
    // Never include tokens/secrets here: callers pass only ids, counts and error strings.
    console.log(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...extra }));
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Shallow-merges a state patch into an accumulator, deep-merging the known nested object columns. */
function mergePatch(base: Record<string, unknown>, patch: Record<string, unknown>): Record<string, unknown> {
  const out = { ...base };
  for (const [key, value] of Object.entries(patch)) {
    if (
      NESTED_PATCH_KEYS.has(key) &&
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      out[key] &&
      typeof out[key] === "object"
    ) {
      out[key] = { ...(out[key] as Record<string, unknown>), ...(value as Record<string, unknown>) };
    } else {
      out[key] = value;
    }
  }
  return out;
}

function readCaPem(): string | null {
  try {
    return readFileSync("/data/tls/ca.pem", "utf8");
  } catch {
    return null;
  }
}

/**
 * The hostname `tlscert` writes to `/data/telemetry-hostname` once the
 * private-CA leaf and `ca.pem` for it are in place (hostname mode only).
 */
function readHostnameMarker(): string | null {
  try {
    return readFileSync("/data/telemetry-hostname", "utf8").trim().toLowerCase() || null;
  } catch {
    return null;
  }
}

export interface TelemetryEnsurerDeps {
  manager: { ensure(mode: BudgetMode, ctx: { fqdn: string; caPem: string }): Promise<EnsureResult> };
  /** `options.telemetry_hostname`: set = hostname mode (private CA), unset = tailnet FQDN mode. */
  telemetryHostname: string | undefined;
  /** Throws while the tailnet FQDN is not written yet. Only used in tailnet mode. */
  readFqdn: () => string;
  readCaPem: () => string | null;
  /** Only used in hostname mode. */
  readHostnameMarker: () => string | null;
  log: Logger;
  isStopping: () => boolean;
  retryMs?: number;
  /** Cap on consecutive fast retries after thrown attempts (default 5). */
  maxThrowRetries?: number;
}

export interface TelemetryEnsurer {
  /** Runs one ensure for `mode`. Never throws. */
  run(mode: BudgetMode): Promise<void>;
  /** Clears a pending fast retry (shutdown). */
  cancel(): void;
}

/**
 * Wires the telemetry-config manager to the files the shell services write.
 * Picks the registered hostname (`telemetry_hostname` when set, otherwise the
 * tailnet FQDN) and waits only for what that mode needs: hostname mode needs
 * `ca.pem` plus the marker naming this hostname (so a CA chain left over from
 * the tailnet mode is never registered against the new hostname); tailnet
 * mode needs the FQDN and `ca.pem`, as before.
 *
 * When a run is skipped as not ready, or `ensure()` throws, a single one-shot
 * retry is scheduled `retryMs` later (default 30 s) instead of waiting for the
 * next 5-minute budget poll. Bounded: at most one timer exists at a time
 * (every run clears the pending one first), none is scheduled once the config
 * has been confirmed (`changed: true` or `current`) or while stopping, and
 * results the manager already backs off on itself (post_failed, poll_backoff,
 * token_error, ...) are left to that schedule. Fast retries after a thrown
 * attempt are capped at `maxThrowRetries` (default 5) in a row; after that
 * only the budget poll retries, until an attempt returns without throwing
 * (a not-ready skip counts), which resets the count. Not-ready skips keep
 * retrying every `retryMs` without a cap.
 */
export function createTelemetryEnsurer(deps: TelemetryEnsurerDeps): TelemetryEnsurer {
  const retryMs = deps.retryMs ?? TELEMETRY_RETRY_MS;
  const maxThrowRetries = deps.maxThrowRetries ?? TELEMETRY_MAX_THROW_RETRIES;
  const { log } = deps;
  let retryTimer: NodeJS.Timeout | null = null;
  let confirmed = false;
  let lastMode: BudgetMode = "normal";
  // Fast retries already scheduled for the current run of thrown attempts.
  let throwRetries = 0;

  function clearRetry(): void {
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = null;
  }

  /** Returns whether a retry is now pending. */
  function scheduleRetry(): boolean {
    if (retryTimer) return true;
    if (confirmed || deps.isStopping()) return false;
    retryTimer = setTimeout(() => {
      retryTimer = null;
      if (deps.isStopping()) return;
      void attempt(lastMode, true);
    }, retryMs);
    return true;
  }

  function logEnsureResult(result: EnsureResult): void {
    if (result.changed) {
      log("info", "telemetry config ensure", { result });
    } else if (ROUTINE_ENSURE_REASONS.has(result.reason)) {
      log("debug", "telemetry config ensure skipped", { result });
    } else {
      log("warning", "telemetry config ensure not synced", { result });
    }
  }

  // The not-ready skip keeps its warning on scheduled runs (budget poll,
  // every 5 min, as before) and drops to debug on the 30 s fast retries.
  function readContext(skipLevel: LogLevel): { fqdn: string; caPem: string } | null {
    if (deps.telemetryHostname) {
      const caPem = deps.readCaPem();
      const marker = deps.readHostnameMarker();
      if (!caPem || marker !== deps.telemetryHostname) {
        log(skipLevel, "telemetry config skipped: private CA not ready yet", {
          hostname: deps.telemetryHostname,
          ca_pem: caPem ? "present" : "missing",
          marker: marker === null ? "missing" : marker === deps.telemetryHostname ? "match" : "other_hostname",
        });
        return null;
      }
      return { fqdn: deps.telemetryHostname, caPem };
    }

    let fqdn: string | null;
    try {
      fqdn = deps.readFqdn();
    } catch (err) {
      fqdn = null;
      log("debug", "tailnet FQDN not ready", { error: errMsg(err) });
    }
    const caPem = deps.readCaPem();
    if (!fqdn || !caPem) {
      log(skipLevel, "telemetry config skipped: tailnet FQDN or CA chain not ready yet");
      return null;
    }
    return { fqdn, caPem };
  }

  async function attempt(mode: BudgetMode, fromRetry: boolean): Promise<void> {
    lastMode = mode;
    clearRetry();

    const ctx = readContext(fromRetry ? "debug" : "warning");
    if (!ctx) {
      throwRetries = 0;
      scheduleRetry();
      return;
    }
    try {
      const result = await deps.manager.ensure(mode, ctx);
      throwRetries = 0;
      logEnsureResult(result);
      if (result.changed || result.reason === "current") {
        confirmed = true;
      } else if (result.reason !== "in_flight") {
        // The manager reports the config as not (or no longer) confirmed;
        // its own backoff governs the next attempt, but a later skip or
        // throw may fast-retry again.
        confirmed = false;
      }
    } catch (err) {
      log("error", "telemetry config ensure failed", { error: errMsg(err) });
      if (throwRetries < maxThrowRetries) {
        if (scheduleRetry()) throwRetries++;
      } else if (throwRetries === maxThrowRetries) {
        throwRetries++; // log the hand-over once per run of failures
        log("warning", "telemetry config ensure keeps failing; next attempt at the budget poll", {
          fast_retries: maxThrowRetries,
        });
      }
    }
  }

  return {
    run: (mode) => attempt(mode, false),
    cancel: clearRetry,
  };
}

export interface PatchAccumulator {
  /** Merges an incoming state patch into whatever's pending (deep-merging the known nested columns). */
  merge(patch: Record<string, unknown>): void;
  /**
   * Flushes whatever's pending via `sink.mergeState`, or no-ops if nothing
   * is pending. Never throws. A failed patch is re-queued under newer data
   * and dropped after 3 consecutive failures.
   */
  flush(): Promise<void>;
}

/**
 * Accumulates `vehicle_state` patches between flush ticks and merges them
 * into one `sink.mergeState` call. Pulled out of `main()` as its own small
 * factory so shutdown's "flush everything pending" sequence is unit
 * testable with a fake sink, without having to import (and thereby run)
 * `main()` itself.
 */
export function createPatchAccumulator(sink: Pick<Sink, "mergeState">, health: Health, log: Logger): PatchAccumulator {
  let pendingPatch: Record<string, unknown> = {};
  // Consecutive mergeState failures of the (re-queued) pending patch.
  let consecutiveFailures = 0;
  // Tracks a `sink.mergeState` call already in flight, the same way
  // `Batcher` tracks `flushingPromise` — so a shutdown-time flush() never
  // starts a second, overlapping mergeState call alongside a periodic
  // flush tick's own. Instead it waits for that call to finish, then
  // merges whatever accumulated (or was left pending) in the meantime.
  let flushingPromise: Promise<void> | null = null;

  async function doFlush(): Promise<void> {
    if (Object.keys(pendingPatch).length === 0) return;
    const patch = pendingPatch;
    pendingPatch = {};

    const task = (async () => {
      try {
        await sink.mergeState(patch);
        consecutiveFailures = 0;
      } catch (err) {
        health.patchFailed(err);
        consecutiveFailures++;
        if (consecutiveFailures >= MAX_PATCH_ATTEMPTS) {
          // A patch rejected this many times in a row is most likely
          // permanently bad (e.g. a cast error); stop retrying it so it
          // cannot block every later patch forever.
          consecutiveFailures = 0;
          log("error", `mergeState failed ${MAX_PATCH_ATTEMPTS} times in a row, dropping patch`, { error: errMsg(err) });
          return;
        }
        // Re-queue UNDERNEATH whatever arrived since (including while this
        // call was in flight): newer values win, but a one-off Supabase blip
        // no longer loses e.g. a lock change that only resends hourly.
        pendingPatch = mergePatch(patch, pendingPatch);
        log("warning", "mergeState failed, re-queuing patch", { error: errMsg(err), attempt: consecutiveFailures });
      }
    })();

    flushingPromise = task;
    try {
      await task;
    } finally {
      // Only clear the pointer if it's still ours: guards against a later
      // flush's in-flight marker ever being clobbered (mirrors Batcher).
      if (flushingPromise === task) flushingPromise = null;
    }
  }

  return {
    merge(patch: Record<string, unknown>): void {
      pendingPatch = mergePatch(pendingPatch, patch);
    },
    async flush(): Promise<void> {
      if (flushingPromise) {
        await flushingPromise.catch(() => {});
      }
      await doFlush();
    },
  };
}

/**
 * Shutdown-time "flush everything pending" sequence: rows first, then the
 * pending state patch — always both, regardless of whether the row flush
 * succeeded. `Batcher.flush()` never throws (it reports `{ ok, error }`),
 * but this still guards against an unexpected throw from a non-Batcher
 * `rowBatcher` so shutdown always reaches the patch flush.
 */
export async function runShutdownFlush(
  rowBatcher: { flush(): Promise<{ ok: boolean; error?: unknown }> } | null,
  patchAccumulator: PatchAccumulator | null,
  log: Logger,
): Promise<void> {
  try {
    const result = await rowBatcher?.flush();
    if (result && !result.ok) {
      log("error", "final flush failed", { error: errMsg(result.error) });
    }
  } catch (err) {
    log("error", "final flush failed", { error: errMsg(err) });
  }
  await patchAccumulator?.flush();
}

async function main(): Promise<void> {
  // SIGTERM/SIGINT must be wired before anything else below can block for a
  // long time (loadOptions, the vehicle-resolve retry loop, or — formerly —
  // an awaited first budget poll that could run for up to ~10 minutes while
  // a telemetry registration polls). Everything the handler touches is
  // declared here as a mutable binding the rest of main() fills in, so the
  // handler works correctly no matter how early or late the signal arrives.
  let log: Logger = bootLogger;
  let stopping = false;
  let shuttingDown = false;
  let mqttSource: MqttSource | null = null;
  let rowBatcher: Batcher<SignalRow> | null = null;
  let patchAccumulator: PatchAccumulator | null = null;
  let flushTimer: NodeJS.Timeout | null = null;
  let heartbeatTimer: NodeJS.Timeout | null = null;
  let budgetTimer: NodeJS.Timeout | null = null;
  let telemetryEnsurer: TelemetryEnsurer | null = null;

  async function shutdown(): Promise<void> {
    if (shuttingDown) return;
    shuttingDown = true;
    stopping = true;
    log("info", "shutting down");
    if (flushTimer) clearInterval(flushTimer);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    if (budgetTimer) clearInterval(budgetTimer);
    telemetryEnsurer?.cancel();
    mqttSource?.stop();
    // Waits for any row flush already in flight, then flushes everything
    // still pending — rows AND the pending state patch — never dropping
    // either just because shutdown landed mid-tick. Exits 0 regardless of
    // whether the flush succeeded; a failure was already logged above.
    await runShutdownFlush(rowBatcher, patchAccumulator, log);
    process.exit(0);
  }

  process.on("SIGTERM", () => {
    shutdown().catch(() => process.exit(1));
  });
  process.on("SIGINT", () => {
    shutdown().catch(() => process.exit(1));
  });

  const options = loadOptions();
  log = makeLogger(options.log_level);
  log("info", "ingest starting", { vin: options.tesla_vin, tailscale_enabled: options.tailscale_enabled });

  const client = createClient(options.supabase_url, options.supabase_service_key, {
    auth: { persistSession: false },
  });
  const sink: Sink = SupabaseSink(client, { vehicleId: "", ownerId: "" });

  let vehicle = await sink.resolveVehicle(options.tesla_vin);
  while (!vehicle) {
    log("warning", "vehicle not found yet, retrying", { vin: options.tesla_vin, retry_in_ms: VEHICLE_POLL_MS });
    await sleep(VEHICLE_POLL_MS);
    vehicle = await sink.resolveVehicle(options.tesla_vin);
  }
  await sink.ensureStateRow();
  log("info", "vehicle resolved", { vehicleId: vehicle.vehicleId, budgetMode: vehicle.budgetMode });

  const health = new Health();
  rowBatcher = new Batcher<SignalRow>({
    onFlush: async (rows) => {
      await sink.insertSignals(rows);
      await sink.countSignals(rows.length);
      health.flushed(rows.length);
    },
  });
  const activeRowBatcher = rowBatcher;

  patchAccumulator = createPatchAccumulator(sink, health, log);
  const activePatchAccumulator = patchAccumulator;

  function onEvent(ev: BridgeEvent): void {
    health.received();
    health.eventAt(ev.at);
    if (ev.kind === "connectivity") health.connectivity(ev.status);
    if (ev.kind === "alert") health.alert(ev.name, ev.active);
    if (ev.kind === "error") health.vehicleError(ev.name, ev.body);
    if (ev.kind === "field" && vehicle) {
      activeRowBatcher.push(toSignalRow(ev, vehicle.vehicleId, vehicle.ownerId));
    }
    activePatchAccumulator.merge(toStatePatch(ev) as Record<string, unknown>);
  }

  mqttSource = startMqttSource({
    url: `mqtt://${options.mqtt_host}:${options.mqtt_port}`,
    username: options.mqtt_username,
    password: options.mqtt_password,
    base: "garage",
    vin: options.tesla_vin,
    onEvent,
    onStatus: (status, detail) => {
      if (status === "error") {
        const message = detail instanceof Error ? detail.message : String(detail);
        health.mqttError(message);
        log("error", "mqtt status", { status, detail: message });
      } else {
        log("debug", "mqtt status", { status });
      }
    },
  });

  // Hostname mode (telemetry_hostname set) registers through the local proxy
  // without needing Tailscale at all, so it constructs the manager even when
  // tailscale_enabled is false.
  if (options.tailscale_enabled || options.telemetry_hostname) {
    const token = BridgeToken({ apiBase: options.garage_api_base, secret: options.bridge_secret });
    const telemetryManager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: options.tesla_vin,
      token,
      sink,
      insecureTls: true,
    });
    telemetryEnsurer = createTelemetryEnsurer({
      manager: telemetryManager,
      telemetryHostname: options.telemetry_hostname,
      readFqdn: () => readFqdn(),
      readCaPem,
      readHostnameMarker,
      log,
      isStopping: () => stopping,
    });
    if (options.telemetry_hostname) {
      log("info", "telemetry registration uses telemetry_hostname (private CA)", { hostname: options.telemetry_hostname });
    }
  } else {
    log("info", "tailscale disabled: skipping telemetry config manager (dev/e2e)");
  }

  async function flushTick(force: boolean): Promise<void> {
    await activeRowBatcher.flushIfDue(force ? Date.now() + FORCE_FLUSH_AHEAD_MS : Date.now());
    await activePatchAccumulator.flush();
  }

  async function runBudgetPoll(): Promise<void> {
    const resolved = await sink.resolveVehicle(options.tesla_vin);
    if (!resolved) {
      log("warning", "vehicle disappeared on budget poll", { vin: options.tesla_vin });
      return;
    }
    vehicle = resolved;

    await telemetryEnsurer?.run(resolved.budgetMode as BudgetMode);
  }

  flushTimer = setInterval(() => {
    if (stopping) return;
    flushTick(false).catch((err) => log("error", "flush tick failed", { error: errMsg(err) }));
  }, FLUSH_INTERVAL_MS);
  heartbeatTimer = setInterval(() => {
    if (stopping) return;
    health.setDropped(activeRowBatcher.stats().dropped);
    sink
      .heartbeat(health.payload() as unknown as Record<string, unknown>)
      .catch((err) => log("error", "heartbeat failed", { error: errMsg(err) }));
  }, HEARTBEAT_INTERVAL_MS);
  budgetTimer = setInterval(() => {
    if (stopping) return;
    runBudgetPoll().catch((err) => log("error", "budget poll failed", { error: errMsg(err) }));
  }, BUDGET_POLL_MS);

  // Fired, not awaited: a telemetry registration can poll for up to ~10
  // minutes, and main() must return promptly so the process is fully up
  // (and SIGTERM-responsive) well before that finishes.
  if (!stopping) {
    runBudgetPoll().catch((err) => log("error", "budget poll failed", { error: errMsg(err) }));
  }
}

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

// Guarded so importing this module under Vitest (e.g. to unit-test
// `createPatchAccumulator`/`runShutdownFlush`) never kicks off the real
// add-on process. Vitest sets `process.env.VITEST` itself; production never
// has it set.
if (!process.env.VITEST) {
  main().catch((err) => {
    console.error(JSON.stringify({ ts: new Date().toISOString(), level: "error", msg: "ingest fatal", error: errMsg(err) }));
    process.exit(1);
  });
}
