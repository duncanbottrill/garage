#!/usr/bin/env bash
# Funnel mTLS smoke test.
#
# Builds garage-bridge:dev, runs it with tailscale_enabled, brings a real
# Tailscale node up inside the container, gets a real Let's Encrypt cert
# via `tailscale cert`, stands in for the `telemetry` service with an
# openssl mTLS echo server on 8443, and proves from the Mac (NOT on the
# tailnet) that a TLS handshake requesting a client certificate reaches
# that process through Tailscale Funnel as raw TCP.
#
# Usage: TS_AUTHKEY=tskey-auth-... dev/funnel-smoke.sh
#
# The auth key is taken only from the TS_AUTHKEY environment variable. It
# is written to a throwaway options file in the scratchpad (never inside
# this repo) and never printed or logged by this script.
#
# The real run scripts read their config via `bashio::config`, which talks
# to the real Home Assistant Supervisor API (http://supervisor) — there is
# none outside an actual HA host. For local docker-only testing this script
# starts dev/mock-supervisor.py, a tiny HTTP server that answers the one
# endpoint bashio::config needs (GET /addons/self/options/config) from the
# same options file, and points the container at it via the SUPERVISOR_API
# env var. This does not change the add-on's production behavior.
set -euo pipefail

: "${TS_AUTHKEY:?Set TS_AUTHKEY to a Tailscale auth key (see ~/.garage/vercel-secrets.env)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="/private/tmp/claude-501/-Users-duncanbottrill/39fa406e-49a3-4b11-ab98-0cd8cbd0ac10/scratchpad"
OPTIONS_FILE="${SCRATCH_DIR}/options.smoke.json"
CONTAINER_NAME="garage-bridge-smoke"
IMAGE_TAG="garage-bridge:dev"
TS_HOSTNAME="garage-bridge-smoke"
MOCK_SUPERVISOR_PORT=8126
MOCK_SUPERVISOR_PID=""

TS_SOCK="/run/tailscale/tailscaled.sock"

BLOCK_PATTERNS='enable HTTPS Certificates|HTTPS Certificates is not enabled|login\.tailscale\.com/.*funnel|Funnel is not enabled|funnel.*not allowed|flag to enable it|tailnet policy'

# shellcheck disable=SC2329 # invoked indirectly via the trap below
cleanup() {
  echo
  echo "==== cleanup ===="
  docker exec "${CONTAINER_NAME}" tailscale --socket="${TS_SOCK}" logout >/dev/null 2>&1 || true
  docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  if [ -n "${MOCK_SUPERVISOR_PID}" ]; then
    kill "${MOCK_SUPERVISOR_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${OPTIONS_FILE}"
  echo "cleanup done (container stopped/removed, mock supervisor killed, options file deleted)"
  echo "NOTE: the node may still show in the Tailscale admin console; remove it there if so."
}
trap cleanup EXIT

mkdir -p "${SCRATCH_DIR}"

echo "==== build ===="
docker build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base-debian:bookworm \
  -f "${REPO_ROOT}/addon/garage-bridge/Dockerfile" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

echo "==== writing options file (scratchpad only) ===="
cat > "${OPTIONS_FILE}" <<JSON
{
  "tailscale_enabled": true,
  "tailscale_authkey": "${TS_AUTHKEY}",
  "tailscale_hostname": "${TS_HOSTNAME}",
  "tesla_private_key": "",
  "tesla_vin": "",
  "garage_api_base": "https://garage.duncanbottrill.com",
  "bridge_secret": "",
  "supabase_url": "",
  "supabase_service_key": "",
  "mqtt_host": "core-mosquitto",
  "mqtt_port": 1883,
  "mqtt_username": "",
  "mqtt_password": "",
  "log_level": "info"
}
JSON
chmod 600 "${OPTIONS_FILE}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "==== starting mock Supervisor API (local testing only) ===="
python3 "${REPO_ROOT}/dev/mock-supervisor.py" "${OPTIONS_FILE}" "${MOCK_SUPERVISOR_PORT}" &
MOCK_SUPERVISOR_PID=$!
sleep 1

echo "==== run container ===="
docker run -d --name "${CONTAINER_NAME}" \
  -v "${OPTIONS_FILE}:/data/options.json:ro" \
  -e "SUPERVISOR_API=http://host.docker.internal:${MOCK_SUPERVISOR_PORT}" \
  -e "SUPERVISOR_TOKEN=garage-smoke-dev" \
  "${IMAGE_TAG}"

check_blocked() {
  local logs
  logs="$(docker logs "${CONTAINER_NAME}" 2>&1)"
  if grep -qiE "${BLOCK_PATTERNS}" <<<"${logs}"; then
    echo
    echo "==== BLOCKED ===="
    echo "Tailscale/tailnet policy is blocking this smoke test. Exact message(s):"
    grep -iE "${BLOCK_PATTERNS}" <<<"${logs}"
    echo "=================="
    exit 1
  fi
}

echo "==== waiting for tailscale node + FQDN ===="
FQDN=""
for _ in $(seq 1 90); do
  check_blocked
  if FQDN="$(docker exec "${CONTAINER_NAME}" cat /data/tailscale/fqdn 2>/dev/null)" && [ -n "${FQDN}" ]; then
    break
  fi
  sleep 2
done
if [ -z "${FQDN}" ]; then
  echo "FAIL: tailscale node never came up / no FQDN written" >&2
  docker logs "${CONTAINER_NAME}" --tail 200 || true
  exit 1
fi
echo "FQDN: ${FQDN}"

echo "==== waiting for tlscert (tailscale cert via Let's Encrypt) ===="
CERT_READY=0
for _ in $(seq 1 90); do
  check_blocked
  if docker exec "${CONTAINER_NAME}" test -s /data/tls/server.crt \
      && docker exec "${CONTAINER_NAME}" test -s /data/tls/server.key; then
    CERT_READY=1
    break
  fi
  sleep 2
done
if [ "${CERT_READY}" -ne 1 ]; then
  echo "FAIL: /data/tls/server.crt never materialized" >&2
  docker logs "${CONTAINER_NAME}" --tail 200 || true
  exit 1
fi
echo "cert present at /data/tls/server.crt"

echo "==== ca.pem chain subjects ===="
docker exec "${CONTAINER_NAME}" sh -c '
  rm -f /tmp/cablock*.pem
  i=0
  awk "/BEGIN CERTIFICATE/{i++; f=\"/tmp/cablock\" i \".pem\"} {print > f} /END CERTIFICATE/{close(f)}" /data/tls/ca.pem
  for f in /tmp/cablock*.pem; do
    [ -f "$f" ] || continue
    echo "-- $f --"
    openssl x509 -noout -subject -in "$f"
    rm -f "$f"
  done
'

echo "==== starting stand-in mTLS server (telemetry placeholder stays as-is) ===="
docker exec -d "${CONTAINER_NAME}" openssl s_server \
  -accept 8443 \
  -cert /data/tls/server.crt \
  -key /data/tls/server.key \
  -Verify 1 \
  -CAfile /data/tls/server.crt \
  -www
sleep 2

echo "==== tailscale funnel status / serve status (from inside container) ===="
docker exec "${CONTAINER_NAME}" tailscale --socket="${TS_SOCK}" funnel status || true
docker exec "${CONTAINER_NAME}" tailscale --socket="${TS_SOCK}" serve status || true

if command -v tailscale >/dev/null 2>&1; then
  echo "==== Mac tailscale status (informational only; Mac is not on this tailnet) ===="
  tailscale status 2>&1 | head -5 || true
fi

echo "==== openssl s_client from the Mac (default, TLS1.3) ===="
S_CLIENT_OUT="$(openssl s_client -connect "${FQDN}:443" -servername "${FQDN}" </dev/null 2>&1 || true)"
echo "${S_CLIENT_OUT}" | grep -E "Acceptable client certificate CA names|Verify return code|CertificateRequest" || echo "(no matching lines in default-TLS output)"

echo "==== openssl s_client from the Mac (-tls1_2) ===="
S_CLIENT_TLS12_OUT="$(openssl s_client -connect "${FQDN}:443" -servername "${FQDN}" -tls1_2 </dev/null 2>&1 || true)"
echo "${S_CLIENT_TLS12_OUT}" | grep -E "Acceptable client certificate CA names|Verify return code|CertificateRequest" || echo "(no matching lines in TLS1.2 output)"

echo "==== presented certificate subject/issuer ===="
CERT_SUBJECT="$(openssl s_client -connect "${FQDN}:443" -servername "${FQDN}" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer 2>/dev/null || true)"
echo "${CERT_SUBJECT}"

HANDSHAKE_OK=0
if grep -qE "Acceptable client certificate CA names|CertificateRequest" <<<"${S_CLIENT_OUT}${S_CLIENT_TLS12_OUT}"; then
  HANDSHAKE_OK=1
fi

CERT_OK=0
if grep -q "${FQDN}" <<<"${CERT_SUBJECT}" && grep -qiE "let's encrypt|LETSENCRYPT" <<<"${CERT_SUBJECT}"; then
  CERT_OK=1
fi

echo
if [ "${HANDSHAKE_OK}" -eq 1 ] && [ "${CERT_OK}" -eq 1 ]; then
  echo "RESULT: PASS"
  echo "evidence: client-cert request reached our process through Funnel, and the presented cert matches ${FQDN} and is issued by Let's Encrypt."
  EXIT_CODE=0
else
  echo "RESULT: FAIL"
  echo "handshake_ok=${HANDSHAKE_OK} cert_ok=${CERT_OK}"
  EXIT_CODE=1
fi

exit "${EXIT_CODE}"
