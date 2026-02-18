#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq

SCENARIO="keycloak-auth"
PROFILE="steady"
RATE="200"
DURATION="5m"
REPLICAS="1"

for arg in "$@"; do
  case "$arg" in
    scenario=*) SCENARIO="${arg#*=}" ;;
    profile=*) PROFILE="${arg#*=}" ;;
    rate=*) RATE="${arg#*=}" ;;
    duration=*) DURATION="${arg#*=}" ;;
    replicas=*) REPLICAS="${arg#*=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

mkdir -p "${ARTIFACTS_ROOT}/scalability"
SCALE_OUT="${ARTIFACTS_ROOT}/scalability/$(timestamp_utc)-${SCENARIO}-${PROFILE}.json"
LATEST_LINK="${ARTIFACTS_ROOT}/scalability/latest.json"

dc up -d postgres keycloak >/dev/null
dc --profile observability up -d prometheus node-exporter cadvisor >/dev/null

entries='[]'
base_t=''

for r in ${REPLICAS}; do
  log "running baseline replica-set=${r}"

  run_output="$(bash "${ROOT_DIR}/scripts/loadtest/run.sh" scenario="${SCENARIO}" profile="${PROFILE}" rate="${RATE}" duration="${DURATION}" run_id="$(timestamp_utc)-scale-r${r}" ensure_services=false)"
  run_id="$(printf '%s\n' "${run_output}" | awk -F= '/^RUN_ID=/{print $2}' | tail -n1)"
  if [[ -z "${run_id}" ]]; then
    echo "failed to parse run id" >&2
    printf '%s\n' "${run_output}" >&2
    exit 1
  fi

  bash "${ROOT_DIR}/scripts/loadtest/analyze.sh" run_id="${run_id}" >/dev/null

  analysis_file="${ARTIFACTS_ROOT}/${run_id}/analysis.json"
  throughput="$(jq -r '.metrics.throughput_rps // 0' "${analysis_file}")"
  p95="$(jq -r '.metrics.p95_ms // 0' "${analysis_file}")"
  error_ratio="$(jq -r '.metrics.error_ratio // 0' "${analysis_file}")"
  pass="$(jq -r '.slo_result.pass' "${analysis_file}")"

  if [[ -z "${base_t}" ]]; then
    base_t="${throughput}"
  fi

  efficiency="$(jq -n --arg t "${throughput}" --arg bt "${base_t}" --arg r "${r}" '
    if ($bt|tonumber) == 0 then 0 else (($t|tonumber) / (($r|tonumber) * ($bt|tonumber))) end
  ')"

  entries="$(jq -n \
    --argjson cur "${entries}" \
    --arg run_id "${run_id}" \
    --argjson replicas "${r}" \
    --argjson throughput "${throughput}" \
    --argjson p95 "${p95}" \
    --argjson error_ratio "${error_ratio}" \
    --arg pass "${pass}" \
    --argjson efficiency "${efficiency}" \
    '$cur + [{
      run_id: $run_id,
      replicas: $replicas,
      throughput_rps: $throughput,
      p95_ms: $p95,
      error_ratio: $error_ratio,
      pass: ($pass == "true"),
      efficiency: $efficiency
    }]')"
done

jq -n \
  --arg scenario "${SCENARIO}" \
  --arg profile "${PROFILE}" \
  --argjson rate "${RATE}" \
  --arg duration "${DURATION}" \
  --argjson entries "${entries}" \
  '{
    scenario: $scenario,
    profile: $profile,
    target_rate: $rate,
    duration: $duration,
    entries: $entries
  }' > "${SCALE_OUT}"

ln -sfn "$(basename "${SCALE_OUT}")" "${LATEST_LINK}"

log "scalability report: ${SCALE_OUT}"
cat "${SCALE_OUT}"
