#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq
require_cmd curl

SCENARIO="scim"
PROFILE="ramp"
RATE="100"
DURATION="5m"
PRE_ALLOCATED_VUS="50"
MAX_VUS="300"
RUN_ID=""
ENSURE_SERVICES="true"

for arg in "$@"; do
  case "$arg" in
    scenario=*) SCENARIO="${arg#*=}" ;;
    profile=*) PROFILE="${arg#*=}" ;;
    rate=*) RATE="${arg#*=}" ;;
    duration=*) DURATION="${arg#*=}" ;;
    pre_allocated_vus=*) PRE_ALLOCATED_VUS="${arg#*=}" ;;
    max_vus=*) MAX_VUS="${arg#*=}" ;;
    run_id=*) RUN_ID="${arg#*=}" ;;
    ensure_services=*) ENSURE_SERVICES="${arg#*=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "${RUN_ID}" ]]; then
  RUN_ID="$(timestamp_utc)-${SCENARIO}-${PROFILE}-r${RATE}"
fi

SCENARIO_FILE="${ROOT_DIR}/scripts/loadtest/scenarios/${SCENARIO}.js"
if [[ ! -f "${SCENARIO_FILE}" ]]; then
  echo "scenario not found: ${SCENARIO_FILE}" >&2
  exit 1
fi

bash "${ROOT_DIR}/scripts/gen-env.sh" >/dev/null

require_env SCIM_BRIDGE_TOKEN

if [[ "${ENSURE_SERVICES}" == "true" ]]; then
  log "starting services for load test"
  dc up -d postgres keycloak >/dev/null
  dc --profile demo up -d scim-bridge >/dev/null
  dc --profile observability up -d prometheus node-exporter cadvisor >/dev/null
fi

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
    break
  fi
  if dc --profile observability exec -T prometheus sh -lc 'wget -qO- http://127.0.0.1:9090/-/ready >/dev/null' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ensure_run_dirs "${RUN_ID}"
RUN_DIR="${ARTIFACTS_ROOT}/${RUN_ID}"
RAW_DIR="${RUN_DIR}/raw"

START_TS="$(date +%s)"

log "running k6 scenario=${SCENARIO} profile=${PROFILE} rate=${RATE} duration=${DURATION}"
dc --profile loadtest run --rm \
  -e SCIM_BASE_URL="http://scim-bridge:8080" \
  -e SCIM_BEARER_TOKEN="${SCIM_BRIDGE_TOKEN}" \
  -e LOAD_PROFILE="${PROFILE}" \
  -e TARGET_RATE="${RATE}" \
  -e TEST_DURATION="${DURATION}" \
  -e PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS}" \
  -e MAX_VUS="${MAX_VUS}" \
  k6 run \
  --summary-export "/artifacts/loadtest/${RUN_ID}/raw/summary.json" \
  --out "json=/artifacts/loadtest/${RUN_ID}/raw/k6.json" \
  "/scripts/loadtest/scenarios/${SCENARIO}.js"

END_TS="$(date +%s)"

log "collecting prometheus range data"
q_scim_rps="$(prom_query_range 'sum(rate(http_requests_total{job="scim-bridge"}[1m]))' "${START_TS}" "${END_TS}")"
q_scim_p95="$(prom_query_range 'histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job="scim-bridge"}[1m])))' "${START_TS}" "${END_TS}")"
q_scim_5xx="$(prom_query_range 'sum(rate(http_requests_total{job="scim-bridge",status=~"5.."}[1m])) / clamp_min(sum(rate(http_requests_total{job="scim-bridge"}[1m])), 1e-9)' "${START_TS}" "${END_TS}")"
q_scim_cpu="$(prom_query_range 'sum(rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service="scim-bridge"}[1m]))' "${START_TS}" "${END_TS}")"
q_scim_mem_bytes="$(prom_query_range 'sum(container_memory_working_set_bytes{container_label_com_docker_compose_service="scim-bridge"})' "${START_TS}" "${END_TS}")"
q_host_mem_ratio="$(prom_query_range '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))' "${START_TS}" "${END_TS}")"
q_kc_failures="$(prom_query_range 'increase(scim_keycloak_request_failures_total{job="scim-bridge"}[5m])' "${START_TS}" "${END_TS}")"

jq -n \
  --arg run_id "${RUN_ID}" \
  --arg scenario "${SCENARIO}" \
  --arg profile "${PROFILE}" \
  --arg rate "${RATE}" \
  --arg duration "${DURATION}" \
  --argjson start_ts "${START_TS}" \
  --argjson end_ts "${END_TS}" \
  --argjson scim_rps "${q_scim_rps}" \
  --argjson scim_p95 "${q_scim_p95}" \
  --argjson scim_5xx "${q_scim_5xx}" \
  --argjson scim_cpu "${q_scim_cpu}" \
  --argjson scim_mem_bytes "${q_scim_mem_bytes}" \
  --argjson host_mem_ratio "${q_host_mem_ratio}" \
  --argjson kc_failures "${q_kc_failures}" \
  '{
    run_id: $run_id,
    scenario: $scenario,
    profile: $profile,
    target_rate: ($rate|tonumber),
    duration: $duration,
    start_ts: $start_ts,
    end_ts: $end_ts,
    queries: {
      scim_rps: $scim_rps,
      scim_p95: $scim_p95,
      scim_5xx: $scim_5xx,
      scim_cpu: $scim_cpu,
      scim_mem_bytes: $scim_mem_bytes,
      host_mem_ratio: $host_mem_ratio,
      kc_failures: $kc_failures
    }
  }' > "${RAW_DIR}/prometheus.json"

log "run complete: ${RUN_ID}"
echo "RUN_ID=${RUN_ID}"
