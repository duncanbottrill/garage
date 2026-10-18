import { FleetClient, FleetError, vehicleDataToState } from "@garage/core";
import { env } from "@/lib/env"; import { serviceClient, userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("vehicle-data", u.id, { perMinute: 2, perDay: 40 })).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const { vehicle_id } = await req.json().catch(() => ({})); const sb = serviceClient();
  const { data: v } = await sb.from("vehicles").select("id, vin, budget_mode").eq("id", vehicle_id).eq("owner_id", u.id).maybeSingle();
  if (!v?.vin) return Response.json({ error: "no_vehicle" }, { status: 404 });
  if (v.budget_mode === "minimal") return Response.json({ error: "budget_minimal" }, { status: 429 });
  const t = await currentAccessToken(u.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  const fleet = new FleetClient({ baseUrl: env().TESLA_FLEET_BASE, token: t.token });
  // ensure the vehicle_state row exists before any billable call, so merge_vehicle_state
  // below always has a row to merge into even on a vehicle's very first fetch.
  const { error: stateInitError } = await sb.from("vehicle_state").upsert({ vehicle_id: v.id, owner_id: u.id }, { onConflict: "vehicle_id", ignoreDuplicates: true });
  if (stateInitError) return Response.json({ error: "state_init_failed" }, { status: 500 });
  const { error: ledgerError } = await sb.rpc("increment_usage", { p_owner: u.id, p_category: "data", p_count: 1 });
  if (ledgerError) return Response.json({ error: "ledger_unavailable" }, { status: 503 }); // never make an unlogged billable call
  try {
    const payload = await fleet.get<any>(`/api/1/vehicles/${v.vin}/vehicle_data?endpoints=${encodeURIComponent("charge_state;climate_state;drive_state;location_data;vehicle_state")}`);
    const state = vehicleDataToState(payload, new Date());
    const { error: mergeError } = await sb.rpc("merge_vehicle_state", { p_vehicle: v.id, p_patch: state });
    if (mergeError) return Response.json({ error: "state_write_failed" }, { status: 500 });
    return Response.json({ state });
  } catch (e) {
    if (e instanceof FleetError && e.status === 408) return Response.json({ error: "asleep" }, { status: 409 });
    return Response.json({ error: e instanceof Error ? e.message : "fleet_error" }, { status: 502 });
  }
}
