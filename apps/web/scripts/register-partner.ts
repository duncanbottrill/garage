import { env } from "../src/lib/env";
const e = env(); const AUTH = "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token";
const tok = await fetch(AUTH, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ grant_type: "client_credentials", client_id: e.TESLA_CLIENT_ID, client_secret: e.TESLA_CLIENT_SECRET, scope: "openid vehicle_device_data vehicle_cmds vehicle_charging_cmds", audience: e.TESLA_FLEET_BASE }) });
if (!tok.ok) throw new Error("partner token failed: " + (await tok.text()));
const { access_token } = await tok.json();
const reg = await fetch(e.TESLA_FLEET_BASE + "/api/1/partner_accounts", { method: "POST", headers: { authorization: `Bearer ${access_token}`, "content-type": "application/json" }, body: JSON.stringify({ domain: new URL(e.TESLA_REDIRECT_URI).host }) });
console.log(reg.status, await reg.text());
const check = await fetch(e.TESLA_FLEET_BASE + "/api/1/partner_accounts/public_key?domain=" + new URL(e.TESLA_REDIRECT_URI).host, { headers: { authorization: `Bearer ${access_token}` } });
console.log("public key check:", check.status, await check.text());
