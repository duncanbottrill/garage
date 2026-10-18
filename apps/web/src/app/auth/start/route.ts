import { createPkce, newState } from "@/lib/pkce"; import { authorizeUrl } from "@/lib/tesla-auth"; import { serviceClient, userFromRequest } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export async function GET(req: Request) {
  const user = await userFromRequest(req); if (!user) return new Response("unauthorized", { status: 401 });
  const { verifier, challenge } = createPkce(); const state = newState();
  const { error } = await serviceClient().from("oauth_states").insert({ state, owner_id: user.id, verifier }); if (error) return new Response("state store failed", { status: 500 });
  return Response.redirect(authorizeUrl(challenge, state), 302);
}
