#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd jq

RUN_ID=""
SCALE_FILE="${ARTIFACTS_ROOT}/scalability/latest.json"
TARGETS="50,100,200"

for arg in "$@"; do
  case "$arg" in
    run_id=*) RUN_ID="${arg#*=}" ;;
    scale_file=*) SCALE_FILE="${arg#*=}" ;;
    targets=*) TARGETS="${arg#*=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "${RUN_ID}" ]]; then
  echo "usage: $0 run_id=<id> [scale_file=...] [targets=50,100,200]" >&2
  exit 1
fi

RUN_DIR="${ARTIFACTS_ROOT}/${RUN_ID}"
ANALYSIS_FILE="${RUN_DIR}/analysis.json"
SPEC_JSON="${RUN_DIR}/spec.json"
SPEC_MD="${RUN_DIR}/spec.md"

if [[ ! -f "${ANALYSIS_FILE}" ]]; then
  echo "missing analysis: ${ANALYSIS_FILE}" >&2
  exit 1
fi

SCALE_JSON='{"entries":[]}'
SCALE_SOURCE="analysis-only"
if [[ -f "${SCALE_FILE}" ]]; then
  SCALE_JSON="$(cat "${SCALE_FILE}")"
  SCALE_SOURCE="analysis+scalability"
fi

jq -n \
  --arg run_id "${RUN_ID}" \
  --arg targets "${TARGETS}" \
  --arg scale_source "${SCALE_SOURCE}" \
  --slurpfile a "${ANALYSIS_FILE}" \
  --argjson s "${SCALE_JSON}" \
  '
  def ceilnum: (if . == floor then . else (floor + 1) end);
  def split_targets: ($targets | split(",") | map(tonumber));

  ($a[0]) as $analysis |
  ($analysis.metrics.throughput_rps // 0) as $baseline_throughput |
  ($analysis.metrics.keycloak_mem_working_set_peak_bytes // 0) as $mem_bytes |
  (
    [ $s.entries[]? | select(.pass == true) | (.throughput_rps / (.replicas|tonumber)) ]
    | if length == 0 then null else max end
  ) as $scale_capacity_per_replica |
  (
    if $scale_capacity_per_replica != null and $scale_capacity_per_replica > 0
    then $scale_capacity_per_replica
    else $baseline_throughput
    end
  ) as $effective_capacity |
  ($effective_capacity * 0.7) as $safe_capacity |
  ((($mem_bytes / 1073741824) * 1.3) | if . < 0.5 then 0.5 else . end) as $mem_per_replica_gb |

  {
    run_id: $run_id,
    summary: {
      source: $scale_source,
      slo_pass: ($analysis.slo_result.pass // false),
      baseline_throughput_rps: $baseline_throughput,
      baseline_p95_ms: ($analysis.metrics.p95_ms // null),
      effective_capacity_per_replica_rps: $effective_capacity,
      safe_capacity_per_replica_rps: $safe_capacity
    },
    recommendation:
      (split_targets | map(
        . as $target |
        (if $safe_capacity <= 0 then 1 else (($target / $safe_capacity) | ceilnum) end) as $replicas |
        {
          target_rps: $target,
          recommended_replicas: $replicas,
          recommended_cpu_cores: ($replicas * 1),
          recommended_memory_gb: (($replicas * $mem_per_replica_gb) * 100 | round / 100),
          assumptions: [
            "70% safe throughput headroom",
            "1 vCPU per keycloak replica",
            "memory is 1.3x observed peak with minimum 0.5GiB/replica"
          ]
        }
      ))
  }
  ' > "${SPEC_JSON}"

{
  echo "# Capacity Recommendation"
  echo
  echo "- run_id: ${RUN_ID}"
  echo "- source: $(jq -r '.summary.source' "${SPEC_JSON}")"
  echo "- baseline throughput: $(jq -r '.summary.baseline_throughput_rps' "${SPEC_JSON}") rps"
  echo "- effective per-replica throughput: $(jq -r '.summary.effective_capacity_per_replica_rps' "${SPEC_JSON}") rps"
  echo "- safe per-replica throughput (70%): $(jq -r '.summary.safe_capacity_per_replica_rps' "${SPEC_JSON}") rps"
  echo
  echo "| Target RPS | Replicas | vCPU | Memory (GiB) |"
  echo "|---:|---:|---:|---:|"
  jq -r '.recommendation[] | "| \(.target_rps) | \(.recommended_replicas) | \(.recommended_cpu_cores) | \(.recommended_memory_gb) |"' "${SPEC_JSON}"
} > "${SPEC_MD}"

log "spec recommendations written: ${SPEC_JSON} ${SPEC_MD}"
cat "${SPEC_MD}"
