import { describe, it, expect, beforeAll } from "vitest";
import { admin, userClient } from "./helpers";

describe("row level security", () => {
  let a: Awaited<ReturnType<typeof userClient>>, b: typeof a;
  beforeAll(async () => {
    a = await userClient("a@test.local"); b = await userClient("b@test.local");
    await admin.from("vehicles").insert({ owner_id: a.id, vin: "VINAAAA", display_name: "A car" });
  });
  it("owner reads own vehicle", async () => {
    const { data } = await a.client.from("vehicles").select("vin");
    expect(data?.map(v => v.vin)).toContain("VINAAAA");
  });
  it("other user sees nothing", async () => {
    const { data } = await b.client.from("vehicles").select("vin");
    expect(data).toEqual([]);
  });
  it("users cannot read tesla_credentials", async () => {
    await admin.from("tesla_credentials").insert({ owner_id: a.id, refresh_token_enc: "\\x00" });
    const { data } = await a.client.from("tesla_credentials").select("*");
    expect(data).toEqual([]);
  });
  it("increment_usage is service-only", async () => {
    const { error } = await a.client.rpc("increment_usage", { p_owner: a.id, p_category: "commands", p_count: 1 });
    expect(error).not.toBeNull();
    const { error: e2 } = await admin.rpc("increment_usage", { p_owner: a.id, p_category: "commands", p_count: 1 });
    expect(e2).toBeNull();
  });
});
