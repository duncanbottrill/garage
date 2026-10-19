#!/usr/bin/env bash
# Generates a throwaway self-signed TLS pair for local (tailscale_enabled:
# false) boots of the bridge image: dev/tls/{server.crt,server.key},
# meant to be bind-mounted read-only into the container at /data/tls so
# telemetry/run finds a cert+key without a real Tailscale node/tlscert
# loop. Not for anything else — re-running overwrites the pair, and
# dev/tls/ is gitignored.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="${REPO_ROOT}/dev/tls"
mkdir -p "${TLS_DIR}"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj "/CN=garage-bridge.dev" \
  -addext "subjectAltName=DNS:garage-bridge.dev" \
  -keyout "${TLS_DIR}/server.key" \
  -out "${TLS_DIR}/server.crt"

chmod 600 "${TLS_DIR}/server.key"
echo "wrote ${TLS_DIR}/server.crt and ${TLS_DIR}/server.key"
