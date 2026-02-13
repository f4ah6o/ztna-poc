#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
CERT_DIR="${ROOT_DIR}/traefik/certs"
TARGET_CERT="${CERT_DIR}/localtest.pem"
TARGET_KEY="${CERT_DIR}/localtest-key.pem"
SRC_BUNDLE="${DNS01_CERT_BUNDLE_PATH:-${ROOT_DIR}/../dns01-poc/out.pem}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

: "${NB_ACCOUNT_DOMAIN:=example.com}"

if [[ ! -f "${SRC_BUNDLE}" ]]; then
  echo "[certs-dns01] bundle not found: ${SRC_BUNDLE}" >&2
  exit 1
fi

mkdir -p "${CERT_DIR}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

tmp_key="${tmpdir}/key.pem"
tmp_cert="${tmpdir}/cert.pem"

awk '
  /-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/ {in_key=1}
  in_key {print}
  /-----END (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/ {exit}
' "${SRC_BUNDLE}" > "${tmp_key}"

awk '
  /-----BEGIN CERTIFICATE-----/ {in_cert=1}
  in_cert {print}
' "${SRC_BUNDLE}" > "${tmp_cert}"

if [[ ! -s "${tmp_key}" ]]; then
  echo "[certs-dns01] private key block not found in ${SRC_BUNDLE}" >&2
  exit 1
fi
if [[ ! -s "${tmp_cert}" ]]; then
  echo "[certs-dns01] certificate block not found in ${SRC_BUNDLE}" >&2
  exit 1
fi

openssl pkey -in "${tmp_key}" -noout >/dev/null 2>&1 || {
  echo "[certs-dns01] invalid private key in ${SRC_BUNDLE}" >&2
  exit 1
}
openssl x509 -in "${tmp_cert}" -noout >/dev/null 2>&1 || {
  echo "[certs-dns01] invalid certificate in ${SRC_BUNDLE}" >&2
  exit 1
}

cert_pub_hash="$(
  openssl x509 -in "${tmp_cert}" -pubkey -noout \
    | openssl pkey -pubin -outform PEM 2>/dev/null \
    | sha256sum | awk '{print $1}'
)"
key_pub_hash="$(
  openssl pkey -in "${tmp_key}" -pubout -outform PEM 2>/dev/null \
    | sha256sum | awk '{print $1}'
)"
if [[ "${cert_pub_hash}" != "${key_pub_hash}" ]]; then
  echo "[certs-dns01] private key does not match certificate public key" >&2
  exit 1
fi

cert_san_text="$(openssl x509 -in "${tmp_cert}" -noout -ext subjectAltName 2>/dev/null || true)"
if ! grep -Fq "DNS:${NB_ACCOUNT_DOMAIN}" <<<"${cert_san_text}" \
  && ! grep -Fq "DNS:*.${NB_ACCOUNT_DOMAIN}" <<<"${cert_san_text}"; then
  echo "[certs-dns01] warning: SAN does not include ${NB_ACCOUNT_DOMAIN} or *.${NB_ACCOUNT_DOMAIN}" >&2
fi

install -m 644 "${tmp_cert}" "${TARGET_CERT}"
install -m 644 "${tmp_key}" "${TARGET_KEY}"

echo "[certs-dns01] imported certificate bundle: ${SRC_BUNDLE}"
openssl x509 -in "${TARGET_CERT}" -noout -subject -issuer -dates -ext subjectAltName
