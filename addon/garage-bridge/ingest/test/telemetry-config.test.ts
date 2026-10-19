import { describe, it, expect, vi } from "vitest";
import { cadenceFields, configHash, desiredConfig, TelemetryConfigManager, type EnsureResult } from "../src/telemetry-config";
import { BridgeTokenError } from "../src/bridge-token";
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

  it("triples every interval for reduced mode, leaving minimum_delta and resend_interval_seconds untouched", () => {
    const fields = cadenceFields("reduced");

    expect(fields.Location).toEqual({ interval_seconds: 30 });
    expect(fields.Soc).toEqual({ interval_seconds: 180, minimum_delta: 0.5 });
    // resend_interval_seconds is a "re-send even if unchanged" ceiling, not a
    // sampling rate — it must not stretch out under a reduced budget mode.
    expect(fields.Gear).toEqual({ interval_seconds: 3, resend_interval_seconds: 3600 });
    expect(Object.keys(fields)).toHaveLength(32);
  });

  it("sextuples every interval for minimal mode, drops VehicleSpeed, and still leaves resend_interval_seconds untouched", () => {
    const fields = cadenceFields("minimal");

    expect(fields.VehicleSpeed).toBeUndefined();
    expect(fields.Location).toEqual({ interval_seconds: 60 });
    expect(fields.Gear).toEqual({ interval_seconds: 6, resend_interval_seconds: 3600 });
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
  const hostname = "garage-bridge.tail1234.ts.net";
  const caPem = "-----BEGIN CERT-----ca-pem-a-----END CERT-----";

  it("is stable across field key order", () => {
    const a = configHash({ hostname, caPem, fields: { Soc: { interval_seconds: 60 }, Location: { interval_seconds: 10 } } });
    const b = configHash({ hostname, caPem, fields: { Location: { interval_seconds: 10 }, Soc: { interval_seconds: 60 } } });
    expect(a).toBe(b);
  });

  it("changes when an interval changes", () => {
    const a = configHash({ hostname, caPem, fields: { Soc: { interval_seconds: 60 } } });
    const b = configHash({ hostname, caPem, fields: { Soc: { interval_seconds: 61 } } });
    expect(a).not.toBe(b);
  });

  it("differs across budget modes' cadence tables", () => {
    expect(configHash({ hostname, caPem, fields: cadenceFields("normal") })).not.toBe(
      configHash({ hostname, caPem, fields: cadenceFields("reduced") }),
    );
  });

  it("changes when the hostname changes, fields and CA held constant", () => {
    const a = configHash({ hostname, caPem, fields: cadenceFields("normal") });
    const b = configHash({ hostname: "other-bridge.tail9999.ts.net", caPem, fields: cadenceFields("normal") });
    expect(a).not.toBe(b);
  });

  it("changes when the CA PEM changes, hostname and fields held constant", () => {
    const a = configHash({ hostname, caPem, fields: cadenceFields("normal") });
    const b = configHash({ hostname, caPem: "-----BEGIN CERT-----different-ca-----END CERT-----", fields: cadenceFields("normal") });
    expect(a).not.toBe(b);
  });
});

function makeVehicle(overrides: Partial<ResolvedVehicle> = {}): ResolvedVehicle {
  return {
    vehicleId: "veh-1",
    ownerId: "owner-1",
    budgetMode: "normal",
    configHash: null,
    configVersion: 0,
    confirmedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeSink(vehicle: ResolvedVehicle): Sink & { countUsage: ReturnType<typeof vi.fn>; setTelemetryConfig: ReturnType<typeof vi.fn>; resolveVehicle: ReturnType<typeof vi.fn> } {
  return {
    ensureStateRow: vi.fn(),
    insertSignals: vi.fn(),
    mergeState: vi.fn(),
    heartbeat: vi.fn(),
    countUsage: vi.fn().mockResolvedValue(undefined),
    countSignals: vi.fn(),
    resolveVehicle: vi.fn().mockResolvedValue(vehicle),
    setTelemetryConfig: vi.fn().mockResolvedValue(undefined),
  } as unknown as Sink & { countUsage: ReturnType<typeof vi.fn>; setTelemetryConfig: ReturnType<typeof vi.fn>; resolveVehicle: ReturnType<typeof vi.fn> };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status });
}

describe("TelemetryConfigManager construction", () => {
  it("throws when insecureTls is combined with a non-local proxyBase", () => {
    expect(() =>
      TelemetryConfigManager({
        proxyBase: "https://example.com:4443",
        vin: "VIN1",
        token: { get: vi.fn() },
        sink: makeSink(makeVehicle()),
        insecureTls: true,
      }),
    ).toThrow(/127\.0\.0\.1|localhost/);
  });

  it("allows insecureTls with a 127.0.0.1 or localhost proxyBase", () => {
    expect(() =>
      TelemetryConfigManager({
        proxyBase: "https://localhost:4443",
        vin: "VIN1",
        token: { get: vi.fn() },
        sink: makeSink(makeVehicle()),
        insecureTls: true,
      }),
    ).not.toThrow();
  });
});

describe("TelemetryConfigManager.ensure", () => {
  it("makes no calls at all when the hash already matches and confirmation is fresh", async () => {
    const fields = cadenceFields("normal");
    const vehicle = makeVehicle({ configHash: configHash({ hostname: "x.ts.net", caPem: "ca", fields }), configVersion: 2 });
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

    expect(result).toEqual({ changed: false, reason: "current" });
    expect(fetchMock).not.toHaveBeenCalled();
    expect(sink.countUsage).not.toHaveBeenCalled();
    expect(sink.setTelemetryConfig).not.toHaveBeenCalled();
  });

  it("re-registers when the hash matches but telemetry_confirmed_at is older than 150 days", async () => {
    const fields = cadenceFields("normal");
    const hostname = "x.ts.net";
    const caPem = "ca";
    const matchingHash = configHash({ hostname, caPem, fields });

    const now = new Date("2026-10-19T00:00:00.000Z").getTime();
    const staleConfirmedAt = new Date(now - 151 * 24 * 3600 * 1000).toISOString();
    const vehicle = makeVehicle({ configHash: matchingHash, configVersion: 5, confirmedAt: staleConfirmedAt });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ response: {} }))
      .mockResolvedValueOnce(jsonResponse({ response: { synced: true } }));

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    const result = await manager.ensure("normal", { fqdn: hostname, caPem }, now);

    expect(result).toEqual({ changed: true });
    expect(fetchMock).toHaveBeenCalledTimes(2); // POST + 1 poll — staleness forced a real re-registration
  });

  it("posts once, polls until synced, and stamps confirmedAt from clock() (the time the synced poll returned), not ensure-start", async () => {
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
    const ensureStart = new Date("2026-10-19T00:00:00.000Z").getTime();
    const syncedReturnedAt = new Date("2026-10-19T00:00:31.000Z"); // distinct from ensure-start
    const clock = vi.fn().mockReturnValue(syncedReturnedAt);

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
      insecureTls: true,
      clock,
    });

    const result = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, ensureStart);

    expect(result).toEqual({ changed: true });
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
    // confirmedAt is clock()'s value (the time the synced:true poll RETURNED), not ensure-start.
    expect(setArgs.confirmedAt).toBe(syncedReturnedAt.toISOString());
    expect(setArgs.confirmedAt).not.toBe(new Date(ensureStart).toISOString());
    expect(setArgs.lastError).toBeNull();
    expect(typeof setArgs.hash).toBe("string");
  });

  it("fetches errors and records telemetry_last_error when synced never arrives within the first 40-poll run", async () => {
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

    expect(result).toEqual({ changed: false, reason: "not_synced" });

    expect(sink.setTelemetryConfig).toHaveBeenCalledTimes(1);
    expect(sink.setTelemetryConfig).toHaveBeenCalledWith({ lastError: "config_rejected: unsupported field" });

    // 1 POST + 40 polls + 1 errors fetch, every one counted as data usage.
    expect(fetchMock).toHaveBeenCalledTimes(42);
    expect(sink.countUsage).toHaveBeenCalledTimes(42);
  }, 10_000);

  it("returns in_flight when a second ensure() overlaps an in-progress one", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };

    let resolvePost: (() => void) | undefined;
    const postPending = new Promise<Response>((resolve) => {
      resolvePost = () => resolve(jsonResponse({ response: {} }));
    });

    const fetchMock = vi.fn().mockImplementationOnce(() => postPending);
    const sleep = vi.fn().mockResolvedValue(undefined);

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    // Both calls' resolveVehicle() microtasks queue in order; the first one's
    // continuation runs synchronously (no intervening await) through the
    // current/inFlight/token-wait checks and sets inFlight = true before the
    // second call's own continuation gets a turn — so no extra synchronization
    // is needed here, same as the old (pre-resolveVehicle-in-the-gate) version
    // of this test.
    const first = manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" });
    const second = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" });

    expect(second).toEqual({ changed: false, reason: "in_flight" });

    fetchMock.mockImplementation(async () => jsonResponse({ response: { synced: true } }));
    resolvePost!();
    const firstResult = await first;
    expect(firstResult).toEqual({ changed: true });
  });

  it("Sequence (b): a POST failure backs off with ZERO calls, and the window-end call re-POSTs and confirms (POST count 2, GET count 1)", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 1 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi.fn().mockResolvedValueOnce(jsonResponse({ error: "server_error" }, 500));

    const t0 = new Date("2026-10-19T00:00:00.000Z").getTime();
    let simClock = t0;

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
      clock: () => new Date(simClock),
    });

    const first = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, t0);
    expect(first).toEqual({ changed: false, reason: "post_failed" });
    expect(fetchMock).toHaveBeenCalledTimes(1); // stopped immediately on the non-2xx POST, no polling

    // +5min and +10min: still inside the 15-minute POST backoff window -> post_backoff, ZERO calls.
    for (const offsetMin of [5, 10]) {
      const t = t0 + offsetMin * 60_000;
      simClock = t;
      // eslint-disable-next-line no-await-in-loop
      const result = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, t);
      expect(result).toEqual({ changed: false, reason: "post_backoff" });
    }
    expect(fetchMock).toHaveBeenCalledTimes(1); // no new calls at all during backoff

    // +15min: the backoff window has elapsed exactly (now === nextPostAt) -> re-POSTs (2nd attempt).
    // Make this one succeed, and synced on the very first poll.
    fetchMock.mockResolvedValueOnce(jsonResponse({ response: {} })); // POST #2 -> 200
    fetchMock.mockResolvedValueOnce(jsonResponse({ response: { synced: true } })); // poll #1 -> synced

    const t15 = t0 + 15 * 60_000;
    simClock = t15;
    const confirmed = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, t15);
    expect(confirmed).toEqual({ changed: true });

    expect(fetchMock).toHaveBeenCalledTimes(3); // 1 failed POST + 1 succeeded POST + 1 poll
    const posts = fetchMock.mock.calls.filter((c) => (c[1] as RequestInit | undefined)?.method === "POST");
    const gets = fetchMock.mock.calls.filter((c) => (c[1] as RequestInit | undefined)?.method !== "POST");
    expect(posts).toHaveLength(2);
    expect(gets).toHaveLength(1);
  });

  it("a config hash change bypasses an active POST backoff window for the old hash", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 1 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi.fn().mockResolvedValueOnce(jsonResponse({ error: "server_error" }, 500));

    const t0 = new Date("2026-10-19T00:00:00.000Z").getTime();
    let simClock = t0;

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
      clock: () => new Date(simClock),
    });

    const first = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, t0);
    expect(first).toEqual({ changed: false, reason: "post_failed" });
    expect(fetchMock).toHaveBeenCalledTimes(1);

    // Different fqdn => different hash => a fresh POST happens immediately,
    // even though we're still inside the backoff window for the OLD hash.
    fetchMock.mockImplementation(async () => jsonResponse({ response: { synced: true } }));
    const tWithinWindow = t0 + 5 * 60_000;
    simClock = tWithinWindow;
    const result = await manager.ensure("normal", { fqdn: "new-host.ts.net", caPem: "ca" }, tWithinWindow);

    expect(result).toEqual({ changed: true });
    const postCall = fetchMock.mock.calls[1]!;
    expect(postCall[1]).toMatchObject({ method: "POST" });
  });

  it("Sequence (d): refreshes the bridge token once on a 401 mid-poll and confirms after the retry succeeds", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const token = {
      get: vi.fn().mockImplementation(async (getOpts?: { force?: boolean }) =>
        getOpts?.force
          ? { access_token: "fresh-tok", expires_at: "2099-01-01" }
          : { access_token: "stale-tok", expires_at: "2099-01-01" },
      ),
    };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ response: {} })) // POST -> 200
      .mockResolvedValueOnce(jsonResponse({ response: { synced: false } })) // poll attempt #1 -> not synced
      .mockResolvedValueOnce(jsonResponse({ error: "unauthorized" }, 401)) // poll attempt #2 (stale token) -> 401
      .mockResolvedValueOnce(jsonResponse({ response: { synced: true } })); // poll attempt #2 retried (fresh token) -> synced

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    const result = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" });

    expect(result).toEqual({ changed: true });
    expect(fetchMock).toHaveBeenCalledTimes(4);

    const forcedCalls = (token.get as ReturnType<typeof vi.fn>).mock.calls.filter((c) => (c[0] as { force?: boolean } | undefined)?.force === true);
    expect(forcedCalls).toHaveLength(1);

    const retriedCall = fetchMock.mock.calls[3]!;
    expect(retriedCall[1]).toMatchObject({ headers: { authorization: "Bearer fresh-tok" } });
  });

  it("throws when the retried call after a forced token refresh is still 401", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "bad-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ error: "unauthorized" }, 401))
      .mockResolvedValueOnce(jsonResponse({ error: "unauthorized" }, 401));

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    await expect(manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" })).rejects.toThrow(/unauthorized after forced token refresh/);
    expect(fetchMock).toHaveBeenCalledTimes(2); // original + one retry, then it throws
    expect(token.get).toHaveBeenCalledTimes(2);
    expect((token.get as ReturnType<typeof vi.fn>).mock.calls[1]![0]).toEqual({ force: true });
  });

  it("stores a bridge-token error as token:<code> and skips registration until retryAt", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const retryAt = "2026-10-19T01:00:00.000Z";
    const token = { get: vi.fn().mockRejectedValue(new BridgeTokenError("token_unavailable", retryAt)) };
    const fetchMock = vi.fn();
    const sleep = vi.fn().mockResolvedValue(undefined);

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    const t0 = new Date("2026-10-19T00:00:00.000Z").getTime();
    const first = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, t0);
    expect(first).toEqual({ changed: false, reason: "token_error" });
    expect(sink.setTelemetryConfig).toHaveBeenCalledWith({ lastError: "token:token_unavailable" });
    expect(fetchMock).not.toHaveBeenCalled(); // never reached a proxy call

    // Still before retryAt: the current-config check (step 1) still runs resolveVehicle — it's
    // ordered ahead of the token-wait gate — but no token or HTTP calls happen once that gate trips.
    token.get.mockClear();
    sink.resolveVehicle.mockClear();
    const tBefore = t0 + 30 * 60_000;
    const second = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, tBefore);
    expect(second).toEqual({ changed: false, reason: "token_wait" });
    expect(token.get).not.toHaveBeenCalled();
    expect(sink.resolveVehicle).toHaveBeenCalledTimes(1);

    // After retryAt: attempts again.
    token.get.mockResolvedValue({ access_token: "tok", expires_at: "2099-01-01" });
    fetchMock.mockImplementation(async () => jsonResponse({ response: { synced: true } }));
    const tAfter = new Date("2026-10-19T01:30:00.000Z").getTime();
    const third = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, tAfter);
    expect(third).toEqual({ changed: true });
  });

  it("Sequence (c): a never-synced run schedules its own doubling poll delay (5→10→20→40 min) from clock(), not entry-now", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 2 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      if (init?.method === "POST") return jsonResponse({ response: {} });
      if (url.includes("fleet_telemetry_errors")) {
        return jsonResponse({ response: { fleet_telemetry_errors: [{ name: "config_rejected", body: "nope" }] } });
      }
      return jsonResponse({ response: { synced: false } });
    });

    const t0 = new Date("2026-10-19T00:00:00.000Z").getTime();
    let simClock = t0;

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
      clock: () => new Date(simClock),
    });

    function callAt(minutesFromT0: number) {
      const now = t0 + minutesFromT0 * 60_000;
      // clock() tracks this call's `now`: the manager schedules its next
      // backoff/poll deadline from clock() ("a fresh now after the work"),
      // and pinning it to the test's own `now` keeps the gating comparisons
      // (driven by `now`) and the scheduling (driven by `clock()`) in sync,
      // which is what makes this deterministic.
      simClock = now;
      return manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, now);
    }

    // Call #1 (t=0): the first run right after the accepted POST — 40 bounded
    // polls plus 1 errors fetch, all within this one ensure() call.
    // nextPollAt = now(0) + pollDelayMs(5min) = +5min; pollDelayMs doubles to
    // 10min for the next run.
    const r1 = await callAt(0);
    expect(r1).toEqual({ changed: false, reason: "not_synced" });
    expect(fetchMock).toHaveBeenCalledTimes(1 + 40 + 1); // POST + 40 polls + 1 errors fetch

    const getCountsAt: number[] = [];
    async function countGetsAt(minutesFromT0: number): Promise<EnsureResult> {
      const before = fetchMock.mock.calls.length;
      const result = await callAt(minutesFromT0);
      getCountsAt.push(fetchMock.mock.calls.length - before);
      return result;
    }

    // +5min: now(5) >= nextPollAt(5) -> proceeds, 4 bounded polls (not the
    // first run, so no errors re-fetch). nextPollAt = now(5) + pollDelayMs
    // (10min, doubled after call #1) = +15min; pollDelayMs doubles to 20min.
    await countGetsAt(5);
    // +10min: now(10) < nextPollAt(15) -> poll_backoff, zero calls.
    await countGetsAt(10);
    // +15min: now(15) >= nextPollAt(15) -> proceeds, 4 polls. nextPollAt =
    // now(15) + pollDelayMs(20min) = +35min; pollDelayMs doubles to 40min.
    await countGetsAt(15);
    // +25min: now(25) < nextPollAt(35) -> poll_backoff, zero calls.
    await countGetsAt(25);
    // +30min: now(30) < nextPollAt(35) -> still poll_backoff, zero calls.
    await countGetsAt(30);

    // Computed from the rule above (not the task sketch's rough "4+0+4+4+0" —
    // that sketch didn't account for the first run's own 10-minute span of
    // 15s-apart polls not advancing the schedule's basis beyond entry-now):
    expect(getCountsAt).toEqual([4, 0, 4, 0, 0]);
  }, 10_000);

  it("false-confirm guard: a POST failure's backoff window blocks any call, even one that would've reported synced:true", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi.fn().mockResolvedValueOnce(jsonResponse({ error: "server_error" }, 500));

    const t0 = new Date("2026-10-19T00:00:00.000Z").getTime();
    let simClock = t0;

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
      clock: () => new Date(simClock),
    });

    const first = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, t0);
    expect(first).toEqual({ changed: false, reason: "post_failed" });

    // If a GET were made now it would report synced:true — but we're still
    // within the 15-minute POST backoff window, so no GET is ever attempted,
    // and nothing can be falsely confirmed from it.
    fetchMock.mockImplementation(async () => jsonResponse({ response: { synced: true } }));
    sink.setTelemetryConfig.mockClear();

    const tWithinWindow = t0 + 5 * 60_000;
    simClock = tWithinWindow;
    const second = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" }, tWithinWindow);

    expect(second).toEqual({ changed: false, reason: "post_backoff" });
    expect(fetchMock).toHaveBeenCalledTimes(1); // only the original failed POST
    expect(sink.setTelemetryConfig).not.toHaveBeenCalled();
  });

  it("false-confirm guard: synced:true with a mismatched config.hostname is not trusted as confirmation", async () => {
    const vehicle = makeVehicle({ configHash: "stale-hash", configVersion: 0 });
    const sink = makeSink(vehicle);
    const token = { get: vi.fn().mockResolvedValue({ access_token: "tesla-tok", expires_at: "2099-01-01" }) };
    const sleep = vi.fn().mockResolvedValue(undefined);

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ response: {} })) // POST -> 200
      .mockImplementation(async () =>
        jsonResponse({
          response: { synced: true, config: { hostname: "someone-elses-host.ts.net", fields: cadenceFields("normal") } },
        }),
      );

    const manager = TelemetryConfigManager({
      proxyBase: "https://127.0.0.1:4443",
      vin: "VIN1",
      token,
      sink,
      fetch: fetchMock as unknown as typeof fetch,
      sleep,
    });

    const result = await manager.ensure("normal", { fqdn: "x.ts.net", caPem: "ca" });

    expect(result).toEqual({ changed: false, reason: "not_synced" });
    expect(sink.setTelemetryConfig).not.toHaveBeenCalledWith(
      expect.objectContaining({ hash: expect.anything(), confirmedAt: expect.anything() }),
    );
    // 1 POST + 40 polls (every one rejected by the hostname mismatch) + 1 errors fetch.
    expect(fetchMock).toHaveBeenCalledTimes(1 + 40 + 1);
  }, 10_000);
});
