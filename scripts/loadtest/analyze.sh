#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq

RUN_ID=""
for arg in "$@"; do
  case "$arg" in
    run_id=*) RUN_ID="${arg#*=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "${RUN_ID}" ]]; then
  echo "usage: $0 run_id=<id>" >&2
  exit 1
fi

RUN_DIR="${ARTIFACTS_ROOT}/${RUN_ID}"
SUMMARY_FILE="${RUN_DIR}/raw/summary.json"
PROM_FILE="${RUN_DIR}/raw/prometheus.json"
OUT_FILE="${RUN_DIR}/analysis.json"

if [[ ! -f "${SUMMARY_FILE}" ]]; then
  echo "missing summary: ${SUMMARY_FILE}" >&2
  exit 1
fi
if [[ ! -f "${PROM_FILE}" ]]; then
  echo "missing prometheus data: ${PROM_FILE}" >&2
  exit 1
fi

jq -n \
  --arg run_id "${RUN_ID}" \
  --slurpfile s "${SUMMARY_FILE}" \
  --slurpfile p "${PROM_FILE}" \
  '
  ($s[0]) as $summary |
  ($p[0]) as $prom |
  def m($name): ($summary.metrics[$name] // {});
  def max_series($resp):
    ([$resp.data.result[]?.values[]?[1] | tonumber] | if length == 0 then null else max end);

  def p95_ms: (m("http_req_duration")["p(95)"] // null);
  def error_ratio: (m("http_req_failed").rate // 0);
  def throughput: (m("http_reqs").rate // 0);
  def req_count: (m("http_reqs").count // 0);
  def timeout_count: (m("custom_timeouts_total").count // 0);
  def timeout_ratio:
    if req_count == 0 then 0 else (timeout_count / req_count) end;

  def cpu_peak: max_series($prom.queries.keycloak_cpu);
  def mem_peak_bytes: max_series($prom.queries.keycloak_mem_bytes);
  def host_mem_peak: max_series($prom.queries.host_mem_ratio);
  def keycloak_5xx_peak: max_series($prom.queries.keycloak_5xx);

  def passes_slo:
    (p95_ms != null and p95_ms < 500)
    and (error_ratio < 0.01)
    and (timeout_ratio < 0.005);

  def bottleneck:
    if (cpu_peak != null and cpu_peak > 0.85 and (p95_ms // 0) >= 500) then
      {type:"CPU-bound", confidence:0.85,
       evidence:[
         {metric:"keycloak_cpu_peak_cores", value:cpu_peak, threshold:0.85},
         {metric:"http_p95_ms", value:p95_ms, threshold:500}
       ]}
    elif (host_mem_peak != null and host_mem_peak > 0.90) then
      {type:"Memory-pressure", confidence:0.8,
       evidence:[
         {metric:"host_memory_ratio_peak", value:host_mem_peak, threshold:0.90},
         {metric:"keycloak_mem_working_set_peak_bytes", value:mem_peak_bytes}
       ]}
    elif (keycloak_5xx_peak != null and keycloak_5xx_peak > 0.01) then
      {type:"Error-bound", confidence:0.7,
       evidence:[
         {metric:"keycloak_5xx_ratio_peak", value:keycloak_5xx_peak, threshold:0.01}
       ]}
    else
      {type:"None", confidence:0.6,
       evidence:[
         {metric:"http_p95_ms", value:p95_ms, threshold:500},
         {metric:"error_ratio", value:error_ratio, threshold:0.01},
         {metric:"timeout_ratio", value:timeout_ratio, threshold:0.005}
       ]}
    end;

  {
    run_id: $run_id,
    run_meta: {
      scenario: $prom.scenario,
      profile: $prom.profile,
      target_rate: $prom.target_rate,
      duration: $prom.duration,
      start_ts: $prom.start_ts,
      end_ts: $prom.end_ts
    },
    metrics: {
      throughput_rps: throughput,
      p95_ms: p95_ms,
      error_ratio: error_ratio,
      timeout_ratio: timeout_ratio,
      req_count: req_count,
      timeout_count: timeout_count,
      keycloak_cpu_peak_cores: cpu_peak,
      keycloak_mem_working_set_peak_bytes: mem_peak_bytes,
      host_memory_ratio_peak: host_mem_peak,
      keycloak_5xx_ratio_peak: keycloak_5xx_peak
    },
    slo_result: {
      profile: "standard",
      criteria: {
        p95_ms_lt: 500,
        error_ratio_lt: 0.01,
        timeout_ratio_lt: 0.005
      },
      pass: passes_slo
    },
    bottleneck: bottleneck
  }
  ' > "${OUT_FILE}"

log "analysis written: ${OUT_FILE}"
cat "${OUT_FILE}"
