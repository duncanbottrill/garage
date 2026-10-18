import { serviceClient, userFromRequest } from "@/lib/supabase"; import { limit } from "@/lib/ratelimit";
export const dynamic = "force-dynamic";
export async function POST(req: Request) {
  const u = await userFromRequest(req); if (!u) return Response.json({ error: "unauthorized" }, { status: 401 });
  if (!(await limit("usage", u.id)).ok) return Response.json({ error: "rate_limited" }, { status: 429 });
  const b = await req.json().catch(() => ({}));
  const rawCount = Number(b.count ?? 1);
  if (!Number.isFinite(rawCount) || Math.trunc(rawCount) !== rawCount) return Response.json({ error: "bad_count" }, { status: 400 });
  const count = Math.min(Math.max(rawCount, 1), 100);
  if (b.category !== "commands" && b.category !== "wakes") return Response.json({ error: "bad_category" }, { status: 400 });
  const { error } = await serviceClient().rpc("increment_usage", { p_owner: u.id, p_category: b.category, p_count: count }); if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ ok: true });
}
