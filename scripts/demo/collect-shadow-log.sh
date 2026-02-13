#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

lines="${1:-50}"
log "Last ${lines} lines from squid shadow log"
dc --profile exitnode exec -T squid sh -lc "tail -n ${lines} /var/log/squid/shadow.log"
