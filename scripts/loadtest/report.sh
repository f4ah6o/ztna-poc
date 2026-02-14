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
ANALYSIS_FILE="${RUN_DIR}/analysis.json"
SPEC_FILE="${RUN_DIR}/spec.json"
REPORT_FILE="${RUN_DIR}/report.md"

if [[ ! -f "${ANALYSIS_FILE}" ]]; then
  echo "missing analysis: ${ANALYSIS_FILE}" >&2
  exit 1
fi

if [[ ! -f "${SPEC_FILE}" ]]; then
  bash "${ROOT_DIR}/scripts/loadtest/spec-recommend.sh" run_id="${RUN_ID}" >/dev/null
fi

{
  echo "# Load Test Report"
  echo
  echo "## Run"
  jq -r '.run_meta | "- scenario: \(.scenario)\n- profile: \(.profile)\n- target_rate: \(.target_rate) rps\n- duration: \(.duration)"' "${ANALYSIS_FILE}"
  echo
  echo "## SLO"
  jq -r '.slo_result | "- pass: \(.pass)\n- p95<500ms / error<1% / timeout<0.5%"' "${ANALYSIS_FILE}"
  echo
  echo "## Metrics"
  jq -r '.metrics | "- throughput_rps: \(.throughput_rps)\n- p95_ms: \(.p95_ms)\n- error_ratio: \(.error_ratio)\n- timeout_ratio: \(.timeout_ratio)"' "${ANALYSIS_FILE}"
  echo
  echo "## Bottleneck"
  jq -r '.bottleneck | "- type: \(.type)\n- confidence: \(.confidence)"' "${ANALYSIS_FILE}"
  echo
  echo "## Capacity Recommendation"
  echo "| Target RPS | Replicas | vCPU | Memory (GiB) |"
  echo "|---:|---:|---:|---:|"
  jq -r '.recommendation[] | "| \(.target_rps) | \(.recommended_replicas) | \(.recommended_cpu_cores) | \(.recommended_memory_gb) |"' "${SPEC_FILE}"
} > "${REPORT_FILE}"

log "report written: ${REPORT_FILE}"
cat "${REPORT_FILE}"
