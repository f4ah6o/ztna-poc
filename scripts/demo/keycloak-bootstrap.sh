#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

required=(KC_ADMIN KC_ADMIN_PASSWORD KC_REALM NB_OIDC_CLIENT_ID NB_UI_DOMAIN)
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

log "Keycloak bootstrap completed"
