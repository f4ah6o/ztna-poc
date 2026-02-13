#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

bash "${ROOT_DIR}/scripts/gen-env.sh"
bash "${ROOT_DIR}/scripts/demo/exitnode-bootstrap.sh"
bash "${ROOT_DIR}/scripts/demo/verify-squid-path.sh"
bash "${ROOT_DIR}/scripts/demo/verify-saas-block.sh"

log "Exit node + SquidSCAS demo flow completed"
