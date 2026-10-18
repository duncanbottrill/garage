import { createClient } from "@supabase/supabase-js";
import { env } from "./env";
export function serviceClient() { const e = env(); return createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } }); }
export async function userFromRequest(req: Request): Promise<{ id: string } | null> {
  const h = req.headers.get("authorization") ?? ""; const jwt = h.startsWith("Bearer ") ? h.slice(7) : null; if (!jwt) return null;
  const e = env(); const c = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { data, error } = await c.auth.getUser(jwt); if (error || !data.user) return null; return { id: data.user.id };
}
export function requireCron(req: Request) { return req.headers.get("authorization") === `Bearer ${env().CRON_SECRET}`; }
