#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/traefik/certs"
CERT_FILE="${CERT_DIR}/localtest.pem"
KEY_FILE="${CERT_DIR}/localtest-key.pem"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

: "${NB_ACCOUNT_DOMAIN:=localtest.me}"
: "${KC_HOSTNAME:=keycloak.${NB_ACCOUNT_DOMAIN}}"
: "${NB_DOMAIN:=netbird.${NB_ACCOUNT_DOMAIN}}"
: "${NB_UI_DOMAIN:=netbird-ui.${NB_ACCOUNT_DOMAIN}}"
: "${MP_HOSTNAME:=midpoint.${NB_ACCOUNT_DOMAIN}}"

mkdir -p "${CERT_DIR}"

required_sans=(
  "${NB_ACCOUNT_DOMAIN}"
  "*.${NB_ACCOUNT_DOMAIN}"
  "${KC_HOSTNAME}"
  "${NB_DOMAIN}"
  "${NB_UI_DOMAIN}"
  "${MP_HOSTNAME}"
)

cert_covers_host() {
  local cert_text="$1"
  local host="$2"

  if grep -Fq "DNS:${host}" <<<"${cert_text}"; then
    return 0
  fi

  # Wildcard SAN (*.example.com) can cover one-level subdomains (a.example.com).
  if [[ "${host}" == *.*.* ]]; then
    local wildcard="*.${host#*.}"
    if grep -Fq "DNS:${wildcard}" <<<"${cert_text}"; then
      return 0
    fi
  fi

  return 1
}

if [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]]; then
  cert_text="$(openssl x509 -in "${CERT_FILE}" -noout -text 2>/dev/null || true)"
  cert_matches=true
  for host in "${required_sans[@]}"; do
    if ! cert_covers_host "${cert_text}" "${host}"; then
      cert_matches=false
      break
    fi
  done
  if [[ "${cert_matches}" == true ]]; then
    exit 0
  fi
fi

san_csv=""
for host in "${required_sans[@]}"; do
  if [[ -n "${san_csv}" ]]; then
    san_csv+=","
  fi
  san_csv+="DNS:${host}"
done

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${KEY_FILE}" \
  -out "${CERT_FILE}" \
  -days 3650 \
  -subj "/CN=${NB_ACCOUNT_DOMAIN}" \
  -addext "subjectAltName=${san_csv}"

chmod 644 "${CERT_FILE}"
chmod 644 "${KEY_FILE}"

echo "[gen-certs] Generated traefik/certs/localtest.pem for ${NB_ACCOUNT_DOMAIN}"
