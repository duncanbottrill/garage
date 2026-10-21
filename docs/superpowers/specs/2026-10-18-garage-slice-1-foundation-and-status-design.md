# Garage — Slice 1: Foundation and Status

**Status:** approved in conversation 2026-10-18, pending written review
**Owner:** Duncan Bottrill
**Scope of this document:** the whole system at architecture level, and slice 1 (foundation and live status) in implementable detail. Slices 2 to 4 are recorded as scope only and get their own specs.

## 1. What this is

A Tessie-class companion app for one Tesla (2025 Model Y Dual Motor Performance), for iPhone and Mac, built on Tesla's Fleet API directly. Personal use first; designed so a public product is a change of hosting and accounts, not a rewrite.

Slice 1 replaces Tessie for daily use: live state of the car, controls, and the plumbing every later slice depends on.

### Goals

- Live vehicle state on iPhone and Mac within seconds of the car reporting it, without polling.
- Lock, climate, charging and frunk controls that work from anywhere.
- Zero Tesla API spend in normal use (inside the $10 monthly credit), with hard guardrails.
- Telemetry history captured from day one so slices 2 and 3 have data when they arrive.
- A visual identity that is dark, distinctive and current (Figma direction 04).

### Non-goals for slice 1

- Drive and charge logs, battery health, tariff costs, automations, Sentry or dashcam.
- Widgets, Watch, Live Activities, Siri, CarPlay, HomeKit.
- Multi-vehicle, multi-user, billing, public sign-up.
- Android.

## 2. Fixed facts

| Item | Value |
|---|---|
| Car | 2025 Model Y Dual Motor Performance, one vehicle, UK |
| Fleet API region | EU (`https://fleet-api.prd.eu.vn.cloud.tesla.com`; token endpoint `https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token`, authorize at `auth.tesla.com`) |
| Tesla developer app | created 2026-10-18, client ID `3f7843f7-ba1d-4091-9e6b-a41acfe7ef5c`; secret held by Duncan, never in the repo |
| Registered domain | `garage.duncanbottrill.com` (Vercel project `car-backend`, team `duncan-bottrills-projects`) |
| Redirect URI | `https://garage.duncanbottrill.com/auth/callback` |
| Public key path | `https://garage.duncanbottrill.com/.well-known/appspecific/com.tesla.3p.public-key.pem` |
| Always-on host | Home Assistant Green (HAOS, aarch64, 4 GB RAM, 32 GB eMMC); Core needs updating from 2025.10.4 |
| Fleet API prices (2026-10) | $1 per 150k streaming signals, per 1k commands, per 500 data requests, per 50 wakes; $10 free credit per month; billing limit left at 0 as a hard stop |
| Design | Figma file DataTes, page Directions, frame "D4 / Hybrid" (node 2:2) and style guides for 01 and 02 |

## 3. Architecture

Five parts, one job each.

```
 car ──(Fleet Telemetry, mTLS, protobuf)──▶ HA Green: Garage Bridge add-on (telemetry) ──▶ Supabase ──(Realtime)──▶ iPhone / Mac app
 car ◀──(signed command)── Tesla Fleet API ◀── HA Green: Garage Bridge add-on (proxy) ◀──(Tailscale)── iPhone / Mac app
                                             Vercel (garage domain): public key, OAuth callback, token refresh, small API
```

- **State flows one way**: car → Home Assistant → Supabase → app.
- **Commands flow one way**: app → proxy (over Tailscale) → Tesla → car.
- The two paths never cross. If the house is offline the app shows last-known state with its age; commands resume when Tailscale reconnects.
- Nothing that can move the car is reachable from the public internet. The only inbound listener is the telemetry receiver, which requires a Tesla client certificate.

### 3.1 Components and their contracts

| Component | Runs on | Does | Depends on |
|---|---|---|---|
| Garage Bridge add-on (ours) | HA Green | One add-on, four services: `tailscaled` (own tailnet node, Funnel exposes port 443 → telemetry receiver only, tailnet-only route to the proxy), Tesla's `tesla-http-proxy` (holds the private key, signs commands), Tesla's `fleet-telemetry` (unmodified), and the ingest worker, which fetches the Tesla access token from `GET /api/bridge/token` with its per-owner bridge secret. See §5. | Tailscale account (free); Supabase service key; bridge secret; Tesla command key (all via HA add-on options) |
| Supabase | cloud | System of record; Realtime fan-out; RLS | — |
| Vercel app (`apps/web`) | Vercel | Public key, OAuth callback, token refresh cron, authenticated API routes; later the home dashboard | Supabase, Upstash |
| Apple app (`apps/apple`) | iPhone, Mac | Status UI, controls, onboarding | Supabase session, Tailscale on device |

## 4. Tesla integration

### 4.1 Authentication and token custody

- One-time OAuth authorization-code flow with PKCE, started from the app, completed in the browser, landing on the Vercel callback. Scopes: `openid offline_access vehicle_device_data vehicle_cmds vehicle_charging_cmds vehicle_location`.
- The refresh token is stored in Supabase table `tesla_credentials`, encrypted application-side with XChaCha20-Poly1305 (`encryptToken`, `packages/core`) before the write, readable only by the service role.
- Tesla refresh tokens are single-use. Rotation happens in one place, `refreshAll`, behind a per-owner claim lock; the daily cron and the on-demand path in `/api/token` and `/api/bridge/token` both go through it, so there is at most one rotation per owner at a time.
- The proxy service and the ingest worker (both inside the Garage Bridge add-on) call `GET /api/bridge/token` with their per-owner bridge secret on start and whenever a request returns 401. They never touch `tesla_credentials` directly and never refresh.
- Partner registration (`POST /api/1/partner_accounts` with the garage domain) is a one-time script in `apps/web/scripts/`, run from the Mac with the client credentials.

### 4.2 Virtual key

- P-256 key pair generated once on the Mac with `openssl` (script in `apps/web/scripts/keygen.sh`, per the runbook).
- Public key committed to `apps/web/public/.well-known/appspecific/com.tesla.3p.public-key.pem`.
- Private key pasted into the Garage Bridge add-on's `tesla_private_key` option (HA stores add-on options encrypted at rest on the Green; the add-on restores line breaks lost by HA's single-line password field and validates the result before handing it to the proxy — see §5.2, §5.3). It exists nowhere else; a copy in the Mac keychain is the backup.
- Pairing: Duncan opens `https://tesla.com/_ak/garage.duncanbottrill.com` on the phone with the Tesla app installed, at the car, and approves.

### 4.3 Commands

The app calls the proxy over Tailscale:

```
POST https://<green-tailnet-name>:4443/api/1/vehicles/{vin}/command/{name}
Authorization: Bearer <tesla access token>   (fetched by the app from Vercel /api/token, short-lived, see 7.2)
```

Slice-1 command set: `door_lock`, `door_unlock`, `auto_conditioning_start`, `auto_conditioning_stop`, `set_temps`, `remote_seat_heater_request`, `set_preconditioning_max` (defrost), `charge_port_door_open`, `charge_port_door_close`, `charge_start`, `charge_stop`, `set_charge_limit`, `set_scheduled_charging`, `actuate_trunk` (frunk), `flash_lights`, `honk_horn`.

Wake policy: if `vehicle_state.sleep_state = asleep`, the app asks before sending `wake_up`. Never automatic.

### 4.4 Telemetry

- The ingest worker, on first run and whenever the config version changes, calls `POST /api/1/vehicles/fleet_telemetry_config` with: hostname (the Green's Funnel hostname, `*.ts.net`), port 443, the CA chain for that hostname, and the signal list below. Confirmed via `fleet_telemetry_config` GET; the result is stored on `vehicles`.
- Signals, slice 1 (names per Tesla's telemetry schema): `Soc`, `BatteryLevel`, `EstBatteryRange`, `IdealBatteryRange`, `ChargeState`, `DetailedChargeState`, `ChargerPower` (ACChargingPower / DCChargingPower), `ChargeLimitSoc`, `ChargeAmps`, `ChargePortDoorOpen`, `ScheduledChargingStartTime`, `InsideTemp`, `OutsideTemp`, `HvacPower`, `ClimateKeeperMode`, `Location`, `VehicleSpeed`, `Odometer`, `Gear`, `Locked`, `DoorState`, `FdWindow`/`FpWindow`/`RdWindow`/`RpWindow`, `TpmsPressureFl/Fr/Rl/Rr`, `SentryMode`, `VehicleName`, `SoftwareUpdateVersion`, plus the implicit connectivity/sleep events.
- Cadence: 10 s while `Gear` ≠ P or charging; otherwise change-triggered only. Budget expectation: 2–4 USD/month, inside the credit.
- The telemetry server runs unmodified from Tesla's `fleet-telemetry` image with a config that writes to a local named pipe/ZMQ socket consumed by the ingest worker (no Kafka, no Kinesis).

### 4.5 Budget guardrails

- `api_usage(category, month, count)` incremented by whoever makes a billable call (ingest worker for signals estimated from message counts, app via Vercel for commands and wakes, worker for data requests).
- Vercel cron `/api/cron/budget` projects month-end spend daily. Thresholds: at 70% of credit, widen the awake interval to 30 s; at 90%, change-triggered only; always refuse automatic wakes. State written to `vehicles.budget_mode`, shown as a banner in the app.
- Tesla's own billing limit stays at 0.

### 4.6 Manual refresh

A "Refresh now" action in More (not on Status) makes one `vehicle_data` request via Vercel, counted in the ledger. Only shown when telemetry is older than 10 minutes and the car is believed awake.

## 5. Home Assistant layer

**Amended 2026-10-19 (Plan 1B as built).** §5.1–5.3 below described three separate add-ons (Tailscale, Tesla HTTP Proxy, Garage Bridge). Plan 1B shipped one add-on instead — **Garage Bridge** — running `tailscaled`, Tesla's `tesla-http-proxy`, Tesla's `fleet-telemetry` and the ingest worker as four s6-supervised services in a single container. §5.1–5.8 below replace the three-add-on design with what actually shipped.

**Amended 2026-10-19 (Plan 1B Task 9, add-on 0.2.0).** Tesla rejects a telemetry config whose hostname is not under the partner account's root domain (`hostname domain does not match with partner account`), so the tailnet `*.ts.net` name cannot be registered. The receiver now runs under a hostname in the partner domain (option `telemetry_hostname`, e.g. `telemetry.duncanbottrill.com`), reached through a DNS `A` record and a router port-forward (external TCP 443 → the Green's 443, which the add-on maps to the container's 8443), or, behind CGNAT, an `AAAA` record to the Green's global IPv6 address or a relay host that forwards raw TCP to the tailnet-only `garage-bridge.<tailnet>.ts.net:8443`. Its certificate comes from a private CA the add-on keeps in `/data/ca` (P-256, 10 years; 90-day leaf renewed inside 30 days), which the config's `ca` field tells the car to trust, so no public certificate is needed. In that mode `tlscert` does not wait for Tailscale, the 443 Funnel is not published, and the config `hostname` is `telemetry_hostname`; Tailscale stays only for the tailnet-only 4443 proxy serve and the tailnet-only 8443 relay route. The Funnel + `tailscale cert` path described below is kept as the fallback when `telemetry_hostname` is empty and is documented for reference only: Tesla does not accept it for registration.

### 5.1 Processes (`garage-bridge/`, repo root)

Custom add-on repository `duncanbottrill/garage` (`repository.yaml` and `garage-bridge/config.yaml` at the repo root, as Home Assistant requires), architecture `aarch64` (and `amd64` for local dev), image built by GitHub Actions and pushed to GHCR; HA pulls the image (never builds it — both GHCR packages must be public, since the Green has no registry credentials).

One container, `s6-overlay` supervising five services:

| Service | Runs | Does |
|---|---|---|
| `tailscale` | `tailscaled --tun=userspace-networking` | Joins the tailnet as its own node (hostname configurable, `garage-bridge` by default); `tailscale serve --tcp=443 tcp://127.0.0.1:8443` plus `tailscale funnel 443 on` publishes the telemetry receiver to the public internet as a raw TCP forward (TLS, including the car's client certificate, terminates in `fleet-telemetry`, never in Tailscale); a second rule, `tailscale serve --tcp=4443 tcp://127.0.0.1:4443`, exposes the command proxy on the tailnet only — never funneled |
| `tlscert` | `tailscale cert` | Issues/renews the Let's Encrypt certificate for the node's `*.ts.net` hostname once a day; see §5.6 |
| `telemetry` | `fleet-telemetry` v0.9.5 (Tesla's binary, unmodified) | Terminates the car's mTLS stream on `0.0.0.0:8443`; republishes every record to the HA Mosquitto broker add-on on topics `garage/<VIN>/v/<Field>`, `garage/<VIN>/connectivity`, `garage/<VIN>/alerts/<name>/current`, `garage/<VIN>/errors/<name>` |
| `proxy` | `tesla-http-proxy` v0.4.1 (`github.com/teslamotors/vehicle-command`) | Holds our Tesla command private key; signs Fleet API requests and, transparently, the telemetry config JWS; binds `127.0.0.1:4443` behind its own TLS pair in `/data/proxy-tls`: since add-on 0.3.0 that is the Let's Encrypt certificate for the node's tailnet FQDN (`tlscert` writes a copy there and restarts the proxy when it changes), so iOS and macOS trust it without pinning; a self-signed pair is used only with `tailscale_enabled` off (or briefly on a first start, until `tailscale cert` answers); reachable from the tailnet via the `tailscale serve` rule above |
| `ingest` | Node 22, TypeScript, bundles `@garage/core` | Subscribes to the Mosquitto topics, writes `signals` and patches `vehicle_state`, registers the telemetry config through `proxy`, adapts cadence to `vehicles.budget_mode`; see §5.2 |

### 5.2 Ingest worker behaviour

- Fetches a Tesla access token from `GET <garage_api_base>/api/bridge/token` with header `x-bridge-secret`. Never holds a Tesla refresh token and never persists an access token — it keeps the token in memory only, cached until ~60 s before its `expires_at` and re-fetched on a 401.
- `signals` rows are batched (≤200 rows or every 2 s) and upserted; `vehicle_state` is written only through `merge_vehicle_state(p_vehicle, p_patch)` (§6.1), never directly.
- A decoded value of `null` (Tesla's `"invalid"` wire value), a bare `SNA`, or an enum ending `Unknown`/`SNA` (e.g. `WindowStateUnknown`, `ShiftStateSNA`) means "no information" and produces no state patch — never a false `"null"` string, all-doors-closed, or `false`.
- An in-memory buffer holds up to 5 minutes of pending `signals` rows when Supabase is unreachable; past that, the oldest rows are dropped and the count is surfaced in `vehicle_state.bridge_health`.
- A `vehicle_state` patch that fails to write is re-queued underneath whatever arrived since it failed (newer values win key-by-key, including the known nested columns `doors`/`windows`/`tpms_bar`/`bridge_health`) and dropped after 3 consecutive failures, so one permanently-rejected patch cannot block every later one.
- Heartbeat: `vehicle_state.bridge_seen_at` and `bridge_health` every 30 s, via the same `merge_vehicle_state` path. The app still treats >90 s as "bridge offline" (§10).

### 5.3 Add-on options

All secrets arrive through HA add-on options (encrypted at rest on the Green); none are baked into the image or repo.

| Option | Type | Required | Default |
|---|---|---|---|
| `tailscale_enabled` | bool | yes | `true` |
| `tailscale_authkey` | password | when `tailscale_enabled` | — |
| `tailscale_hostname` | string | yes | `garage-bridge` |
| `telemetry_hostname` | string | no (needed for Tesla to accept the config) | — |
| `tesla_private_key` | password | when `tailscale_enabled` | — |
| `tesla_vin` | string | yes | — |
| `garage_api_base` | url | yes | `https://garage.duncanbottrill.com` |
| `bridge_secret` | password | yes | — |
| `supabase_url` | url | yes | — |
| `supabase_service_key` | password | yes | — |
| `mqtt_host` | string | yes | `core-mosquitto` |
| `mqtt_port` | port | yes | `1883` |
| `mqtt_username` | string | no | — |
| `mqtt_password` | password | no | — |
| `log_level` | list | yes | `info` |

`tesla_private_key` is pasted as a YAML block scalar (`|`) in the Configuration tab's YAML editor, since the normal single-line password field strips its newlines; the add-on restores line breaks and validates the key before handing it to `proxy`, idling with a clear log line rather than crash-looping if it still doesn't parse. Full detail and the exact YAML form: `garage-bridge/DOCS.md`.

### 5.4 Telemetry config registration

- Registered through `proxy` at `POST /api/1/vehicles/fleet_telemetry_config` with `{ vins: [VIN], config }`; the proxy signs it (`Tesla.SS256`) and forwards to `fleet_telemetry_config_jws`. Config body: `hostname` = the node's tailnet FQDN, `port` 443, `ca` = the PEM chain from `tailscale cert`, `fields` per budget mode (§5.5), `alert_types: ["service"]`, `exp` = now + 180 days.
- Confirmed by polling `GET /api/1/vehicles/{vin}/fleet_telemetry_config`. A poll counts as confirmation only when the response has `synced: true`, `key_paired !== false`, and a `config` object whose `hostname` and field-name set match ours — a missing or `null` config, or one that doesn't match, proves nothing about what the car is actually streaming and is never trusted.
- Tesla answers the POST with HTTP 200 even when it skipped our VIN, listing it under `response.skipped_vehicles.<reason>` (`missing_key` — the virtual key isn't paired — `unsupported_hardware`, `unsupported_firmware`, `max_configs`). A skipped POST is treated as a failure, not a success: `telemetry_last_error = skipped:<reason>`, the normal POST backoff applies, and pairing the key afterwards is picked up on the next retry without an add-on restart.
- POST failures (including a skip) back off from 15 minutes, doubling to a 6-hour cap. Once a POST is accepted, confirmation is polled up to 40 times, 15 s apart (~10 min); if that run doesn't confirm, later checks poll on a separately-doubling 5 min → 60 min schedule, up to 4 attempts each.
- `vehicles.telemetry_config_hash` is the SHA-256 of the canonical JSON of `{ hostname, ca_sha256, fields }` — so a tailnet FQDN change or a rotated CA chain re-registers the car, not only a cadence/budget-mode change. A confirmation is also treated as stale (forcing re-registration) once `telemetry_confirmed_at` is more than 150 days old, ahead of the config's own 180-day `exp`.

### 5.5 Cadence by budget mode

`normal` tier (32 fields; `minimum_delta` noted where Tesla's schema carries one, resend interval for the three fields re-sent on an hourly ceiling even if unchanged): `Location` 10 s, `VehicleSpeed` 10 s, `Soc` 60 s (Δ0.5), `BatteryLevel` 60 s, `EstBatteryRange` 60 s (Δ1), `ChargeState` 10 s, `DetailedChargeState` 10 s, `ACChargingPower`/`DCChargingPower`/`ChargeAmps` 30 s, `ChargeLimitSoc` 60 s, `ChargePortDoorOpen` 10 s, `ScheduledChargingStartTime` 300 s, `InsideTemp`/`OutsideTemp` 60 s (Δ0.5), `HvacPower` 10 s, `ClimateKeeperMode` 60 s, `Odometer` 60 s (Δ0.1), `Gear`/`Locked`/`DoorState` 1 s (resend hourly), `FdWindow`/`FpWindow`/`RdWindow`/`RpWindow` 5 s, `TpmsPressureFl/Fr/Rl/Rr` 300 s, `SentryMode` 10 s, `VehicleName`/`SoftwareUpdateVersion` 3600 s.

`reduced` triples every interval (minimum 1 s); `minimal` sextuples every interval and drops `VehicleSpeed` (`Location` lands on 60 s purely because 10 × 6 = 60, with no special-casing needed). `minimum_delta` and the resend ceiling are never scaled by budget mode — a stuck door/gear/lock value must still re-confirm hourly even under `minimal`.

### 5.6 Certificates

`tlscert` issues/renews the node's Let's Encrypt certificate once a day via `tailscale cert`, writing `server.crt`/`server.key`/`ca.pem` to temp files then `mv`-ing them into place (key first, so a reader never sees a certificate without its key). It takes the leaf certificate's SHA-256 fingerprint before and after each issue; on a change, it restarts `telemetry` (`s6-svc -r`, guarded on the service directory existing) so the renewed pair is picked up without a full add-on restart — `fleet-telemetry` otherwise reads its TLS pair once at startup and would keep serving the expiring certificate. `ca.pem` is the Let's Encrypt intermediate chain with the build-time-baked ISRG Root X1 appended unless the chain `tailscale cert` returned already ends in it.

### 5.7 Persistence

Nothing persists outside `/data` on the Green's eMMC: `/data/tailscale` (node state/keys), `/data/tls` (the Let's Encrypt pair and chain), `/data/private-key.pem` (the normalised Tesla command key, mode 600), `/data/proxy-tls` (the proxy's pair: the Let's Encrypt certificate for the tailnet FQDN since 0.3.0, self-signed only with Tailscale disabled), `/data/config.json` (`fleet-telemetry`'s rendered config). The ingest's own bounded in-memory buffers (§5.2) are the only place a brief Supabase outage is absorbed; nothing is spooled to disk for that.

### 5.8 Deferred

- A bridge credential narrower than the full Supabase service key — still deferred from the 1A.2 review; the ingest holds the full service key today.
- `merge_vehicle_state`'s `p_clear` parameter and a merge staleness guard (§6.1) — still deferred from the 1A.2 review. The ingest only ever sends fields it actually received, so staleness mainly matters against a manual refresh (§4.6), which is rare.
- ~~The `proxy` service's own TLS listener uses a self-signed certificate on the tailnet rather than a trusted one; deferred to Plan 1C.~~ Done in add-on 0.3.0 (Plan 1C): the listener presents the Let's Encrypt certificate for the tailnet FQDN, and is self-signed only when Tailscale is disabled.
- MQTT → HA entity discovery, so the car's fields show up as native HA sensors/automations, is deferred to slice 4. `fleet-telemetry` already publishes the per-field topics a later discovery layer would consume.
## 6. Data model (Supabase)

Migrations in `supabase/migrations/`, numbered. RLS enabled on every table; policies scope by `owner_id = auth.uid()`; the service role bypasses for the bridge and Vercel.

```sql
vehicles(
  id uuid pk, owner_id uuid references auth.users, vin text unique, tesla_vehicle_id bigint,
  display_name text, model text, trim text, pack_kwh numeric,
  telemetry_config_version int, telemetry_confirmed_at timestamptz,
  budget_mode text check (budget_mode in ('normal','reduced','minimal')) default 'normal',
  created_at timestamptz default now())

vehicle_state(
  vehicle_id uuid pk references vehicles,
  -- charge
  soc numeric, range_km numeric, charge_state text, charger_power_kw numeric, charge_limit_soc int,
  charge_port_open bool, scheduled_charge_at timestamptz, charge_at timestamptz,
  -- climate
  inside_c numeric, outside_c numeric, hvac_on bool, climate_keeper text, climate_at timestamptz,
  -- motion / position
  lat numeric, lng numeric, heading numeric, speed_kph numeric, gear text, odometer_km numeric, location_at timestamptz,
  -- body
  locked bool, doors jsonb, windows jsonb, frunk_open bool, trunk_open bool, body_at timestamptz,
  tpms_bar jsonb, sentry bool,
  -- meta
  sleep_state text, software_version text, bridge_seen_at timestamptz, bridge_health jsonb,
  updated_at timestamptz)

signals(
  vehicle_id uuid, name text, value_num numeric, value_text text, value_json jsonb, recorded_at timestamptz,
  primary key (vehicle_id, name, recorded_at))  -- partitioned by month on recorded_at

-- drives and charges are created in the slice 1 migration with their final columns and left empty; slice 2 populates them
drives(
  id uuid pk, vehicle_id uuid references vehicles, started_at timestamptz, ended_at timestamptz,
  start_lat numeric, start_lng numeric, end_lat numeric, end_lng numeric,
  start_place_id uuid references places, end_place_id uuid references places,
  start_odometer_km numeric, end_odometer_km numeric, distance_km numeric,
  start_soc numeric, end_soc numeric, energy_kwh numeric, wh_per_km numeric, max_speed_kph numeric,
  inside_c_start numeric, outside_c_start numeric, created_at timestamptz default now())

charges(
  id uuid pk, vehicle_id uuid references vehicles, started_at timestamptz, ended_at timestamptz,
  lat numeric, lng numeric, place_id uuid references places,
  start_soc numeric, end_soc numeric, energy_added_kwh numeric, energy_drawn_kwh numeric,
  peak_power_kw numeric, charger_type text check (charger_type in ('ac','dc_supercharger','dc_other')),
  cost_minor int, currency text default 'GBP', tariff_id uuid, created_at timestamptz default now())
places(id, owner_id, name, lat, lng, radius_m, kind)
api_usage(owner_id, category text, month date, count bigint, primary key(owner_id, category, month))
tesla_credentials(owner_id pk, refresh_token_enc bytea, access_token text, access_expires_at timestamptz, rotated_at timestamptz)
```

- Units stored metric (km, °C, kW, bar); converted in the app and dashboard.
- Retention: `signals` full resolution 12 months, then a nightly job downsamples to 1-minute medians into `signals_1m` (slice 3 introduces it; the partitioning is in place now).
- Realtime enabled on `vehicle_state` only.

### 6.1 vehicle_state write contract

- Single write path: `merge_vehicle_state(p_vehicle, p_patch)`. Nothing else writes `vehicle_state` directly.
- Patch keys overwrite scalars; the jsonb columns `doors`, `windows`, `tpms_bar`, `bridge_health` merge object-wise (existing keys not present in the patch survive).
- A JSON `null` in the patch means "omit", not "set to null" — fields cannot be cleared this way yet. A `p_clear` parameter is planned for Plan 1B.
- Door/window keys are `driver_front`, `passenger_front`, `driver_rear`, `passenger_rear` — never the short `fl`/`fr`/`rl`/`rr` form used by early fixtures (migration 0013 strips any leftovers).
- The row must already exist: callers upsert `{vehicle_id, owner_id}` with `ignoreDuplicates` first, then call `merge_vehicle_state`.

## 7. Vercel app (`apps/web`)

Next.js (App Router), same conventions as tp-backend. Slice 1 routes:

| Route | Purpose |
|---|---|
| `GET /.well-known/appspecific/com.tesla.3p.public-key.pem` | static public key |
| `POST /auth/start` | requires a Supabase JWT; builds the Tesla authorize URL with PKCE, state bound to the Supabase user |
| `GET /auth/callback` | exchanges code, stores encrypted refresh token, redirects to `garage://connected` |
| `GET /api/token` | returns the current Tesla access token to an authenticated app user for proxy calls (Supabase JWT required; rate-limited via Upstash) |
| `GET /api/bridge/token` | returns the current Tesla access token to the HA add-on, authenticated by its per-owner bridge secret (`x-bridge-secret`), rate-limited |
| `POST /api/admin/bridge-secret` | mints (and rotates) a bridge secret for an owner; admin secret |
| `POST /api/admin/register-partner` | one-time Tesla partner registration; admin secret |
| `POST /api/usage` | app reports commands/wakes for the ledger |
| `POST /api/vehicle-data` | manual refresh (section 4.6) |
| `POST /api/vehicles/sync` | re-syncs the owner's vehicles from Tesla |
| `GET /api/connection` | token/connection health for the caller (section 10) |
| `GET /api/cron/tesla-refresh`, `GET /api/cron/budget` | crons (Vercel Cron, secret header) |

### 7.2 Why the app fetches the Tesla token from Vercel

The proxy needs a Tesla bearer token on each request. The app never holds the refresh token; it asks Vercel for the current access token (valid up to 8 h), caches it in memory, and re-asks on 401. This keeps rotation in one place and the app free of Tesla secrets.

## 8. Apple app (`apps/apple`)

- SwiftUI, one Xcode project, targets iOS 26 and macOS 26. Swift Package `GarageKit` holds the vehicle store, command client, models and design tokens; the app target is thin.
- **VehicleStore**: Supabase Swift SDK, Realtime subscription to `vehicle_state`; per-field freshness; last snapshot persisted in app support for instant cold launch.
- **CommandClient**: base URL from settings (tailnet name), bearer from `/api/token`, optimistic state with `pending` markers, a per-command in-flight guard (a second tap of a command already in flight is dropped), 10 s timeout, typed errors mapped to copy. Detects Tailscale reachability with a TLS handshake probe of the proxy (nothing billed); when unreachable, controls disable with a "Connect Tailscale" action (opens the Tailscale app).
- **Screens**: Status (04), Climate sheet, Charge sheet, More, Onboarding. Onboarding has four steps: (1) Sign in with Apple, which creates the Supabase account that owns everything; (2) Connect Tesla: `POST /auth/start` with the Supabase JWT returns the Tesla URL, which the app opens in `ASWebAuthenticationSession`, returning on `garage://connected`; (3) confirm the vehicle (one in slice 1, picker later); (4) check Tailscale reachability of the proxy, with instructions and the pairing deep link if the key is not yet paired. Drives, Charges, Battery tabs ship with designed empty states.
- **Navigation**: iPhone `TabView` with the iOS 26 floating glass tab bar; Mac `NavigationSplitView` sidebar with the same five sections and a two-column Status (map left, sheet content right).
- **Map**: MapKit with a dark standard style, car annotation with a breathing halo while `bridge_seen_at` is fresh, recent trail from the last 30 minutes of `Location` signals. Pan and pinch on both platforms; the camera follows the car only once it has moved more than 50 m.
- **Status sheet stops (iPhone, amended 2026-10-21)**: the docked sheet has two stops. `full` shows everything; dragging it down (48 pt, or a flick) snaps to `compact`: hero numeral, charge line and the quick actions, the tiles gone and the rest of the screen map. Dragging up restores `full`. The stop is remembered (`UserDefaults` `statusSheetStop`). The Mac panel has no stops.
- **Design system**: `GarageKit/Design` generated from `packages/tokens/tokens.json` (colours, type scale, radii, spacing). Big Shoulders Display and Instrument Sans bundled (OFL).

## 9. Design system rules (from Figma 04)

- Type: Big Shoulders Display SemiBold for hero and tile numerals only, ≥22 pt, never in tables. Instrument Sans for all else; tabular figures on in any column of numbers. Labels 10–11 pt small caps, +12% tracking.
- Colour: background `#0B0F14`, glass `#0F151C` at 80–90%, ink `#EAF0F6`, muted `#7D8A99`, accent `#4FE3FF` (route, car, active state only), charging `#3DDC97`, warning `#FFB020`, hairlines white at 8%.
- Shape: sheet 28, pill 22, control 18, tile 16.
- Motion: numerals roll on change; car dot breathes while live, solid when stale; glass tab bar collapses on scroll (system behaviour).
- Icons: Lucide, 1.5 pt stroke, no custom glyphs.
- Figma: everything bound to styles; repeated elements componentised on a components page; ask before creating components.

## 10. Failure modes

| Condition | Detection | User sees |
|---|---|---|
| House/bridge offline | `bridge_seen_at` > 90 s | figures show age; car dot solid; banner "Telemetry paused since 14:02" |
| Tailscale not connected on device | proxy TLS handshake probe fails | controls disabled; "Connect Tailscale" button |
| Command rejected | proxy/Tesla error | optimistic state reverts; plain-language reason; key-missing errors point to pairing |
| Car asleep | `sleep_state` | prompt before wake; wakes counted |
| Token refresh failing | cron error → `tesla_credentials.rotated_at` stale | red row in More; push notification (slice 4); app keeps last-known data, never signs out |
| Budget threshold | `budget_mode` | banner explaining reduced cadence |
| Supabase unreachable from bridge | buffer then drop | `dropped_count` in More's connection health |
| Token health | `GET /api/connection` or `get_tesla_connection()` | red row in More with `last_error` |

## 11. Security

- Private key only on the Green; refresh token only in Supabase (encrypted); the app holds a Supabase session and a short-lived Tesla access token in memory. A leaked access token cannot move the car: 2021+ vehicles reject unsigned commands and the signing key is only on the Green.
- RLS on every table from migration 0001.
- Proxy bound to the tailnet interface; Funnel exposes only the telemetry receiver, which enforces Tesla client-certificate mTLS.
- Vercel routes require a Supabase JWT; crons require a secret header; Upstash rate limits on `/api/token`, `/api/vehicle-data`, `/api/usage`, with an in-memory fallback limiter when Upstash env vars are absent (local dev and tests), so rate limiting degrades rather than disappears.
- Admin routes (`/api/admin/bridge-secret`, `/api/admin/register-partner`) require a separate `ADMIN_SECRET` bearer header, distinct from `CRON_SECRET`, so a leaked cron secret cannot mint bridge secrets or re-run partner registration.
- Repo is public-safe: no secrets; `.env.example` and HA options only.

## 12. Testing

- `garage-bridge/ingest`: unit tests on decode → state mapping with recorded fixtures (captured from the real car once streaming) and synthetic edge cases (sleep mid-drive, dropout, out-of-order timestamps). Integration test runs the real `fleet-telemetry` binary with a replayed stream against a local Supabase.
- `apps/web`: route tests with mocked Tesla endpoints; PKCE/state checks; cron idempotency (refresh twice → one rotation).
- `apps/apple`: GarageKit unit tests (freshness, optimistic revert, idempotency); snapshot tests of Status/Climate/Charge/More in states live, stale, offline, pending.
- `supabase`: migrations applied in CI against a branch database; RLS policy tests (owner A cannot read owner B).

## 13. Repository layout

```
garage/
  repository.yaml        HA add-on repository descriptor (repo root, as HA requires)
  garage-bridge/          Garage Bridge HA add-on
  apps/web/              Next.js on Vercel (garage domain)
  apps/apple/            Xcode project + GarageKit package
  packages/tokens/       tokens.json → Swift + CSS generators
  supabase/              migrations, seed, policy tests
  docs/superpowers/      specs and plans
```

## 14. Phasing

1. **Slice 1 — Foundation and Status** (this spec).
2. **Slice 2 — Logging**: drive/charge detectors, Drives and Charges tabs, places, flat-rate tariff resolver, home dashboard (web, wall-mounted layout).
3. **Slice 3 — Battery and insight**: health estimates, charge curves, efficiency vs temperature, Octopus half-hourly tariff integration, Battery tab, `signals_1m` downsampling.
4. **Slice 4 — Surfaces**: widgets, Live Activities, Watch, MQTT → HA entities → HomeKit, automations, push notifications.

## 15. Slice 1 acceptance criteria

- From a cold start on iPhone, the Status screen shows state of charge, range, inside/outside temperature, location on the map, locked state and charge state, each with its freshness, within 3 s of launch (cached) and updates within 15 s of a change while the car is awake (live).
- Lock, unlock, climate on/off with temperature, charge limit, charge start/stop, port open/close and frunk work from the app on and off the home network, with no step reaching the proxy from the public internet.
- The car is never woken without a confirmation tap.
- 30 days of normal use stays inside Tesla's $10 credit, verified from `api_usage` and the Tesla developer dashboard.
- The Mac app shows the same data in the split layout and can issue the same commands.
- Onboarding completes without touching a terminal, except the one-time key generation and partner registration scripts run by Duncan.
- Bridge offline, Tailscale off, command rejected and token failure each produce the state described in section 10.

## 16. Open items carried into the plan

- ~~Confirm raw-TCP Funnel is available in the HA Tailscale add-on build~~ — resolved in Plan 1B Task 2: `tailscaled` inside the Garage Bridge add-on publishes raw-TCP Funnel directly (§5); the port-forward/DuckDNS fallback was not needed.
- Capture a real telemetry fixture in the first week of streaming and freeze it as the test corpus.
- Decide the app's bundle id and the `garage://` URL scheme at project creation.
