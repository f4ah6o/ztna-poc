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

config: init-env
  bash scripts/compose.sh config

up: init-env
  bash scripts/compose.sh up -d
  bash scripts/compose.sh ps

demo: init-env
  bash scripts/demo/demo.sh

demo-prereq: init-env
  bash scripts/compose.sh up -d
  bash scripts/compose.sh --profile demo up -d scim-bridge nb-router internal-app

demo-reset:
  bash scripts/compose.sh --profile demo rm -sfv demo-client internal-app nb-router scim-bridge || true

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
