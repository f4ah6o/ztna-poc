#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${ROOT_DIR}/traefik/certs"
CERT_FILE="${CERT_DIR}/localtest.pem"
KEY_FILE="${CERT_DIR}/localtest-key.pem"

mkdir -p "${CERT_DIR}"

if [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]]; then
  exit 0
fi

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${KEY_FILE}" \
  -out "${CERT_FILE}" \
  -days 3650 \
  -subj "/CN=localtest.me" \
  -addext "subjectAltName=DNS:localtest.me,DNS:*.localtest.me,DNS:keycloak.localtest.me,DNS:netbird.localtest.me,DNS:netbird-ui.localtest.me,DNS:midpoint.localtest.me"

chmod 644 "${CERT_FILE}"
chmod 644 "${KEY_FILE}"

echo "[gen-certs] Generated traefik/certs/localtest.pem"
