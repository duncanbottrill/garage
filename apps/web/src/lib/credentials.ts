import type { SupabaseClient } from "@supabase/supabase-js";
import { serviceClient } from "./supabase";
import { refreshAll } from "./tesla-refresh";
const STALE_WINDOW_MS = 30 * 60_000; // refresh once less than 30 minutes of access remains
const MIN_VALID_MS = 60_000; // never hand back a token with under 60s of life left
const LOCK_WAIT_MS = 1_500;
const LOCK_WAIT_RETRIES = 3;
type Row = { access_token: string | null; access_expires_at: string | null; next_refresh_at?: string | null };
function isStale(row: Row | null | undefined, now: Date) {
  return !row?.access_token || !row.access_expires_at || new Date(row.access_expires_at).getTime() - now.getTime() < STALE_WINDOW_MS;
}
function isUsable(row: Row | null | undefined, now: Date) {
  return !!row?.access_token && !!row.access_expires_at && new Date(row.access_expires_at).getTime() - now.getTime() >= MIN_VALID_MS;
}
export type AccessTokenStatus =
  | { status: "ok"; token: string; expiresAt: string }
  | { status: "not_connected" }
  | { status: "unavailable"; retryAt: string | null };
type Opts = { refreshIfStale?: boolean; fetch?: typeof fetch; now?: Date; client?: SupabaseClient; sleep?: (ms: number) => Promise<void> };
// Distinguishes "never connected" (no tesla_credentials row at all) from "connected but no
// usable token right now" (a row exists but refresh is failing or still mid-rotation), so
// callers can tell a user to connect vs. tell them to wait and retry.
export async function currentAccessTokenStatus(ownerId: string, o: Opts = {}): Promise<AccessTokenStatus> {
  const sb = o.client ?? serviceClient();
  const now = o.now ?? new Date();
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const refreshIfStale = o.refreshIfStale ?? true;
  let sawRow = false;
  const read = async (): Promise<Row | null> => {
    const { data } = await sb.from("tesla_credentials").select("access_token, access_expires_at, next_refresh_at").eq("owner_id", ownerId).maybeSingle();
    if (data) sawRow = true;
    return data ?? null;
  };
  let row = await read();
  if (!row && !sawRow) return { status: "not_connected" };
  if (refreshIfStale && isStale(row, now)) {
    try {
      const result = await refreshAll({ ownerId, refreshWithinMs: 30 * 60_000, fetch: o.fetch, now, client: sb, sleep });
      const locked = result.failed.some((x) => x.owner_id === ownerId && x.error === "locked");
      if (locked) {
        // someone else is mid-rotation for this owner — poll briefly for the result they're about to store
        for (let i = 0; i < LOCK_WAIT_RETRIES; i++) {
          await sleep(LOCK_WAIT_MS);
          row = await read();
          if (!isStale(row, now)) break;
        }
      } else {
        row = await read();
      }
    } catch {
      // refreshAll threw (e.g. a transient DB error) — fall back to whatever is already
      // stored rather than surfacing a 500 from a token endpoint that can tolerate staleness.
      row = await read();
    }
  }
  if (!row) return { status: "not_connected" };
  if (!isUsable(row, now)) return { status: "unavailable", retryAt: row.next_refresh_at ?? null };
  return { status: "ok", token: row.access_token as string, expiresAt: row.access_expires_at as string };
}
export async function currentAccessToken(ownerId: string, o: Opts = {}) {
  const s = await currentAccessTokenStatus(ownerId, o);
  return s.status === "ok" ? { token: s.token, expiresAt: s.expiresAt } : null;
}
