import { describe, it, expect, vi } from "vitest";
import { createProxyUrlPublisher, type Logger } from "../src/index";

const FQDN = "garage-bridge.tail068c8f.ts.net";
const URL = "https://garage-bridge.tail068c8f.ts.net:4443";

function fakeLog(): { log: Logger; calls: Array<[string, string, Record<string, unknown> | undefined]> } {
  const calls: Array<[string, string, Record<string, unknown> | undefined]> = [];
  const log: Logger = (level, msg, extra) => {
    calls.push([level, msg, extra]);
  };
  return { log, calls };
}

interface Setup {
  tailscaleEnabled: boolean;
  fqdn?: () => string;
  setProxyBaseUrl?: (url: string | null) => Promise<void>;
}

function setup(s: Setup) {
  const setProxyBaseUrl = vi.fn(s.setProxyBaseUrl ?? (async (): Promise<void> => {}));
  const readFqdn = vi.fn(s.fqdn ?? (() => FQDN));
  const { log, calls } = fakeLog();
  const publisher = createProxyUrlPublisher({
    tailscaleEnabled: s.tailscaleEnabled,
    readFqdn,
    sink: { setProxyBaseUrl },
    log,
  });
  return { publisher, setProxyBaseUrl, readFqdn, calls };
}

describe("createProxyUrlPublisher", () => {
  it("publishesProxyBaseUrlFromFqdn", async () => {
    const enabled = setup({ tailscaleEnabled: true });
    await enabled.publisher.onHeartbeat();
    expect(enabled.setProxyBaseUrl).toHaveBeenCalledTimes(1);
    expect(enabled.setProxyBaseUrl).toHaveBeenCalledWith(URL);

    // Same FQDN on the next heartbeat: nothing to write.
    await enabled.publisher.onHeartbeat();
    expect(enabled.setProxyBaseUrl).toHaveBeenCalledTimes(1);

    const disabled = setup({ tailscaleEnabled: false });
    await disabled.publisher.onHeartbeat();
    await disabled.publisher.onHeartbeat();
    expect(disabled.setProxyBaseUrl).toHaveBeenCalledTimes(1);
    expect(disabled.setProxyBaseUrl).toHaveBeenCalledWith(null);
    expect(disabled.readFqdn).not.toHaveBeenCalled();
  });

  it("republishes when the FQDN changes", async () => {
    let fqdn = FQDN;
    const { publisher, setProxyBaseUrl } = setup({ tailscaleEnabled: true, fqdn: () => fqdn });
    await publisher.onHeartbeat();
    fqdn = "garage-bridge-1.tail068c8f.ts.net";
    await publisher.onHeartbeat();
    expect(setProxyBaseUrl.mock.calls).toEqual([[URL], ["https://garage-bridge-1.tail068c8f.ts.net:4443"]]);
  });

  it("writes nothing while the FQDN is not ready, then publishes once it is", async () => {
    let ready = false;
    const { publisher, setProxyBaseUrl, calls } = setup({
      tailscaleEnabled: true,
      fqdn: () => {
        if (!ready) throw new Error("ENOENT: no such file or directory, open '/data/tailscale/fqdn'");
        return FQDN;
      },
    });
    await publisher.onHeartbeat();
    await publisher.onHeartbeat();
    expect(setProxyBaseUrl).not.toHaveBeenCalled();
    expect(calls.filter(([level]) => level !== "debug")).toEqual([]);

    ready = true;
    await publisher.onHeartbeat();
    expect(setProxyBaseUrl).toHaveBeenCalledTimes(1);
    expect(setProxyBaseUrl).toHaveBeenCalledWith(URL);
  });

  it("retries on the next heartbeat after a failed write and never throws", async () => {
    let fail = true;
    const { publisher, setProxyBaseUrl, calls } = setup({
      tailscaleEnabled: true,
      setProxyBaseUrl: async () => {
        if (fail) throw new Error("column vehicles.proxy_base_url does not exist");
      },
    });
    await expect(publisher.onHeartbeat()).resolves.toBeUndefined();
    expect(calls.some(([level, msg]) => level === "warning" && msg === "proxy_base_url publish failed")).toBe(true);

    fail = false;
    await publisher.onHeartbeat();
    expect(setProxyBaseUrl).toHaveBeenCalledTimes(2);

    await publisher.onHeartbeat();
    expect(setProxyBaseUrl).toHaveBeenCalledTimes(2);
  });

  it("logs the published URL once at info", async () => {
    const { publisher, calls } = setup({ tailscaleEnabled: true });
    await publisher.onHeartbeat();
    await publisher.onHeartbeat();
    expect(calls.filter(([level]) => level === "info")).toEqual([["info", "proxy_base_url published", { proxy_base_url: URL }]]);
  });

  it("does not start a second write while one is in flight", async () => {
    let release!: () => void;
    const { publisher, setProxyBaseUrl } = setup({
      tailscaleEnabled: true,
      setProxyBaseUrl: () => new Promise<void>((resolve) => (release = resolve)),
    });
    const first = publisher.onHeartbeat();
    await publisher.onHeartbeat();
    expect(setProxyBaseUrl).toHaveBeenCalledTimes(1);
    release();
    await first;
    await publisher.onHeartbeat();
    expect(setProxyBaseUrl).toHaveBeenCalledTimes(1);
  });
});
