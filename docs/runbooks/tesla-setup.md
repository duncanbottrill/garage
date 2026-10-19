# Tesla setup runbook (one-time, Duncan)
1. `apps/web/scripts/keygen.sh` → commit the public key; store `~/.garage/private-key.pem` in 1Password.
2. Deploy `apps/web` (Task 12) and confirm `curl https://garage.duncanbottrill.com/.well-known/appspecific/com.tesla.3p.public-key.pem` returns the PEM.
3. `.env.local` with TESLA_CLIENT_SECRET etc., then `pnpm --filter @garage/web exec tsx scripts/register-partner.ts` → expect 200 and the public key echoed back.
4. Pair the key: at the car, on the phone with the Tesla app, open `https://tesla.com/_ak/garage.duncanbottrill.com` and approve.
5. Connect the account: from the app's onboarding (Plan 1C), or temporarily by calling `/auth/start` with a Supabase JWT.
6. Mint the bridge secret, once per owner:
   ```
   curl -X POST -H "authorization: Bearer $ADMIN_SECRET" -H "content-type: application/json" \
     -d '{"owner_id":"<owner uuid>"}' https://garage.duncanbottrill.com/api/admin/bridge-secret
   ```
   Store the returned secret in the add-on options (`x-bridge-secret` header for `GET /api/bridge/token`); it is shown once.
7. Set `ALLOWED_OWNER_IDS` on Vercel to the owner uuid(s).
8. Once the owner account exists, disable email sign-ups in the Supabase dashboard: Authentication → Providers → Email → turn off "Allow new users to sign up". Only do this after deciding how the Apple identity will be linked to the owner account (Plan 1C) — disabling sign-ups first would block that linking path.

## Garage Bridge on the Home Assistant Green

Owner steps to take the Garage Bridge add-on from zero to streaming on the Green.

1. **Tailscale admin console.** Access controls: a tailnet policy with `tag:garage` owned by the admin (`"tagOwners": { "tag:garage": ["autogroup:admin"] }`) and Funnel granted to it (`"nodeAttrs": [{ "target": ["tag:garage"], "attr": ["funnel"] }]`). DNS page: HTTPS certificates enabled. Settings → Keys: generate a REUSABLE, PRE-AUTHORISED auth key tagged `tag:garage`. Before any of this, remove any stale `garage-bridge*` machine left by an earlier install or test — otherwise the new node joins as `garage-bridge-1` and its FQDN, certificate and telemetry hostname all change with it.
2. **Home Assistant.** Install the official Mosquitto broker add-on. Settings → People → Users: create a user `garage` for it, with "Can only log in from the local network" turned off. Start Mosquitto.
3. **Add the repository.** Settings → Add-ons → Add-on store → ⋮ → Repositories → add `https://github.com/duncanbottrill/garage`. Install "Garage Bridge" from the store.
4. **Fill the options.** Where each value comes from:
   - `tailscale_authkey` — the reusable, pre-authorised `tag:garage` key from step 1.
   - `tesla_private_key` — the PEM at `~/.garage/private-key.pem`, pasted in the Configuration tab's YAML editor as a block scalar (`tesla_private_key: |`, each line of the PEM indented two spaces underneath, BEGIN/END lines included). The single-line password field loses the PEM's newlines.
   - `tesla_vin` — the car's VIN, exactly as registered in Garage.
   - `bridge_secret` — from `~/.garage/vercel-secrets.env`, or minted fresh with `POST /api/admin/bridge-secret` (see the main Tesla setup steps above) if it isn't there.
   - `supabase_url`, `supabase_service_key` — from the Supabase project dashboard.
   - `mqtt_username`/`mqtt_password` — the `garage` Home Assistant user from step 2 and its password.
   Never write a real secret value into this doc or any committed file — only where it comes from.
5. **Start it, then check the Log tab.** The healthy-start lines, copied exactly from `garage-bridge/DOCS.md` (verified against the code):
   1. `tailscale up as garage-bridge.<tailnet>.ts.net`, followed by the `tailscale funnel status` and `serve status` output, which should list TCP port 443 on that name forwarded to `127.0.0.1:8443`.
   2. `tlscert: certificate for garage-bridge.<tailnet>.ts.net refreshed`.
   3. `wrote /data/config.json (mqtt broker core-mosquitto:1883, log_level info)` and `telemetry: starting fleet-telemetry on 0.0.0.0:8443`.
   4. `proxy: starting tesla-http-proxy on 127.0.0.1:4443`.
   5. Ingest JSON lines: `"msg":"ingest starting"`, then `"msg":"vehicle resolved"`.
   6. Within about ten minutes: `"msg":"telemetry config ensure","result":{"changed":true}`.
6. **Verify in Supabase.** `vehicles.telemetry_config_hash` is set and `telemetry_confirmed_at` is recent; `signals` rows are arriving; `vehicle_state.bridge_seen_at` is fresh (updates every 30 s).
7. **Capture real payloads for the test fixtures.** From the Mosquitto add-on's own terminal, or any tailnet host with access to the broker, run `mosquitto_sub -v -t 'garage/#'` for the first ~10 minutes of streaming and save the output under `dev/replay/fixtures/`. This closes the review gap that real `fleet-telemetry` → MQTT payload shapes were never captured.
8. **After 24 hours**, check `api_usage` in Supabase and the Tesla developer dashboard against the Fleet API billing posture.

### Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `tailscale up` fails / `node is in state NeedsLogin` | The auth key was already used (not reusable) or has expired | Generate a new REUSABLE, PRE-AUTHORISED key tagged `tag:garage` |
| `node is in state NeedsMachineAuth` | The key isn't pre-authorised and device approval is on | Pre-authorise the key, or approve the device in the admin console |
| `could not publish port 443 through Tailscale Funnel` | Funnel isn't granted to `tag:garage`; the log prints a `login.tailscale.com` URL to enable it | Add the `nodeAttrs` Funnel grant from step 1, or follow the printed URL |
| `telemetry config ensure not synced` with `telemetry_last_error: skipped:missing_key` | The Tesla virtual key isn't paired with the car yet | Pair it first: on a phone with the Tesla app, at the car, open `https://tesla.com/_ak/garage.duncanbottrill.com` and approve. The add-on retries on its own (15 min → 6 h backoff), so it picks the pairing up without a restart |
| `proxy: tesla_private_key is not a valid PEM private key` | The key lost its line breaks in the single-line password field | Re-paste it in the YAML editor's block form (`tesla_private_key: \|`), as in step 4 |
| `tlscert: tailscale cert failed; retrying in 10 minutes` | HTTPS certificates are disabled for the tailnet, or Let's Encrypt is rate-limiting this name | Enable HTTPS certificates on the tailnet's DNS page and wait for the retry |

### Releasing a new version

Bump `version` in `garage-bridge/config.yaml`, commit, then:

```
git tag bridge-vX.Y.Z
git push origin bridge-vX.Y.Z
```

CI publishes `ghcr.io/duncanbottrill/garage-bridge-aarch64:X.Y.Z` and `-amd64:X.Y.Z`, plus `:latest` for both. On the very first publish, make both GHCR packages public (repository → Packages → package settings → Change visibility) — the Green has no registry credentials and cannot pull a private image.
