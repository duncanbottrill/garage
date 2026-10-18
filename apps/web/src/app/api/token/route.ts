import { userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic";
export async function GET(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("token", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const t = await currentAccessToken(u.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  return Response.json({ access_token: t.token, expires_at: t.expiresAt }, { headers: { "cache-control": "no-store" } });
}
