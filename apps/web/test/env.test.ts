import { describe, it, expect } from "vitest";
import { env } from "@/lib/env";
describe("env", () => {
  it("lists missing names", () => { expect(() => env({} as any)).toThrow(/TESLA_CLIENT_ID.*CRON_SECRET/s); });
  it("returns values when present", () => {
    const src = Object.fromEntries(["TESLA_CLIENT_ID","TESLA_CLIENT_SECRET","TESLA_REDIRECT_URI","TESLA_FLEET_BASE","SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TOKEN_ENC_KEY","CRON_SECRET","APP_RETURN_URL"].map(k => [k, "x"]));
    expect(env(src as any).TESLA_CLIENT_ID).toBe("x");
  });
  it("ALLOWED_OWNER_IDS is optional", () => {
    const src = Object.fromEntries(["TESLA_CLIENT_ID","TESLA_CLIENT_SECRET","TESLA_REDIRECT_URI","TESLA_FLEET_BASE","SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TOKEN_ENC_KEY","CRON_SECRET","APP_RETURN_URL"].map(k => [k, "x"]));
    expect(() => env(src as any)).not.toThrow();
    expect(env(src as any).ALLOWED_OWNER_IDS).toBeUndefined();
  });
});
