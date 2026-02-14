#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ARTIFACTS_ROOT="${ROOT_DIR}/artifacts/loadtest"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

log() {
  printf '[loadtest] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing env: ${name}" >&2
    exit 1
  fi
}

dc() {
  bash "${ROOT_DIR}/scripts/compose.sh" "$@"
}

timestamp_utc() {
  date -u +"%Y%m%dT%H%M%SZ"
}

ensure_run_dirs() {
  local run_id="$1"
  mkdir -p "${ARTIFACTS_ROOT}/${run_id}/raw"
}

prom_query_range() {
  local query="$1"
  local start_ts="$2"
  local end_ts="$3"
  local step="${4:-15s}"
  local out=""
  if out="$(curl -fsS --get 'http://127.0.0.1:9090/api/v1/query_range' \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${start_ts}" \
    --data-urlencode "end=${end_ts}" \
    --data-urlencode "step=${step}" 2>/dev/null)"; then
    printf '%s\n' "${out}"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local query_uri
    query_uri="$(jq -rn --arg v "${query}" '$v|@uri')"
    if out="$(dc --profile observability exec -T prometheus sh -lc \
      "wget -qO- 'http://127.0.0.1:9090/api/v1/query_range?query=${query_uri}&start=${start_ts}&end=${end_ts}&step=${step}'" 2>/dev/null)"; then
      printf '%s\n' "${out}"
      return 0
    fi
  fi

  echo '{"status":"error","data":{"result":[]}}'
}
