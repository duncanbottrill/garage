import { FleetClient, FleetError, vehicleDataToState } from "@garage/core";
import { env } from "@/lib/env"; import { serviceClient, userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("vehicle-data", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const { vehicle_id } = await req.json().catch(() => ({})); const sb = serviceClient();
  const { data: v } = await sb.from("vehicles").select("id, tesla_vehicle_id").eq("id", vehicle_id).eq("owner_id", u.id).maybeSingle();
  if (!v?.tesla_vehicle_id) return Response.json({ error: "no_vehicle" }, { status: 404 });
  const t = await currentAccessToken(u.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  const fleet = new FleetClient({ baseUrl: env().TESLA_FLEET_BASE, token: t.token });
  const { error: ledgerError } = await sb.rpc("increment_usage", { p_owner: u.id, p_category: "data", p_count: 1 });
  if (ledgerError) return Response.json({ error: "ledger_unavailable" }, { status: 503 }); // never make an unlogged billable call
  try {
    const payload = await fleet.get<any>(`/api/1/vehicles/${v.tesla_vehicle_id}/vehicle_data?endpoints=${encodeURIComponent("charge_state;climate_state;drive_state;location_data;vehicle_state")}`);
    const state = vehicleDataToState(payload, new Date());
    const { error: stateError } = await sb.from("vehicle_state").upsert({ vehicle_id: v.id, owner_id: u.id, ...state });
    if (stateError) return Response.json({ error: "state_write_failed" }, { status: 500 });
    return Response.json({ state });
  } catch (e) {
    if (e instanceof FleetError && e.status === 408) return Response.json({ error: "asleep" }, { status: 409 });
    return Response.json({ error: e instanceof Error ? e.message : "fleet_error" }, { status: 502 });
  }
}
