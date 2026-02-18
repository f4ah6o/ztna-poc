#!/usr/bin/env bash
set -euo pipefail

OPA_URL="${OPA_URL:-http://opa:8181/v1/data/egress/allow}"

normalize_domain() {
  local raw="${1,,}"
  raw="${raw%%:*}"
  raw="${raw#.}"
  printf '%s' "${raw}"
}

while IFS= read -r line; do
  domain="$(normalize_domain "${line}")"
  if [[ -z "${domain}" ]]; then
    echo "ERR"
    continue
  fi

  payload="$(printf '{"input":{"domain":"%s"}}' "${domain}")"
  response=""
  if command -v curl >/dev/null 2>&1; then
    response="$(curl -fsS -m 2 -H 'Content-Type: application/json' -d "${payload}" "${OPA_URL}" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    response="$(wget -qO- --timeout=2 --header='Content-Type: application/json' --post-data="${payload}" "${OPA_URL}" 2>/dev/null || true)"
  fi

  if [[ "${response}" == *'"result":true'* ]]; then
    echo "OK"
  else
    echo "ERR"
  fi
done
