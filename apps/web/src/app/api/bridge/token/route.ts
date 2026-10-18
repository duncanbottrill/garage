import { bridgeOwnerFromRequest } from "@/lib/bridge-auth"; import { limit } from "@/lib/ratelimit"; import { currentAccessTokenStatus } from "@/lib/credentials";
export const dynamic = "force-dynamic"; export const maxDuration = 30;
export async function GET(req: Request) {
  const o = await bridgeOwnerFromRequest(req); if (!o) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("bridge-token", o.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const s = await currentAccessTokenStatus(o.id);
  if (s.status === "not_connected") return Response.json({ error: "not_connected" }, { status: 404 });
  if (s.status === "unavailable") return Response.json({ error: "token_unavailable", retry_at: s.retryAt }, { status: 503 });
  return Response.json({ access_token: s.token, expires_at: s.expiresAt }, { headers: { "cache-control": "no-store" } });
}
