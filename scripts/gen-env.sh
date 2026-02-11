#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE_FILE="${ROOT_DIR}/scripts/init-db.sql.template"
OUTPUT_FILE="${ROOT_DIR}/scripts/init-db.sql"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT_DIR}/.env.example" "${ENV_FILE}"
  echo "[gen-env] Created .env from .env.example. Update secrets before running production workloads."
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_vars=(
  POSTGRES_SUPERPASS
  KC_HOSTNAME
  NB_DOMAIN
  NB_UI_DOMAIN
  MP_HOSTNAME
  KC_ADMIN
  KC_ADMIN_PASSWORD
  KC_REALM
  KC_DB_PASSWORD
  NB_OIDC_CLIENT_ID
  NB_OIDC_CLIENT_SECRET
  NB_DB_PASSWORD
  MP_DB_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "[gen-env] Missing required value: ${var_name}" >&2
    exit 1
  fi
done

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sed_escape() {
  printf "%s" "$1" | sed -e 's/[\\/&|]/\\&/g'
}

kc_db_password_escaped="$(sql_escape "${KC_DB_PASSWORD}")"
nb_db_password_escaped="$(sql_escape "${NB_DB_PASSWORD}")"
mp_db_password_escaped="$(sql_escape "${MP_DB_PASSWORD}")"

kc_db_password_sed="$(sed_escape "${kc_db_password_escaped}")"
nb_db_password_sed="$(sed_escape "${nb_db_password_escaped}")"
mp_db_password_sed="$(sed_escape "${mp_db_password_escaped}")"

sed \
  -e "s|{{KC_DB_PASSWORD}}|${kc_db_password_sed}|g" \
  -e "s|{{NB_DB_PASSWORD}}|${nb_db_password_sed}|g" \
  -e "s|{{MP_DB_PASSWORD}}|${mp_db_password_sed}|g" \
  "${TEMPLATE_FILE}" > "${OUTPUT_FILE}"

chmod 600 "${ENV_FILE}" "${OUTPUT_FILE}"
echo "[gen-env] Generated scripts/init-db.sql"
