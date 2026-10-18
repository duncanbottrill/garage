import { decryptToken, encryptToken } from "@garage/core";
import type { SupabaseClient } from "@supabase/supabase-js";
import { env } from "./env"; import { serviceClient } from "./supabase"; import { TOKEN_URL } from "./tesla-auth";
const STORE_RETRY_DELAYS_MS = [200, 500];
const LOCK_DURATION_MS = 90_000;
const DEFAULT_REFRESH_WITHIN_MS = 3 * 3600_000; // cron sweep: refresh when less than 3h of access remains
const TESLA_FETCH_TIMEOUT_MS = 20_000;
export async function refreshAll(o: { fetch?: typeof fetch; now?: Date; client?: SupabaseClient; sleep?: (ms: number) => Promise<void>; ownerId?: string; refreshWithinMs?: number } = {}) {
  const e = env(); const f = o.fetch ?? fetch; const sb = o.client ?? serviceClient();
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const refreshWithinMs = o.refreshWithinMs ?? DEFAULT_REFRESH_WITHIN_MS;
  const rotated: string[] = [], failed: { owner_id: string; error: string }[] = [], skipped: string[] = [];
  // Cheap, pre-claim candidate select: owner_id + access_expires_at only. This view can be
  // stale by the time we win the lock (another caller may have just rotated this row), so it
  // is used only to decide which rows are worth attempting a claim for — never to decide
  // whether to actually rotate, and never as the source of the refresh token.
  let q = sb.from("tesla_credentials").select("owner_id, access_expires_at, next_refresh_at");
  if (o.ownerId) q = q.eq("owner_id", o.ownerId);
  const { data: rows, error } = await q; if (error) throw error;
  for (const row of rows ?? []) {
    // Per-row clock: tests inject a fixed `now` and expect it held constant across the whole
    // sweep, but a real cron sweep over many rows must not timestamp a later row's lock with
    // a `now` that was captured before the loop started — so default to a fresh clock read
    // per row rather than one shared instant for the entire sweep.
    const claimNow = o.now ?? new Date();
    const expMs = row.access_expires_at ? new Date(row.access_expires_at).getTime() : 0;
    if (expMs - claimNow.getTime() >= refreshWithinMs) continue;
    // Backoff: a row that failed recently is held back from the sweep until its backoff
    // window has passed, even though it would otherwise be due. Checked before any claim
    // attempt so a backed-off row never contends for the lock at all.
    if (row.next_refresh_at && new Date(row.next_refresh_at).getTime() > claimNow.getTime()) {
      skipped.push(row.owner_id);
      continue;
    }
    // Claim the per-owner lock atomically: a single conditional UPDATE. Tesla refresh tokens
    // are single-use, so two concurrent rotations for the same owner can invalidate the whole
    // token family — only the caller that wins this UPDATE may call Tesla for this row. The
    // UPDATE returns the row AS CLAIMED: all work below (staleness re-check, decryption, the
    // Tesla call) must use that claimed row, never the pre-claim select above, which may have
    // been read before a previous holder released the lock and rotated it.
    const nowIso = claimNow.toISOString();
    const lockUntilIso = new Date(claimNow.getTime() + LOCK_DURATION_MS).toISOString();
    const { data: claimed, error: claimError } = await sb.from("tesla_credentials")
      .update({ refresh_lock_until: lockUntilIso })
      .eq("owner_id", row.owner_id)
      .or("refresh_lock_until.is.null,refresh_lock_until.lt." + nowIso)
      .select("owner_id, refresh_token_enc, access_expires_at, refresh_failures");
    if (claimError) {
      // Per-row failure, not fatal to the whole sweep — move on to the next candidate.
      failed.push({ owner_id: row.owner_id, error: `claim_failed: ${String((claimError as any)?.message ?? claimError)}` });
      continue;
    }
    if (!claimed || claimed.length === 0) {
      // someone else is already refreshing this owner — not a real failure, so callers can
      // treat it as "try again shortly" rather than an error worth surfacing to the user.
      failed.push({ owner_id: row.owner_id, error: "locked" });
      continue;
    }
    const claimedRow = claimed[0] as { owner_id: string; refresh_token_enc: unknown; access_expires_at: string | null; refresh_failures: number | null };
    // Re-check staleness now that we hold the lock: the row may have just been rotated by
    // whoever held the lock before us, in which case it is no longer due and must not be
    // rotated again with a (now-consumed) refresh token.
    const claimedExpMs = claimedRow.access_expires_at ? new Date(claimedRow.access_expires_at).getTime() : 0;
    if (claimedExpMs - claimNow.getTime() >= refreshWithinMs) {
      skipped.push(row.owner_id);
      const { error: relErr } = await sb.from("tesla_credentials").update({ refresh_lock_until: null }).eq("owner_id", row.owner_id).eq("refresh_lock_until", lockUntilIso);
      if (relErr) console.error("tesla-refresh: failed to release lock", { owner_id: row.owner_id, error: relErr.message });
      continue;
    }
    try {
      const rt = decryptToken(hexToBytes(claimedRow.refresh_token_enc), e.TOKEN_ENC_KEY);
      const r = await f(TOKEN_URL, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "refresh_token", client_id: e.TESLA_CLIENT_ID, refresh_token: rt }),
        signal: AbortSignal.timeout(TESLA_FETCH_TIMEOUT_MS) });
      if (!r.ok) throw new Error(`refresh ${r.status}: ${(await r.text()).slice(0, 200)}`);
      const t = await r.json() as { access_token: string; refresh_token: string; expires_in: number };
      // Tesla has already invalidated the old refresh token at this point, so the new
      // token must be stored even if that takes a few attempts — losing it here locks
      // the owner out permanently.
      const updatePayload = { refresh_token_enc: "\\x" + Buffer.from(encryptToken(t.refresh_token, e.TOKEN_ENC_KEY)).toString("hex"),
        access_token: t.access_token, access_expires_at: new Date(claimNow.getTime() + t.expires_in * 1000).toISOString(), rotated_at: claimNow.toISOString(), last_error: null,
        refresh_failures: 0, next_refresh_at: null };
      let stored = false, lastStoreError: unknown = null;
      const storeDelays = [0, ...STORE_RETRY_DELAYS_MS];
      for (const delay of storeDelays) {
        if (delay > 0) await sleep(delay);
        // Token-fenced store: only write if the row still holds the exact refresh token we just
        // consumed from Tesla. This — not the lock — is what must still be true for the write to
        // be safe: the lock can legitimately expire (or be force-cleared) while we're mid-flight
        // and a late store must still land, whereas if refresh_token_enc has changed, someone
        // else has already re-authed or rotated this row with a token that is valid for them, and
        // overwriting it would discard that. Supabase reports a zero-row match as success with no
        // error, so the row count from .select() is the only way to detect it. Treat zero rows as
        // a store failure for this attempt: it will retry (and ultimately report rotated_unstored)
        // rather than silently discarding Tesla's already-issued new token pair.
        const { data: ud, error: ue } = await sb.from("tesla_credentials").update(updatePayload)
          .select("owner_id").eq("refresh_token_enc", claimedRow.refresh_token_enc as string).eq("owner_id", row.owner_id);
        if (!ue && ud?.length === 1) { stored = true; break; }
        lastStoreError = ue ?? new Error("token_changed: refresh_token_enc no longer matches the consumed token");
      }
      if (!stored) {
        console.error("tesla-refresh: rotated but unstored", { owner_id: row.owner_id });
        throw new Error(`rotated_unstored: ${String((lastStoreError as any)?.message ?? lastStoreError)}`);
      }
      rotated.push(row.owner_id);
    } catch (err: any) {
      failed.push({ owner_id: row.owner_id, error: String(err?.message ?? err) });
      try {
        const n = (claimedRow.refresh_failures ?? 0) + 1;
        const backoffMs = Math.min(2 ** n * 60_000, 6 * 3600_000);
        const { error: le } = await sb.from("tesla_credentials").update({
          last_error: String(err?.message ?? err).slice(0, 500),
          refresh_failures: n,
          next_refresh_at: new Date(claimNow.getTime() + backoffMs).toISOString(),
        }).eq("owner_id", row.owner_id);
        if (le) throw le;
      } catch (lastErrorErr: any) {
        console.error("tesla-refresh: failed to record last_error", { owner_id: row.owner_id, error: String(lastErrorErr?.message ?? lastErrorErr) });
      }
    } finally {
      // Owned release: only clear the lock if it still holds the exact value we set, so a
      // release that runs late (e.g. after our own claim expired) can never clear a lock that
      // some other caller has since claimed for themselves.
      const { error: relErr } = await sb.from("tesla_credentials").update({ refresh_lock_until: null }).eq("owner_id", row.owner_id).eq("refresh_lock_until", lockUntilIso);
      if (relErr) console.error("tesla-refresh: failed to release lock", { owner_id: row.owner_id, error: relErr.message });
    }
  }
  return { rotated, failed, skipped };
}
function hexToBytes(v: unknown): Uint8Array {
  // supabase-js returns bytea as "\\x..." hex string
  const s = String(v); const hex = s.startsWith("\\x") ? s.slice(2) : s; return new Uint8Array(Buffer.from(hex, "hex"));
}
