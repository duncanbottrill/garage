import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { loadOptions } from "../src/options";

const BASE = {
  tailscale_enabled: true,
  tailscale_authkey: "tskey-auth-test",
  tailscale_hostname: "garage-bridge",
  tesla_private_key: "-----BEGIN EC PRIVATE KEY-----\nx\n-----END EC PRIVATE KEY-----",
  tesla_vin: "XP7YTEST00000001",
  garage_api_base: "https://garage.duncanbottrill.com",
  bridge_secret: "secret",
  supabase_url: "https://example.supabase.co",
  supabase_service_key: "service-key",
  mqtt_host: "core-mosquitto",
  mqtt_port: 1883,
  log_level: "info",
};

describe("loadOptions", () => {
  let dir: string | undefined;

  afterEach(() => {
    if (dir) rmSync(dir, { recursive: true, force: true });
    dir = undefined;
  });

  function optionsFile(extra: Record<string, unknown>): string {
    dir = mkdtempSync(path.join(tmpdir(), "options-"));
    const file = path.join(dir, "options.json");
    writeFileSync(file, JSON.stringify({ ...BASE, ...extra }));
    return file;
  }

  it("leaves telemetry_hostname undefined when the option is absent", () => {
    expect(loadOptions(optionsFile({})).telemetry_hostname).toBeUndefined();
  });

  it("treats an empty telemetry_hostname as unset", () => {
    expect(loadOptions(optionsFile({ telemetry_hostname: "" })).telemetry_hostname).toBeUndefined();
  });

  it("treats a whitespace-only telemetry_hostname as unset", () => {
    expect(loadOptions(optionsFile({ telemetry_hostname: "   " })).telemetry_hostname).toBeUndefined();
  });

  it("treats a null telemetry_hostname as unset", () => {
    expect(loadOptions(optionsFile({ telemetry_hostname: null })).telemetry_hostname).toBeUndefined();
  });

  it("returns the trimmed, lower-cased telemetry_hostname when set", () => {
    const opts = loadOptions(optionsFile({ telemetry_hostname: "  Telemetry.Garage.DuncanBottrill.com \n" }));
    expect(opts.telemetry_hostname).toBe("telemetry.garage.duncanbottrill.com");
  });

  it("rejects a telemetry_hostname with internal whitespace", () => {
    expect(() => loadOptions(optionsFile({ telemetry_hostname: "telemetry.garage .duncanbottrill.com" }))).toThrow(
      /telemetry_hostname 'telemetry\.garage \.duncanbottrill\.com' is not a valid hostname/,
    );
  });

  it("rejects a telemetry_hostname with characters outside [a-z0-9.-]", () => {
    for (const bad of ["telemetry_garage.duncanbottrill.com", "https://telemetry.duncanbottrill.com", "telemetry.duncanbottrill.com:443", "tele/metry.com"]) {
      expect(() => loadOptions(optionsFile({ telemetry_hostname: bad })), bad).toThrow(/telemetry_hostname .* is not a valid hostname/);
    }
  });

  it("accepts letters, digits, dots and hyphens after trimming and lower-casing", () => {
    const opts = loadOptions(optionsFile({ telemetry_hostname: "\tTelemetry-1.Garage.DuncanBottrill.COM\n" }));
    expect(opts.telemetry_hostname).toBe("telemetry-1.garage.duncanbottrill.com");
  });

  it("still reads the existing options unchanged", () => {
    const opts = loadOptions(optionsFile({ telemetry_hostname: "telemetry.garage.duncanbottrill.com" }));
    expect(opts.tesla_vin).toBe("XP7YTEST00000001");
    expect(opts.tailscale_enabled).toBe(true);
    expect(opts.mqtt_port).toBe(1883);
  });
});
