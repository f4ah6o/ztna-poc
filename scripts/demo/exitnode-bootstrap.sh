#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd bash
require_cmd curl
require_cmd jq
require_timeout

bash "${ROOT_DIR}/scripts/gen-env.sh"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

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
dc --profile demo up -d demo-client >/dev/null
dc --profile exitnode up -d memcached squidscas exitnode-gw squid >/dev/null

bash "${ROOT_DIR}/scripts/demo/keycloak-bootstrap.sh"

if [[ -z "${NB_EXITNODE_SETUP_KEY:-}" ]]; then
  log "NB_EXITNODE_SETUP_KEY is empty. Creating setup key via NetBird API"

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
    echo "failed to obtain Keycloak admin token for exitnode setup key creation" >&2
    exit 1
  fi

  setup_key_resp=""
  for i in $(seq 1 30); do
    if setup_key_resp="$(
      curl -k -fsS -X POST "https://${NB_DOMAIN}/api/setup-keys" \
        -H "Authorization: Bearer ${admin_token}" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"demo-exitnode-$(date +%s)\",\"type\":\"reusable\",\"expires_in\":0,\"auto_groups\":[],\"usage_limit\":0,\"ephemeral\":false,\"allow_extra_dns_labels\":true}" 2>/dev/null
    )"; then
      break
    fi
    if (( i % 5 == 0 )); then
      log "Waiting NetBird API for exitnode setup-key... retry ${i}/30"
    fi
    sleep 2
  done

  if [[ -z "${setup_key_resp}" ]]; then
    echo "failed to create exitnode setup key from NetBird API" >&2
    exit 1
  fi

  NB_EXITNODE_SETUP_KEY="$(printf '%s' "${setup_key_resp}" | jq -r '.key')"
  if [[ -z "${NB_EXITNODE_SETUP_KEY}" || "${NB_EXITNODE_SETUP_KEY}" == "null" ]]; then
    echo "failed to parse setup key response: ${setup_key_resp}" >&2
    exit 1
  fi

  log "Created temporary setup key for exitnode"
fi

log "Resetting exitnode-gw local NetBird state"
dc --profile exitnode exec -T exitnode-gw sh -lc 'netbird down >/dev/null 2>&1 || true'

dc --profile exitnode exec -T exitnode-gw sh -lc 'pkill -x netbird >/dev/null 2>&1 || true'
log "Starting exitnode-gw NetBird daemon"
dc --profile exitnode exec -d exitnode-gw sh -lc '/usr/local/bin/netbird service run --log-file console >/tmp/netbird-exitnode.log 2>&1'
for _ in $(seq 1 30); do
  if dc --profile exitnode exec -T exitnode-gw sh -lc 'test -S /var/run/netbird.sock'; then
    break
  fi
  sleep 1
done

log "Logging exitnode-gw into NetBird"
if ! run_with_heartbeat "Waiting exitnode-gw registration" \
  run_with_timeout 120 bash "${ROOT_DIR}/scripts/compose.sh" --profile exitnode exec -T exitnode-gw /usr/local/bin/netbird up \
  --management-url "http://netbird:80" \
  --admin-url "https://${NB_UI_DOMAIN}" \
  --hostname nb-exitnode \
  --setup-key "${NB_EXITNODE_SETUP_KEY}" \
  --log-file console; then
  echo "exitnode-gw netbird up failed" >&2
  dc --profile exitnode exec -T exitnode-gw sh -lc 'tail -n 120 /tmp/netbird-exitnode.log 2>/dev/null || true' >&2 || true
  exit 1
fi

log "Applying exitnode iptables rules"
dc --profile exitnode exec -T exitnode-gw sh -lc '
  set -eu
  command -v iptables >/dev/null 2>&1
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || true

  iptables -t nat -D PREROUTING -i wt0 -p tcp --dport 80 -j REDIRECT --to-ports 3128 2>/dev/null || true
  iptables -t nat -D PREROUTING -i wt0 -p tcp --dport 443 -j REDIRECT --to-ports 3128 2>/dev/null || true
  iptables -D FORWARD -i wt0 -p udp --dport 443 -j DROP 2>/dev/null || true
  iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true

  iptables -t nat -A PREROUTING -i wt0 -p tcp --dport 80 -j REDIRECT --to-ports 3128
  iptables -t nat -A PREROUTING -i wt0 -p tcp --dport 443 -j REDIRECT --to-ports 3128
  iptables -A FORWARD -i wt0 -p udp --dport 443 -j DROP
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
'

log "Exit node bootstrap completed"
