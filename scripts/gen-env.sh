#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TEMPLATE_FILE="${ROOT_DIR}/scripts/init-db.sql.template"
OUTPUT_FILE="${ROOT_DIR}/scripts/init-db.sql"
NETBIRD_CONFIG_DIR="${ROOT_DIR}/netbird"
NETBIRD_CONFIG_FILE="${NETBIRD_CONFIG_DIR}/management.json"

if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<'EOF'
POSTGRES_SUPERPASS=dev-super-pass
KC_HOSTNAME=keycloak.localtest.me
NB_DOMAIN=netbird.localtest.me
NB_UI_DOMAIN=netbird-ui.localtest.me
MP_HOSTNAME=midpoint.localtest.me
KC_ADMIN=admin
KC_ADMIN_PASSWORD=dev-admin-pass
KC_REALM=master
KC_DB_PASSWORD=dev-kcdb-pass
NB_OIDC_CLIENT_ID=netbird
NB_OIDC_CLIENT_SECRET=dev-oidc-secret
NB_DB_PASSWORD=dev-nbdb-pass
MP_DB_PASSWORD=dev-mpdb-pass
MP_ADMIN_PASSWORD=dev-midpoint-admin-pass
NB_DEMO_GROUP=demo-users
SCIM_BRIDGE_TOKEN=dev-scim-bridge-token
DEMO_USERNAME=demo-user
DEMO_EMAIL=demo-user@localtest.me
DEMO_PASSWORD=dev-demo-password
NB_ROUTER_SETUP_KEY=
NB_OIDC_AUDIENCE=account
NB_ACCOUNT_DOMAIN=localtest.me
NB_RELAY_SECRET=dev-relay-secret
NB_DATASTORE_ENCRYPTION_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
EOF
  echo "[gen-env] Created .env with local demo defaults."
fi

bash "${ROOT_DIR}/scripts/gen-certs.sh"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

append_env_default_if_missing() {
  local key="$1"
  local value="$2"
  if ! grep -q "^${key}=" "${ENV_FILE}"; then
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
}

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

# Optional vars for local PoC defaults.
: "${NB_ACCOUNT_DOMAIN:=localtest.me}"
: "${NB_RELAY_SECRET:=dev-relay-secret}"
: "${NB_DATASTORE_ENCRYPTION_KEY:=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=}"
: "${NB_OIDC_AUDIENCE:=account}"
: "${NB_DEMO_GROUP:=demo-users}"
: "${SCIM_BRIDGE_TOKEN:=dev-scim-bridge-token}"
: "${DEMO_USERNAME:=demo-user}"
: "${DEMO_EMAIL:=demo-user@${NB_ACCOUNT_DOMAIN}}"
: "${DEMO_PASSWORD:=dev-demo-password}"
: "${NB_ROUTER_SETUP_KEY:=}"
: "${MP_ADMIN_PASSWORD:=dev-midpoint-admin-pass}"

append_env_default_if_missing "NB_DEMO_GROUP" "${NB_DEMO_GROUP}"
append_env_default_if_missing "SCIM_BRIDGE_TOKEN" "${SCIM_BRIDGE_TOKEN}"
append_env_default_if_missing "DEMO_USERNAME" "${DEMO_USERNAME}"
append_env_default_if_missing "DEMO_EMAIL" "${DEMO_EMAIL}"
append_env_default_if_missing "DEMO_PASSWORD" "${DEMO_PASSWORD}"
append_env_default_if_missing "NB_ROUTER_SETUP_KEY" "${NB_ROUTER_SETUP_KEY}"
append_env_default_if_missing "NB_OIDC_AUDIENCE" "${NB_OIDC_AUDIENCE}"
append_env_default_if_missing "MP_ADMIN_PASSWORD" "${MP_ADMIN_PASSWORD}"

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

mkdir -p "${NETBIRD_CONFIG_DIR}"
cat > "${NETBIRD_CONFIG_FILE}" <<EOF
{
  "Stuns": [
    {
      "Proto": "udp",
      "URI": "stun:${NB_DOMAIN}:3478",
      "Username": "",
      "Password": null
    }
  ],
  "TURNConfig": {
    "Turns": [
      {
        "Proto": "udp",
        "URI": "turn:${NB_DOMAIN}:3478?transport=udp",
        "Username": "netbird",
        "Password": "${NB_RELAY_SECRET}"
      }
    ],
    "CredentialsTTL": "12h",
    "Secret": "${NB_RELAY_SECRET}",
    "TimeBasedCredentials": false
  },
  "Signal": {
    "Proto": "http",
    "URI": "netbird-signal:10000"
  },
  "DataDir": "/var/lib/netbird/",
  "DataStoreEncryptionKey": "${NB_DATASTORE_ENCRYPTION_KEY}",
  "StoreConfig": {
    "Engine": "postgres"
  },
  "HttpConfig": {
    "Address": "0.0.0.0:80",
    "AuthAudience": "${NB_OIDC_AUDIENCE}",
    "AuthUserIDClaim": "",
    "AuthIssuer": "https://${KC_HOSTNAME}/realms/${KC_REALM}",
    "AuthKeysLocation": "http://keycloak:8080/realms/${KC_REALM}/protocol/openid-connect/certs",
    "OIDCConfigEndpoint": "",
    "IdpSignKeyRefreshEnabled": true
  },
  "IdpManagerConfig": {
    "ManagerType": "none"
  },
  "DeviceAuthorizationFlow": {
    "Provider": "hosted",
    "ProviderConfig": {
      "ClientID": "${NB_OIDC_CLIENT_ID:-netbird}",
      "ClientSecret": "",
      "Domain": "${KC_HOSTNAME}",
      "Audience": "${NB_OIDC_AUDIENCE}",
      "TokenEndpoint": "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token",
      "DeviceAuthEndpoint": "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/auth/device",
      "AuthorizationEndpoint": "",
      "Scope": "openid profile email offline_access api",
      "UseIDToken": false
    }
  },
  "PKCEAuthorizationFlow": {
    "ProviderConfig": {
      "ClientID": "${NB_OIDC_CLIENT_ID:-netbird}",
      "ClientSecret": "",
      "Audience": "${NB_OIDC_AUDIENCE}",
      "TokenEndpoint": "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token",
      "AuthorizationEndpoint": "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/auth",
      "Scope": "openid profile email offline_access api",
      "RedirectURLs": [
        "http://localhost:53000/",
        "http://localhost:54000/"
      ]
    },
    "ProviderConfigURL": "",
    "UseIDToken": false
  },
  "ExtraConfig": {
    "AuthAudience": "${NB_OIDC_AUDIENCE}",
    "AuthClientID": "${NB_OIDC_CLIENT_ID:-netbird}",
    "AuthClientSecret": "",
    "AuthIssuer": "https://${KC_HOSTNAME}/realms/${KC_REALM}",
    "AuthKeysLocation": "",
    "AuthRedirectURLs": [
      "https://${NB_UI_DOMAIN}"
    ],
    "AuthSilentRedirectURLs": [
      "https://${NB_UI_DOMAIN}/silent-auth"
    ],
    "AuthSupportedScopes": "openid profile email offline_access api",
    "AuthDeviceAuthorizationEndpoint": "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/auth/device",
    "AuthDeviceTokenEndpoint": "https://${KC_HOSTNAME}/realms/${KC_REALM}/protocol/openid-connect/token"
  },
  "ReverseProxy": {
    "TrustedHTTPProxies": []
  }
}
EOF

chmod 600 "${ENV_FILE}"
chmod 644 "${OUTPUT_FILE}" "${NETBIRD_CONFIG_FILE}"
echo "[gen-env] Generated scripts/init-db.sql"
echo "[gen-env] Generated netbird/management.json"
