import { encryptToken } from "@garage/core";
import { env } from "./env"; import { serviceClient } from "./supabase";
export const AUTH_BASE = "https://auth.tesla.com/oauth2/v3"; // browser-facing authorize only
export const TOKEN_URL = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token"; // all server-to-server /token calls (Tesla requirement)
export const SCOPES = "openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds vehicle_location";
export function authorizeUrl(challenge: string, state: string) {
  const e = env(); const u = new URL(AUTH_BASE + "/authorize");
  u.search = new URLSearchParams({ response_type: "code", client_id: e.TESLA_CLIENT_ID, redirect_uri: e.TESLA_REDIRECT_URI, scope: SCOPES, state, code_challenge: challenge, code_challenge_method: "S256", locale: "en-GB", prompt: "login" }).toString();
  return u.toString();
}
export interface TokenSet { access_token: string; refresh_token: string; expires_in: number }
export async function exchangeCode(o: { code: string; verifier: string; fetch?: typeof fetch }): Promise<TokenSet> {
  const e = env(); const f = o.fetch ?? fetch;
  const r = await f(TOKEN_URL, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", client_id: e.TESLA_CLIENT_ID, client_secret: e.TESLA_CLIENT_SECRET, code: o.code, code_verifier: o.verifier, redirect_uri: e.TESLA_REDIRECT_URI, audience: e.TESLA_FLEET_BASE }) });
  if (!r.ok) throw new Error(`token exchange ${r.status}: ${await r.text()}`);
  return r.json();
}
export async function storeCredentials(ownerId: string, t: TokenSet) {
  const e = env(); const sb = serviceClient();
  const { error } = await sb.from("tesla_credentials").upsert({ owner_id: ownerId, refresh_token_enc: "\\x" + Buffer.from(encryptToken(t.refresh_token, e.TOKEN_ENC_KEY)).toString("hex"),
    access_token: t.access_token, access_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(), rotated_at: new Date().toISOString(), last_error: null });
  if (error) throw error;
}
