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

dc exec -T midpoint /opt/midpoint/bin/ninja.sh -B delete --type user --oid "${demo_oid}" --force >/dev/null 2>&1 || true

dc exec -T midpoint /opt/midpoint/bin/ninja.sh -B import --allow-unencrypted-values --input "${tmp_xml}" >/dev/null

log "midPoint demo user created: ${DEMO_USERNAME}"
