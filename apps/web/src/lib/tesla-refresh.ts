import { decryptToken, encryptToken } from "@garage/core";
import { env } from "./env"; import { serviceClient } from "./supabase"; import { AUTH_BASE } from "./tesla-auth";
export async function refreshAll(o: { fetch?: typeof fetch; now?: Date } = {}) {
  const e = env(); const f = o.fetch ?? fetch; const now = o.now ?? new Date(); const sb = serviceClient();
  const rotated: string[] = [], failed: { owner_id: string; error: string }[] = [];
  const { data: rows, error } = await sb.from("tesla_credentials").select("owner_id, refresh_token_enc, access_expires_at"); if (error) throw error;
  for (const row of rows ?? []) {
    // refresh when less than 3h of access remains (cron runs every 4h; access lasts 8h)
    const expMs = row.access_expires_at ? new Date(row.access_expires_at).getTime() : 0;
    if (expMs - now.getTime() > 3 * 3600_000) continue;
    try {
      const rt = decryptToken(hexToBytes(row.refresh_token_enc), e.TOKEN_ENC_KEY);
      const r = await f(AUTH_BASE + "/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "refresh_token", client_id: e.TESLA_CLIENT_ID, refresh_token: rt }) });
      if (!r.ok) throw new Error(`refresh ${r.status}: ${(await r.text()).slice(0, 200)}`);
      const t = await r.json() as { access_token: string; refresh_token: string; expires_in: number };
      const { error: ue } = await sb.from("tesla_credentials").update({ refresh_token_enc: "\\x" + Buffer.from(encryptToken(t.refresh_token, e.TOKEN_ENC_KEY)).toString("hex"),
        access_token: t.access_token, access_expires_at: new Date(now.getTime() + t.expires_in * 1000).toISOString(), rotated_at: now.toISOString(), last_error: null }).eq("owner_id", row.owner_id);
      if (ue) throw ue; rotated.push(row.owner_id);
    } catch (err: any) {
      failed.push({ owner_id: row.owner_id, error: String(err?.message ?? err) });
      await sb.from("tesla_credentials").update({ last_error: String(err?.message ?? err).slice(0, 500) }).eq("owner_id", row.owner_id);
    }
  }
  return { rotated, failed };
}
function hexToBytes(v: unknown): Uint8Array {
  // supabase-js returns bytea as "\\x..." hex string
  const s = String(v); const hex = s.startsWith("\\x") ? s.slice(2) : s; return new Uint8Array(Buffer.from(hex, "hex"));
}
