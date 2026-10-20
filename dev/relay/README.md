# Garage relay (for owners behind CGNAT)

Tesla will only stream Fleet Telemetry to a hostname under the partner
account's root domain, and the car connects straight to it with mTLS. If the
Home Assistant Green sits behind carrier-grade NAT (router WAN address in
100.64.0.0/10) and has no public IPv6, a tiny relay VM with a public IPv4
forwards TCP 443 to the add-on's tailnet-only 8443 route. Nothing is decrypted
on the relay.

## Oracle Cloud Always Free (£0)

1. Sign up at https://cloud.oracle.com (Always Free tier; home region
   **UK South (London)**). A card is needed for identity checks only.
2. Compute → Instances → **Create instance**: name `garage-relay`, image
   **Ubuntu 24.04** or **Oracle Linux 9** (the script handles both), shape **VM.Standard.E2.1.Micro** (Always Free; the Ampere
   A1 shape also works if capacity is available), default VCN/public subnet,
   **assign a public IPv4 address**, and download the generated SSH private key.
3. Networking → Virtual cloud networks → your VCN → the public subnet →
   its **security list** → **Add ingress rule**: source `0.0.0.0/0`, protocol
   TCP, destination port `443`.
4. SSH in and run the setup script with a reusable, pre-authorised
   `tag:garage` Tailscale auth key (never paste the key anywhere else):

   ```bash
   ssh -i ~/Downloads/ssh-key-*.key ubuntu@<public-ip>   # user is `opc` on Oracle Linux
   curl -fsSL https://raw.githubusercontent.com/duncanbottrill/garage/main/dev/relay/setup.sh \
     | sudo TS_AUTHKEY='tskey-auth-...' bash
   ```

5. Add an **A record** for the telemetry hostname (e.g. `garage-bridge`) →
   the relay's public IPv4. Set the add-on option `telemetry_hostname` to the
   same name and restart Garage Bridge.
6. Check from outside (OpenSSL 3, not macOS LibreSSL):

   ```bash
   openssl s_client -connect garage-bridge.duncanbottrill.com:443 \
     -servername garage-bridge.duncanbottrill.com </dev/null 2>&1 | grep -E 'issuer=|Acceptable'
   ```

   `issuer=O=Garage Bridge CA` (plus a client-certificate request on
   OpenSSL 3) means the car will reach the receiver.

`TARGET` defaults to the garage-bridge node's tailnet IP and port 8443; pass
`TARGET=<ip>:8443` if the node ever changes address (`tailscale status` on
the relay lists it). Oracle reclaims idle Always Free VMs after seven days of
low usage, so the script installs a timer that keeps CPU use around 25%.
