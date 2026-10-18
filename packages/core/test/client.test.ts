import { describe, it, expect, vi } from "vitest";
import { FleetClient, FleetError } from "../src/tesla/client";
const mk = (status: number, body: unknown) => vi.fn(async () => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }));
describe("FleetClient", () => {
  it("unwraps response envelope and sends bearer", async () => {
    const f = mk(200, { response: { ok: 1 } });
    const c = new FleetClient({ baseUrl: "https://x", token: "T", fetch: f as any });
    expect(await c.get("/a")).toEqual({ ok: 1 });
    expect((f.mock.calls[0] as any)[1].headers.authorization).toBe("Bearer T");
  });
  it("throws FleetError with status and code", async () => {
    const c = new FleetClient({ baseUrl: "https://x", token: "T", fetch: mk(408, { error: "vehicle unavailable" }) as any });
    await expect(c.post("/b", {})).rejects.toMatchObject({ status: 408, code: "vehicle unavailable" } satisfies Partial<FleetError>);
  });
});
