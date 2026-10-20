#!/usr/bin/env bash
# Garage relay: forwards public TCP 443 to the Garage Bridge receiver over
# Tailscale, for owners behind CGNAT. Raw TCP passthrough: TLS (and the car's
# client certificate) terminates on the Green, never here.
#
# Run as root on a fresh Ubuntu 22.04/24.04 or Oracle Linux 8/9 VM (target:
# Oracle Cloud Always Free, VM.Standard.E2.1.Micro, London):
#   curl -fsSL https://raw.githubusercontent.com/duncanbottrill/garage/main/dev/relay/setup.sh \
#     | sudo TS_AUTHKEY='tskey-auth-...' bash
#
# No package manager is used on Oracle Linux: dnf alone exhausts the 1 GB
# shape. Tailscale comes from its static tarball and the forwarder is a
# stdlib Python script. Ubuntu uses apt + socat.
#
# Env:
#   TS_AUTHKEY   required; a reusable, pre-authorised Tailscale key (tag:garage)
#   TARGET       tailnet address of the receiver (default: the garage-bridge
#                node's tailnet IP and the add-on's tailnet-only 8443 route)
#   RELAY_NAME   tailscale hostname for this VM (default garage-relay)
#   TS_VERSION   tailscale static build to install when not using apt (1.104.1)
set -euo pipefail

: "${TS_AUTHKEY:?set TS_AUTHKEY to a reusable, pre-authorised tag:garage Tailscale auth key}"
TARGET="${TARGET:-100.64.63.100:8443}"
RELAY_NAME="${RELAY_NAME:-garage-relay}"
TS_VERSION="${TS_VERSION:-1.104.1}"
RAW_BASE="https://raw.githubusercontent.com/duncanbottrill/garage/main/dev/relay"

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo)" >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  OS=debian
else
  OS=rhel
fi

echo "==> swap (the 1 GB Always Free shape thrashes without it)"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> tailscale"
if [ "${OS}" = debian ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq socat curl ca-certificates iptables-persistent >/dev/null
  command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
else
  if ! command -v tailscale >/dev/null 2>&1; then
    case "$(uname -m)" in
      x86_64) TS_ARCH=amd64 ;;
      aarch64) TS_ARCH=arm64 ;;
      *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    TGZ="tailscale_${TS_VERSION}_${TS_ARCH}.tgz"
    TMP="$(mktemp -d)"
    curl -fsSL "https://pkgs.tailscale.com/stable/${TGZ}" -o "${TMP}/${TGZ}"
    tar -xzf "${TMP}/${TGZ}" -C "${TMP}"
    install -m 0755 "${TMP}/tailscale_${TS_VERSION}_${TS_ARCH}/tailscale" /usr/bin/tailscale
    install -m 0755 "${TMP}/tailscale_${TS_VERSION}_${TS_ARCH}/tailscaled" /usr/sbin/tailscaled
    install -m 0644 "${TMP}/tailscale_${TS_VERSION}_${TS_ARCH}/systemd/tailscaled.service" /etc/systemd/system/tailscaled.service
    install -m 0644 "${TMP}/tailscale_${TS_VERSION}_${TS_ARCH}/systemd/tailscaled.defaults" /etc/default/tailscaled
    mkdir -p /var/lib/tailscale
    rm -rf "${TMP}"
    systemctl daemon-reload
  fi
  systemctl enable --now tailscaled >/dev/null
fi
tailscale up --authkey="${TS_AUTHKEY}" --hostname="${RELAY_NAME}" --accept-dns=false
echo "    tailnet node: $(tailscale status --self --json | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -1)"

echo "==> firewall: allow inbound TCP 443"
if [ "${OS}" = rhel ]; then
  # Oracle Linux images run firewalld (only SSH open by default).
  firewall-cmd --permanent --add-port=443/tcp >/dev/null
  firewall-cmd --reload >/dev/null
else
  # Oracle's Ubuntu images ship an INPUT chain that rejects everything but SSH.
  if ! iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
  fi
  netfilter-persistent save >/dev/null
fi

echo "==> relay service (443 -> ${TARGET})"
if [ "${OS}" = rhel ]; then
  curl -fsSL "${RAW_BASE}/garage-relay.py" -o /usr/local/bin/garage-relay.py
  chmod 0755 /usr/local/bin/garage-relay.py
  EXEC="/usr/bin/python3 /usr/local/bin/garage-relay.py"
else
  EXEC="/usr/bin/socat -d TCP-LISTEN:443,fork,reuseaddr,backlog=64 TCP:${TARGET},connect-timeout=10"
fi
cat > /etc/systemd/system/garage-relay.service <<UNIT
[Unit]
Description=Garage relay: public TCP 443 -> ${TARGET} over Tailscale
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Environment=TARGET=${TARGET}
Environment=LISTEN_PORT=443
ExecStart=${EXEC}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

echo "==> keepalive (Oracle reclaims idle Always Free VMs after 7 days)"
cat > /etc/systemd/system/garage-keepalive.service <<'UNIT'
[Unit]
Description=Garage relay keepalive: ~25% CPU duty cycle so Oracle does not reclaim the VM

[Service]
Type=oneshot
ExecStart=/usr/bin/timeout 150 /bin/sh -c 'while :; do :; done'
SuccessExitStatus=124
UNIT
cat > /etc/systemd/system/garage-keepalive.timer <<'UNIT'
[Unit]
Description=Run the Garage relay keepalive every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now garage-relay.service garage-keepalive.timer >/dev/null
systemctl restart garage-relay.service
sleep 1
systemctl --no-pager --lines=3 status garage-relay.service || true

echo
echo "Relay ready. Public IPv4: $(curl -4 -fsS --max-time 5 https://api.ipify.org || echo '?')"
echo "Next: point the telemetry hostname's A record at that address, and open TCP 443"
echo "in the VCN security list (Oracle console) if you have not already."
