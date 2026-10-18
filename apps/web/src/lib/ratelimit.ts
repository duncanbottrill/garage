import { Ratelimit } from "@upstash/ratelimit";
import { Redis } from "@upstash/redis";
import { env } from "./env";
let rl: Ratelimit | null | undefined;
function limiter() {
  if (rl !== undefined) return rl; const e = env();
  rl = e.UPSTASH_REDIS_REST_URL && e.UPSTASH_REDIS_REST_TOKEN
    ? new Ratelimit({ redis: new Redis({ url: e.UPSTASH_REDIS_REST_URL, token: e.UPSTASH_REDIS_REST_TOKEN }), limiter: Ratelimit.slidingWindow(10, "1 m"), prefix: "garage" }) : null;
  return rl;
}
export async function limit(key: string, userId: string): Promise<{ ok: boolean }> {
  const l = limiter(); if (!l) return { ok: true }; const r = await l.limit(`${key}:${userId}`); return { ok: r.success };
}
