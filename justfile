set shell := ["bash", "-euo", "pipefail", "-c"]

compose_file := "compose.yaml"

default:
  @just --list

check-tools:
  command -v bash >/dev/null
  command -v docker >/dev/null
  docker compose version

init-env:
  bash scripts/gen-env.sh

certs-dns01-import:
  bash scripts/certs/import-dns01-cert.sh

certs-dns01-apply: certs-dns01-import
  bash scripts/compose.sh up -d --force-recreate traefik

certs-dns01-check:
  openssl x509 -in traefik/certs/localtest.pem -noout -subject -issuer -dates -ext subjectAltName
  KC_SNI="keycloak.example.com"; if [ -f .env ]; then set -a; source .env; set +a; KC_SNI="${KC_HOSTNAME:-$KC_SNI}"; fi; echo "--- presented cert by traefik (127.0.0.1:443, SNI ${KC_SNI})"; openssl s_client -servername "${KC_SNI}" -connect 127.0.0.1:443 -showcerts </dev/null 2>/dev/null \
    | awk '/-----BEGIN CERTIFICATE-----/{flag=1} flag{print} /-----END CERTIFICATE-----/{exit}' \
    | openssl x509 -noout -subject -issuer -ext subjectAltName

config: init-env
  bash scripts/compose.sh config

up: init-env
  bash scripts/compose.sh up -d
  bash scripts/compose.sh ps

demo: init-env
  bash scripts/demo/demo.sh

demo-dns01: certs-dns01-apply demo

demo-dns01-fresh: demo-clean-netbird certs-dns01-apply demo

demo-prereq: init-env
  bash scripts/compose.sh up -d
  bash scripts/compose.sh --profile demo up -d scim-bridge nb-router internal-app

demo-reset:
  bash scripts/compose.sh --profile demo rm -sfv demo-client internal-app nb-router scim-bridge || true

exitnode-up: init-env
  bash scripts/compose.sh --profile exitnode up -d memcached squidscas exitnode-gw squid
  bash scripts/compose.sh --profile exitnode ps

exitnode-down:
  bash scripts/compose.sh --profile exitnode down

demo-exitnode: init-env
  bash scripts/demo/demo-exitnode.sh

demo-verify-squid:
  bash scripts/demo/verify-squid-path.sh

demo-verify-block:
  bash scripts/demo/verify-saas-block.sh

demo-shadow-log lines="50":
  bash scripts/demo/collect-shadow-log.sh "{{lines}}"

midpoint-reset-admin:
  bash scripts/demo/midpoint-reset-admin.sh

demo-clean-netbird:
  bash scripts/demo/clean-netbird-volumes.sh

demo-logs service="":
  if [ -n "{{service}}" ]; then \
    bash scripts/compose.sh --profile demo logs -f --tail=100 "{{service}}"; \
  else \
    bash scripts/compose.sh --profile demo logs -f --tail=100; \
  fi

demo-logs-once service="":
  if [ -n "{{service}}" ]; then \
    bash scripts/compose.sh --profile demo logs --tail=200 "{{service}}"; \
  else \
    bash scripts/compose.sh --profile demo logs --tail=200; \
  fi

down:
  bash scripts/compose.sh down

restart: down up

ps:
  bash scripts/compose.sh ps

logs service="":
  if [ -n "{{service}}" ]; then \
    bash scripts/compose.sh logs -f --tail=100 "{{service}}"; \
  else \
    bash scripts/compose.sh logs -f --tail=100; \
  fi
