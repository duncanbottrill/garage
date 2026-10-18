import { describe, it, expect, vi, beforeAll } from "vitest";
beforeAll(() => { for (const [k, v] of Object.entries({ TESLA_CLIENT_ID: "cid", TESLA_CLIENT_SECRET: "sec", TESLA_REDIRECT_URI: "https://g/auth/callback", TESLA_FLEET_BASE: "https://fleet", SUPABASE_URL: "http://x", SUPABASE_ANON_KEY: "a", SUPABASE_SERVICE_ROLE_KEY: "s", TOKEN_ENC_KEY: Buffer.alloc(32, 1).toString("base64"), CRON_SECRET: "c", APP_RETURN_URL: "garage://connected" })) process.env[k] = v; });
describe("tesla auth", () => {
  it("authorize url carries PKCE and scopes", async () => {
    const { authorizeUrl } = await import("@/lib/tesla-auth"); const u = new URL(authorizeUrl("CH", "ST"));
    expect(u.searchParams.get("code_challenge")).toBe("CH"); expect(u.searchParams.get("state")).toBe("ST"); expect(u.searchParams.get("scope")).toContain("vehicle_cmds");
  });
  it("exchangeCode posts form with verifier and audience", async () => {
    const { exchangeCode } = await import("@/lib/tesla-auth");
    const f = vi.fn(async (_u: any, init: any) => { const p = new URLSearchParams(init.body); expect(p.get("code_verifier")).toBe("V"); expect(p.get("audience")).toBe("https://fleet"); return new Response(JSON.stringify({ access_token: "A", refresh_token: "R", expires_in: 28800 }), { status: 200 }); });
    expect((await exchangeCode({ code: "C", verifier: "V", fetch: f as any })).refresh_token).toBe("R");
  });
});
