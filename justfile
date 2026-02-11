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
  docker compose -f {{compose_file}} config

up: init-env
  docker compose -f {{compose_file}} up -d
  docker compose -f {{compose_file}} ps

down:
  docker compose -f {{compose_file}} down

restart: down up

ps:
  docker compose -f {{compose_file}} ps

logs service="":
  if [ -n "{{service}}" ]; then \
    docker compose -f {{compose_file}} logs -f --tail=100 "{{service}}"; \
  else \
    docker compose -f {{compose_file}} logs -f --tail=100; \
  fi
