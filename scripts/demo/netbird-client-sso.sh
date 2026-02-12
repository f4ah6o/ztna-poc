#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

required=(NB_DOMAIN NB_UI_DOMAIN KC_HOSTNAME KC_REALM)
for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "missing env: $v" >&2; exit 1; }
done

log "Starting demo-client daemon"
dc --profile demo up -d demo-client >/dev/null
dc --profile demo exec -T demo-client sh -lc 'pkill -x netbird >/dev/null 2>&1 || true'
dc --profile demo exec -d demo-client sh -lc '/usr/local/bin/netbird service run --log-file console >/tmp/netbird-service.log 2>&1'
for _ in $(seq 1 20); do
  if dc --profile demo exec -T demo-client sh -lc 'test -S /var/run/netbird.sock'; then
    break
  fi
  sleep 1
done

log "Starting NetBird SSO login for demo-client (on-prem: ${NB_DOMAIN})"
log "Complete login in browser when URL is shown below"
if open_url "https://${KC_HOSTNAME}/realms/${KC_REALM}/device"; then
  log "Opened browser for Keycloak device login page"
else
  log "Could not auto-open browser. Open manually: https://${KC_HOSTNAME}/realms/${KC_REALM}/device"
fi

dc --profile demo exec demo-client /usr/local/bin/netbird \
  --management-url "http://netbird:80" \
  --admin-url "https://${NB_UI_DOMAIN}" \
  --hostname demo-client \
  up \
  --log-file console
