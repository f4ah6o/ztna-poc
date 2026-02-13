#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

log "Sending explicit proxy request from demo-client via exitnode-gw:3129"
page=""
for i in $(seq 1 10); do
  page="$(
    dc --profile demo --profile exitnode exec -T demo-client sh -lc \
      'NO_PROXY= no_proxy= http_proxy=http://exitnode-gw:3129 https_proxy=http://exitnode-gw:3129 wget -qO- --timeout=15 http://example.com' || true
  )"
  if [[ "${page}" == *"Example Domain"* ]]; then
    break
  fi
  sleep 2
done

if [[ "${page}" != *"Example Domain"* ]]; then
  echo "proxy path verification failed: unexpected HTTP response" >&2
  printf '%s\n' "${page}" >&2
  exit 1
fi

if ! dc --profile exitnode exec -T squid sh -lc "tail -n 200 /var/log/squid/shadow.log | grep -qi 'example.com'"; then
  echo "proxy path verification failed: example.com not found in shadow.log" >&2
  dc --profile exitnode exec -T squid sh -lc 'tail -n 80 /var/log/squid/shadow.log || true' >&2 || true
  exit 1
fi

log "Verified: explicit proxy path and squid shadow log"
