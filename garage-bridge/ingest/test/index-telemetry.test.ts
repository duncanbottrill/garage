import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { createTelemetryEnsurer, type Logger } from "../src/index";
import type { EnsureResult } from "../src/telemetry-config";

const CA = "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n";
const HOST = "telemetry.garage.duncanbottrill.com";
const FQDN = "garage-bridge.tail068c8f.ts.net";

function fakeLog(): { log: Logger; calls: Array<[string, string, Record<string, unknown> | undefined]> } {
  const calls: Array<[string, string, Record<string, unknown> | undefined]> = [];
  const log: Logger = (level, msg, extra) => {
    calls.push([level, msg, extra]);
  };
  return { log, calls };
}

interface Setup {
  telemetryHostname?: string;
  fqdn?: () => string;
  caPem?: () => string | null;
  marker?: () => string | null;
  ensure?: (...args: unknown[]) => Promise<EnsureResult>;
  stopping?: () => boolean;
}

function setup(s: Setup = {}) {
  const ensure = vi.fn(s.ensure ?? (async (): Promise<EnsureResult> => ({ changed: true })));
  const readFqdn = vi.fn(s.fqdn ?? (() => FQDN));
  const readCaPem = vi.fn(s.caPem ?? (() => CA));
  const readHostnameMarker = vi.fn(s.marker ?? (() => HOST));
  const { log, calls } = fakeLog();
  const ensurer = createTelemetryEnsurer({
    manager: { ensure },
    telemetryHostname: s.telemetryHostname,
    readFqdn,
    readCaPem,
    readHostnameMarker,
    log,
    isStopping: s.stopping ?? (() => false),
  });
  return { ensurer, ensure, readFqdn, readCaPem, readHostnameMarker, calls };
}

describe("createTelemetryEnsurer", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  describe("tailnet mode (no telemetry_hostname)", () => {
    it("registers the tailnet FQDN with the CA chain", async () => {
      const { ensurer, ensure } = setup();
      await ensurer.run("normal");
      expect(ensure).toHaveBeenCalledTimes(1);
      expect(ensure).toHaveBeenCalledWith("normal", { fqdn: FQDN, caPem: CA });
    });

    it("skips with the existing warning when the FQDN is not ready", async () => {
      const { ensurer, ensure, calls } = setup({
        fqdn: () => {
          throw new Error("ENOENT");
        },
      });
      await ensurer.run("normal");
      expect(ensure).not.toHaveBeenCalled();
      expect(calls).toContainEqual(["warning", "telemetry config skipped: tailnet FQDN or CA chain not ready yet", undefined]);
    });

    it("never consults the hostname marker", async () => {
      const { ensurer, readHostnameMarker } = setup();
      await ensurer.run("normal");
      expect(readHostnameMarker).not.toHaveBeenCalled();
    });
  });

  describe("hostname mode (telemetry_hostname set)", () => {
    it("registers telemetry_hostname, not the tailnet FQDN, and never reads the FQDN", async () => {
      const { ensurer, ensure, readFqdn } = setup({ telemetryHostname: HOST });
      await ensurer.run("normal");
      expect(ensure).toHaveBeenCalledWith("normal", { fqdn: HOST, caPem: CA });
      expect(readFqdn).not.toHaveBeenCalled();
    });

    it("does not wait for the tailnet FQDN (tailscale may be down)", async () => {
      const { ensurer, ensure } = setup({
        telemetryHostname: HOST,
        fqdn: () => {
          throw new Error("ENOENT");
        },
      });
      await ensurer.run("normal");
      expect(ensure).toHaveBeenCalledTimes(1);
    });

    it("skips while ca.pem is missing", async () => {
      const { ensurer, ensure, calls } = setup({ telemetryHostname: HOST, caPem: () => null });
      await ensurer.run("normal");
      expect(ensure).not.toHaveBeenCalled();
      expect(calls.some(([level, msg]) => level === "warning" && msg === "telemetry config skipped: private CA not ready yet")).toBe(true);
    });

    it("skips while the private-CA marker does not name this hostname (a stale tailnet ca.pem may still be in place)", async () => {
      const { ensurer, ensure } = setup({ telemetryHostname: HOST, marker: () => "old.example.com" });
      await ensurer.run("normal");
      expect(ensure).not.toHaveBeenCalled();
    });

    it("skips while the private-CA marker is missing", async () => {
      const { ensurer, ensure } = setup({ telemetryHostname: HOST, marker: () => null });
      await ensurer.run("normal");
      expect(ensure).not.toHaveBeenCalled();
    });
  });

  describe("fast retry", () => {
    it("retries 30 s after a not-ready skip, and registers once ready", async () => {
      let ready = false;
      const { ensurer, ensure } = setup({ telemetryHostname: HOST, caPem: () => (ready ? CA : null) });
      await ensurer.run("normal");
      expect(ensure).not.toHaveBeenCalled();

      ready = true;
      await vi.advanceTimersByTimeAsync(29_999);
      expect(ensure).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(1);
      expect(ensure).toHaveBeenCalledTimes(1);
      expect(ensure).toHaveBeenCalledWith("normal", { fqdn: HOST, caPem: CA });
    });

    it("retries 30 s after ensure throws", async () => {
      let calls = 0;
      const { ensurer, ensure } = setup({
        ensure: async (): Promise<EnsureResult> => {
          calls++;
          if (calls === 1) throw new Error("supabase down");
          return { changed: true };
        },
      });
      await ensurer.run("normal");
      expect(ensure).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(30_000);
      expect(ensure).toHaveBeenCalledTimes(2);
    });

    it("keeps retrying every 30 s while still not ready, one timer at a time", async () => {
      const { ensurer, readCaPem } = setup({ telemetryHostname: HOST, caPem: () => null });
      await ensurer.run("normal");
      expect(readCaPem).toHaveBeenCalledTimes(1);
      expect(vi.getTimerCount()).toBe(1);
      await vi.advanceTimersByTimeAsync(30_000);
      expect(readCaPem).toHaveBeenCalledTimes(2);
      expect(vi.getTimerCount()).toBe(1);
      await vi.advanceTimersByTimeAsync(30_000);
      expect(readCaPem).toHaveBeenCalledTimes(3);
      expect(vi.getTimerCount()).toBe(1);
    });

    it("does not stack timers when the budget poll runs while a retry is pending", async () => {
      const { ensurer, readCaPem } = setup({ telemetryHostname: HOST, caPem: () => null });
      await ensurer.run("normal");
      await ensurer.run("normal");
      await ensurer.run("normal");
      expect(vi.getTimerCount()).toBe(1);
      await vi.advanceTimersByTimeAsync(30_000);
      expect(readCaPem).toHaveBeenCalledTimes(4);
      expect(vi.getTimerCount()).toBe(1);
    });

    it("cancels a pending retry when a later run confirms", async () => {
      let ready = false;
      const { ensurer, ensure } = setup({ telemetryHostname: HOST, caPem: () => (ready ? CA : null) });
      await ensurer.run("normal");
      expect(vi.getTimerCount()).toBe(1);
      ready = true;
      await ensurer.run("normal");
      expect(ensure).toHaveBeenCalledTimes(1);
      expect(vi.getTimerCount()).toBe(0);
      await vi.advanceTimersByTimeAsync(60_000);
      expect(ensure).toHaveBeenCalledTimes(1);
    });

    it("schedules no retry once confirmed (changed: true)", async () => {
      const { ensurer } = setup();
      await ensurer.run("normal");
      expect(vi.getTimerCount()).toBe(0);
    });

    it("schedules no retry when the config is already current", async () => {
      const { ensurer } = setup({ ensure: async () => ({ changed: false, reason: "current" }) });
      await ensurer.run("normal");
      expect(vi.getTimerCount()).toBe(0);
    });

    it("leaves backoff results to the manager's own schedule (no 30 s retry)", async () => {
      for (const reason of ["post_failed", "post_backoff", "poll_backoff", "not_synced", "token_error", "token_wait", "in_flight"] as const) {
        const { ensurer } = setup({ ensure: async () => ({ changed: false, reason }) });
        await ensurer.run("normal");
        expect(vi.getTimerCount(), reason).toBe(0);
      }
    });

    it("does not fast-retry a thrown ensure once the config was confirmed", async () => {
      let calls = 0;
      const { ensurer, ensure } = setup({
        ensure: async (): Promise<EnsureResult> => {
          calls++;
          if (calls === 1) return { changed: true };
          throw new Error("supabase blip");
        },
      });
      await ensurer.run("normal");
      await ensurer.run("normal");
      expect(ensure).toHaveBeenCalledTimes(2);
      expect(vi.getTimerCount()).toBe(0);
    });

    it("retries with the most recent budget mode", async () => {
      let ready = false;
      const { ensurer, ensure } = setup({ caPem: () => (ready ? CA : null) });
      await ensurer.run("normal");
      await ensurer.run("reduced");
      ready = true;
      await vi.advanceTimersByTimeAsync(30_000);
      expect(ensure).toHaveBeenCalledWith("reduced", { fqdn: FQDN, caPem: CA });
    });

    it("cancel() clears a pending retry", async () => {
      const { ensurer, readCaPem } = setup({ caPem: () => null });
      await ensurer.run("normal");
      ensurer.cancel();
      expect(vi.getTimerCount()).toBe(0);
      await vi.advanceTimersByTimeAsync(60_000);
      expect(readCaPem).toHaveBeenCalledTimes(1);
    });

    it("does not schedule or fire a retry while stopping", async () => {
      let stopping = false;
      const { ensurer, readCaPem } = setup({ caPem: () => null, stopping: () => stopping });
      await ensurer.run("normal");
      stopping = true;
      await vi.advanceTimersByTimeAsync(30_000);
      expect(readCaPem).toHaveBeenCalledTimes(1);
      expect(vi.getTimerCount()).toBe(0);
    });

    it("logs the not-ready skip at warning on a scheduled run but only at debug on a fast retry", async () => {
      const { ensurer, calls } = setup({ telemetryHostname: HOST, caPem: () => null });
      await ensurer.run("normal");
      await vi.advanceTimersByTimeAsync(30_000);
      await vi.advanceTimersByTimeAsync(30_000);
      const skips = calls.filter(([, msg]) => msg === "telemetry config skipped: private CA not ready yet").map(([level]) => level);
      expect(skips).toEqual(["warning", "debug", "debug"]);
    });

    it("never throws out of run(), even when ensure throws", async () => {
      const { ensurer, calls } = setup({
        ensure: async () => {
          throw new Error("boom");
        },
      });
      await expect(ensurer.run("normal")).resolves.toBeUndefined();
      expect(calls).toContainEqual(["error", "telemetry config ensure failed", { error: "boom" }]);
    });
  });
});
