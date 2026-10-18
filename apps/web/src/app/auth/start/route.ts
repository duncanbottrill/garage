import { createPkce, newState } from "@/lib/pkce"; import { authorizeUrl } from "@/lib/tesla-auth"; import { serviceClient, userFromRequest } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export function GET() { return new Response("use POST", { status: 405, headers: { allow: "POST" } }); }
export async function POST(req: Request) {
  const user = await userFromRequest(req); if (!user) return Response.json({ error: "unauthorized" }, { status: 401 });
  const { verifier, challenge } = createPkce(); const state = newState();
  const { error } = await serviceClient().from("oauth_states").insert({ state, owner_id: user.id, verifier }); if (error) return Response.json({ error: "state_store_failed" }, { status: 500 });
  return Response.json({ url: authorizeUrl(challenge, state) }, { headers: { "cache-control": "no-store" } });
}
