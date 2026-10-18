import { it, expect } from "vitest";
import { createHash } from "node:crypto";
import { createPkce } from "@/lib/pkce";
it("challenge is S256 of verifier", () => {
  const { verifier, challenge } = createPkce();
  expect(verifier).toMatch(/^[A-Za-z0-9_-]{64}$/);
  expect(challenge).toBe(createHash("sha256").update(verifier).digest("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));
});
