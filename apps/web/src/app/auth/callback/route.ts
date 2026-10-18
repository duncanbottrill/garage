import { env } from "@/lib/env"; import { serviceClient } from "@/lib/supabase"; import { exchangeCode, storeCredentials } from "@/lib/tesla-auth";
export const dynamic = "force-dynamic";
const back = (q: string) => Response.redirect(env().APP_RETURN_URL + "?" + q, 302);
export async function GET(req: Request) {
  const u = new URL(req.url); const code = u.searchParams.get("code"), state = u.searchParams.get("state"), teslaError = u.searchParams.get("error");
  if (!state) return back("error=missing_params");
  const sb = serviceClient();
  const { data: row } = await sb.from("oauth_states").select("owner_id, verifier, created_at").eq("state", state).maybeSingle();
  const { error: delError } = await sb.from("oauth_states").delete().eq("state", state);
  if (delError) console.error("oauth_states delete failed", delError.message);
  if (!code) return back("error=" + encodeURIComponent((teslaError ?? "missing_params").slice(0, 40)));
  if (!row || Date.now() - new Date(row.created_at).getTime() > 10 * 60_000) return back("error=bad_state");
  try { await storeCredentials(row.owner_id, await exchangeCode({ code, verifier: row.verifier })); return back("ok=1"); }
  catch (e: any) { return back("error=" + encodeURIComponent(String(e?.message ?? e).slice(0, 120))); }
}
