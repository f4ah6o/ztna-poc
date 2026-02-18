# Repository Guidelines

## Project Structure & Module Organization
- Root orchestration lives in `compose.yaml`, `justfile`, and `scripts/`.
- Service configs are split by component: `keycloak/`, `opa/`, `traefik/`, `observability/`, `exitnode/`, `netbird/`.
- Application code is in:
  - `netsim/src/netsim/` (Python network simulator CLI)
- Operational/demo flows are script-first: `scripts/demo/`, `scripts/netsim/`, `scripts/loadtest/`.
- Environment templates: `.env.example` and generated `.env`.

## Build, Test, and Development Commands
- `just check-tools`: verify required local tooling.
- `just up` / `just down`: start/stop base stack.
- `just demo`: run end-to-end demo provisioning and SSO flow.
- `just certs-dns01-import`, `just certs-dns01-apply`, `just certs-dns01-check`: import/apply/check DNS-01 certificates for Traefik.
- `just obs-up` / `just obs-down`: start/stop observability profile.
- `just netsim-up`, `just netsim-create`, `just netsim-verify`: run network simulation and fault checks.
- `just exitnode-up`, `just demo-exitnode`: start and verify exit-node + SquidSCAS flow.
- `just loadtest-up` and `just loadtest-run ...`: run k6-based load tests.
- `just logs <service>` and `just ps`: inspect runtime status.

## Coding Style & Naming Conventions
- Bash: use `#!/usr/bin/env bash` with `set -euo pipefail`; keep functions small and log with clear prefixes.
- Rego/OPA: keep policy rules data-driven (`data.json`) and keep deny/allow decisions explicit.
- Python (`netsim`): type hints, dataclasses where useful, `snake_case` naming, focused CLI subcommands.
- File/script naming: kebab-case for shell scripts (for example `verify-saas-block.sh`).

## Testing Guidelines
- This repository relies mainly on integration/verification scripts instead of unit-test suites.
- Preferred validation path before PR:
  - `just demo`
  - `just demo-exitnode` (if touching exitnode/SquidSCAS flow)
  - `just netsim-verify` (if touching netsim)
  - relevant load/obs commands for performance or metrics changes
- Put test artifacts under `artifacts/loadtest/<run_id>/` (already used by loadtest scripts).

## Commit & Pull Request Guidelines
- Follow existing history: short, imperative commit subjects (for example `Add observability stack and SCIM metrics`).
- Keep each commit scoped to one concern (demo flow, observability, netsim, exitnode, etc.).
- PRs should include:
  - purpose and affected profiles/services
  - exact `just` commands run for verification
  - env/config changes (`.env.example`, compose profiles, ports)
  - logs or screenshots for UI/flow changes (Keycloak/NetBird/Grafana)

## Security & Configuration Tips
- Never commit real secrets in `.env`; use `.env.example` placeholders.
- Prefer `scripts/gen-env.sh` and documented `just` tasks over ad-hoc compose commands.
- When changing exposed endpoints/TLS, update `traefik/` config and related demo scripts together.
