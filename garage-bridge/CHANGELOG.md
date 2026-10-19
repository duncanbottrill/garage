# Changelog

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
