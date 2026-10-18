import { xchacha20poly1305 } from "@noble/ciphers/chacha";
import { randomBytes } from "@noble/ciphers/webcrypto";

const key = (b64: string) => { const k = Buffer.from(b64, "base64"); if (k.length !== 32) throw new Error("TOKEN_ENC_KEY must be 32 bytes"); return new Uint8Array(k); };

export function encryptToken(plain: string, keyB64: string): Uint8Array {
  const nonce = randomBytes(24);
  const ct = xchacha20poly1305(key(keyB64), nonce).encrypt(new TextEncoder().encode(plain));
  const out = new Uint8Array(24 + ct.length); out.set(nonce); out.set(ct, 24); return out;
}
export function decryptToken(cipher: Uint8Array, keyB64: string): string {
  const nonce = cipher.slice(0, 24), ct = cipher.slice(24);
  return new TextDecoder().decode(xchacha20poly1305(key(keyB64), nonce).decrypt(ct));
}
