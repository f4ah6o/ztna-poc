#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

required=(SCIM_BRIDGE_TOKEN DEMO_USERNAME DEMO_EMAIL DEMO_PASSWORD NB_DEMO_GROUP)
for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "missing env: $v" >&2; exit 1; }
done

log "Provisioning demo user/group to Keycloak through SCIM bridge"

payload_group="$(mktemp)"
payload_user="$(mktemp)"
trap 'rm -f "${payload_group}" "${payload_user}"' EXIT

cat > "${payload_group}" <<JSON
{"displayName":"${NB_DEMO_GROUP}"}
JSON

cat > "${payload_user}" <<JSON
{
    "userName": "${DEMO_USERNAME}",
    "externalId": "${DEMO_USERNAME}",
    "active": true,
    "name": {"givenName": "Demo", "familyName": "User"},
    "emails": [{"value": "${DEMO_EMAIL}", "primary": true}],
    "password": "${DEMO_PASSWORD}",
    "groups": [{"display": "${NB_DEMO_GROUP}"}]
}
JSON

dc --profile demo cp "${payload_group}" "scim-bridge:/tmp/scim-group.json"
dc --profile demo cp "${payload_user}" "scim-bridge:/tmp/scim-user.json"

scim_post_with_retry() {
  local endpoint="$1"
  local payload_file="$2"
  local allow_failure="${3:-false}"
  local attempts=5
  local output=""
  local rc=0
  local i

  for i in $(seq 1 "${attempts}"); do
    output="$(
      dc --profile demo exec -T scim-bridge sh -lc "wget -S -O- \
        --header='Authorization: Bearer ${SCIM_BRIDGE_TOKEN}' \
        --header='Content-Type: application/json' \
        --post-file='${payload_file}' \
        'http://127.0.0.1:8080${endpoint}'" 2>&1
    )" && return 0

    rc=$?
    if (( i < attempts )); then
      log "SCIM POST ${endpoint} failed (attempt ${i}/${attempts}, rc=${rc}), retrying..."
      sleep 2
      continue
    fi
  done

  if [[ "${allow_failure}" == "true" ]]; then
    log "SCIM POST ${endpoint} failed after retries but continuing"
    printf '%s\n' "${output}" >&2
    return 0
  fi

  echo "SCIM POST ${endpoint} failed after retries (rc=${rc})" >&2
  printf '%s\n' "${output}" >&2
  return "${rc}"
}

scim_post_with_retry "/scim/v2/Groups" "/tmp/scim-group.json" true
scim_post_with_retry "/scim/v2/Users" "/tmp/scim-user.json" false

log "SCIM sync completed"
