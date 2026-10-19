# Garage Bridge

Receives your Tesla's Fleet Telemetry stream on your own Home Assistant
box and writes it to Garage's Supabase database. It also registers the
telemetry configuration with the car, signing the request with your
vehicle-command key.

## What runs inside the add-on

Five s6-supervised services:

- **tailscale**: joins your tailnet as its own node (userspace networking)
  and serves the command proxy (4443) to the tailnet only. With a
  `telemetry_hostname` it also serves the receiver (8443) to the tailnet
  only, as the route for a relay host (see [Behind CGNAT?](#behind-cgnat)).
  Without a
  `telemetry_hostname` it also publishes port 443 to the internet with
  Tailscale Funnel (the fallback; see [Public hostname](#public-hostname-required)).
- **tlscert**: with `telemetry_hostname` set, issues the receiver's
  certificate for that name from the add-on's own private CA, re-checks it
  daily and restarts the receiver when it is renewed. Without it, gets a
  Let's Encrypt certificate for `<hostname>.<tailnet>.ts.net` with
  `tailscale cert` instead.
- **telemetry**: Tesla's `fleet-telemetry` receiver, listening on port 8443
  inside the container and published on the Green's port 443 (the router
  forwards external TCP 443 there), publishing every record to the local
  Mosquitto broker.
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
     Only the Funnel fallback needs this grant; with `telemetry_hostname`
     set, Funnel is not used.
2. **MagicDNS and HTTPS certificates enabled** for the tailnet (DNS page in
   the admin console). Without HTTPS certificates `tailscale cert` fails and
   Funnel cannot start. Again only needed for the Funnel fallback.
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
   FQDN changes with it (and, in the Funnel fallback, its certificate and
   telemetry hostname too).
8. **A public telemetry hostname, its DNS record and a route in from the
   internet** (an IPv4 port-forward, IPv6, or a relay). See the next
   section.

## Public hostname (required)

Tesla rejects a telemetry configuration whose hostname is not under the
partner account's root domain, with `hostname domain does not match with
partner account`. Garage's partner domain is `garage.duncanbottrill.com`, so
the root domain is `duncanbottrill.com` and the receiver needs a name under
it, for example `telemetry.duncanbottrill.com`. A Tailscale
`*.ts.net` Funnel name can never pass this check.

1. **DNS.** At the DNS provider for `duncanbottrill.com`, add an `A` record
   for the chosen name pointing at the home's public IPv4 address. If the
   ISP changes that address, the record has to follow it (update it by hand
   or use the provider's dynamic DNS). Behind CGNAT this does not work; see
   [Behind CGNAT?](#behind-cgnat) and [IPv6 route](#ipv6-route).
2. **Router port-forward.** Give the Green a fixed LAN address (a DHCP
   reservation), then forward external TCP 443 to the Green's LAN address,
   port 443. On an eero: the eero app, Settings, Network settings,
   Reservations & port forwarding, pick the Green, Add a port forward,
   external port 443, internal port 443, TCP. The add-on publishes the
   receiver on the Green's port 443 (the container itself listens on 8443).
   If another add-on already uses port 443 on the Green, change the host
   port in this add-on's Network section and forward external 443 to that
   port instead; the IPv6 route then no longer works, because IPv6 has no
   port translation.
3. **The option.** Set `telemetry_hostname` to the chosen name and restart
   the add-on.

**The private CA.** The receiver's certificate does not come from a public
CA. The add-on creates its own certificate authority on first start, in
`/data/ca` (a P-256 key and a self-signed certificate, `CN=Garage Bridge CA`,
valid for 10 years), and issues the receiver a 90-day certificate for
`telemetry_hostname` from it. The name is in the certificate's
subjectAltName; the subject is just `O=Garage Bridge`, since a CN cannot
hold a name longer than 64 characters. If a key file no longer matches its
certificate, the add-on re-issues the leaf, or re-creates the CA (and then
the leaf). Tesla is told to trust that CA through the
`ca` field of the telemetry configuration, so the car accepts the
certificate even though no browser would. The leaf renews itself when it
has less than 30 days left (about every 60 days) and the receiver restarts
to load it. Deleting `/data/ca` makes the add-on create a new CA on its next
start; that changes the CA the configuration names, and since the
configuration hash covers `ca_sha256`, the ingest re-registers the car
automatically.

**Checking it from outside.** From a machine that is not on the home
network (a phone hotspot will do):

```
openssl s_client -connect telemetry.duncanbottrill.com:443 \
  -servername telemetry.duncanbottrill.com </dev/null 2>&1 \
  | grep -E 'Acceptable client certificate|subject=|issuer='
```

A working setup prints the subject `O=Garage Bridge`, the issuer
`CN=Garage Bridge CA`, and `Acceptable client certificate CA names`
followed by Tesla's issuing CAs: the receiver is asking for the car's client
certificate. A timeout means the DNS record or the port-forward is wrong.

On a Mac, the `openssl` in `/usr/bin` is LibreSSL, which does not print
the `Acceptable client certificate CA names` list. Use Homebrew's OpenSSL 3
(`$(brew --prefix openssl)/bin/openssl s_client ...`), or take the
`issuer=... Garage Bridge CA` line plus a completed handshake as proof.

**The Funnel fallback.** With `telemetry_hostname` empty, the add-on
behaves as 0.1.0 did: Funnel publishes 443 at
`<tailscale_hostname>.<tailnet>.ts.net` with a Let's Encrypt certificate.
The receiver is reachable that way, but Tesla does not accept that hostname
for registration, so the car never streams.

### Behind CGNAT?

If the router's WAN (internet) address is in `100.64.0.0/10`
(`100.64.0.0` to `100.127.255.255`), or differs from what an outside "what
is my IP" page reports, the ISP puts the home behind carrier-grade NAT and
an IPv4 port-forward can never be reached from the internet. Options:

- **IPv6** (no NAT), if the ISP provides it: see [IPv6 route](#ipv6-route).
- **A relay host** with a public IPv4 address (a small VPS) on the same
  tailnet. In hostname mode the add-on serves the receiver to the tailnet
  only (never Funnel) on `garage-bridge.<tailnet>.ts.net:8443`. The relay
  forwards public TCP 443 to that address as raw TCP: SNI passthrough, NO
  TLS termination, so the car still sees the private-CA certificate and
  completes mTLS with the receiver. For example:

  ```
  socat TCP-LISTEN:443,fork,reuseaddr TCP:garage-bridge.<tailnet>.ts.net:8443
  ```

  or an nginx `stream` block (not `http`):

  ```
  stream {
    server {
      listen 443;
      proxy_pass garage-bridge.<tailnet>.ts.net:8443;
    }
  }
  ```

  Point the `A` record at the relay's public address. The tailnet policy
  must let the relay reach `tag:garage` on TCP 8443 (the default allow-all
  policy does). The add-on logs `serving fleet-telemetry on tailnet TCP
  8443` when the route is up.

### IPv6 route

IPv6 addresses are globally routable, so with IPv6 the internet reaches
the Green directly on port 443, with no port translation and no CGNAT in
the way.

1. **Turn IPv6 on at the router.** On an eero: the eero app, Settings,
   Network settings, IPv6.
2. **Open TCP 443 to the Green.** IPv6 has no NAT, but the router's
   firewall still blocks inbound connections. On an eero, open the port on
   the Green's reservation (Reservations & port forwarding, the Green, TCP
   443). Whether the eero applies that opening to the Green's IPv6 address
   has not been verified here; check from outside (below).
3. **Find the Green's global IPv6 address.** Home Assistant: Settings,
   System, Network, the network adapter, IPv6. Use the address starting
   with `2` (global), not `fe80:` (link-local) or `fd` (local only).
4. **DNS.** Add an `AAAA` record for the telemetry hostname (the same name
   as the `A` record) pointing at that address. If the A route does not
   work (CGNAT with no relay), leave the `A` record out, so that clients
   do not try a dead IPv4 address first.
5. **Check it** from an outside machine with IPv6:
   `openssl s_client -6 -connect <telemetry hostname>:443 -servername <telemetry hostname> </dev/null`.

Caveats: the car has to reach IPv6 over its cellular link, and that is
not verified; if it cannot, only the IPv4 or relay route works for it. If
the ISP rotates the home's IPv6 prefix, the Green's address changes and
the `AAAA` record has to be updated.

Inside the add-on, fleet-telemetry is configured for `0.0.0.0:8443`, but
Go listens dual-stack on `[::]:8443` for that address. Tested locally
(Docker 29 in Colima, not on Home Assistant OS itself), Docker forwards an
IPv6 connection to the published host port 443 into the container in both
network setups: on an IPv4-only container network `docker-proxy` listens
on `[::]:443` and forwards to the container's IPv4 address, and on an
IPv6-enabled network an `ip6tables` DNAT rule sends it to the container's
IPv6 address on 8443. Both completed the TLS handshake with the
private-CA certificate.

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
| `telemetry_hostname` | string | yes, in practice | empty | The public receiver name under `duncanbottrill.com`, e.g. `telemetry.duncanbottrill.com` (see Public hostname). Empty selects the Funnel fallback, which Tesla does not accept for registration. |
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

Open the Log tab after starting. With `telemetry_hostname` set you should
see these (the services start in parallel, so the first lines can
interleave):

1. `tlscert: telemetry_hostname is telemetry.duncanbottrill.com; serving
   fleet-telemetry with the add-on's private CA (/data/ca), not a Tailscale
   certificate`, then `tlscert: private-CA certificate for
   telemetry.duncanbottrill.com issued` (`unchanged` on later starts;
   `renewed` on the first start after upgrading from 0.1.0, or after a
   renewal) and, when it changed, `tlscert: restarting fleet-telemetry to
   load it`.
2. `wrote /data/config.json (mqtt broker core-mosquitto:1883, log_level info)`
   and `telemetry: starting fleet-telemetry on 0.0.0.0:8443`.
3. `tailscale up as garage-bridge.<tailnet>.ts.net`, then `tailscale:
   telemetry_hostname is set; not publishing 443 through Funnel (telemetry
   arrives via the router port-forward or a relay), serving 4443 and 8443
   to the tailnet only`, `tailscale: serving fleet-telemetry on tailnet TCP
   8443 (tailnet only, for a relay host behind CGNAT; not Funnel)`, then
   the `funnel status` and `serve status` output: serve lists TCP 4443 and
   8443, Funnel lists nothing. A Tailscale problem does not hold up the
   receiver or the registration.
4. `proxy: starting tesla-http-proxy on 127.0.0.1:4443`.
5. Ingest JSON lines: `"msg":"ingest starting"`,
   `"msg":"telemetry registration uses telemetry_hostname (private CA)"`,
   then `"msg":"vehicle resolved"`.
6. Within about ten minutes:
   `"msg":"telemetry config ensure","result":{"changed":true}`. This
   means Tesla reports the car has synced this add-on's configuration
   (hostname and fields match, virtual key paired). The ingest has no
   separate "bridge token ok" line: a bridge token problem shows up as
   `"msg":"telemetry config ensure not synced"` with
   `"reason":"token_error"`, and `vehicles.telemetry_last_error` holds
   `token:<code>`.

In the Funnel fallback (no `telemetry_hostname`) step 1 is instead
`tlscert: certificate for garage-bridge.<tailnet>.ts.net refreshed`, after
`tailscale up`, and the serve status lists TCP 443 forwarded to
`127.0.0.1:8443` as well.

Once the car is awake and streaming, Garage's status data changes and in
Supabase `vehicles.telemetry_confirmed_at` is recent, `signals` rows are
arriving, and `vehicle_state.bridge_seen_at` updates every 30 seconds. The
ingest does not log individual signals at `info`.

## Troubleshooting

- **`telemetry config ensure not synced` with `post_failed` and
  `telemetry_last_error` containing `hostname domain does not match with
  partner account`**: `telemetry_hostname` is empty (the Funnel fallback)
  or not under `duncanbottrill.com`. Set it as described in Public
  hostname.
- **`tlscert: telemetry_hostname '...' is not a valid hostname`** or
  **`... is not a valid DNS name`**, with the ingest logging `ingest fatal`
  and restarting: fix the option (letters, digits, hyphens and dots only,
  no spaces inside the name; spaces at the ends and upper case are fine)
  and restart.
- **`"msg":"telemetry config skipped: private CA not ready yet"`** for more
  than a minute: tlscert has not written the certificate. Look for a
  `tlscert:` error further up the log.
- **The car never connects although the configuration is synced**: run the
  outside check in Public hostname. A timeout is the DNS record or the
  port-forward (external 443 to the Green's port 443), or the home is behind
  CGNAT (see Behind CGNAT?).
- **`tailscale: could not serve TCP 8443 to the tailnet`**: only the relay
  route is affected; the router port-forward and IPv6 still work. Check
  the `serve status` output.
- **`tailscale: 'tailscale up' failed` or `node is in state NeedsLogin`**:
  the auth key was already used (it was not reusable), has expired, or may
  not apply `tag:garage`. Create a new reusable, pre-authorised key with the
  tag and paste it into `tailscale_authkey`.
- **`node is in state NeedsMachineAuth`**: the key is not pre-authorised
  and device approval is on. Approve the machine in the admin console, or
  use a pre-authorised key.
- **`could not publish port 443 through Tailscale Funnel`** (Funnel
  fallback only): Funnel is not granted to `tag:garage` (the `nodeAttrs`
  entry in step 1), or HTTPS certificates are off.
- **`could not publish the proxy port 4443 on the tailnet`** (hostname
  mode): `tailscale serve` failed; read the serve output just above it in
  the log, and check that the node is up and the tailnet policy allows
  `tag:garage`.
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

`8443/tcp` is the telemetry receiver (mTLS). The container listens on 8443
and Home Assistant maps it to the Green's port 443, so an IPv4 forward of
external TCP 443 and a direct IPv6 connection both arrive on 443. Change
the host port in the add-on's Network section if 443 is taken. In hostname
mode it is also served to the tailnet on 8443 (for a relay); in the Funnel
fallback it is reached through Funnel on 443.

`9090/tcp` serves `fleet-telemetry`'s Prometheus metrics inside the
container and is the add-on's watchdog check; it is not mapped to the host.

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
