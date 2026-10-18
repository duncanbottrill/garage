import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";
import { env } from "./env";
type Opts = { perMinute?: number; perDay?: number };
let redis: Redis | null | undefined; const upstash = new Map<string, Ratelimit>(); const mem = new Map<string, number[]>();
function redisClient() { if (redis !== undefined) return redis; const e = env(); redis = e.UPSTASH_REDIS_REST_URL && e.UPSTASH_REDIS_REST_TOKEN ? new Redis({ url: e.UPSTASH_REDIS_REST_URL, token: e.UPSTASH_REDIS_REST_TOKEN }) : null; return redis; }
function upstashLimiter(name: string, n: number, window: "1 m" | "1 d") { const k = `${name}:${window}`; let l = upstash.get(k); if (!l) { l = new Ratelimit({ redis: redisClient()!, limiter: Ratelimit.slidingWindow(n, window), prefix: `garage:${k}` }); upstash.set(k, l); } return l; }
function memAllow(key: string, n: number, windowMs: number, now: number) { const arr = (mem.get(key) ?? []).filter(t => now - t < windowMs); if (arr.length >= n) { mem.set(key, arr); return false; } arr.push(now); mem.set(key, arr); return true; }
export async function limit(key: string, userId: string, o: Opts = {}): Promise<{ ok: boolean }> {
  const perMinute = o.perMinute ?? 10, perDay = o.perDay; const id = `${key}:${userId}`;
  if (redisClient()) {
    const m = await upstashLimiter(key, perMinute, "1 m").limit(id); if (!m.success) return { ok: false };
    if (perDay) { const d = await upstashLimiter(key, perDay, "1 d").limit(id); if (!d.success) return { ok: false }; }
    return { ok: true };
  }
  const now = Date.now();
  if (!memAllow(id + ":m", perMinute, 60_000, now)) return { ok: false };
  if (perDay && !memAllow(id + ":d", perDay, 86_400_000, now)) return { ok: false };
  return { ok: true };
}
export function _resetLimiterForTests() { mem.clear(); }
