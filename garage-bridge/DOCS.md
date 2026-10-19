# Garage Bridge

Receives your Tesla's Fleet Telemetry stream on your own Home Assistant
box and writes it to Garage's Supabase database. It also registers the
telemetry configuration with the car, signing the request with your
vehicle-command key.

## What runs inside the add-on

Five s6-supervised services:

- **tailscale**: joins your tailnet as its own node (userspace networking)
  and publishes port 443 to the internet with Tailscale Funnel, so Tesla's
  servers can reach the receiver at `<hostname>.<tailnet>.ts.net`.
- **tlscert**: gets a Let's Encrypt certificate for that name with
  `tailscale cert`, re-checks it daily, and restarts the receiver when the
  certificate is renewed.
- **telemetry**: Tesla's `fleet-telemetry` receiver on port 8443 (behind
  the Funnel), publishing every record to the local Mosquitto broker.
- **proxy**: Tesla's `tesla-http-proxy` on `127.0.0.1:4443`, which signs
  Fleet API requests with your private key. Only the ingest talks to it.
- **ingest**: reads the MQTT records, writes signals and vehicle state to
  Supabase, and registers the telemetry configuration with the car through
  the proxy.

## Before you install

You need all of these. Most failed first starts come from a missing one.

1. **Tailscale account and tailnet policy.** In the Tailscale admin
   console, Access controls, make sure the policy:
   - declares the tag, owned by the admin: `"tagOwners": { "tag:garage": ["autogroup:admin"] }`;
   - grants Funnel to it: `"nodeAttrs": [{ "target": ["tag:garage"], "attr": ["funnel"] }]`.
2. **MagicDNS and HTTPS certificates enabled** for the tailnet (DNS page in
   the admin console). Without HTTPS certificates `tailscale cert` fails and
   Funnel cannot start.
3. **A reusable, pre-authorised auth key tagged `tag:garage`** (Settings,
   Keys, Generate auth key: Reusable on, Pre-approved on, Tags `tag:garage`).
   A one-off key is consumed the first time the add-on starts and every
   restart after that fails. A 90-day expiry is fine: once the node has
   joined it keeps its own node key.
4. **Mosquitto broker add-on** installed and started, and a Home Assistant
   user called `garage` for it (Settings, People, Users; turn off "Can only
   log in from the local network"). The add-on logs in to Mosquitto as this
   user.
5. **The Tesla virtual key paired with the car.** At the car, on a phone
   with the Tesla app, open `https://tesla.com/_ak/garage.duncanbottrill.com`
   and approve. Until this is done Tesla accepts the telemetry
   configuration request but skips the car (see Troubleshooting).
6. **The car registered in Garage.** The ingest waits, logging
   `vehicle not found yet, retrying`, until a `vehicles` row with this VIN
   exists.
7. **No stale Tailscale node with the same name.** If an earlier install or
   test left a machine called `garage-bridge` in the admin console, remove
   it first. Otherwise the new node becomes `garage-bridge-1` and its
   FQDN, certificate and telemetry hostname change with it.

## Installing

Settings, Add-ons, Add-on store, the menu (top right), Repositories: add
`https://github.com/duncanbottrill/garage`. "Garage Bridge" then appears in
the store; install it.

Home Assistant does not build the image. It pulls
`ghcr.io/duncanbottrill/garage-bridge-aarch64` (Home Assistant Green) or
`-amd64` from GHCR at the version in the add-on's `config.yaml`. CI pushes
that tag only when a `bridge-v<version>` git tag is pushed. Both GHCR
packages must be public (a one-time setting by the repository owner),
because the Green has no registry credentials.

## Configuration

Fill the options on the Configuration tab, then start the add-on.

| Option | Type | Required | Default | Where the value comes from |
| --- | --- | --- | --- | --- |
| `tailscale_enabled` | bool | yes | `true` | Leave `true`. `false` is for the local dev harness only. |
| `tailscale_authkey` | password | when `tailscale_enabled` | empty | The reusable, pre-authorised `tag:garage` key from step 3. |
| `tailscale_hostname` | string | yes | `garage-bridge` | The node name on the tailnet; the FQDN becomes `<this>.<tailnet>.ts.net`. |
| `tesla_private_key` | password | when `tailscale_enabled` | empty | The vehicle-command private key PEM, `~/.garage/private-key.pem` (kept in 1Password). See below. |
| `tesla_vin` | string | yes | empty | The car's VIN, exactly as registered in Garage. |
| `garage_api_base` | url | yes | `https://garage.duncanbottrill.com` | The Garage backend. Leave the default. |
| `bridge_secret` | password | yes | empty | Minted once per owner by the backend owner (admin `POST /api/admin/bridge-secret`) and shown only once. |
| `supabase_url` | url | yes | empty | The Garage Supabase project URL, from the backend owner. |
| `supabase_service_key` | password | yes | empty | The Supabase service-role key, held by the backend owner. |
| `mqtt_host` | string | yes | `core-mosquitto` | The Mosquitto add-on's hostname. Leave the default. |
| `mqtt_port` | port | yes | `1883` | Leave the default. |
| `mqtt_username` | string | no | empty | `garage`, the Home Assistant user from step 4. |
| `mqtt_password` | password | no | empty | That user's password. |
| `log_level` | list | yes | `info` | `trace`, `debug`, `info`, `warning` or `error`. |

### Pasting the Tesla private key

The PEM is several lines long. Password fields on the Configuration tab are
single-line, so a key pasted there loses its line breaks. The add-on
restores them before handing the key to the proxy, and logs an error if the
result still is not a valid key. The most reliable way is the YAML editor
(the menu on the Configuration tab, Edit in YAML) with a block scalar:

```yaml
tesla_private_key: |
  -----BEGIN EC PRIVATE KEY-----
  <base64 line 1>
  <base64 line 2>
  <base64 line 3>
  -----END EC PRIVATE KEY-----
```

Copy every line of `~/.garage/private-key.pem`, including the BEGIN and END
lines, and indent each one by two spaces under `tesla_private_key: |`.

## A healthy start

Open the Log tab after starting. In order, you should see:

1. `tailscale up as garage-bridge.<tailnet>.ts.net`, followed by the
   `tailscale funnel status` and `serve status` output, which should list
   TCP port 443 on that name forwarded to `127.0.0.1:8443`.
2. `tlscert: certificate for garage-bridge.<tailnet>.ts.net refreshed`.
3. `wrote /data/config.json (mqtt broker core-mosquitto:1883, log_level info)`
   and `telemetry: starting fleet-telemetry on 0.0.0.0:8443`.
4. `proxy: starting tesla-http-proxy on 127.0.0.1:4443`.
5. Ingest JSON lines: `"msg":"ingest starting"`, then
   `"msg":"vehicle resolved"`.
6. Within about ten minutes:
   `"msg":"telemetry config ensure","result":{"changed":true}`. This
   means Tesla reports the car has synced this add-on's configuration
   (hostname and fields match, virtual key paired). The ingest has no
   separate "bridge token ok" line: a bridge token problem shows up as
   `"msg":"telemetry config ensure not synced"` with
   `"reason":"token_error"`, and `vehicles.telemetry_last_error` holds
   `token:<code>`.

Once the car is awake and streaming, Garage's status data changes and in
Supabase `vehicles.telemetry_confirmed_at` is recent, `signals` rows are
arriving, and `vehicle_state.bridge_seen_at` updates every 30 seconds. The
ingest does not log individual signals at `info`.

## Troubleshooting

- **`tailscale: 'tailscale up' failed` or `node is in state NeedsLogin`**:
  the auth key was already used (it was not reusable), has expired, or may
  not apply `tag:garage`. Create a new reusable, pre-authorised key with the
  tag and paste it into `tailscale_authkey`.
- **`node is in state NeedsMachineAuth`**: the key is not pre-authorised
  and device approval is on. Approve the machine in the admin console, or
  use a pre-authorised key.
- **`could not publish port 443 through Tailscale Funnel`**: Funnel is not
  granted to `tag:garage` (the `nodeAttrs` entry in step 1), or HTTPS
  certificates are off.
- **`tlscert: tailscale cert failed; retrying in 10 minutes`**: HTTPS
  certificates are not enabled for the tailnet, or Let's Encrypt is rate
  limiting this name. Enable them and wait for the retry.
- **`tlscert: waiting for /data/tailscale/fqdn`** repeating: the tailscale
  service has not come up. Look further up the log for its error.
- **`telemetry config ensure not synced` with `post_failed` and
  `telemetry_last_error` set to `skipped:missing_key`**: Tesla skipped the
  car because the virtual key is not paired (on the Fleet API this shows as
  "Access not granted" or `missing_key`). Pair it (step 5 above). The add-on
  retries on its own, backing off from 15 minutes up to 6 hours, so it picks
  the pairing up without a restart. Other `skipped:` reasons
  (`unsupported_hardware`, `unsupported_firmware`, `max_configs`) need
  action on the Tesla side.
- **`proxy: tesla_private_key is not a valid PEM private key`**: paste the
  key again in the YAML block form shown above.
- **The node is called `garage-bridge-1`**: an old `garage-bridge` machine
  still exists in the admin console. Remove it and restart the add-on.
- **`vehicle not found yet, retrying`**: `tesla_vin` does not match a car
  registered in Garage.

## Ports

`9090/tcp` serves `fleet-telemetry`'s Prometheus metrics inside the
container and is the add-on's watchdog check. The telemetry receiver is
reached only through the Tailscale Funnel; no host port is opened for it.

## Building locally

Docker on the development Mac is Colima (arm64 native), so `docker build`
produces the same architecture as the Green. From the repo root:

```
docker build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base-debian:bookworm \
  --build-arg BUILD_ARCH=aarch64 \
  -f garage-bridge/Dockerfile -t garage-bridge:dev .
```

`BUILD_ARCH` defaults to `aarch64` and feeds the `io.hass.arch` label; pass
`amd64` (with a matching `BUILD_FROM`) to build for that architecture.
`dev/e2e-bridge.sh` runs the image end to end against a local Supabase.
