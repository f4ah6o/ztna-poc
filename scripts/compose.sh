#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/compose.yaml"

compose_base_cmd() {
  local cmd
  printf -v cmd 'docker compose -f %q' "${COMPOSE_FILE}"
  for arg in "$@"; do
    printf -v cmd '%s %q' "${cmd}" "${arg}"
  done
  printf '%s' "${cmd}"
}

if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  exec docker compose -f "${COMPOSE_FILE}" "$@"
fi

if command -v sg >/dev/null 2>&1; then
  cmd="$(compose_base_cmd "$@")"
  exec sg docker -c "${cmd}"
fi

echo "docker daemon access is not available for this shell." >&2
echo "Use a shell with docker group access, or run via: sg docker -c 'docker compose ...'" >&2
exit 1
