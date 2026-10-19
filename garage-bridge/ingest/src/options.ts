import { readFileSync } from "node:fs";

export type LogLevel = "trace" | "debug" | "info" | "warning" | "error";

export interface IngestOptions {
  tailscale_enabled: boolean;
  tailscale_authkey: string | undefined;
  tailscale_hostname: string;
  /**
   * Public telemetry hostname under the Tesla partner domain (e.g.
   * `telemetry.garage.duncanbottrill.com`). When set, the add-on serves
   * fleet-telemetry with a leaf from its own private CA and registers this
   * hostname with Tesla instead of the tailnet FQDN. Trimmed and
   * lower-cased; empty or whitespace-only means unset. Anything else outside
   * `[a-z0-9.-]` (including inner whitespace) makes `loadOptions` throw, the
   * same rule `tlscert/run` applies before it idles.
   */
  telemetry_hostname?: string;
  tesla_private_key: string | undefined;
  tesla_vin: string;
  garage_api_base: string;
  bridge_secret: string;
  supabase_url: string;
  supabase_service_key: string;
  mqtt_host: string;
  mqtt_port: number;
  mqtt_username: string | undefined;
  mqtt_password: string | undefined;
  log_level: LogLevel;
}

const ALWAYS_REQUIRED = ["tesla_vin", "bridge_secret", "supabase_url", "supabase_service_key", "mqtt_host"] as const;

/**
 * Reads and validates `/data/options.json` (Home Assistant add-on options).
 * Throws a single error listing every missing required key. `tesla_private_key`
 * and `tailscale_authkey` are only required when `tailscale_enabled` is true —
 * they're consumed by the proxy/tailscale shell services, not by this module,
 * but ingest is the first process to fail fast on a bad options file.
 */
export function loadOptions(path = "/data/options.json"): IngestOptions {
  const raw = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;

  const missing: string[] = [];
  for (const key of ALWAYS_REQUIRED) {
    if (!raw[key]) missing.push(key);
  }

  const tailscaleEnabled = raw.tailscale_enabled !== false;
  if (tailscaleEnabled) {
    if (!raw.tailscale_authkey) missing.push("tailscale_authkey");
    if (!raw.tesla_private_key) missing.push("tesla_private_key");
  }

  if (missing.length > 0) {
    throw new Error(`garage-bridge ingest: missing required option(s): ${missing.join(", ")}`);
  }

  return {
    tailscale_enabled: tailscaleEnabled,
    tailscale_authkey: asString(raw.tailscale_authkey),
    tailscale_hostname: asString(raw.tailscale_hostname) ?? "garage-bridge",
    telemetry_hostname: asHostname(raw.telemetry_hostname),
    tesla_private_key: asString(raw.tesla_private_key),
    tesla_vin: asString(raw.tesla_vin)!,
    garage_api_base: asString(raw.garage_api_base) ?? "https://garage.duncanbottrill.com",
    bridge_secret: asString(raw.bridge_secret)!,
    supabase_url: asString(raw.supabase_url)!,
    supabase_service_key: asString(raw.supabase_service_key)!,
    mqtt_host: asString(raw.mqtt_host)!,
    mqtt_port: typeof raw.mqtt_port === "number" ? raw.mqtt_port : 1883,
    mqtt_username: asString(raw.mqtt_username),
    mqtt_password: asString(raw.mqtt_password),
    log_level: (asString(raw.log_level) as LogLevel | undefined) ?? "info",
  };
}

function asString(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

const HOSTNAME_CHARS = /^[a-z0-9.-]+$/;

function asHostname(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const trimmed = v.trim().toLowerCase();
  if (trimmed.length === 0) return undefined;
  if (!HOSTNAME_CHARS.test(trimmed)) {
    throw new Error(
      `garage-bridge ingest: telemetry_hostname '${trimmed}' is not a valid hostname ` +
        "(letters, digits, dots and hyphens only, e.g. telemetry.duncanbottrill.com)",
    );
  }
  return trimmed;
}
