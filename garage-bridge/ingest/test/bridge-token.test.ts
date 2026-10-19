import { describe, it, expect, vi } from "vitest";
import { BridgeToken, BridgeTokenError } from "../src/bridge-token";

function fetchStub(responses: Array<{ status: number; body: unknown }>) {
  let i = 0;
  return vi.fn(async (_url: string, _init?: RequestInit) => {
    const r = responses[Math.min(i, responses.length - 1)]!;
    i++;
    return new Response(JSON.stringify(r.body), { status: r.status });
  });
}

describe("BridgeToken", () => {
  it("fetches once and caches the token across calls within the TTL", async () => {
    const start = 1_000_000;
    const fetch = fetchStub([{ status: 200, body: { access_token: "tok-1", expires_at: new Date(start + 120_000).toISOString() } }]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "s3cret", fetch: fetch as unknown as typeof globalThis.fetch });

    const a = await token.get({ now: start });
    const b = await token.get({ now: start + 1000 });

    expect(a.access_token).toBe("tok-1");
    expect(b.access_token).toBe("tok-1");
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch.mock.calls[0]![1]).toMatchObject({ headers: { "x-bridge-secret": "s3cret" } });
  });

  it("re-fetches once within 60s of expiry", async () => {
    const start = 1_000_000;
    const fetch = fetchStub([
      { status: 200, body: { access_token: "tok-1", expires_at: new Date(start + 120_000).toISOString() } },
      { status: 200, body: { access_token: "tok-2", expires_at: new Date(start + 240_000).toISOString() } },
    ]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "s", fetch: fetch as unknown as typeof globalThis.fetch });

    // 61s of remaining life: still cached (margin is 60s).
    await token.get({ now: start });
    const stillCached = await token.get({ now: start + 59_000 });
    expect(stillCached.access_token).toBe("tok-1");
    expect(fetch).toHaveBeenCalledTimes(1);

    // Inside the 60s refresh margin: refetches.
    const refreshed = await token.get({ now: start + 61_001 });
    expect(refreshed.access_token).toBe("tok-2");
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("force bypasses a still-fresh cache and re-fetches", async () => {
    const start = 1_000_000;
    const fetch = fetchStub([
      { status: 200, body: { access_token: "tok-1", expires_at: new Date(start + 120_000).toISOString() } },
      { status: 200, body: { access_token: "tok-2", expires_at: new Date(start + 240_000).toISOString() } },
    ]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "s", fetch: fetch as unknown as typeof globalThis.fetch });

    await token.get({ now: start });
    expect(fetch).toHaveBeenCalledTimes(1);

    // Well within the TTL, but force must still re-fetch.
    const forced = await token.get({ now: start + 1000, force: true });
    expect(forced.access_token).toBe("tok-2");
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("throws a typed not_connected error on 404", async () => {
    const fetch = fetchStub([{ status: 404, body: { error: "not_connected" } }]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "s", fetch: fetch as unknown as typeof globalThis.fetch });

    await expect(token.get({ now: 0 })).rejects.toSatisfy((err: unknown) => err instanceof BridgeTokenError && err.code === "not_connected");
  });

  it("throws a typed token_unavailable error on 503, carrying retry_at", async () => {
    const fetch = fetchStub([{ status: 503, body: { error: "token_unavailable", retry_at: "2026-10-19T09:00:00Z" } }]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "s", fetch: fetch as unknown as typeof globalThis.fetch });

    await expect(token.get({ now: 0 })).rejects.toSatisfy(
      (err: unknown) => err instanceof BridgeTokenError && err.code === "token_unavailable" && err.retryAt === "2026-10-19T09:00:00Z",
    );
  });

  it("throws a typed unauthorized error on 401", async () => {
    const fetch = fetchStub([{ status: 401, body: { error: "unauthorized" } }]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "wrong", fetch: fetch as unknown as typeof globalThis.fetch });

    await expect(token.get({ now: 0 })).rejects.toSatisfy((err: unknown) => err instanceof BridgeTokenError && err.code === "unauthorized");
  });

  it("never sends the secret or token in a way that would be logged as a URL", async () => {
    const fetch = fetchStub([{ status: 200, body: { access_token: "tok-1", expires_at: new Date(2_000_000).toISOString() } }]);
    const token = BridgeToken({ apiBase: "https://garage.test", secret: "s3cret", fetch: fetch as unknown as typeof globalThis.fetch });
    await token.get({ now: 0 });
    const url = String(fetch.mock.calls[0]![0]);
    expect(url).not.toContain("s3cret");
  });
});
