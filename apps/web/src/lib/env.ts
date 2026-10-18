const REQUIRED = ["TESLA_CLIENT_ID","TESLA_CLIENT_SECRET","TESLA_REDIRECT_URI","TESLA_FLEET_BASE","SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TOKEN_ENC_KEY","CRON_SECRET","APP_RETURN_URL"] as const;
const OPTIONAL = ["UPSTASH_REDIS_REST_URL","UPSTASH_REDIS_REST_TOKEN","ALLOWED_OWNER_IDS","ADMIN_SECRET"] as const;
type Env = Record<(typeof REQUIRED)[number], string> & Partial<Record<(typeof OPTIONAL)[number], string>>;
export function env(source: NodeJS.ProcessEnv = process.env): Env {
  const missing = REQUIRED.filter((k) => !source[k]);
  if (missing.length) throw new Error("Missing env: " + missing.join(", "));
  const out: any = {}; for (const k of [...REQUIRED, ...OPTIONAL]) out[k] = source[k]; return out as Env;
}
