import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";
import type { BudgetMode } from "@garage/core";
import { loadOptions, type LogLevel } from "./options";
import { startMqttSource } from "./mqtt-source";
import { toSignalRow, toStatePatch, type BridgeEvent, type SignalRow } from "./state";
import { Batcher } from "./batcher";
import { Health } from "./health";
import { SupabaseSink } from "./supabase-sink";
import { BridgeToken } from "./bridge-token";
import { TelemetryConfigManager } from "./telemetry-config";

const LEVELS: readonly LogLevel[] = ["trace", "debug", "info", "warning", "error"];
const NESTED_PATCH_KEYS = new Set(["doors", "windows", "tpms_bar", "bridge_health"]);

const VEHICLE_POLL_MS = 30_000;
const FLUSH_INTERVAL_MS = 2_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const BUDGET_POLL_MS = 5 * 60_000;
const FORCE_FLUSH_AHEAD_MS = 2_500; // > Batcher's default maxAgeMs, well under maxBufferMs

function makeLogger(minLevel: LogLevel) {
  const minIdx = LEVELS.indexOf(minLevel);
  return (level: LogLevel, msg: string, extra?: Record<string, unknown>) => {
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

function readTailnetFqdn(hostname: string): string | null {
  // Written by the `tlscert` rootfs service once `tailscale cert` has run.
  try {
    const tailnet = readFileSync("/data/tailscale/fqdn", "utf8").trim();
    return tailnet ? `${hostname}.${tailnet}.ts.net` : null;
  } catch {
    return null;
  }
}

function readCaPem(): string | null {
  try {
    return readFileSync("/data/tls/ca.pem", "utf8");
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const options = loadOptions();
  const log = makeLogger(options.log_level);
  log("info", "ingest starting", { vin: options.tesla_vin, tailscale_enabled: options.tailscale_enabled });

  const client = createClient(options.supabase_url, options.supabase_service_key, {
    auth: { persistSession: false },
  });
  const sink = SupabaseSink(client, { vehicleId: "", ownerId: "" });

  let vehicle = await sink.resolveVehicle(options.tesla_vin);
  while (!vehicle) {
    log("warning", "vehicle not found yet, retrying", { vin: options.tesla_vin, retry_in_ms: VEHICLE_POLL_MS });
    await sleep(VEHICLE_POLL_MS);
    vehicle = await sink.resolveVehicle(options.tesla_vin);
  }
  await sink.ensureStateRow();
  log("info", "vehicle resolved", { vehicleId: vehicle.vehicleId, budgetMode: vehicle.budgetMode });

  const health = new Health();
  const rowBatcher = new Batcher<SignalRow>({
    onFlush: async (rows) => {
      await sink.insertSignals(rows);
      await sink.countSignals(rows.length);
      health.flushed(rows.length);
    },
  });

  let pendingPatch: Record<string, unknown> = {};

  function onEvent(ev: BridgeEvent): void {
    health.received();
    health.eventAt(ev.at);
    if (ev.kind === "connectivity") health.connectivity(ev.status);
    if (ev.kind === "alert") health.alert(ev.name, ev.active);
    if (ev.kind === "error") health.patchFailed(new Error(`${ev.name}: ${ev.body}`));
    if (ev.kind === "field" && vehicle) {
      rowBatcher.push(toSignalRow(ev, vehicle.vehicleId, vehicle.ownerId));
    }
    pendingPatch = mergePatch(pendingPatch, toStatePatch(ev) as Record<string, unknown>);
  }

  const mqttSource = startMqttSource({
    url: `mqtt://${options.mqtt_host}:${options.mqtt_port}`,
    username: options.mqtt_username,
    password: options.mqtt_password,
    base: "garage",
    vin: options.tesla_vin,
    onEvent,
    onStatus: (status, detail) =>
      log("debug", "mqtt status", { status, detail: detail instanceof Error ? detail.message : detail }),
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
    await rowBatcher.flushIfDue(force ? Date.now() + FORCE_FLUSH_AHEAD_MS : Date.now());

    if (Object.keys(pendingPatch).length === 0) return;
    const patch = pendingPatch;
    pendingPatch = {};
    try {
      await sink.mergeState(patch);
    } catch (err) {
      pendingPatch = mergePatch(patch, pendingPatch);
      health.patchFailed(err);
      log("error", "mergeState failed", { error: errMsg(err) });
    }
  }

  async function runBudgetPoll(): Promise<void> {
    const resolved = await sink.resolveVehicle(options.tesla_vin);
    if (!resolved) {
      log("warning", "vehicle disappeared on budget poll", { vin: options.tesla_vin });
      return;
    }
    vehicle = resolved;

    if (!telemetryManager) return;
    const fqdn = readTailnetFqdn(options.tailscale_hostname);
    const caPem = readCaPem();
    if (!fqdn || !caPem) {
      log("warning", "telemetry config skipped: tailnet FQDN or CA chain not ready yet");
      return;
    }
    try {
      const result = await telemetryManager.ensure(resolved.budgetMode as BudgetMode, { fqdn, caPem });
      if (result.changed) log("info", "telemetry config ensure", { result });
    } catch (err) {
      log("error", "telemetry config ensure failed", { error: errMsg(err) });
    }
  }

  const flushTimer = setInterval(() => {
    flushTick(false).catch((err) => log("error", "flush tick failed", { error: errMsg(err) }));
  }, FLUSH_INTERVAL_MS);
  const heartbeatTimer = setInterval(() => {
    sink
      .heartbeat(health.payload() as unknown as Record<string, unknown>)
      .catch((err) => log("error", "heartbeat failed", { error: errMsg(err) }));
  }, HEARTBEAT_INTERVAL_MS);
  const budgetTimer = setInterval(() => {
    runBudgetPoll().catch((err) => log("error", "budget poll failed", { error: errMsg(err) }));
  }, BUDGET_POLL_MS);

  await runBudgetPoll();

  let shuttingDown = false;
  async function shutdown(): Promise<void> {
    if (shuttingDown) return;
    shuttingDown = true;
    log("info", "shutting down");
    clearInterval(flushTimer);
    clearInterval(heartbeatTimer);
    clearInterval(budgetTimer);
    mqttSource.stop();
    try {
      await flushTick(true);
    } catch (err) {
      log("error", "final flush failed", { error: errMsg(err) });
    }
    process.exit(0);
  }

  process.on("SIGTERM", () => {
    shutdown().catch(() => process.exit(1));
  });
}

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

main().catch((err) => {
  console.error(JSON.stringify({ ts: new Date().toISOString(), level: "error", msg: "ingest fatal", error: errMsg(err) }));
  process.exit(1);
});
