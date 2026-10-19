# Garage Bridge

Tesla Fleet Telemetry receiver, command signing proxy, and Supabase ingest
for the Garage project, packaged as a Home Assistant add-on.

## What it does

Five s6-supervised services run inside the add-on container:

- **tailscale** — joins the Tailscale tailnet so Tesla's Fleet Telemetry
  servers can reach this add-on over a stable, authenticated hostname.
- **tlscert** — provisions the TLS certificate the telemetry receiver and
  proxy present.
- **telemetry** — `fleet-telemetry`, Tesla's official receiver for streamed
  vehicle data.
- **proxy** — `tesla-http-proxy` from `vehicle-command`, which signs
  commands sent to the vehicle.
- **ingest** — forwards telemetry and command results into Supabase and
  MQTT for the rest of Garage to consume.

This task (Task 1 of Plan 1B) only establishes the skeleton: all five
services are placeholders that log a line and sleep. Later tasks replace
each placeholder with its real implementation.

## Configuration

| Option | Description |
| --- | --- |
| `tailscale_enabled` | Whether the add-on joins a Tailscale tailnet. |
| `tailscale_authkey` | Tailscale auth key (leave blank to authenticate interactively). |
| `tailscale_hostname` | Hostname to advertise on the tailnet. |
| `tesla_private_key` | Private key used to sign commands sent to the vehicle. |
| `tesla_vin` | VIN of the vehicle this bridge serves. |
| `garage_api_base` | Base URL of the Garage web app's API. |
| `bridge_secret` | Shared secret authenticating requests between this bridge and Garage. |
| `supabase_url` | Supabase project URL. |
| `supabase_service_key` | Supabase service-role key used for ingest writes. |
| `mqtt_host` | MQTT broker host (defaults to the Home Assistant Mosquitto add-on). |
| `mqtt_port` | MQTT broker port. |
| `mqtt_username` | MQTT username, if required. |
| `mqtt_password` | MQTT password, if required. |
| `log_level` | Log verbosity: `trace`, `debug`, `info`, `warning`, or `error`. |

## Ports

`9090/tcp` exposes `fleet-telemetry`'s Prometheus metrics internally; it is
also used as the add-on's watchdog check.

## Installing

Settings → Add-ons → Add-on store → ⋮ (top right) → Repositories → add
`https://github.com/duncanbottrill/garage` → Add. "Garage Bridge" then
appears in the store; install it from there.

The add-on images (`ghcr.io/duncanbottrill/garage-bridge-aarch64` and
`ghcr.io/duncanbottrill/garage-bridge-amd64`) are built and pushed by CI
(`.github/workflows/addon.yml`) and pulled from GHCR — Home Assistant does
not build the image itself. The two GHCR packages must be set to public
(one-time, by the repository owner) so the Green can pull them without
needing its own registry credentials.

## Building locally

Docker on this Mac is Colima (arm64 native), so `docker build` produces the
same architecture as the Green. From the repo root:

```
docker build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base-debian:bookworm \
  --build-arg BUILD_ARCH=aarch64 \
  -f garage-bridge/Dockerfile -t garage-bridge:dev .
```

`BUILD_ARCH` defaults to `aarch64` and feeds the `io.hass.arch` label; pass
`amd64` (with a matching `BUILD_FROM`) when building for that architecture.

## Status

Skeleton only — services are placeholders. Not yet functional end to end.
