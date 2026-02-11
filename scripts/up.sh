#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "${ROOT_DIR}/scripts/gen-env.sh"
docker compose -f "${ROOT_DIR}/compose.yaml" up -d
docker compose -f "${ROOT_DIR}/compose.yaml" ps
