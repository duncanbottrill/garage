import { FleetClient } from "@garage/core";
import type { SupabaseClient } from "@supabase/supabase-js";
import { env } from "./env"; import { serviceClient } from "./supabase"; import { currentAccessToken } from "./credentials";
const MODEL_BY_VIN_CHAR: Record<string, string> = { Y: "Model Y", "3": "Model 3", S: "Model S", X: "Model X", C: "Cybertruck" };
export async function syncVehicles(ownerId: string, o: { fetch?: typeof fetch; client?: SupabaseClient } = {}) {
  const sb = o.client ?? serviceClient();
  const t = await currentAccessToken(ownerId, { client: sb, fetch: o.fetch }); if (!t) return { vehicles: [], error: "not_connected" };
  const fleet = new FleetClient({ baseUrl: env().TESLA_FLEET_BASE, token: t.token, fetch: o.fetch });
  await sb.rpc("increment_usage", { p_owner: ownerId, p_category: "data", p_count: 1 });
  let list: Array<{ id: number; vin: string; display_name: string; state?: string }>;
  try { list = await fleet.get("/api/1/vehicles"); } catch (e: any) { return { vehicles: [], error: String(e?.message ?? e) }; }
  const out: Array<{ id: string; vin: string; display_name: string }> = [];
  for (const v of list ?? []) {
    const model = MODEL_BY_VIN_CHAR[v.vin?.[3] ?? ""] ?? null;
    const { data: row, error } = await sb.from("vehicles").upsert({ owner_id: ownerId, vin: v.vin, tesla_vehicle_id: v.id, display_name: v.display_name || "Tesla", model }, { onConflict: "vin" }).select("id, vin, display_name").single();
    if (error || !row) { console.error("vehicles upsert failed", error?.message); continue; }
    await sb.from("vehicle_state").upsert({ vehicle_id: row.id, owner_id: ownerId, sleep_state: v.state ?? null }, { onConflict: "vehicle_id", ignoreDuplicates: true });
    out.push(row);
  }
  return { vehicles: out };
}
