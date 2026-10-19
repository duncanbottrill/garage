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

## Status

Skeleton only — services are placeholders. Not yet functional end to end.
