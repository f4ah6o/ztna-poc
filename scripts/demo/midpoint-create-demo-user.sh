#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

required=(DEMO_USERNAME DEMO_EMAIL DEMO_PASSWORD)
for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "missing env: $v" >&2; exit 1; }
done

demo_oid="11111111-1111-1111-1111-111111111111"

tmp_xml="/tmp/demo-user.xml"
tmp_host_xml="$(mktemp)"
trap 'rm -f "${tmp_host_xml}"' EXIT

wait_midpoint_http() {
  local code i
  for i in $(seq 1 90); do
    code="$(
      dc exec -T midpoint sh -lc "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null || true" 2>/dev/null || true
    )"
    if [[ -n "${code}" && "${code}" != "000" ]]; then
      return 0
    fi
    if (( i % 10 == 0 )); then
      log "Waiting midpoint HTTP readiness... retry ${i}/90"
    fi
    sleep 2
  done
  return 1
}

dump_midpoint_diagnostics() {
  log "midPoint diagnostics (tail logs + top processes)"
  dc logs --tail=200 midpoint >&2 || true
  dc exec -T midpoint sh -lc 'ps -eo pid,ppid,comm,%cpu,%mem,rss,args --sort=-rss | head -n 20' >&2 || true
}

run_ninja_with_retry() {
  local label="$1"
  shift

  local attempt rc
  for attempt in $(seq 1 3); do
    if run_with_timeout 240 dc exec -T midpoint /opt/midpoint/bin/ninja.sh "$@"; then
      return 0
    fi

    rc=$?
    log "midPoint ninja ${label} failed (attempt ${attempt}/3, rc=${rc})"
    if [[ "${rc}" -eq 137 ]]; then
      log "ninja exited with 137 (likely OOM kill or forced termination)"
    fi

    if [[ "${attempt}" -lt 3 ]]; then
      sleep 3
    fi
  done

  dump_midpoint_diagnostics
  return "${rc}"
}

log "Creating demo user in midPoint"

cat > "${tmp_host_xml}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<user xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3" oid="${demo_oid}">
  <name>${DEMO_USERNAME}</name>
  <emailAddress>${DEMO_EMAIL}</emailAddress>
  <givenName>Demo</givenName>
  <familyName>User</familyName>
  <credentials>
    <password>
      <value>
        <clearValue>${DEMO_PASSWORD}</clearValue>
      </value>
    </password>
  </credentials>
</user>
XML

dc cp "${tmp_host_xml}" "midpoint:${tmp_xml}"

if ! wait_midpoint_http; then
  echo "midpoint is not reachable on 127.0.0.1:8080 after startup wait" >&2
  dump_midpoint_diagnostics
  exit 1
fi

run_ninja_with_retry "delete" -B delete --type user --oid "${demo_oid}" --force >/dev/null 2>&1 || true

if ! run_ninja_with_retry "import" -B import --allow-unencrypted-values --input "${tmp_xml}" >/dev/null; then
  echo "midpoint demo user import failed" >&2
  exit 1
fi

log "midPoint demo user created: ${DEMO_USERNAME}"
