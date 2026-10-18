import { createHash, randomBytes } from "node:crypto";
import { serviceClient } from "./supabase";
export function hashSecret(secret: string) { return createHash("sha256").update(secret).digest("hex"); }
export function newBridgeSecret() { return "gbs_" + randomBytes(36).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "").slice(0, 48); }
export async function bridgeOwnerFromRequest(req: Request): Promise<{ id: string } | null> {
  const secret = req.headers.get("x-bridge-secret"); if (!secret || !secret.startsWith("gbs_")) return null;
  const sb = serviceClient();
  const { data } = await sb.from("bridge_secrets").select("owner_id").eq("secret_hash", hashSecret(secret)).maybeSingle();
  if (!data) return null;
  await sb.from("bridge_secrets").update({ last_used_at: new Date().toISOString() }).eq("owner_id", data.owner_id);
  return { id: data.owner_id };
}
