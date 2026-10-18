import { serviceClient } from "./supabase";
export async function currentAccessToken(ownerId: string) {
  const { data } = await serviceClient().from("tesla_credentials").select("access_token, access_expires_at").eq("owner_id", ownerId).maybeSingle();
  if (!data?.access_token || !data.access_expires_at || new Date(data.access_expires_at).getTime() < Date.now() + 60_000) return null;
  return { token: data.access_token, expiresAt: data.access_expires_at };
}
