import { createClient } from "@supabase/supabase-js";
import { env } from "./env";
export function serviceClient() { const e = env(); return createClient(e.SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } }); }
export async function userFromRequest(req: Request): Promise<{ id: string } | null> {
  const h = req.headers.get("authorization") ?? ""; const jwt = h.startsWith("Bearer ") ? h.slice(7) : null; if (!jwt) return null;
  const e = env(); const c = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { data, error } = await c.auth.getUser(jwt); if (error || !data.user) return null;
  const allow = (process.env.ALLOWED_OWNER_IDS ?? "").split(",").map(s => s.trim()).filter(Boolean);
  const deployed = !!process.env.VERCEL_ENV;
  // On Vercel, an unset allow-list is a misconfiguration, not "allow everyone" — fail closed
  // rather than silently letting any Supabase user through on a deployed environment.
  if (deployed && allow.length === 0) return null;
  if (allow.length && !allow.includes(data.user.id)) return null;
  return { id: data.user.id };
}
export function requireCron(req: Request) {
  const secret = process.env.CRON_SECRET;
  if (!secret) return false;
  return req.headers.get("authorization") === `Bearer ${secret}`;
}
export function requireAdmin(req: Request) {
  const s = process.env.ADMIN_SECRET;
  if (!s) return false;
  return req.headers.get("authorization") === `Bearer ${s}`;
}
