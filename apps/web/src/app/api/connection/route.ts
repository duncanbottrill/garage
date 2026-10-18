import { userFromRequest, serviceClient } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export async function GET(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  const { data, error } = await serviceClient().from("tesla_credentials").select("rotated_at, last_error, access_expires_at, refresh_lock_until, refresh_failures, next_refresh_at").eq("owner_id", u.id).maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ connected: false, rotated_at: null, last_error: null, access_expires_at: null, rotating: false, refresh_failures: 0, next_refresh_at: null });
  return Response.json({ connected: true, rotated_at: data.rotated_at, last_error: data.last_error, access_expires_at: data.access_expires_at, rotating: !!data.refresh_lock_until && new Date(data.refresh_lock_until).getTime() > Date.now(), refresh_failures: data.refresh_failures, next_refresh_at: data.next_refresh_at }, { headers: { "cache-control": "no-store" } });
}
