#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

log "Checking blocked SaaS domain policy (.dropbox.com)"
set +e
resp="$(
  dc --profile demo --profile exitnode exec -T demo-client sh -lc \
    'NO_PROXY= no_proxy= http_proxy=http://exitnode-gw:3129 https_proxy=http://exitnode-gw:3129 wget -S -O- --timeout=20 https://www.dropbox.com 2>&1'
)"
rc=$?
set -e

if [[ ${rc} -eq 0 ]]; then
  echo "expected dropbox to be blocked but request succeeded" >&2
  printf '%s\n' "${resp}" >&2
  exit 1
fi

if [[ "${resp}" != *"403"* && "${resp}" != *"Access Denied"* && "${resp}" != *"denied"* ]]; then
  echo "blocked request failed, but expected deny indicators not found" >&2
  printf '%s\n' "${resp}" >&2
fi

if ! dc --profile exitnode exec -T squid sh -lc "tail -n 200 /var/log/squid/shadow.log | grep -qi 'dropbox.com'"; then
  echo "expected dropbox access record in shadow.log" >&2
  dc --profile exitnode exec -T squid sh -lc 'tail -n 80 /var/log/squid/shadow.log || true' >&2 || true
  exit 1
fi

log "Verified: blocked SaaS policy is applied"
