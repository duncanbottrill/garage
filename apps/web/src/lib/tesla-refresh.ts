import { decryptToken, encryptToken } from "@garage/core";
import type { SupabaseClient } from "@supabase/supabase-js";
import { env } from "./env"; import { serviceClient } from "./supabase"; import { AUTH_BASE } from "./tesla-auth";
const STORE_RETRY_DELAYS_MS = [200, 500];
const LOCK_DURATION_MS = 90_000;
export async function refreshAll(o: { fetch?: typeof fetch; now?: Date; client?: SupabaseClient; sleep?: (ms: number) => Promise<void>; ownerId?: string; force?: boolean } = {}) {
  const e = env(); const f = o.fetch ?? fetch; const now = o.now ?? new Date(); const sb = o.client ?? serviceClient();
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const rotated: string[] = [], failed: { owner_id: string; error: string }[] = [];
  let q = sb.from("tesla_credentials").select("owner_id, refresh_token_enc, access_expires_at");
  if (o.ownerId) q = q.eq("owner_id", o.ownerId);
  const { data: rows, error } = await q; if (error) throw error;
  for (const row of rows ?? []) {
    // refresh when less than 3h of access remains (cron runs every 4h; access lasts 8h) — unless forced
    if (!o.force) {
      const expMs = row.access_expires_at ? new Date(row.access_expires_at).getTime() : 0;
      if (expMs - now.getTime() >= 3 * 3600_000) continue;
    }
    // Claim the per-owner lock atomically: a single conditional UPDATE. Tesla refresh tokens
    // are single-use, so two concurrent rotations for the same owner can invalidate the whole
    // token family — only the caller that wins this UPDATE may call Tesla for this row.
    const nowIso = now.toISOString();
    const lockUntilIso = new Date(now.getTime() + LOCK_DURATION_MS).toISOString();
    const { data: claimed, error: claimError } = await sb.from("tesla_credentials")
      .update({ refresh_lock_until: lockUntilIso })
      .eq("owner_id", row.owner_id)
      .or("refresh_lock_until.is.null,refresh_lock_until.lt." + nowIso)
      .select("owner_id");
    if (claimError) throw claimError;
    if (!claimed || claimed.length === 0) {
      // someone else is already refreshing this owner — not a real failure, so callers can
      // treat it as "try again shortly" rather than an error worth surfacing to the user.
      failed.push({ owner_id: row.owner_id, error: "locked" });
      continue;
    }
    try {
      const rt = decryptToken(hexToBytes(row.refresh_token_enc), e.TOKEN_ENC_KEY);
      const r = await f(AUTH_BASE + "/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "refresh_token", client_id: e.TESLA_CLIENT_ID, refresh_token: rt }) });
      if (!r.ok) throw new Error(`refresh ${r.status}: ${(await r.text()).slice(0, 200)}`);
      const t = await r.json() as { access_token: string; refresh_token: string; expires_in: number };
      // Tesla has already invalidated the old refresh token at this point, so the new
      // token must be stored even if that takes a few attempts — losing it here locks
      // the owner out permanently.
      const updatePayload = { refresh_token_enc: "\\x" + Buffer.from(encryptToken(t.refresh_token, e.TOKEN_ENC_KEY)).toString("hex"),
        access_token: t.access_token, access_expires_at: new Date(now.getTime() + t.expires_in * 1000).toISOString(), rotated_at: now.toISOString(), last_error: null };
      let stored = false, lastStoreError: unknown = null;
      const storeDelays = [0, ...STORE_RETRY_DELAYS_MS];
      for (const delay of storeDelays) {
        if (delay > 0) await sleep(delay);
        const { error: ue } = await sb.from("tesla_credentials").update(updatePayload).eq("owner_id", row.owner_id);
        if (!ue) { stored = true; break; }
        lastStoreError = ue;
      }
      if (!stored) {
        console.error("tesla-refresh: rotated but unstored", { owner_id: row.owner_id });
        throw new Error(`rotated_unstored: ${String((lastStoreError as any)?.message ?? lastStoreError)}`);
      }
      rotated.push(row.owner_id);
    } catch (err: any) {
      failed.push({ owner_id: row.owner_id, error: String(err?.message ?? err) });
      try {
        const { error: le } = await sb.from("tesla_credentials").update({ last_error: String(err?.message ?? err).slice(0, 500) }).eq("owner_id", row.owner_id);
        if (le) throw le;
      } catch (lastErrorErr: any) {
        console.error("tesla-refresh: failed to record last_error", { owner_id: row.owner_id, error: String(lastErrorErr?.message ?? lastErrorErr) });
      }
    } finally {
      // Always release the lock we claimed, whether the rotation succeeded or failed.
      const { error: relErr } = await sb.from("tesla_credentials").update({ refresh_lock_until: null }).eq("owner_id", row.owner_id);
      if (relErr) console.error("tesla-refresh: failed to release lock", { owner_id: row.owner_id, error: relErr.message });
    }
  }
  return { rotated, failed };
}
function hexToBytes(v: unknown): Uint8Array {
  // supabase-js returns bytea as "\\x..." hex string
  const s = String(v); const hex = s.startsWith("\\x") ? s.slice(2) : s; return new Uint8Array(Buffer.from(hex, "hex"));
}
