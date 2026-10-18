import { requireCron, serviceClient } from "@/lib/supabase"; import { hashSecret, newBridgeSecret } from "@/lib/bridge-auth";
export const dynamic = "force-dynamic";
export async function POST(req: Request) {
  if (!requireCron(req)) return new Response("forbidden", { status: 403 });
  const b = await req.json().catch(() => ({})); const owner = String(b.owner_id ?? "");
  if (!/^[0-9a-f-]{36}$/.test(owner)) return Response.json({ error: "bad_owner" }, { status: 400 });
  const secret = newBridgeSecret();
  const { error } = await serviceClient().from("bridge_secrets").upsert({ owner_id: owner, secret_hash: hashSecret(secret), created_at: new Date().toISOString(), last_used_at: null });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ owner_id: owner, secret }, { headers: { "cache-control": "no-store" } });
}
