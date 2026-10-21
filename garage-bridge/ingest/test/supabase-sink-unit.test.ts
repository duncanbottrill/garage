import { describe, it, expect, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { SupabaseSink } from "../src/supabase-sink";

const IDS = { vehicleId: "11111111-1111-1111-1111-111111111111", ownerId: "22222222-2222-2222-2222-222222222222" };

function fakeClient(row: Record<string, unknown> | null = null, selectError: { message: string } | null = null) {
  const rpc = vi.fn().mockResolvedValue({ error: null });
  const maybeSingle = vi.fn().mockResolvedValue({ data: row, error: selectError });
  const eq = vi.fn().mockReturnValue({ maybeSingle });
  const select = vi.fn().mockReturnValue({ eq });
  const from = vi.fn().mockReturnValue({ select });
  return { client: { rpc, from } as unknown as SupabaseClient, rpc, from, select, eq };
}

describe("SupabaseSink (fake client)", () => {
  it("mergeState without clears sends only p_vehicle and p_patch", async () => {
    const { client, rpc } = fakeClient();
    await SupabaseSink(client, IDS).mergeState({ soc: 80, nothing: null });
    expect(rpc).toHaveBeenCalledWith("merge_vehicle_state", { p_vehicle: IDS.vehicleId, p_patch: { soc: 80 } });
  });

  it("mergeState with clears adds p_clear", async () => {
    const { client, rpc } = fakeClient();
    await SupabaseSink(client, IDS).mergeState({ soc: 80 }, ["scheduled_charge_at"]);
    expect(rpc).toHaveBeenCalledWith("merge_vehicle_state", {
      p_vehicle: IDS.vehicleId,
      p_patch: { soc: 80 },
      p_clear: ["scheduled_charge_at"],
    });
  });

  it("getProxyBaseUrl reads vehicles.proxy_base_url for this vehicle", async () => {
    const { client, from, select, eq } = fakeClient({ proxy_base_url: "https://garage-bridge.tail068c8f.ts.net:4443" });
    await expect(SupabaseSink(client, IDS).getProxyBaseUrl()).resolves.toBe("https://garage-bridge.tail068c8f.ts.net:4443");
    expect(from).toHaveBeenCalledWith("vehicles");
    expect(select).toHaveBeenCalledWith("proxy_base_url");
    expect(eq).toHaveBeenCalledWith("id", IDS.vehicleId);
  });

  it("getProxyBaseUrl returns null for an empty column or a missing row, and throws on an error", async () => {
    await expect(SupabaseSink(fakeClient({ proxy_base_url: null }).client, IDS).getProxyBaseUrl()).resolves.toBeNull();
    await expect(SupabaseSink(fakeClient(null).client, IDS).getProxyBaseUrl()).resolves.toBeNull();
    await expect(SupabaseSink(fakeClient(null, { message: "boom" }).client, IDS).getProxyBaseUrl()).rejects.toBeTruthy();
  });
});
