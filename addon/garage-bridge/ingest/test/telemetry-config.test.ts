import { describe, it, expect, vi } from "vitest";
import { cadenceFields, configHash, desiredConfig, TelemetryConfigManager, type EnsureResult } from "../src/telemetry-config";
import type { ResolvedVehicle, Sink } from "../src/supabase-sink";

describe("cadenceFields", () => {
  it("matches the Global Constraints cadence table for normal mode", () => {
    const fields = cadenceFields("normal");

    expect(fields.Location).toEqual({ interval_seconds: 10 });
    expect(fields.Soc).toEqual({ interval_seconds: 60, minimum_delta: 0.5 });
    expect(fields.EstBatteryRange).toEqual({ interval_seconds: 60, minimum_delta: 1 });
    expect(fields.Odometer).toEqual({ interval_seconds: 60, minimum_delta: 0.1 });
    expect(fields.Gear).toEqual({ interval_seconds: 1, resend_interval_seconds: 3600 });
    expect(fields.DoorState).toEqual({ interval_seconds: 1, resend_interval_seconds: 3600 });
    expect(fields.FdWindow).toEqual({ interval_seconds: 5 });
    expect(fields.TpmsPressureRr).toEqual({ interval_seconds: 300 });
    expect(fields.VehicleName).toEqual({ interval_seconds: 3600 });
    expect(fields.SoftwareUpdateVersion).toEqual({ interval_seconds: 3600 });

    // The plan's literal field-by-field cadence listing enumerates 32 distinct
    // field names (FdWindow/FpWindow/RdWindow/RpWindow and
    // TpmsPressureFl/Fr/Rl/Rr each expand to 4); see task-4-report.md concerns
    // for the discrepancy with the plan's own prose count of 31.
    expect(Object.keys(fields)).toHaveLength(32);
  });

  it("triples every interval and resend for reduced mode, leaving minimum_delta untouched", () => {
    const fields = cadenceFields("reduced");

    expect(fields.Location).toEqual({ interval_seconds: 30 });
    expect(fields.Soc).toEqual({ interval_seconds: 180, minimum_delta: 0.5 });
    expect(fields.Gear).toEqual({ interval_seconds: 3, resend_interval_seconds: 10800 });
    expect(Object.keys(fields)).toHaveLength(32);
  });

  it("sextuples every interval for minimal mode and drops VehicleSpeed", () => {
    const fields = cadenceFields("minimal");

    expect(fields.VehicleSpeed).toBeUndefined();
    expect(fields.Location).toEqual({ interval_seconds: 60 });
    expect(fields.Gear).toEqual({ interval_seconds: 6, resend_interval_seconds: 21600 });
    expect(Object.keys(fields)).toHaveLength(31);
  });
});

describe("desiredConfig", () => {
  it("builds the telemetry config body per the plan's shape", () => {
    const now = new Date("2026-10-19T00:00:00.000Z");
    const body = desiredConfig({ fqdn: "garage-bridge.tail1234.ts.net", caPem: "-----BEGIN CERT-----", mode: "normal", now });

    expect(body.hostname).toBe("garage-bridge.tail1234.ts.net");
    expect(body.port).toBe(443);
    expect(body.ca).toBe("-----BEGIN CERT-----");
    expect(body.alert_types).toEqual(["service"]);
    expect(body.exp).toBe(Math.floor(now.getTime() / 1000) + 180 * 24 * 3600);
    expect(Object.keys(body.fields)).toHaveLength(32);
  });
});

describe("configHash", () => {
  it("is stable across key order", () => {
    const a = configHash({ Soc: { interval_seconds: 60 }, Location: { interval_seconds: 10 } });
    const b = configHash({ Location: { interval_seconds: 10 }, Soc: { interval_seconds: 60 } });
    expect(a).toBe(b);
  });

  it("changes when an interval changes", () => {
    const a = configHash({ Soc: { interval_seconds: 60 } });
    const b = configHash({ Soc: { interval_seconds: 61 } });
    expect(a).not.toBe(b);
  });

  it("differs across budget modes' cadence tables", () => {
    expect(configHash(cadenceFields("normal"))).not.toBe(configHash(cadenceFields("reduced")));
  });
});

function makeVehicle(overrides: Partial<ResolvedVehicle> = {}): ResolvedVehicle {
  return {
    vehicleId: "veh-1",
    ownerId: "owner-1",
    budgetMode: "normal",
    configHash: null,
    configVersion: 0,
    ...overrides,
  };
}

function makeSink(vehicle: ResolvedVehicle): Sink & { countUsage: ReturnType<typeof vi.fn>; setTelemetryConfig: ReturnType<typeof vi.fn> } {
  return {
    ensureStateRow: vi.fn(),
    insertSignals: vi.fn(),
    mergeState: vi.fn(),
    heartbeat: vi.fn(),
    countUsage: vi.fn().mockResolvedValue(undefined),
    countSignals: vi.fn(),
    resolveVehicle: vi.fn().mockResolvedValue(vehicle),
    setTelemetryConfig: vi.fn().mockResolvedValue(undefined),
  } as unknown as Sink & { countUsage: ReturnType<typeof vi.fn>; setTelemetryConfig: ReturnType<typeof vi.fn> };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status });
}

describe("TelemetryConfigManager.ensure", () => {
  it("makes no calls at all when the hash already matches", async () => {
    const fields = cadenceFields("normal");
    const vehicle = makeVehicle({ configHash: configHash(fields), configVersion: 2 });
    const sink = makeSink(vehicle);
    const fetchMock = vi.fn();

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token: { get: vi.fn() },
      sink,
      fetch: fetchMock as unknown as typeof fetch,
    });

    const result: EnsureResult = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" });

    expect(result).toEqual({ changed: false });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(sink.countUsage).not.toHaveBeenCalled();
    expect(sink.setTelemetryConfig).not.toHaveBeenCalled();
  });

  it("posts once, polls until synced, and records hash/version on success", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 3 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };

    const fetchMock = vi
      .fn()
      // POST fleet_telemetry_config
      .mockResolvedValueOnce(jsonResponse({ response: {} }))
      // GET poll #1: not synced
      .mockResolvedValueOnce(jsonResponse({ response: { synced: false } }))
      // GET poll #2: synced
      .mockResolvedValueOnce(jsonResponse({ response: { synced: true } }));

    const sleep = vi.fn().mockResolvedValue(undefined);

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
      insecureTls: true,
    });

    const now = new Date("2026-10-19T00:00:00.000Z");
    const result = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, now);

    expect(result).toEqual({ changed: true, synced: true });
    expect(fetchMock).toHaveBeenCalledTimes(3);

    const postCall = fetchMock.mock.calls[0]!;
    expect(String(postCall[0])).toBe("https://127.0.0.1:4443/api/1/vehicles/fleet_telemetry_config");
    expect(postCall[1]).toMatchObject({ method: "POST", headers: { authorization: "Bearer tesla-tok" } });
    const postedBody = JSON.parse(postCall[1].body);
    expect(postedBody.vins).toEqual(["VIN1"]);
    expect(postedBody.config.hostname).toBe("x.ts.net");

    // Never logs/transmits the bridge secret; only the Tesla token appears, in the auth header (mocked),
    // which the manager itself never writes to any log.
    expect(sink.countUsage).toHaveBeenCalledTimes(3);
    expect(sink.countUsage).toHaveBeenCalledWith("data", 1);

    expect(sink.setTelemetryConfig).toHaveBeenCalledTimes(1);
    const [setArgs] = sink.setTelemetryConfig.mock.calls[0]!;
    expect(setArgs.version).toBe(4);
    expect(setArgs.confirmedAt).toBe(now.toISOString());
    expect(setArgs.lastError).toBeNull();
    expect(typeof setArgs.hash).toBe("string");
  });

  it("fetches errors and records telemetry_last_error when synced never arrives", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };

    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith("/fleet_telemetry_config") && !url.includes("vehicles/VIN1/")) {
        return jsonResponse({ response: {} }); // POST
      }
      if (url.includes("fleet_telemetry_errors")) {
        return jsonResponse({ response: { fleet_telemetry_errors: [{ name: "config_rejected", body: "unsupported field", created_at: "now" }] } });
      }
      return jsonResponse({ response: { synced: false } }); // polls
    });

    const sleep = vi.fn().mockResolvedValue(undefined);

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    const result = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" });

    expect(result.changed).toBe(true);
    expect((result as { synced: false; error: string }).synced).toBe(false);
    expect((result as { synced: false; error: string }).error).toBe("config_rejected: unsupported field");

    expect(sink.setTelemetryConfig).toHaveBeenCalledTimes(1);
    expect(sink.setTelemetryConfig).toHaveBeenCalledWith({ lastError: "config_rejected: unsupported field" });

    // 1 POST + 40 polls + 1 errors fetch, every one counted as data usage.
    expect(fetchMock).toHaveBeenCalledTimes(42);
    expect(sink.countUsage).toHaveBeenCalledTimes(42);
  }, 10_000);
});
