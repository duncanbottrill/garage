import { userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { syncVehicles } from "@/lib/vehicles";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("vehicles-sync", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const r = await syncVehicles(u.id); return Response.json(r, { status: r.error ? 502 : 200 });
}
