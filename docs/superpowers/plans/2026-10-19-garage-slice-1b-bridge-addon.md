# Garage Slice 1B — Home Assistant Bridge Add-on Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single Home Assistant add-on, "Garage Bridge", that receives the car's Fleet Telemetry stream, signs Tesla commands, and writes live state and signal history into Supabase, so the Status screen has real data behind it.

**Architecture:** One container, four supervised processes. `tailscaled` (userspace networking) makes the add-on its own tailnet node, publishes the telemetry port to the internet with Funnel as a raw TCP forward (so TLS, including Tesla's client certificate, terminates in our receiver), and exposes the command proxy tailnet-only. `fleet-telemetry` (Tesla's binary, v0.9.5) receives the mTLS stream and republishes every field to the Home Assistant Mosquitto broker. `tesla-http-proxy` (Tesla's vehicle-command binary) signs commands and, transparently, the telemetry config JWS. `ingest` (Node 22, TypeScript, bundles `@garage/core`) subscribes to MQTT, batches `signals` rows, applies `merge_vehicle_state` patches, keeps the heartbeat, registers the telemetry config through the proxy using the bridge secret, and adapts cadence to `vehicles.budget_mode`.

**Tech Stack:** Home Assistant add-on on `ghcr.io/home-assistant/{arch}-base` (Alpine, s6-overlay v3, bashio); Tailscale (Alpine package); `tesla/fleet-telemetry:v0.9.5` (multi-arch); `tesla-http-proxy` built from `github.com/teslamotors/vehicle-command` v0.4.1; Node 22 + esbuild; `mqtt` npm client; vitest; GitHub Actions + GHCR.

**Research:** `.superpowers/sdd/research-tesla-telemetry.md` and `.superpowers/sdd/research-ha-addons.md` (2026-10-19). Spec: `docs/superpowers/specs/2026-10-18-garage-slice-1-foundation-and-status-design.md` §5 (amended by Task 8 here).

## Global Constraints

- Plan 1A/1A.2 constraints hold (metric units, no automatic wakes, every billable call counted, conventional commits with trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`).
- **The bridge never holds Tesla tokens or the Supabase anon key.** It holds: the Supabase service key (writes only via `signals` insert, `merge_vehicle_state`, `increment_usage`, `vehicles` update of telemetry columns), the bridge secret (for `GET https://garage.duncanbottrill.com/api/bridge/token` with header `x-bridge-secret`), the Tesla command private key (for the proxy), a Tailscale auth key, and the Mosquitto credentials. All arrive through add-on options; none are baked into the image or repo.
- `vehicle_state` is written only through `merge_vehicle_state(p_vehicle, p_patch)` (JSON null = omit; door/window keys `driver_front|passenger_front|driver_rear|passenger_rear`; the row must exist, the ingest upserts `{vehicle_id, owner_id}` with `ignoreDuplicates` once at start).
- Telemetry config is registered through the proxy at `POST /api/1/vehicles/fleet_telemetry_config` with `{ vins: [VIN], config }`; the proxy signs it (`Tesla.SS256`) and forwards to `fleet_telemetry_config_jws`. Confirm with `GET /api/1/vehicles/{vin}/fleet_telemetry_config` → `synced: true`; on failure read `GET .../fleet_telemetry_errors`.
- Telemetry config body: `hostname` = the add-on's tailnet FQDN (`<hostname>.<tailnet>.ts.net`), `port` 443, `ca` = PEM chain (Let's Encrypt intermediate + ISRG Root X1) from `tailscale cert`, `fields` per budget mode (below), `alert_types: ["service"]`, `exp` = now + 180 days. `Location` requires the `vehicle_location` scope (granted).
- Cadence by budget mode (interval_seconds; `minimum_delta` where noted): **normal** — `Location` 10, `VehicleSpeed` 10, `Soc` 60 (delta 0.5), `BatteryLevel` 60, `EstBatteryRange` 60 (delta 1), `ChargeState` 10, `DetailedChargeState` 10, `ACChargingPower` 30, `DCChargingPower` 30, `ChargeAmps` 30, `ChargeLimitSoc` 60, `ChargePortDoorOpen` 10, `ScheduledChargingStartTime` 300, `InsideTemp` 60 (delta 0.5), `OutsideTemp` 60 (delta 0.5), `HvacPower` 10, `ClimateKeeperMode` 60, `Odometer` 60 (delta 0.1), `Gear` 1 (resend 3600), `Locked` 1 (resend 3600), `DoorState` 1 (resend 3600), `FdWindow`/`FpWindow`/`RdWindow`/`RpWindow` 5, `TpmsPressureFl/Fr/Rl/Rr` 300, `SentryMode` 10, `VehicleName` 3600, `SoftwareUpdateVersion` 3600. **reduced** — every interval × 3 (min 1). **minimal** — every interval × 6 and drop `VehicleSpeed`, `Location` to 60. The config version is the SHA-256 of the canonical JSON of `fields`; stored in `vehicles.telemetry_config_version` as the first 8 hex chars parsed as int? No: store the version as an integer counter in `vehicles.telemetry_config_version` and the hash in `vehicles.telemetry_config_hash` (new text column, Task 4 migration).
- fleet-telemetry `config.json`: `host 0.0.0.0`, `port 8443`, `tls.server_cert`/`server_key` from `/data/tls/`, `records { V: ["mqtt"], alerts: ["mqtt"], errors: ["mqtt"], connectivity: ["mqtt"] }`, `mqtt { broker: <host:port>, client_id: "garage-bridge", username, password, topic_base: "garage", qos: 1 }`, `rate_limit { enabled: true, message_limit: 1000, message_interval_time: 30 }`, `monitoring.prometheus_metrics_port: 9090` (internal only). MQTT topics consumed: `garage/<VIN>/v/<Field>`, `garage/<VIN>/connectivity`, `garage/<VIN>/alerts/<name>/current`, `garage/<VIN>/errors/<name>`.
- Tailscale: `tailscaled --tun=userspace-networking --state=/data/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock`; `tailscale up --authkey=<key> --hostname=garage-bridge --accept-dns=false`; `tailscale cert <fqdn>` into `/data/tls/`; `tailscale serve --bg --tcp=443 tcp://127.0.0.1:8443` + `tailscale funnel --bg 443 on` (telemetry, public); `tailscale serve --bg --tcp=4443 tcp://127.0.0.1:4443` (proxy, tailnet only). Funnel allows only ports 443/8443/10000. The tailnet policy must have Funnel enabled (`nodeAttrs` with `funnel`) and the auth key must be reusable + pre-authorised; both are owner steps in the runbook.
- Storage on the Green is eMMC: nothing persistent except `/data/tailscale`, `/data/tls`, `/data/private-key.pem`, `/data/config.json`; the ingest keeps at most 5 minutes of rows in memory when Supabase is unreachable, then drops oldest and counts `dropped`.
- Local test env for anything touching Supabase: `export SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=$(supabase status -o json 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).ANON_KEY))') SUPABASE_SERVICE_ROLE_KEY=$(supabase status -o json 2>/dev/null | node -e 'process.stdin.on("data",d=>console.log(JSON.parse(d).SERVICE_ROLE_KEY))')`. Docker on this Mac is Colima (arm64 native), so `docker build` produces the same architecture as the Green.

---

## File structure

```
addon/
  repository.yaml                       HA add-on repository descriptor
  garage-bridge/
    config.yaml                         add-on manifest (options, schema, ports, map, image)
    build.yaml                          base images per arch
    Dockerfile                          multi-stage: go builder (proxy), copy fleet-telemetry, node build (ingest), alpine runtime
    DOCS.md                             user documentation shown in HA
    CHANGELOG.md
    rootfs/etc/s6-overlay/s6-rc.d/
      user/contents.d/{tailscale,tlscert,telemetry,proxy,ingest}
      tailscale/{type,run,finish}       tailscaled + up + serve/funnel
      tlscert/{type,run,dependencies.d/tailscale}   cert fetch + daily renew loop
      telemetry/{type,run,finish,dependencies.d/tlscert}  writes config.json, runs fleet-telemetry
      proxy/{type,run,finish,dependencies.d/tlscert}      tesla-http-proxy
      ingest/{type,run,finish,dependencies.d/telemetry}   node dist/ingest.js
    rootfs/usr/bin/
      garage-write-telemetry-config     bash: options → /data/config.json
      garage-tailscale-publish          bash: serve/funnel commands (idempotent)
    ingest/
      package.json  tsconfig.json  esbuild.mjs
      src/index.ts                      wiring: options → clients → run loop
      src/options.ts                    read + validate /data/options.json
      src/mqtt-source.ts                subscribe, parse topics, emit events
      src/decode.ts                     payload normaliser (number|string|bool|object|protobuf-JSON wrappers)
      src/state.ts                      events → signals rows + state patches (uses @garage/core)
      src/batcher.ts                    bounded buffer, flush by size/time, drop-oldest with counters
      src/supabase-sink.ts              insert signals, merge_vehicle_state, heartbeat, vehicles lookup
      src/telemetry-config.ts           desired config per budget mode, hash, CA chain, register/verify via proxy
      src/bridge-token.ts               GET /api/bridge/token client with caching
      src/health.ts                     counters + bridge_health payload
      test/*.test.ts  test/fixtures/*.json
dev/
  compose.bridge.yaml                   mosquitto + the add-on image (tailscale disabled) for local e2e
  replay/publish.mjs                    publishes fixture MQTT messages
.github/workflows/addon.yml             build + push ghcr.io/duncanbottrill/garage-bridge-{arch}, manifest on tag
```

---

### Task 1: Add-on skeleton and image that builds and boots

**Files:**
- Create: `addon/repository.yaml`, `addon/garage-bridge/config.yaml`, `addon/garage-bridge/build.yaml`, `addon/garage-bridge/Dockerfile`, `addon/garage-bridge/DOCS.md`, `addon/garage-bridge/CHANGELOG.md`, `addon/garage-bridge/rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/{tailscale,tlscert,telemetry,proxy,ingest}` (empty files), each service's `type` (`longrun`) and a placeholder `run` that logs and sleeps, `addon/garage-bridge/ingest/package.json` with a stub `src/index.ts` that logs "ingest stub" every 30 s.

**Interfaces:**
- Produces: image `garage-bridge:dev` that starts under s6 with five services, containing `/usr/bin/fleet-telemetry` (v0.9.5), `/usr/bin/tesla-http-proxy` (v0.4.1), `tailscale`/`tailscaled`, `node` 22, and `/app/ingest/dist/ingest.js`. Option names fixed here and used by every later task.

- [ ] **Step 1: Manifest**

`addon/repository.yaml`:
```yaml
name: "Garage add-ons"
url: "https://github.com/duncanbottrill/garage"
maintainer: "Duncan Bottrill <hello@duncanbottrill.com>"
```

`addon/garage-bridge/config.yaml`:
```yaml
name: "Garage Bridge"
version: "0.1.0"
slug: "garage_bridge"
description: "Tesla Fleet Telemetry receiver, command signing proxy and Supabase ingest for Garage"
url: "https://github.com/duncanbottrill/garage"
arch: [aarch64, amd64]
init: false
startup: services
boot: auto
image: "ghcr.io/duncanbottrill/garage-bridge-{arch}"
map:
  - type: share
    read_only: false
ports:
  "9090/tcp": null
ports_description:
  "9090/tcp": "fleet-telemetry Prometheus metrics (internal)"
watchdog: "tcp://[HOST]:[PORT:9090]"
options:
  tailscale_enabled: true
  tailscale_authkey: ""
  tailscale_hostname: "garage-bridge"
  tesla_private_key: ""
  tesla_vin: ""
  garage_api_base: "https://garage.duncanbottrill.com"
  bridge_secret: ""
  supabase_url: ""
  supabase_service_key: ""
  mqtt_host: "core-mosquitto"
  mqtt_port: 1883
  mqtt_username: ""
  mqtt_password: ""
  log_level: "info"
schema:
  tailscale_enabled: bool
  tailscale_authkey: password?
  tailscale_hostname: str
  tesla_private_key: password?
  tesla_vin: str
  garage_api_base: url
  bridge_secret: password?
  supabase_url: url
  supabase_service_key: password?
  mqtt_host: str
  mqtt_port: port
  mqtt_username: str?
  mqtt_password: password?
  log_level: list(trace|debug|info|warning|error)
```

`addon/garage-bridge/build.yaml`:
```yaml
build_from:
  aarch64: ghcr.io/home-assistant/aarch64-base:3.21
  amd64: ghcr.io/home-assistant/amd64-base:3.21
```

- [ ] **Step 2: Dockerfile**

```dockerfile
ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.21
ARG BUILD_ARCH=aarch64

# --- tesla-http-proxy from vehicle-command ---
FROM golang:1.23-alpine AS proxy
RUN apk add --no-cache git && \
    CGO_ENABLED=0 go install github.com/teslamotors/vehicle-command/cmd/tesla-http-proxy@v0.4.1

# --- fleet-telemetry binary (official multi-arch image) ---
FROM tesla/fleet-telemetry:v0.9.5 AS telemetry

# --- ingest bundle ---
FROM node:22-alpine AS ingest
WORKDIR /src
COPY addon/garage-bridge/ingest/package.json addon/garage-bridge/ingest/package-lock.json* ./
RUN npm install --no-audit --no-fund
COPY addon/garage-bridge/ingest/ ./
COPY packages/core/ /core/
RUN npm run build

# --- runtime ---
FROM ${BUILD_FROM}
RUN apk add --no-cache nodejs tailscale ca-certificates jq openssl
COPY --from=proxy /go/bin/tesla-http-proxy /usr/bin/tesla-http-proxy
COPY --from=telemetry /fleet-telemetry /usr/bin/fleet-telemetry
COPY --from=ingest /src/dist /app/ingest/dist
COPY addon/garage-bridge/rootfs/ /
RUN chmod a+x /etc/s6-overlay/s6-rc.d/*/run /etc/s6-overlay/s6-rc.d/*/finish /usr/bin/garage-* 2>/dev/null || true
LABEL io.hass.version="0.1.0" io.hass.type="addon" io.hass.arch="aarch64|amd64"
```
Note: the build context is the **repo root** (so `packages/core` can be copied); the `.github` workflow and the local build command both pass `-f addon/garage-bridge/Dockerfile .`. If `COPY --from=telemetry /fleet-telemetry` fails because the binary lives elsewhere in the image, inspect with `docker run --rm --entrypoint sh tesla/fleet-telemetry:v0.9.5 -c 'ls /'` is not possible (distroless); use `docker create` + `docker export | tar t | grep fleet` and fix the path. If `go install @v0.4.1` fails on module path, clone the tag and `go build ./cmd/tesla-http-proxy`.

- [ ] **Step 3: Services skeleton**

For each of `tailscale tlscert telemetry proxy ingest`: `rootfs/etc/s6-overlay/s6-rc.d/<svc>/type` containing `longrun`; `rootfs/etc/s6-overlay/s6-rc.d/user/contents.d/<svc>` empty; `run`:
```bash
#!/command/with-contenv bashio
# placeholder until the real service lands in a later task
bashio::log.info "<svc>: placeholder"
exec sleep infinity
```
`finish` (all services):
```bash
#!/command/with-contenv bashio
bashio::log.warning "<svc> exited with code ${1}"
```
Dependencies: `tlscert/dependencies.d/tailscale`, `telemetry/dependencies.d/tlscert`, `proxy/dependencies.d/tlscert`, `ingest/dependencies.d/telemetry` (empty files). Also `user/dependencies.d/base` is provided by the base image's s6 setup; do not add it.

- [ ] **Step 4: Ingest stub**

`addon/garage-bridge/ingest/package.json`:
```json
{ "name": "garage-bridge-ingest", "private": true, "type": "module",
  "scripts": { "build": "node esbuild.mjs", "test": "vitest run", "typecheck": "tsc --noEmit -p ." },
  "dependencies": { "mqtt": "^5.10.1", "@supabase/supabase-js": "^2.45.4", "@noble/ciphers": "^1.0.0" },
  "devDependencies": { "esbuild": "^0.24.0", "typescript": "^5.6.3", "vitest": "^2.1.3", "@types/node": "^22.7.5" } }
```
`esbuild.mjs`:
```js
import { build } from "esbuild";
await build({ entryPoints: ["src/index.ts"], bundle: true, platform: "node", target: "node22", format: "esm", outfile: "dist/ingest.js",
  alias: { "@garage/core": process.env.CORE_PATH ?? "../../../packages/core/src/index.ts" }, banner: { js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);" } });
console.log("ingest bundled");
```
In the Dockerfile the core path is `/core/src/index.ts`: set `ENV CORE_PATH=/core/src/index.ts` before `npm run build`. `tsconfig.json`: `{ "extends": "../../../tsconfig.base.json", "compilerOptions": { "paths": { "@garage/core": ["../../../packages/core/src/index.ts"] }, "baseUrl": "." }, "include": ["src", "test"] }`.
`src/index.ts` stub: `setInterval(() => console.log("ingest stub"), 30_000); console.log("ingest stub started");`

- [ ] **Step 5: Build and boot locally**

Run (repo root): `docker build --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.21 -f addon/garage-bridge/Dockerfile -t garage-bridge:dev .`
Then: `docker run --rm -d --name gb -v $(pwd)/dev/options.dev.json:/data/options.json garage-bridge:dev` with `dev/options.dev.json` holding the default options; `sleep 8; docker logs gb | tail -20; docker exec gb sh -c 'fleet-telemetry -version || true; tesla-http-proxy -h 2>&1 | head -3; tailscale version; node -v'`; `docker stop gb`.
Expected: five placeholder lines in logs; versions printed. Add `dev/options.dev.json` to the repo (no secrets).

- [ ] **Step 6: Commit** `feat(addon): garage-bridge add-on skeleton (image builds, services boot)`

---

### Task 2: Funnel mTLS smoke test (needs the owner's Tailscale auth key)

**Files:**
- Create: `dev/funnel-smoke.sh`, `addon/garage-bridge/rootfs/usr/bin/garage-tailscale-publish`, real `tailscale` and `tlscert` service scripts (replacing placeholders)

**Interfaces:**
- Produces: `tailscale/run` that starts `tailscaled` (userspace), runs `tailscale up` with the auth key and hostname, waits for `tailscale status --json` to report `BackendState: Running`, writes the FQDN to `/data/tailscale/fqdn`, then runs `garage-tailscale-publish`. `tlscert/run` fetches `tailscale cert --cert-file /data/tls/server.crt --key-file /data/tls/server.key <fqdn>`, extracts the chain minus leaf into `/data/tls/ca.pem` (append ISRG Root X1 from `/etc/ssl/certs` if missing), then sleeps 24 h and repeats. `garage-tailscale-publish` runs the three serve/funnel commands and prints `tailscale funnel status`.

- [ ] **Step 1: Scripts** (write them fully; shellcheck-clean)

`tailscale/run` (skip entirely when `tailscale_enabled` is false: log and `exec sleep infinity`):
```bash
#!/command/with-contenv bashio
set -euo pipefail
if ! bashio::config.true 'tailscale_enabled'; then bashio::log.warning "tailscale disabled (dev mode)"; exec sleep infinity; fi
mkdir -p /data/tailscale /run/tailscale
AUTHKEY="$(bashio::config 'tailscale_authkey')"; HOSTNAME_TS="$(bashio::config 'tailscale_hostname')"
tailscaled --tun=userspace-networking --state=/data/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock &
TSD=$!
for i in $(seq 1 30); do [ -S /run/tailscale/tailscaled.sock ] && break; sleep 1; done
tailscale --socket=/run/tailscale/tailscaled.sock up --authkey="${AUTHKEY}" --hostname="${HOSTNAME_TS}" --accept-dns=false --reset
for i in $(seq 1 60); do
  if tailscale --socket=/run/tailscale/tailscaled.sock status --json | jq -e '.BackendState=="Running"' >/dev/null; then break; fi; sleep 1
done
FQDN="$(tailscale --socket=/run/tailscale/tailscaled.sock status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
echo "${FQDN}" > /data/tailscale/fqdn
bashio::log.info "tailscale up as ${FQDN}"
/usr/bin/garage-tailscale-publish
wait ${TSD}
```
`garage-tailscale-publish`:
```bash
#!/command/with-contenv bashio
set -euo pipefail
TS="tailscale --socket=/run/tailscale/tailscaled.sock"
$TS serve --bg --tcp=443 tcp://127.0.0.1:8443
$TS funnel --bg 443 on || $TS funnel --bg --tcp=443 tcp://127.0.0.1:8443
$TS serve --bg --tcp=4443 tcp://127.0.0.1:4443
$TS funnel status || true
$TS serve status || true
```
`tlscert/run`:
```bash
#!/command/with-contenv bashio
set -euo pipefail
if ! bashio::config.true 'tailscale_enabled'; then bashio::log.warning "tlscert: tailscale disabled, expecting /data/tls to be provided"; exec sleep infinity; fi
TS="tailscale --socket=/run/tailscale/tailscaled.sock"; mkdir -p /data/tls
while true; do
  FQDN="$(cat /data/tailscale/fqdn)"
  if $TS cert --cert-file /data/tls/server.crt --key-file /data/tls/server.key "${FQDN}"; then
    # chain without the leaf: everything after the first certificate block
    awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n>=2{print}' /data/tls/server.crt > /data/tls/ca.pem
    if ! grep -q "ISRG Root X1" /data/tls/ca.pem 2>/dev/null; then
      awk '/ISRG Root X1/{f=1} f' /etc/ssl/certs/ca-certificates.crt | awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' >> /data/tls/ca.pem || true
    fi
    chmod 600 /data/tls/server.key; bashio::log.info "tlscert: certificate for ${FQDN} refreshed"
  else
    bashio::log.error "tlscert: tailscale cert failed; retrying in 10 minutes"; sleep 600; continue
  fi
  sleep 86400
done
```
(The ISRG root extraction via awk on the system bundle is best-effort; if the bundle lacks a name comment line, fetch `https://letsencrypt.org/certs/isrgrootx1.pem` once at build time into `/usr/share/garage/isrgrootx1.pem` and append that instead. Prefer the build-time file.)

- [ ] **Step 2: Smoke script** `dev/funnel-smoke.sh`: builds the image, runs it with a dev options file that has `tailscale_enabled: true`, the auth key from `$TS_AUTHKEY`, hostname `garage-bridge-smoke`, and a `telemetry` service replaced by a tiny mTLS echo server: inside the container run `openssl s_server -accept 8443 -cert /data/tls/server.crt -key /data/tls/server.key -Verify 1 -CAfile /data/tls/server.crt -www` (require a client cert; any CA is fine for the smoke, we only check that the handshake reaches our process). From the Mac (NOT on the tailnet): `openssl s_client -connect <fqdn>:443 -servername <fqdn> </dev/null 2>&1 | grep -E "Acceptable client certificate CA names|Verify return code|CertificateRequest"` — a `CertificateRequest`/"Acceptable client certificate CA names" line proves the TLS handshake, including the client-cert request, reached our process through Funnel unterminated. Print PASS/FAIL. Also print `tailscale funnel status`.

- [ ] **Step 3: Run it** with the owner-provided key: `TS_AUTHKEY=tskey-auth-… dev/funnel-smoke.sh`. Expected: PASS. If Funnel is not enabled on the tailnet, `tailscale funnel` prints a URL to enable it; stop and report. Record the FQDN and the output in the task report. Clean up: `tailscale logout` in the container, remove the smoke node from the admin console (or use an ephemeral auth key for the smoke).

- [ ] **Step 4: Commit** `feat(addon): tailscale node, funnel publish and cert services; funnel mTLS smoke test`

---
### Task 3: Ingest core — decode, state mapping, batching (pure, tested)

**Files:**
- Create: `addon/garage-bridge/ingest/src/decode.ts`, `src/state.ts`, `src/batcher.ts`, `src/health.ts`, `test/decode.test.ts`, `test/state.test.ts`, `test/batcher.test.ts`, `test/fixtures/mqtt-samples.json`

**Interfaces:**
- Produces:
  - `type BridgeEvent = { kind: "field"; vin: string; name: string; value: unknown; at: Date } | { kind: "connectivity"; vin: string; status: "CONNECTED" | "DISCONNECTED" | "UNKNOWN"; at: Date } | { kind: "alert"; vin: string; name: string; active: boolean; at: Date } | { kind: "error"; vin: string; name: string; body: string; at: Date }`
  - `parseTopic(topic: string, base: string): { vin: string; section: "v" | "connectivity" | "alerts" | "errors"; rest: string[] } | null`
  - `decodePayload(raw: Buffer | string): unknown` — JSON parse; unwraps protobuf-JSON wrappers (`{ "doubleValue": 1 }`, `{ "stringValue": "x" }`, `{ "booleanValue": true }`, `{ "intValue": 3 }`, `{ "locationValue": { latitude, longitude } }`, `{ "shiftStateValue": "ShiftStateD" }` → the inner value); passes through plain numbers/strings/booleans/objects; `"invalid"`/`{ "invalid": true }` → `null`.
  - `toSignalRow(ev: field event, vehicleId, ownerId): { vehicle_id, owner_id, name, value_num, value_text, value_json, recorded_at }` — numbers → `value_num`, booleans/strings → `value_text` (`"true"`/`"false"` for booleans), objects → `value_json`.
  - `toStatePatch(ev: BridgeEvent): Partial<VehicleStateRow>` — field events via `telemetrySignalToState(name, value, at)` from `@garage/core` (after `decodePayload`); connectivity `CONNECTED` → `{ sleep_state: "online" }`, `DISCONNECTED` → `{ sleep_state: "asleep" }`; alerts/errors → `{}` (they go to health).
  - `class Batcher<T>({ maxRows = 200, maxAgeMs = 2000, maxBufferMs = 300_000, onFlush })` with `push(item)`, `flushIfDue(now)`, `stats(): { pending, dropped, flushed }`; drop-oldest once the buffer spans more than `maxBufferMs` of wall time (rows are time-stamped on push).
  - `class Health` collecting `{ received, flushed, dropped, patch_failures, last_event_at, connectivity, active_alerts: string[], last_error: string | null }` and producing the `bridge_health` jsonb.

- [ ] **Step 1: Fixtures** — `test/fixtures/mqtt-samples.json`: an array of `{ topic, payload }` with at least: `garage/XP7Y…/v/Soc` `72.5`; `v/BatteryLevel` `{"doubleValue":72}`; `v/Gear` `"ShiftStateD"`; `v/Gear` `{"shiftStateValue":"ShiftStateP"}`; `v/Location` `{"latitude":54.41,"longitude":-1.72}`; `v/Location` `{"locationValue":{"latitude":54.41,"longitude":-1.72}}`; `v/DoorState` `{"DriverFront":false,"PassengerFront":true,"DriverRear":false,"PassengerRear":false,"TrunkFront":false,"TrunkRear":false}`; `v/Locked` `true`; `v/FpWindow` `"WindowStatePartiallyOpen"`; `v/TpmsPressureFl` `2.9`; `v/VehicleSpeed` `"invalid"`; `v/SentryMode` `"SentryModeStateArmed"`; `connectivity` `{"ConnectionId":"abc","Status":"CONNECTED","CreatedAt":"2026-10-19T08:00:00Z"}`; `alerts/Service_Required/current` `{"Name":"Service_Required","StartedAt":"…","EndedAt":null,"Audiences":["Service"]}`; `errors/SomeError` `{"Name":"SomeError","Body":"detail","Tags":{},"CreatedAt":"…"}`.

- [ ] **Step 2: Tests first** — `decode.test.ts` asserts every fixture decodes to the expected plain value (table-driven); `parseTopic` handles the four sections and rejects foreign bases. `state.test.ts`: `toSignalRow` column placement (`Soc` → `value_num`, `Gear` → `value_text`, `Location` → `value_json`, `Locked` → `value_text "true"`), `toStatePatch` for `Soc` (`soc`, `charge_at`), `Location`, `DoorState` (driver/passenger keys + frunk/trunk), `FpWindow`, connectivity → `sleep_state`, `VehicleSpeed "invalid"` → `{}`. `batcher.test.ts`: flushes at 200 rows; flushes after 2 s via `flushIfDue(now)`; when `onFlush` rejects, rows are retained and retried; drop-oldest once the buffer spans > 5 min (inject timestamps); stats counters.
Run: `cd addon/garage-bridge/ingest && npm install && npm test` → FAIL (modules missing).

- [ ] **Step 3: Implement** the four modules per the interfaces (keep each under ~120 lines; no I/O in these files). `decode.ts` wrapper detection: an object with exactly one key ending in `Value` → return that key's value (recursively for `locationValue`). Numeric strings stay strings (the core mapper's `num()` handles them).

- [ ] **Step 4: Run** → all green (expect ~25 tests). `npm run typecheck`. **Commit** `feat(bridge): ingest core — decode, state mapping, batcher, health`

---

### Task 4: Ingest I/O — MQTT source, Supabase sink, bridge token, telemetry config manager

**Files:**
- Create: `src/options.ts`, `src/mqtt-source.ts`, `src/supabase-sink.ts`, `src/bridge-token.ts`, `src/telemetry-config.ts`, `src/index.ts` (replace stub), `test/telemetry-config.test.ts`, `test/supabase-sink.test.ts`, `test/bridge-token.test.ts`
- Create: `supabase/migrations/0016_telemetry_config_hash.sql` (`alter table vehicles add column telemetry_config_hash text, add column telemetry_last_error text;`)

**Interfaces:**
- Produces:
  - `loadOptions(path = "/data/options.json")` → typed options; throws listing missing required keys (`tesla_vin`, `bridge_secret`, `supabase_url`, `supabase_service_key`, `mqtt_host`); `tesla_private_key` and `tailscale_authkey` are only required when the proxy/tailscale services are enabled (they are read by the shell scripts, not by ingest).
  - `startMqttSource({ url, username, password, base, vin, onEvent, onStatus })` → `{ stop() }`; subscribes `base/<vin>/#`, QoS 1, reconnects with backoff, converts messages to `BridgeEvent` via Task 3.
  - `SupabaseSink(client, { vehicleId, ownerId })`: `insertSignals(rows)` (`.insert(rows, { ... })` ignoring duplicate-key errors on `(vehicle_id, name, recorded_at)` by using `upsert` with `onConflict: "vehicle_id,name,recorded_at", ignoreDuplicates: true`), `mergeState(patch)` → `rpc("merge_vehicle_state")`, `heartbeat(health)` → `mergeState({ bridge_seen_at: now, bridge_health: health })`, `ensureStateRow()`, `resolveVehicle(vin)` → `{ vehicleId, ownerId, budgetMode, configHash, configVersion }` from `vehicles`, `setTelemetryConfig({ hash, version, confirmedAt, lastError })`, `countSignals(n)` → `rpc("increment_usage", { p_owner, p_category: "signals", p_count: n })` (batched per flush).
  - `BridgeToken({ apiBase, secret, fetch? })`: `get()` caches until 60 s before `expires_at`; on 401/404/503 throws a typed error with the server's `error` code.
  - `desiredConfig({ fqdn, caPem, mode, now })` → `{ hostname, port: 443, ca, fields, alert_types: ["service"], exp }` per the Global Constraints cadence table; `configHash(fields)` → sha256 hex of canonical JSON (sorted keys); `TelemetryConfigManager({ proxyBase: "https://127.0.0.1:4443", vin, token: BridgeToken, sink, fetch?, insecureTls: true })` with `ensure(mode, { fqdn, caPem })`: compares `configHash` to `vehicles.telemetry_config_hash`; if different (or never confirmed) → `POST /api/1/vehicles/fleet_telemetry_config` via the proxy with `{ vins: [vin], config }` and bearer; then polls `GET /api/1/vehicles/{vin}/fleet_telemetry_config` every 15 s up to 10 min for `synced: true`; on success `setTelemetryConfig({ hash, version: previous + 1, confirmedAt: now, lastError: null })`; on failure reads `GET .../fleet_telemetry_errors`, stores the first error message in `telemetry_last_error`, and retries on the next budget poll. Counts one `data` usage per GET and the POST as `commands`? No: Tesla bills config endpoints as data requests; count each call as `data`.
  - `index.ts` wiring: load options → service client → `resolveVehicle` (retry every 30 s until the VIN exists) → `ensureStateRow` → start MQTT → batcher flush loop (2 s) → heartbeat every 30 s → budget poll every 5 min (`resolveVehicle` again; `ensure(mode)`), with the proxy's self-signed TLS accepted for `127.0.0.1:4443` only. Graceful shutdown on SIGTERM (flush once).

- [ ] **Step 1: Tests first**
  - `telemetry-config.test.ts`: cadence table for `normal` matches the Global Constraints exactly (assert a handful of fields and the total count 31); `reduced` triples (`Gear` stays 3), `minimal` drops `VehicleSpeed` and sets `Location` 60; `configHash` stable across key order and changes when an interval changes; `ensure()` with a mocked fetch: posts to the proxy once, polls until `synced: true`, records hash/version; when `synced` never arrives it fetches errors and records `telemetry_last_error`; when the hash already matches it makes no calls.
  - `supabase-sink.test.ts` against the local Supabase (service key): `ensureStateRow` idempotent; `insertSignals` with a duplicate key does not throw and the row count is right; `mergeState({ soc: 41 })` lands; `heartbeat` sets `bridge_seen_at`; `countSignals(50)` increments the `signals` ledger. Seed: a user + `vehicles` row with a unique VIN; clean up in `afterAll`.
  - `bridge-token.test.ts`: caching, refresh at 60 s before expiry, typed errors for 404 `not_connected` and 503 `token_unavailable` (mocked fetch).

- [ ] **Step 2: Implement**, `supabase db reset` for 0016, run `npm test` → green (expect ~40 tests in the ingest package). `npm run typecheck`. `npm run build` produces `dist/ingest.js`.

- [ ] **Step 3: Commit** `feat(bridge): ingest I/O — MQTT source, Supabase sink, bridge token, telemetry config manager`

---

### Task 5: Real service scripts — telemetry, proxy, ingest

**Files:**
- Modify: `rootfs/etc/s6-overlay/s6-rc.d/{telemetry,proxy,ingest}/run` (replace placeholders)
- Create: `rootfs/usr/bin/garage-write-telemetry-config`

**Interfaces:**
- Produces: `garage-write-telemetry-config` renders `/data/config.json` from options (jq): host `0.0.0.0`, port 8443, tls paths, records all `["mqtt"]`, mqtt block from options, `rate_limit`, `monitoring.prometheus_metrics_port 9090`, `log_level` from options. `telemetry/run` waits for `/data/tls/server.crt` (or, with tailscale disabled, for files the dev harness mounts), writes the config and `exec fleet-telemetry -config /data/config.json`. `proxy/run` writes `tesla_private_key` option to `/data/private-key.pem` (600) and runs `exec tesla-http-proxy -tls-key /data/tls/server.key -cert /data/tls/server.crt -key-file /data/private-key.pem -host 127.0.0.1 -port 4443 -verbose` (if the proxy refuses the Let's Encrypt key format or requires its own cert, generate a self-signed pair into `/data/proxy-tls/` with `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=garage-bridge"` and use that; ingest already accepts self-signed on 127.0.0.1). `ingest/run`: `exec node /app/ingest/dist/ingest.js` with `LOG_LEVEL` from options. All three `finish` scripts log the exit code; s6 restarts longruns automatically.

- [ ] **Step 1: Write the scripts**, `shellcheck` them (`brew install shellcheck` if missing), rebuild the image.
- [ ] **Step 2: Boot with tailscale disabled and a mounted dev TLS pair** (`dev/tls/` generated by openssl self-signed, mounted to `/data/tls`) and a local Mosquitto (Task 6 compose): confirm in logs that `fleet-telemetry` starts listening on 8443 with TLS, the proxy starts on 4443, and ingest connects to MQTT and logs "resolved vehicle" against the local Supabase (point `supabase_url` at `http://host.docker.internal:54321` — on Colima use `host.lima.internal` or the Mac's LAN IP; document which in `dev/compose.bridge.yaml`).
- [ ] **Step 3: Commit** `feat(addon): telemetry, proxy and ingest service scripts`

---

### Task 6: Local end-to-end harness with MQTT replay

**Files:**
- Create: `dev/compose.bridge.yaml`, `dev/mosquitto.conf`, `dev/replay/publish.mjs`, `dev/options.e2e.json`, `dev/e2e-bridge.sh`

**Interfaces:**
- Produces: `dev/e2e-bridge.sh` that: builds the image; starts `mosquitto` (eclipse-mosquitto:2, anonymous allowed, port 1883) and `garage-bridge:dev` (tailscale disabled, dev TLS mounted, options pointing at the local Supabase via the host address and at the local mosquitto); seeds a vehicle row for a test owner with VIN `XP7YE2E000000001` and an empty state row; runs `dev/replay/publish.mjs` which publishes the Task 3 fixtures (with that VIN) over 10 s plus a `connectivity CONNECTED`; waits 5 s; queries the local Supabase and asserts: ≥ 12 `signals` rows for the VIN's vehicle, `vehicle_state.soc = 72.5` (or the last Soc published), `sleep_state = "online"`, `doors.passenger_front = true`, `bridge_seen_at` within 60 s, `api_usage.signals ≥ 12`; prints PASS/FAIL and tears down.

- [ ] **Step 1: Write the harness**; run it; iterate until PASS. Note: the ingest's `telemetry-config` manager must be disabled in this mode (`tailscale_enabled: false` ⇒ skip config registration, log once).
- [ ] **Step 2: Commit** `test(bridge): local end-to-end harness with MQTT replay`

---

### Task 7: CI build and publish

**Files:**
- Create: `.github/workflows/addon.yml`

**Steps:**
- [ ] Workflow on push to `main` touching `addon/**` or `packages/core/**`, and on tags `bridge-v*`: `docker/setup-qemu-action`, `docker/setup-buildx-action`, login to GHCR with `GITHUB_TOKEN`, build `-f addon/garage-bridge/Dockerfile .` for `linux/arm64` (BUILD_FROM aarch64 base) and `linux/amd64` as two images `ghcr.io/duncanbottrill/garage-bridge-aarch64:<version>` and `…-amd64:<version>` where version comes from `config.yaml`; on tag also push `:latest`. Also a job that runs the ingest unit tests (`npm ci && npm test` in `addon/garage-bridge/ingest`) and `shellcheck addon/garage-bridge/rootfs/**/run addon/garage-bridge/rootfs/usr/bin/*`.
- [ ] Make the GHCR packages public (one-time, owner, or document it) so the Green can pull without credentials.
- [ ] Commit `ci: build and publish the garage-bridge add-on images`

---

### Task 8: Deployment on the Green, spec §5 amendment, runbook

**Files:**
- Modify: `docs/superpowers/specs/2026-10-18-garage-slice-1-foundation-and-status-design.md` §5 (one add-on, own tailscale node, Tesla's proxy binary, MQTT via Mosquitto, config signed via proxy, cadence table, bridge secret), `docs/runbooks/tesla-setup.md` (bridge install section), `addon/garage-bridge/DOCS.md`.

**Owner steps (runbook):**
1. Tailscale admin console: enable Funnel in the tailnet policy (`nodeAttrs: [{ target: ["tag:garage"], attr: ["funnel"] }]` or the Funnel toggle), create a reusable, pre-authorised auth key tagged `tag:garage` (90-day expiry is fine; the node keeps its own key after first auth).
2. Home Assistant: install the official Mosquitto broker add-on, create a HA user `garage` for MQTT (Settings → People → Users, "can only log in from local network" off), start Mosquitto.
3. Add the repository `https://github.com/duncanbottrill/garage` (subfolder `addon` is found automatically via `repository.yaml` at the repo root? No — HA expects `repository.yaml` at the git root. Decision: keep `repository.yaml` at the **repo root** and the add-on at `/garage-bridge`? That moves files. Alternative decision used here: publish the add-on repository as a separate branch `addon-repo` or a separate repo `duncanbottrill/garage-addons` containing `repository.yaml` + `garage-bridge/` (config.yaml only needs `image:`; the Dockerfile is not needed by HA when `image` is set). Task 7's workflow syncs `addon/` to that repo on tag. Document the chosen mechanism.
4. Install Garage Bridge, fill options: Tailscale auth key, hostname `garage-bridge`, Tesla private key (paste the PEM from `~/.garage/private-key.pem`), VIN, bridge secret (from `~/.garage/vercel-secrets.env`), Supabase URL + service key, MQTT user/password. Start.
5. Verify in the add-on log: `tailscale up as garage-bridge.<tailnet>.ts.net`, `tlscert: certificate … refreshed`, `funnel status` showing `tcp://…:443 → 127.0.0.1:8443`, fleet-telemetry listening, proxy listening, ingest `resolved vehicle`, `telemetry config synced`.
6. Verify in Supabase: `vehicles.telemetry_config_hash` set and `telemetry_confirmed_at` recent; `signals` rows arriving; `vehicle_state.bridge_seen_at` fresh; the Status data changing when the car is driven.
7. Verify billing posture after 24 h: `api_usage.signals` count and the Tesla developer dashboard.

**Controller steps:** run the final whole-branch review; merge; apply 0016 to the hosted project; tag `bridge-v0.1.0` so CI publishes the images; then the owner performs steps 1–7 with me on the log output.

---

## Self-review

- **Spec §5 coverage:** Tailscale (own node, Funnel raw TCP, tailnet-only proxy) → Tasks 2, 5; Tesla proxy (Tesla's binary, our key) → Task 5; receiver + ingest → Tasks 3–5; options as the only secret channel → Task 1; eMMC constraint → batcher bounds (Task 3); heartbeat/health → Tasks 3–4; budget_mode adaptation → Task 4; config registration via signed JWS → Task 4; MQTT second sink for HA entities later → built in (fleet-telemetry publishes per-field topics; HA MQTT discovery is slice 4).
- **Open risks carried deliberately:** Funnel raw-TCP + mTLS is smoke-tested in Task 2 before anything depends on it; max fields per config is undocumented (31 fields; if Tesla rejects, Task 4's error path surfaces `telemetry_last_error` and the cadence table shrinks); `tesla-http-proxy` TLS flags are verified in Task 5 with the self-signed fallback; the HA repository layout decision is made in Task 8.
- **Deferred from the 1A.2 review, still deferred:** merge staleness guard and `p_clear` (ingest sends only fields it received, so staleness only matters against manual refresh; manual refresh is rare); narrower bridge credential than the service key.
- **Type consistency:** `BridgeEvent`, `Batcher`, `Health`, `SupabaseSink`, `BridgeToken`, `TelemetryConfigManager` names are used identically in Tasks 3, 4, 6; option keys fixed in Task 1 and read by Tasks 2, 4, 5.
