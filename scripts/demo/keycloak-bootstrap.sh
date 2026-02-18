#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

required=(
  KC_ADMIN
  KC_ADMIN_PASSWORD
  KC_REALM
  NB_OIDC_CLIENT_ID
  NB_UI_DOMAIN
  DEMO_USERNAME
  DEMO_EMAIL
  DEMO_PASSWORD
  NB_DEMO_GROUP
)
for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "missing env: $v" >&2; exit 1; }
done

log "Bootstrapping Keycloak realm/client settings for on-prem NetBird"

for _ in $(seq 1 60); do
  if dc exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "${KC_ADMIN}" \
    --password "${KC_ADMIN_PASSWORD}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

dc exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "${KC_ADMIN}" \
  --password "${KC_ADMIN_PASSWORD}" >/dev/null

if ! dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get "realms/${KC_REALM}" >/dev/null 2>&1; then
  dc exec -T keycloak /opt/keycloak/bin/kcadm.sh create realms \
    -s realm="${KC_REALM}" \
    -s enabled=true >/dev/null
fi

netbird_client_id="$(dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients -r "${KC_REALM}" -q clientId="${NB_OIDC_CLIENT_ID}" --fields id --format csv --noquotes 2>/dev/null | tr -d '\r' | head -n1)"
if [[ -z "${netbird_client_id}" ]]; then
  dc exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r "${KC_REALM}" \
    -s clientId="${NB_OIDC_CLIENT_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s serviceAccountsEnabled=false \
    -s rootUrl="https://${NB_UI_DOMAIN}" \
    -s baseUrl="https://${NB_UI_DOMAIN}" \
    -s 'redirectUris=["https://'"${NB_UI_DOMAIN}"'/*","https://'"${NB_UI_DOMAIN}"'","https://'"${NB_UI_DOMAIN}"'/silent-auth"]' \
    -s 'webOrigins=["+"]' \
    -s 'attributes."oauth2.device.authorization.grant.enabled"="true"' >/dev/null
  netbird_client_id="$(dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients -r "${KC_REALM}" -q clientId="${NB_OIDC_CLIENT_ID}" --fields id --format csv --noquotes | tr -d '\r' | head -n1)"
else
  dc exec -T keycloak /opt/keycloak/bin/kcadm.sh update "clients/${netbird_client_id}" -r "${KC_REALM}" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s rootUrl="https://${NB_UI_DOMAIN}" \
    -s baseUrl="https://${NB_UI_DOMAIN}" \
    -s 'redirectUris=["https://'"${NB_UI_DOMAIN}"'/*","https://'"${NB_UI_DOMAIN}"'","https://'"${NB_UI_DOMAIN}"'/silent-auth"]' \
    -s 'webOrigins=["+"]' \
    -s 'attributes."oauth2.device.authorization.grant.enabled"="true"' >/dev/null
fi

group_id="$(dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get groups -r "${KC_REALM}" --fields id,name \
  | jq -r --arg group "${NB_DEMO_GROUP}" '.[] | select(.name == $group) | .id' \
  | head -n1)"
if [[ -z "${group_id}" ]]; then
  dc exec -T keycloak /opt/keycloak/bin/kcadm.sh create groups -r "${KC_REALM}" -s name="${NB_DEMO_GROUP}" >/dev/null
  group_id="$(dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get groups -r "${KC_REALM}" --fields id,name \
    | jq -r --arg group "${NB_DEMO_GROUP}" '.[] | select(.name == $group) | .id' \
    | head -n1)"
fi

demo_user_id="$(dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get users -r "${KC_REALM}" -q username="${DEMO_USERNAME}" --fields id,username --format csv --noquotes 2>/dev/null \
  | tr -d '\r' \
  | awk -F, 'NR==1{print $1}')"
if [[ -z "${demo_user_id}" ]]; then
  dc exec -T keycloak /opt/keycloak/bin/kcadm.sh create users -r "${KC_REALM}" \
    -s username="${DEMO_USERNAME}" \
    -s enabled=true \
    -s email="${DEMO_EMAIL}" \
    -s emailVerified=true \
    -s firstName=Demo \
    -s lastName=User >/dev/null
  demo_user_id="$(dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get users -r "${KC_REALM}" -q username="${DEMO_USERNAME}" --fields id,username --format csv --noquotes 2>/dev/null \
    | tr -d '\r' \
    | awk -F, 'NR==1{print $1}')"
fi

if [[ -z "${demo_user_id}" ]]; then
  echo "failed to resolve demo user id for ${DEMO_USERNAME}" >&2
  exit 1
fi

dc exec -T keycloak /opt/keycloak/bin/kcadm.sh update "users/${demo_user_id}" -r "${KC_REALM}" \
  -s email="${DEMO_EMAIL}" \
  -s emailVerified=true \
  -s enabled=true >/dev/null

dc exec -T keycloak /opt/keycloak/bin/kcadm.sh set-password -r "${KC_REALM}" \
  --username "${DEMO_USERNAME}" \
  --new-password "${DEMO_PASSWORD}" >/dev/null

if [[ -n "${group_id}" ]]; then
  if ! dc exec -T keycloak /opt/keycloak/bin/kcadm.sh get "users/${demo_user_id}/groups" -r "${KC_REALM}" \
    | jq -e --arg gid "${group_id}" '.[] | select(.id == $gid)' >/dev/null; then
    dc exec -T keycloak /opt/keycloak/bin/kcadm.sh update "users/${demo_user_id}/groups/${group_id}" -r "${KC_REALM}" >/dev/null
  fi
fi

log "Keycloak bootstrap completed (realm/client/demo user/group)"
