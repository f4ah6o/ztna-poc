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

dc --profile demo exec -T scim-bridge sh -lc "wget -qO- \
  --header='Authorization: Bearer ${SCIM_BRIDGE_TOKEN}' \
  --header='Content-Type: application/json' \
  --post-file=/tmp/scim-group.json \
  http://127.0.0.1:8080/scim/v2/Groups >/dev/null || true"

dc --profile demo exec -T scim-bridge sh -lc "wget -qO- \
  --header='Authorization: Bearer ${SCIM_BRIDGE_TOKEN}' \
  --header='Content-Type: application/json' \
  --post-file=/tmp/scim-user.json \
  http://127.0.0.1:8080/scim/v2/Users >/dev/null"

log "SCIM sync completed"
