# Changelog

## 0.3.0

Gets the command proxy ready for the Garage iPhone and Mac app, which
calls it over the tailnet.

- The proxy's listener (tailnet port 4443) now presents the Let's Encrypt
  certificate for the node's tailnet name, from `tailscale cert`, instead
  of a self-signed one, so iOS and macOS trust it without pinning.
  `tlscert` writes it to `/data/proxy-tls/` after the telemetry
  certificate step and every 24 hours, in both modes, and restarts the
  proxy when the certificate changes. In hostname mode it re-checks every
  30 seconds until the tailnet name is known and retries a failed
  `tailscale cert` after 10 minutes.
- On a first start with Tailscale enabled the proxy waits up to 120
  seconds for that certificate, then falls back to a self-signed one
  until `tlscert` replaces it. An existing pair (the 0.2.0 self-signed
  one included) is used until then. With `tailscale_enabled` off the
  proxy generates and keeps a self-signed pair, as before.
- The ingest publishes the proxy URL, `https://<tailnet name>:4443`, to
  the new `vehicles.proxy_base_url` column (migration 0017) on the first
  heartbeat after the tailnet name is known, and again whenever it
  changes; with `tailscale_enabled` off it writes `null`. A failed write
  is retried on the next heartbeat.

## 0.2.0

Fixes Tesla rejecting the telemetry configuration with `hostname domain
does not match with partner account`: the receiver now runs under a
hostname in the partner domain instead of the Tailscale `*.ts.net` name.

- New option `telemetry_hostname` (e.g. `telemetry.duncanbottrill.com`).
  When set, the add-on creates its own private CA in `/data/ca` (P-256,
  10 years) and serves fleet-telemetry with a 90-day certificate for that
  name, renewed when under 30 days remain. Tesla trusts it through the
  configuration's `ca` field, so no public certificate is needed.
- The receiver (container port 8443/tcp) is published on the Green's port
  443, so an IPv4 forward of external TCP 443 (to the Green's port 443)
  and a direct IPv6 connection both work; the host port can be changed in
  the add-on's Network section. In hostname mode the 443 Tailscale Funnel
  is no longer published (an earlier mapping is cleared); the tailnet-only
  4443 serve for the proxy stays, and 8443 is also served to the tailnet
  only (never Funnel) as the route for a relay host when the home is
  behind CGNAT. DOCS covers the CGNAT, relay and IPv6 routes.
- The private CA re-issues the leaf when `server.key` does not match
  `server.crt`, and re-creates the CA when `ca.key` does not match
  `ca.pem`. The leaf has no CN (the name is in the SAN), so names longer
  than 64 characters work.
- `telemetry_hostname` is trimmed and lower-cased; any other character
  outside `[a-z0-9.-]` (spaces inside the name included) is an error in
  both tlscert (which idles) and the ingest (which exits at start).
- The ingest registers `telemetry_hostname` with the private CA and no
  longer waits for Tailscale in that mode. A registration attempt that
  was skipped because the certificate was not ready yet, or that failed
  with an error, is retried after 30 seconds instead of at the next
  5-minute poll; after 5 failed fast retries in a row the 5-minute poll
  takes over until an attempt gets through.
- With `telemetry_hostname` empty everything behaves as in 0.1.0 (the
  Funnel fallback, which Tesla does not accept for registration).

## 0.1.0

First working release of the Garage Bridge add-on.

- Joins the tailnet as its own Tailscale node (userspace networking) using
  a reusable, pre-authorised `tag:garage` auth key, and publishes TCP 443
  through Tailscale Funnel to the receiver. Startup failures (consumed or
  expired key, missing pre-authorisation, Funnel not granted) are logged
  with the likely cause and retried every 30 seconds.
- Gets a Let's Encrypt certificate for `<hostname>.<tailnet>.ts.net` with
  `tailscale cert`, builds the CA chain Tesla needs, re-checks daily, and
  restarts the receiver when the certificate is renewed.
- Runs Tesla's `fleet-telemetry` v0.9.5 on 8443, publishing vehicle
  fields, alerts, errors and connectivity to the local Mosquitto broker.
- Runs Tesla's `tesla-http-proxy` v0.4.1 on `127.0.0.1:4443` with the
  owner's vehicle-command key. A key pasted into the single-line option
  field has its line breaks restored, and an invalid key is reported
  instead of crash-looping.
- Node 22 ingest: subscribes to the MQTT topics, batches `signals` rows
  into Supabase, merges `vehicle_state` through `merge_vehicle_state`
  (failed patches are re-queued under newer data, invalid values dropped
  per key), ignores no-information values (`invalid`, `*Unknown`, `SNA`),
  and sends a health heartbeat every 30 seconds.
- Registers the Fleet Telemetry configuration through the proxy with a
  cadence table set by the vehicle's budget mode, confirms it only when
  Tesla reports the car synced this exact configuration with the virtual
  key paired, backs off on failure (including cars Tesla skipped, e.g.
  `missing_key`), and counts every Fleet API call against the usage
  budget.
- Images for `aarch64` and `amd64` are built by CI and pulled from GHCR;
  the version tag is pushed only from `bridge-v*` git tags.
