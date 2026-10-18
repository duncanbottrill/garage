import { createHash, randomBytes } from "node:crypto";
const b64url = (b: Buffer) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export function createPkce() { const verifier = b64url(randomBytes(48)); const challenge = b64url(createHash("sha256").update(verifier).digest()); return { verifier, challenge }; }
export function newState() { return b64url(randomBytes(24)); }
