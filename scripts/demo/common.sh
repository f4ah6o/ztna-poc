#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/compose.yaml"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

log() {
  printf '[demo] %s\n' "$*"
}

open_url() {
  local url="$1"

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${url}" >/dev/null 2>&1 &
    return 0
  fi

  if command -v wslview >/dev/null 2>&1; then
    wslview "${url}" >/dev/null 2>&1 &
    return 0
  fi

  if command -v open >/dev/null 2>&1; then
    open "${url}" >/dev/null 2>&1 &
    return 0
  fi

  return 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

require_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    return 0
  fi

  echo "missing command: timeout (or gtimeout/perl fallback)" >&2
  exit 1
}

run_with_timeout() {
  local seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@"
    return $?
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}" "$@"
    return $?
  fi

  # macOS default shells often miss timeout/gtimeout.
  perl -e 'alarm shift; exec @ARGV' "${seconds}" "$@"
}

compose_base_cmd() {
  local cmd
  printf -v cmd 'docker compose -f %q' "${COMPOSE_FILE}"
  shift 0
  for arg in "$@"; do
    printf -v cmd '%s %q' "${cmd}" "${arg}"
  done
  printf '%s' "${cmd}"
}

dc() {
  if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" "$@"
  else
    local cmd
    cmd="$(compose_base_cmd "$@")"
    sg docker -c "${cmd}"
  fi
}
