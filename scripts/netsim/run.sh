#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../demo/common.sh"

require_cmd bash

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <netsim-cli-args...>" >&2
  exit 1
fi

bash "${ROOT_DIR}/scripts/gen-env.sh"

if ! dc --profile netsim ps --status running --services | grep -qx "netsim"; then
  dc --profile netsim up -d netsim >/dev/null
fi

dc --profile netsim exec -T netsim python -m netsim.cli --config /app/config.yaml "$@"
