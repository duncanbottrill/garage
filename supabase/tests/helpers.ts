import { createClient } from "@supabase/supabase-js";
const url = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const anon = process.env.SUPABASE_ANON_KEY!;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY!;
export const admin = createClient(url, service, { auth: { persistSession: false } });
export async function userClient(email: string) {
  const { data, error } = await admin.auth.admin.createUser({ email, password: "pass-1234", email_confirm: true });
  if (error && !/already/.test(error.message)) throw error;
  const c = createClient(url, anon, { auth: { persistSession: false } });
  const s = await c.auth.signInWithPassword({ email, password: "pass-1234" });
  if (s.error) throw s.error;
  return { client: c, id: s.data.user!.id };
}
