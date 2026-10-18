import { env } from "@/lib/env"; import { serviceClient } from "@/lib/supabase"; import { exchangeCode, storeCredentials } from "@/lib/tesla-auth";
export const dynamic = "force-dynamic";
const back = (q: string) => Response.redirect(env().APP_RETURN_URL + "?" + q, 302);
export async function GET(req: Request) {
  const u = new URL(req.url); const code = u.searchParams.get("code"), state = u.searchParams.get("state");
  if (!code || !state) return back("error=missing_params");
  const sb = serviceClient();
  const { data: row } = await sb.from("oauth_states").select("owner_id, verifier, created_at").eq("state", state).maybeSingle();
  await sb.from("oauth_states").delete().eq("state", state);
  if (!row || Date.now() - new Date(row.created_at).getTime() > 10 * 60_000) return back("error=bad_state");
  try { await storeCredentials(row.owner_id, await exchangeCode({ code, verifier: row.verifier })); return back("ok=1"); }
  catch (e: any) { return back("error=" + encodeURIComponent(String(e?.message ?? e).slice(0, 120))); }
}
