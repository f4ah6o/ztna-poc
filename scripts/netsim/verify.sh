#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../demo/common.sh"

log() {
  printf '[netsim] %s\n' "$*"
}

run_netsim() {
  bash "${ROOT_DIR}/scripts/netsim/run.sh" "$@"
}

log "Creating topology"
run_netsim create

log "Checking baseline connectivity (client -> saas)"
dc --profile netsim exec -T netsim sh -lc 'ip netns exec client ping -c 2 -W 1 10.88.0.2 >/tmp/netsim-baseline-ping.log'

log "Applying degraded preset"
run_netsim apply-preset --name degraded

dc --profile netsim exec -T netsim sh -lc 'ip netns exec client ping -c 5 -W 1 10.88.0.2 >/tmp/netsim-degraded-ping.log || true'

log "Applying outage (link down) and asserting failure"
run_netsim link --ns gateway --if veth-gw-saas --state down
if dc --profile netsim exec -T netsim sh -lc 'ip netns exec client ping -c 1 -W 1 10.88.0.2 >/tmp/netsim-outage-ping.log 2>&1'; then
  echo "expected ping failure during outage, but ping succeeded" >&2
  exit 1
fi

log "Recovering link"
run_netsim link --ns gateway --if veth-gw-saas --state up

log "Resetting to normal preset"
run_netsim apply-preset --name normal

log "Verifying recovery"
dc --profile netsim exec -T netsim sh -lc 'ip netns exec client ping -c 2 -W 1 10.88.0.2 >/tmp/netsim-recover-ping.log'

log "netsim verify completed"
