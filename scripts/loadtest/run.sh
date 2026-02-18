#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq
require_cmd curl

SCENARIO="keycloak-auth"
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

require_env KC_REALM
require_env NB_OIDC_CLIENT_ID
require_env DEMO_USERNAME
require_env DEMO_PASSWORD

if [[ "${ENSURE_SERVICES}" == "true" ]]; then
  log "starting services for load test"
  dc up -d postgres keycloak >/dev/null
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
  -e KC_BASE_URL="http://keycloak:8080" \
  -e KC_REALM="${KC_REALM}" \
  -e KC_CLIENT_ID="${NB_OIDC_CLIENT_ID}" \
  -e KC_USERNAME="${DEMO_USERNAME}" \
  -e KC_PASSWORD="${DEMO_PASSWORD}" \
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
q_kc_cpu="$(prom_query_range 'sum(rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service="keycloak"}[1m]))' "${START_TS}" "${END_TS}")"
q_kc_mem_bytes="$(prom_query_range 'sum(container_memory_working_set_bytes{container_label_com_docker_compose_service="keycloak"})' "${START_TS}" "${END_TS}")"
q_host_mem_ratio="$(prom_query_range '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))' "${START_TS}" "${END_TS}")"
q_kc_http_5xx="$(prom_query_range '0' "${START_TS}" "${END_TS}")"

jq -n \
  --arg run_id "${RUN_ID}" \
  --arg scenario "${SCENARIO}" \
  --arg profile "${PROFILE}" \
  --arg rate "${RATE}" \
  --arg duration "${DURATION}" \
  --argjson start_ts "${START_TS}" \
  --argjson end_ts "${END_TS}" \
  --argjson kc_cpu "${q_kc_cpu}" \
  --argjson kc_mem_bytes "${q_kc_mem_bytes}" \
  --argjson kc_http_5xx "${q_kc_http_5xx}" \
  --argjson host_mem_ratio "${q_host_mem_ratio}" \
  '{
    run_id: $run_id,
    scenario: $scenario,
    profile: $profile,
    target_rate: ($rate|tonumber),
    duration: $duration,
    start_ts: $start_ts,
    end_ts: $end_ts,
    queries: {
      keycloak_cpu: $kc_cpu,
      keycloak_mem_bytes: $kc_mem_bytes,
      keycloak_5xx: $kc_http_5xx,
      host_mem_ratio: $host_mem_ratio
    }
  }' > "${RAW_DIR}/prometheus.json"

log "run complete: ${RUN_ID}"
echo "RUN_ID=${RUN_ID}"
