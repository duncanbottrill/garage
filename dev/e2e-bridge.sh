#!/usr/bin/env bash
# Local end-to-end harness: builds garage-bridge:dev, boots it (tailscale
# disabled) against a real local Mosquitto (dev/compose.bridge.yaml) and the
# local Supabase, replays the Task 3 MQTT fixtures (dev/replay/publish.mjs)
# with the VIN swapped to a dedicated e2e vehicle, then asserts the result
# landed correctly in the local Supabase DB. Prints PASS/FAIL and tears
# everything down (trap, so cleanup runs on failure too). Safe to run
# repeatedly: seeding is idempotent (fixed ids, ON CONFLICT) and the
# signals/api_usage assertions are floors ("at least"), not exact counts, so
# a second run accumulating more rows still passes.
#
# Usage: dev/e2e-bridge.sh
#
# Requires: a running local Supabase (`supabase start`), Docker/Colima, and
# the `supabase` CLI to read the service role key. No secrets are read from
# disk or committed: the real service role key comes from `supabase status`
# at run time and is substituted into a scratch copy of dev/options.e2e.json
# under $HOME (NOT /private/tmp or the session scratchpad — Colima's VM only
# mounts $HOME, so a bind-mount source outside it silently becomes an empty
# directory inside the container; see dev/funnel-smoke.sh and the Task 5
# report for the same finding).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${REPO_ROOT}/dev"
COMPOSE_FILE="${DEV_DIR}/compose.bridge.yaml"
OPTIONS_TEMPLATE="${DEV_DIR}/options.e2e.json"
FIXTURES_PATH="${REPO_ROOT}/garage-bridge/ingest/test/fixtures/mqtt-samples.json"

SCRATCH_DIR="${HOME}/.garage-e2e-scratch"
RESOLVED_OPTIONS_FILE="${SCRATCH_DIR}/options.e2e.resolved.json"

IMAGE_TAG="garage-bridge:dev"
PROJECT_NAME="garage-bridge-e2e"
MOCK_SUPERVISOR_PORT=8126
BRIDGE_CONTAINER="gb-e2e-bridge"

# Fixed test identities, reused run-over-run (seeding is idempotent on
# these, not a fresh random id per run) so re-running never collides and
# never needs a `supabase db reset`.
OWNER_ID="11111111-1111-1111-1111-111111111111"
OWNER_EMAIL="task6-bridge-e2e@duncanbottrill.com"
VEHICLE_ID="22222222-2222-2222-2222-222222222222"
VIN="XP7YE2E000000001"

READY_TIMEOUT_S=60
ASSERT_TIMEOUT_S=90
ASSERT_POLL_S=3

MOCK_SUPERVISOR_PID=""

# shellcheck disable=SC2329 # invoked indirectly via the trap below
cleanup() {
  local code=$?
  echo
  echo "==== cleanup ===="
  docker-compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" down -v --remove-orphans >/dev/null 2>&1 || true
  if [ -n "${MOCK_SUPERVISOR_PID}" ]; then
    kill "${MOCK_SUPERVISOR_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${RESOLVED_OPTIONS_FILE}"
  echo "cleanup done (compose stack down, mock supervisor killed, resolved options file deleted)"
  exit "${code}"
}
trap cleanup EXIT

mkdir -p "${SCRATCH_DIR}"
chmod 700 "${SCRATCH_DIR}"

echo "==== resolving local Supabase connection (supabase status) ===="
STATUS_JSON="$(supabase status -o json 2>/dev/null)"
API_URL="$(jq -r '.API_URL' <<<"${STATUS_JSON}")"
DB_URL="$(jq -r '.DB_URL' <<<"${STATUS_JSON}")"
SERVICE_ROLE_KEY="$(jq -r '.SERVICE_ROLE_KEY' <<<"${STATUS_JSON}")"
if [ -z "${API_URL}" ] || [ -z "${DB_URL}" ] || [ -z "${SERVICE_ROLE_KEY}" ] || [ "${API_URL}" = "null" ]; then
  echo "FAIL: could not resolve Supabase API_URL/DB_URL/SERVICE_ROLE_KEY — is \`supabase start\` running?" >&2
  exit 1
fi
echo "API_URL=${API_URL}"

echo "==== generating dev TLS pair ===="
bash "${DEV_DIR}/make-dev-tls.sh"

echo "==== building ${IMAGE_TAG} ===="
docker build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base-debian:bookworm \
  -f "${REPO_ROOT}/garage-bridge/Dockerfile" \
  -t "${IMAGE_TAG}" \
  "${REPO_ROOT}"

echo "==== seeding owner + vehicle (idempotent) ===="
psql "${DB_URL}" -v ON_ERROR_STOP=1 -q <<SQL
insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('${OWNER_ID}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '${OWNER_EMAIL}', '{}'::jsonb, '{}'::jsonb, now(), now())
on conflict (id) do nothing;

insert into vehicles (id, owner_id, vin, display_name, budget_mode)
values ('${VEHICLE_ID}', '${OWNER_ID}', '${VIN}', 'E2E Test Vehicle', 'normal')
on conflict (vin) do update set owner_id = excluded.owner_id;
SQL
echo "owner=${OWNER_ID} vehicle=${VEHICLE_ID} vin=${VIN}"

echo "==== computing expected soc from fixtures (last Soc/BatteryLevel event wins) ===="
EXPECTED_SOC="$(node -e '
const fs = require("fs");
const fixtures = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
function unwrap(value) {
  if (value === "invalid") return null;
  if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
  const keys = Object.keys(value);
  if (keys.length !== 1) return value;
  const key = keys[0];
  if (key === "invalid" && value[key] === true) return null;
  if (key.endsWith("Value")) return unwrap(value[key]);
  return value;
}
function decode(raw) {
  let v;
  try { v = JSON.parse(raw); } catch { v = raw; }
  return unwrap(v);
}
let soc = null;
for (const f of fixtures) {
  if (!/\/v\/(Soc|BatteryLevel)$/.test(f.topic)) continue;
  const val = decode(f.payload);
  if (typeof val === "number" && Number.isFinite(val)) soc = val;
}
if (soc === null) throw new Error("no Soc/BatteryLevel fixture found in " + process.argv[1]);
console.log(soc);
' "${FIXTURES_PATH}")"
echo "expected soc = ${EXPECTED_SOC} (fixtures are applied in file order; a later BatteryLevel/Soc event wins over an earlier one, same as production)"

echo "==== writing resolved options file (scratch only, never committed) ===="
jq --arg key "${SERVICE_ROLE_KEY}" '.supabase_service_key = $key' "${OPTIONS_TEMPLATE}" >"${RESOLVED_OPTIONS_FILE}"
chmod 600 "${RESOLVED_OPTIONS_FILE}"

echo "==== starting mock Home Assistant Supervisor API (local testing only) ===="
python3 "${DEV_DIR}/mock-supervisor.py" "${RESOLVED_OPTIONS_FILE}" "${MOCK_SUPERVISOR_PORT}" &
MOCK_SUPERVISOR_PID=$!
sleep 1

echo "==== docker compose up (mosquitto + garage-bridge) ===="
export GARAGE_E2E_OPTIONS_FILE="${RESOLVED_OPTIONS_FILE}"
export GARAGE_E2E_SUPERVISOR_PORT="${MOCK_SUPERVISOR_PORT}"
docker-compose -f "${COMPOSE_FILE}" -p "${PROJECT_NAME}" up -d --force-recreate --remove-orphans

echo "==== waiting for ingest to resolve the vehicle and connect to MQTT (up to ${READY_TIMEOUT_S}s) ===="
READY=0
for _ in $(seq 1 "${READY_TIMEOUT_S}"); do
  LOGS="$(docker logs "${BRIDGE_CONTAINER}" 2>&1 || true)"
  if grep -q '"msg":"vehicle resolved"' <<<"${LOGS}" && grep -q '"status":"connected"' <<<"${LOGS}"; then
    READY=1
    break
  fi
  sleep 1
done
if [ "${READY}" -ne 1 ]; then
  echo "FAIL: ingest never resolved the vehicle / connected to MQTT within ${READY_TIMEOUT_S}s" >&2
  docker logs "${BRIDGE_CONTAINER}" --tail 200 || true
  exit 1
fi

CONFIG_SKIP_COUNT="$(grep -c '"msg":"tailscale disabled: skipping telemetry config manager (dev/e2e)"' <<<"${LOGS}" || true)"
ENSURE_LOG_COUNT="$(grep -c '"msg":"telemetry config ensure' <<<"${LOGS}" || true)"
PROXY_IDLE_COUNT="$(grep -c 'proxy: tesla_private_key is empty, no vehicle command key configured; idling' <<<"${LOGS}" || true)"
echo "telemetry-config skip logged ${CONFIG_SKIP_COUNT} time(s); telemetry-config ensure (proxy-calling) logged ${ENSURE_LOG_COUNT} time(s) (must be 0 — tailscale_enabled:false never constructs the manager, so the proxy client code path is structurally unreachable, not just unobserved)"
echo "proxy idling (no key configured) logged ${PROXY_IDLE_COUNT} time(s) — confirms the proxy itself never had a command key and made no calls either"

echo "==== running MQTT replay (dev/replay/publish.mjs) ===="
if [ ! -d "${DEV_DIR}/replay/node_modules" ]; then
  (cd "${DEV_DIR}/replay" && npm install --no-audit --no-fund)
fi
MQTT_URL="mqtt://127.0.0.1:1883" REPLAY_VIN="${VIN}" REPLAY_DURATION_MS=10000 FIXTURES_PATH="${FIXTURES_PATH}" \
  node "${DEV_DIR}/replay/publish.mjs"

echo "==== asserting against the local Supabase DB (polling up to ${ASSERT_TIMEOUT_S}s for the heartbeat + flush ticks) ===="
ELAPSED=0
PASS=0
while [ "${ELAPSED}" -lt "${ASSERT_TIMEOUT_S}" ]; do
  RESULT="$(psql "${DB_URL}" -tA -F '|' -c "
    select
      (select count(*) from signals where vehicle_id = '${VEHICLE_ID}'),
      coalesce((select soc = ${EXPECTED_SOC} from vehicle_state where vehicle_id = '${VEHICLE_ID}'), false),
      coalesce((select sleep_state = 'online' from vehicle_state where vehicle_id = '${VEHICLE_ID}'), false),
      coalesce((select (doors->>'passenger_front')::boolean = true from vehicle_state where vehicle_id = '${VEHICLE_ID}'), false),
      coalesce((select bridge_seen_at is not null and now() - bridge_seen_at < interval '60 seconds' from vehicle_state where vehicle_id = '${VEHICLE_ID}'), false),
      coalesce((select sum(count) from api_usage where owner_id = '${OWNER_ID}' and category = 'signals' and month = date_trunc('month', now())::date), 0)
  ;")"
  IFS='|' read -r SIGNALS_COUNT SOC_OK SLEEP_OK DOORS_OK SEEN_OK API_USAGE_SIGNALS <<<"${RESULT}"

  SIGNALS_OK=0
  [ "${SIGNALS_COUNT}" -ge 12 ] && SIGNALS_OK=1
  USAGE_OK=0
  [ "${API_USAGE_SIGNALS}" -ge 12 ] && USAGE_OK=1

  if [ "${SIGNALS_OK}" -eq 1 ] && [ "${SOC_OK}" = "t" ] && [ "${SLEEP_OK}" = "t" ] \
    && [ "${DOORS_OK}" = "t" ] && [ "${SEEN_OK}" = "t" ] && [ "${USAGE_OK}" -eq 1 ]; then
    PASS=1
    break
  fi
  sleep "${ASSERT_POLL_S}"
  ELAPSED=$((ELAPSED + ASSERT_POLL_S))
done

echo
echo "==== assertion results ===="
echo "signals rows for vehicle   : ${SIGNALS_COUNT} (want >= 12)"
echo "vehicle_state.soc          : ok=${SOC_OK} (want = ${EXPECTED_SOC})"
echo "vehicle_state.sleep_state  : ok=${SLEEP_OK} (want = online)"
echo "doors.passenger_front      : ok=${DOORS_OK} (want = true)"
echo "bridge_seen_at within 60s  : ok=${SEEN_OK}"
echo "api_usage.signals (owner)  : ${API_USAGE_SIGNALS} (want >= 12)"
echo "telemetry-config skip logged ${CONFIG_SKIP_COUNT}x; ensure/proxy-calling logged ${ENSURE_LOG_COUNT}x (must be 0)"

if [ "${PASS}" -eq 1 ] && [ "${ENSURE_LOG_COUNT}" -eq 0 ] && [ "${CONFIG_SKIP_COUNT}" -ge 1 ]; then
  echo
  echo "RESULT: PASS"
  exit 0
else
  echo
  echo "RESULT: FAIL"
  docker logs "${BRIDGE_CONTAINER}" --tail 300 || true
  exit 1
fi
