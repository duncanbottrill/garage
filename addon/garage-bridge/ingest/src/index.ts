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
import { TelemetryConfigManager } from "./telemetry-config";
import { readFqdn } from "./fqdn";

const LEVELS: readonly LogLevel[] = ["trace", "debug", "info", "warning", "error"];
const NESTED_PATCH_KEYS = new Set(["doors", "windows", "tpms_bar", "bridge_health"]);

const VEHICLE_POLL_MS = 30_000;
const FLUSH_INTERVAL_MS = 2_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const BUDGET_POLL_MS = 5 * 60_000;
const FORCE_FLUSH_AHEAD_MS = 2_500; // > Batcher's default maxAgeMs, well under maxBufferMs

type Logger = (level: LogLevel, msg: string, extra?: Record<string, unknown>) => void;

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
  let flushTimer: NodeJS.Timeout | null = null;
  let heartbeatTimer: NodeJS.Timeout | null = null;
  let budgetTimer: NodeJS.Timeout | null = null;

  async function shutdown(): Promise<void> {
    if (shuttingDown) return;
    shuttingDown = true;
    stopping = true;
    log("info", "shutting down");
    if (flushTimer) clearInterval(flushTimer);
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    if (budgetTimer) clearInterval(budgetTimer);
    mqttSource?.stop();
    try {
      // Waits for any flush already in flight, then flushes everything
      // still pending — never drops rows just because shutdown landed
      // mid-tick.
      await rowBatcher?.flush();
    } catch (err) {
      log("error", "final flush failed", { error: errMsg(err) });
    }
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

  let pendingPatch: Record<string, unknown> = {};

  async function flushPendingPatch(): Promise<void> {
    if (Object.keys(pendingPatch).length === 0) return;
    const patch = pendingPatch;
    pendingPatch = {};
    try {
      await sink.mergeState(patch);
    } catch (err) {
      // Drop the failed patch rather than re-queuing it behind whatever's
      // accumulated since: an old patch re-merged later could overwrite
      // newer state with stale values. Each tick's accumulator only ever
      // holds what arrived since the last successful (or dropped) flush.
      health.patchFailed(err);
      log("error", "mergeState failed, dropping patch", { error: errMsg(err) });
    }
  }

  function onEvent(ev: BridgeEvent): void {
    health.received();
    health.eventAt(ev.at);
    if (ev.kind === "connectivity") health.connectivity(ev.status);
    if (ev.kind === "alert") health.alert(ev.name, ev.active);
    if (ev.kind === "error") health.vehicleError(ev.name, ev.body);
    if (ev.kind === "field" && vehicle) {
      activeRowBatcher.push(toSignalRow(ev, vehicle.vehicleId, vehicle.ownerId));
    }
    pendingPatch = mergePatch(pendingPatch, toStatePatch(ev) as Record<string, unknown>);
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
        health.patchFailed(detail);
        log("error", "mqtt status", { status, detail: detail instanceof Error ? detail.message : String(detail) });
      } else {
        log("debug", "mqtt status", { status });
      }
    },
  });

  let telemetryManager: ReturnType<typeof TelemetryConfigManager> | null = null;
  if (options.tailscale_enabled) {
    const token = BridgeToken({ apiBase: options.garage_api_base, secret: options.bridge_secret });
    telemetryManager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: options.tesla_vin,
      token,
      sink,
      insecureTls: true,
    });
  } else {
    log("info", "tailscale disabled: skipping telemetry config manager (dev/e2e)");
  }

  async function flushTick(force: boolean): Promise<void> {
    await activeRowBatcher.flushIfDue(force ? Date.now() + FORCE_FLUSH_AHEAD_MS : Date.now());
    await flushPendingPatch();
  }

  async function runBudgetPoll(): Promise<void> {
    const resolved = await sink.resolveVehicle(options.tesla_vin);
    if (!resolved) {
      log("warning", "vehicle disappeared on budget poll", { vin: options.tesla_vin });
      return;
    }
    vehicle = resolved;

    if (!telemetryManager) return;

    let fqdn: string | null;
    try {
      fqdn = readFqdn();
    } catch (err) {
      fqdn = null;
      log("debug", "tailnet FQDN not ready", { error: errMsg(err) });
    }
    const caPem = readCaPem();
    if (!fqdn || !caPem) {
      log("warning", "telemetry config skipped: tailnet FQDN or CA chain not ready yet");
      return;
    }
    try {
      const result = await telemetryManager.ensure(resolved.budgetMode as BudgetMode, { fqdn, caPem });
      if ("skipped" in result) {
        log("debug", "telemetry config ensure skipped", { result });
      } else if (result.changed) {
        log("info", "telemetry config ensure", { result });
      }
    } catch (err) {
      log("error", "telemetry config ensure failed", { error: errMsg(err) });
    }
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

main().catch((err) => {
  console.error(JSON.stringify({ ts: new Date().toISOString(), level: "error", msg: "ingest fatal", error: errMsg(err) }));
  process.exit(1);
});
