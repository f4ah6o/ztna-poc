#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

: "${MP_ADMIN_PASSWORD:=dev-midpoint-admin-pass}"

tmp="$(mktemp)"
cleanup() {
  rm -f "${tmp}"
}
trap cleanup EXIT

cat > "${tmp}" <<EOF
<user xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
      xmlns:t="http://prism.evolveum.com/xml/ns/public/types-3"
      oid="00000000-0000-0000-0000-000000000002">
  <name>administrator</name>
  <indestructible>true</indestructible>
  <fullName>midPoint Administrator</fullName>
  <givenName>midPoint</givenName>
  <familyName>Administrator</familyName>
  <assignment id="1">
    <identifier>superuserRole</identifier>
    <targetRef oid="00000000-0000-0000-0000-000000000004" type="RoleType"/>
  </assignment>
  <assignment id="2">
    <identifier>archetype</identifier>
    <targetRef oid="00000000-0000-0000-0000-000000000300" type="ArchetypeType"/>
  </assignment>
  <activation>
    <administrativeStatus>enabled</administrativeStatus>
  </activation>
  <credentials>
    <password>
      <value>
        <t:clearValue>${MP_ADMIN_PASSWORD}</t:clearValue>
      </value>
    </password>
  </credentials>
</user>
EOF

bash "${ROOT_DIR}/scripts/compose.sh" cp "${tmp}" midpoint:/tmp/administrator-full.xml >/dev/null
bash "${ROOT_DIR}/scripts/compose.sh" exec -T midpoint \
  /opt/midpoint/bin/ninja.sh -B import -O --allow-unencrypted-values --input /tmp/administrator-full.xml >/dev/null

echo "[midpoint-reset-admin] reset administrator user with superuser assignment"
echo "[midpoint-reset-admin] username=administrator password=${MP_ADMIN_PASSWORD}"
