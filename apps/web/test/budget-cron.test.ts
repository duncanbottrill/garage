import { describe, it, expect, beforeAll } from "vitest";
import { createClient } from "@supabase/supabase-js";
let ownerId = "", vehicleId = "";
beforeAll(async () => {
  Object.assign(process.env, { TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/cb", TESLA_FLEET_BASE: "https://fleet.test", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://x" });
  const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
  const u = await admin.auth.admin.createUser({ email: "budget@test.local", password: "pass-1234", email_confirm: true }); ownerId = u.data.user?.id ?? (await admin.auth.admin.listUsers()).data.users.find(x => x.email === "budget@test.local")!.id;
  const { data: v } = await admin.from("vehicles").upsert({ owner_id: ownerId, vin: "VINBUDGET" }, { onConflict: "vin" }).select("id").single(); vehicleId = v!.id;
  await admin.from("api_usage").delete().eq("owner_id", ownerId);
  await admin.rpc("increment_usage", { p_owner: ownerId, p_category: "wakes", p_count: 200 }); // $4 so far
});
describe("budget cron", () => {
  it("projects and flips to reduced", async () => {
    const { runBudget } = await import("@/lib/budget-cron");
    const now = new Date(); now.setUTCDate(15); // ~2x projection → ~$8 of $10 → reduced
    const r = (await runBudget({ now })).find(x => x.vehicle_id === vehicleId)!; expect(r.mode).toBe("reduced");
    const admin = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!);
    const { data } = await admin.from("vehicles").select("budget_mode").eq("id", vehicleId).single(); expect(data?.budget_mode).toBe("reduced");
  });
  it("returns to normal when spend is low", async () => {
    const { runBudget } = await import("@/lib/budget-cron");
    const r = (await runBudget({ now: new Date(), budgetUsd: 1000 })).find(x => x.vehicle_id === vehicleId)!; expect(r.mode).toBe("normal");
  });
});
