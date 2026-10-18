import { describe, it, expect } from "vitest";
import { encryptToken, decryptToken } from "../src/crypto";
const KEY = Buffer.alloc(32, 7).toString("base64");
describe("token crypto", () => {
  it("round-trips", () => { expect(decryptToken(encryptToken("rt_abc", KEY), KEY)).toBe("rt_abc"); });
  it("uses a fresh nonce", () => { expect(Buffer.from(encryptToken("x", KEY))).not.toEqual(Buffer.from(encryptToken("x", KEY))); });
  it("rejects a wrong key", () => { expect(() => decryptToken(encryptToken("x", KEY), Buffer.alloc(32, 8).toString("base64"))).toThrow(); });
  it("rejects short keys", () => { expect(() => encryptToken("x", "c2hvcnQ=")).toThrow(/32 bytes/); });
});
