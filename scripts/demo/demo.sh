#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd curl
require_cmd bash
require_cmd jq
require_cmd timeout

bash "${ROOT_DIR}/scripts/gen-env.sh"

# Reload env in case gen-env filled defaults.
cli_nb_router_setup_key="${NB_ROUTER_SETUP_KEY:-}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
if [[ -n "${cli_nb_router_setup_key}" ]]; then
  NB_ROUTER_SETUP_KEY="${cli_nb_router_setup_key}"
fi

run_with_heartbeat() {
  local label="$1"
  shift

  "$@" &
  local pid=$!
  local start_ts now_ts elapsed
  start_ts="$(date +%s)"

  while kill -0 "${pid}" >/dev/null 2>&1; do
    sleep 10
    if kill -0 "${pid}" >/dev/null 2>&1; then
      now_ts="$(date +%s)"
      elapsed="$((now_ts - start_ts))"
      log "${label}... (${elapsed}s)"
    fi
  done

  wait "${pid}"
}

log "Bringing up base stack"
dc up -d >/dev/null
dc up -d --force-recreate netbird netbird-signal >/dev/null

bash "${ROOT_DIR}/scripts/demo/keycloak-bootstrap.sh"

if [[ -z "${NB_ROUTER_SETUP_KEY:-}" ]]; then
  log "NB_ROUTER_SETUP_KEY is empty. Creating one-time reusable setup key via NetBird API"
  admin_token="$(
    curl -k -fsS -X POST "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "client_id=${NB_OIDC_CLIENT_ID}" \
      --data-urlencode 'grant_type=password' \
      --data-urlencode "username=${KC_ADMIN}" \
      --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
    | jq -r '.access_token'
  )"
  if [[ -z "${admin_token}" || "${admin_token}" == "null" ]]; then
    echo "failed to obtain Keycloak admin token for setup key creation" >&2
    exit 1
  fi

  setup_key_resp=""
  for i in $(seq 1 30); do
    if setup_key_resp="$(
      curl -k -fsS -X POST "https://${NB_DOMAIN}/api/setup-keys" \
        -H "Authorization: Bearer ${admin_token}" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"demo-router-$(date +%s)\",\"type\":\"reusable\",\"expires_in\":0,\"auto_groups\":[],\"usage_limit\":0,\"ephemeral\":false,\"allow_extra_dns_labels\":true}" 2>/dev/null
    )"; then
      break
    fi
    if (( i % 5 == 0 )); then
      log "Waiting NetBird API for setup-key creation... retry ${i}/30"
    fi
    sleep 2
  done
  if [[ -z "${setup_key_resp}" ]]; then
    echo "failed to create setup key from NetBird API after retries (last error was likely upstream 502 while service starting)" >&2
    exit 1
  fi
  NB_ROUTER_SETUP_KEY="$(printf '%s' "${setup_key_resp}" | jq -r '.key')"
  setup_key_id="$(printf '%s' "${setup_key_resp}" | jq -r '.id // empty')"
  setup_key_type="$(printf '%s' "${setup_key_resp}" | jq -r '.type // empty')"
  setup_key_expires="$(printf '%s' "${setup_key_resp}" | jq -r '.expires // empty')"
  if [[ -z "${NB_ROUTER_SETUP_KEY}" || "${NB_ROUTER_SETUP_KEY}" == "null" || -z "${setup_key_id}" ]]; then
    echo "failed to create NB_ROUTER_SETUP_KEY from NetBird API response: ${setup_key_resp}" >&2
    exit 1
  fi
  log "Created setup key id=${setup_key_id} type=${setup_key_type:-unknown} expires=${setup_key_expires:-none}"
  export NB_ROUTER_SETUP_KEY
  log "Created temporary setup key for nb-router"
fi

log "Bringing up demo profile services"
dc --profile demo up -d scim-bridge nb-router internal-app >/dev/null

log "Resetting nb-router local NetBird state"
dc --profile demo exec -T nb-router sh -lc 'netbird down >/dev/null 2>&1 || true'

log "Starting nb-router NetBird daemon"
dc --profile demo exec -T nb-router sh -lc 'pkill -x netbird >/dev/null 2>&1 || true'
dc --profile demo exec -d nb-router sh -lc '/usr/local/bin/netbird service run --log-file console >/tmp/netbird-service.log 2>&1'
for _ in $(seq 1 30); do
  if dc --profile demo exec -T nb-router sh -lc 'test -S /var/run/netbird.sock'; then
    break
  fi
  sleep 1
done

log "Logging nb-router into NetBird with setup key"
up_rc=0
if ! run_with_heartbeat "Waiting nb-router registration" \
  timeout 120 bash "${ROOT_DIR}/scripts/compose.sh" --profile demo exec -T nb-router /usr/local/bin/netbird up \
  --management-url "http://netbird:80" \
  --admin-url "https://${NB_UI_DOMAIN}" \
  --hostname nb-router \
  --setup-key "${NB_ROUTER_SETUP_KEY}" \
  --log-file console; then
  up_rc=$?
fi

status_json="$(dc --profile demo exec -T nb-router sh -lc 'netbird status --json 2>/dev/null || true' || true)"
status_mgmt_connected="$(printf '%s' "${status_json}" | jq -r '.management.connected // false' 2>/dev/null || echo false)"
status_signal_connected="$(printf '%s' "${status_json}" | jq -r '.signal.connected // false' 2>/dev/null || echo false)"
status_ip="$(printf '%s' "${status_json}" | jq -r '.netbirdIp // empty' 2>/dev/null || true)"

if [[ "${status_mgmt_connected}" != "true" || "${status_signal_connected}" != "true" || -z "${status_ip}" ]]; then
  echo "nb-router netbird up failed or timed out (120s), and status is not connected" >&2
  printf '%s\n' "${status_json}" >&2
  dc --profile demo exec -T nb-router sh -lc 'cat /var/lib/netbird/default.json 2>/dev/null | head -n 60 || true' >&2 || true
  dc --profile demo exec -T nb-router sh -lc 'tail -n 120 /tmp/netbird-service.log 2>/dev/null || true' >&2 || true
  dc --profile demo logs --tail=120 nb-router >&2 || true
  exit 1
fi

if [[ "${up_rc}" -ne 0 ]]; then
  log "nb-router up returned non-zero (${up_rc}) but peer is connected; continuing"
fi

log "Waiting scim-bridge health"
for i in $(seq 1 30); do
  if dc --profile demo exec -T scim-bridge sh -lc "wget -qO- http://127.0.0.1:8080/healthz >/dev/null" >/dev/null 2>&1; then
    break
  fi
  if (( i % 5 == 0 )); then
    log "Waiting scim-bridge health... retry ${i}/30"
  fi
  sleep 1
done
dc --profile demo exec -T scim-bridge sh -lc "wget -qO- http://127.0.0.1:8080/healthz >/dev/null"

bash "${ROOT_DIR}/scripts/demo/midpoint-create-demo-user.sh"
bash "${ROOT_DIR}/scripts/demo/scim-sync.sh"

log "Approving demo user in NetBird (if pending approval)"
admin_token_for_approve="$(
  curl -k -fsS -X POST "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${NB_OIDC_CLIENT_ID}" \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${KC_ADMIN}" \
    --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
  | jq -r '.access_token'
)"
if [[ -z "${admin_token_for_approve}" || "${admin_token_for_approve}" == "null" ]]; then
  echo "failed to obtain Keycloak admin token for NetBird user approval" >&2
  exit 1
fi

demo_nb_user_id=""
for i in $(seq 1 20); do
  users_resp="$(
    curl -k -fsS "https://${NB_DOMAIN}/api/users" \
      -H "Authorization: Bearer ${admin_token_for_approve}" \
      -H 'Accept: application/json' 2>/dev/null || true
  )"
  demo_nb_user_id="$(printf '%s' "${users_resp}" | jq -r --arg email "${DEMO_EMAIL}" --arg name "${DEMO_USERNAME}" '
    (map(select((.email // "") == $email)) | .[0].id) //
    (map(select((.name // "") == $name)) | .[0].id) //
    empty
  ' 2>/dev/null || true)"
  if [[ -n "${demo_nb_user_id}" ]]; then
    break
  fi
  if (( i % 5 == 0 )); then
    log "Waiting demo-user to appear in NetBird users... retry ${i}/20"
  fi
  sleep 2
done

if [[ -n "${demo_nb_user_id}" ]]; then
  pending_status="$(printf '%s' "${users_resp}" | jq -r --arg id "${demo_nb_user_id}" 'map(select(.id == $id)) | .[0].pending_approval // false' 2>/dev/null || echo false)"
  if [[ "${pending_status}" == "true" ]]; then
    curl -k -fsS -X POST "https://${NB_DOMAIN}/api/users/${demo_nb_user_id}/approve" \
      -H "Authorization: Bearer ${admin_token_for_approve}" \
      -H 'Content-Type: application/json' >/dev/null
    log "Approved NetBird user id=${demo_nb_user_id}"
  else
    log "NetBird user id=${demo_nb_user_id} is already approved"
  fi
else
  log "NetBird demo user not found yet in /api/users; continuing"
fi

log "Validating demo-user can get token from Keycloak"
curl -k -fsS -o /tmp/demo-token.json -X POST "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "client_id=${NB_OIDC_CLIENT_ID}" \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "username=${DEMO_USERNAME}" \
  --data-urlencode "password=${DEMO_PASSWORD}" >/dev/null

bash "${ROOT_DIR}/scripts/demo/netbird-client-sso.sh"
bash "${ROOT_DIR}/scripts/demo/verify-hello.sh"

log "Login info:"
log "Keycloak: https://${KC_HOSTNAME} (username: ${KC_ADMIN}, password: ${KC_ADMIN_PASSWORD})"
log "midPoint: https://${MP_HOSTNAME} (username: administrator, password: ${MP_ADMIN_PASSWORD:-<unset>})"
log "Demo clean:"
log "just demo-clean-netbird  # remove NetBird demo containers/volumes"
log "just demo-reset          # remove only demo profile containers"

log "Demo flow completed"
