import { requireCron } from "@/lib/supabase";
export const dynamic = "force-dynamic";
export const maxDuration = 30;

// One-time Tesla partner registration, run from the server so the client secret never leaves Vercel.
// Guarded by the same secret as the crons. Idempotent: Tesla returns the existing registration on repeat calls.
export async function POST(req: Request) {
  if (!requireCron(req)) return new Response("forbidden", { status: 403 });
  const clientId = process.env.TESLA_CLIENT_ID, clientSecret = process.env.TESLA_CLIENT_SECRET;
  const fleetBase = process.env.TESLA_FLEET_BASE, redirect = process.env.TESLA_REDIRECT_URI;
  if (!clientId || !clientSecret || !fleetBase || !redirect) return Response.json({ error: "missing_env" }, { status: 500 });
  const domain = new URL(redirect).host;
  const tok = await fetch("https://auth.tesla.com/oauth2/v3/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "client_credentials", client_id: clientId, client_secret: clientSecret, scope: "openid vehicle_device_data vehicle_cmds vehicle_charging_cmds", audience: fleetBase }) });
  if (!tok.ok) return Response.json({ step: "partner_token", status: tok.status, body: (await tok.text()).slice(0, 500) }, { status: 502 });
  const { access_token } = await tok.json();
  const reg = await fetch(fleetBase + "/api/1/partner_accounts", { method: "POST", headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json" }, body: JSON.stringify({ domain }) });
  const regBody = (await reg.text()).slice(0, 1000);
  const check = await fetch(fleetBase + "/api/1/partner_accounts/public_key?domain=" + domain, { headers: { authorization: `Bearer ${access_token}` } });
  const checkBody = (await check.text()).slice(0, 1000);
  return Response.json({ domain, register: { status: reg.status, body: regBody }, public_key_check: { status: check.status, body: checkBody } });
}
