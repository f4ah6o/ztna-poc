#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_SCRIPT="${ROOT_DIR}/scripts/compose.sh"

run_docker_cmd() {
  if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker "$@"
    return
  fi

  if command -v sg >/dev/null 2>&1; then
    local cmd="docker"
    local arg
    for arg in "$@"; do
      printf -v cmd '%s %q' "${cmd}" "${arg}"
    done
    sg docker -c "${cmd}"
    return
  fi

  echo "docker daemon access is not available for this shell." >&2
  exit 1
}

bash "${COMPOSE_SCRIPT}" --profile demo rm -sfv demo-client internal-app nb-router || true
bash "${COMPOSE_SCRIPT}" rm -sfv netbird netbird-signal netbird-dashboard || true

project="${COMPOSE_PROJECT_NAME:-$(basename "${ROOT_DIR}")}"
volumes=(
  "${project}_nb_data"
  "${project}_nb_router_data"
  "${project}_nb_client_data"
)

run_docker_cmd volume rm "${volumes[@]}" >/dev/null 2>&1 || true
echo "[demo-clean] removed NetBird containers and volumes for project '${project}'"
