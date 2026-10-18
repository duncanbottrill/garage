import { bridgeOwnerFromRequest } from "@/lib/bridge-auth"; import { limit } from "@/lib/ratelimit"; import { currentAccessToken } from "@/lib/credentials";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function GET(req: Request) {
  const o = await bridgeOwnerFromRequest(req); if (!o) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("bridge-token", o.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const t = await currentAccessToken(o.id); if (!t) return Response.json({ error: "not_connected" }, { status: 404 });
  return Response.json({ access_token: t.token, expires_at: t.expiresAt }, { headers: { "cache-control": "no-store" } });
}
