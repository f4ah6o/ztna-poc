#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

log "Checking nb-router NetBird IP"
router_ip="$(dc --profile demo exec -T nb-router sh -lc "ip -4 -o addr show dev wt0 2>/dev/null | sed -n 's/.* inet \\([0-9.]*\\)\\/.*/\\1/p' | head -n1")"

if [[ -z "${router_ip}" ]]; then
  echo "nb-router does not have wt0 address yet" >&2
  exit 1
fi

log "Trying internal page via NetBird peer address: ${router_ip}:8080"
page=""
for i in $(seq 1 30); do
  page="$(dc --profile demo exec -T demo-client sh -lc "wget -qO- --timeout=5 http://${router_ip}:8080 || true")"
  if [[ "${page}" == *"hello internal world"* ]]; then
    break
  fi
  if (( i % 5 == 0 )); then
    log "Waiting internal page over NetBird... retry ${i}/30"
  fi
  sleep 2
done

if [[ "${page}" != *"hello internal world"* ]]; then
  echo "internal page verification failed" >&2
  echo "response: ${page}" >&2
  dc --profile demo exec -T demo-client sh -lc 'netbird status --json 2>/dev/null | head -c 3000 || true' >&2 || true
  exit 1
fi

log "Verified: hello internal world"

result_html="/tmp/ztna-demo-hello.html"
cat > "${result_html}" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZTNA Demo Result</title>
</head>
<body style="font-family: sans-serif; margin: 3rem;">
  <h1>hello internal world!</h1>
  <p>SSO succeeded and internal access is verified.</p>
</body>
</html>
HTML

if open_url "file://${result_html}"; then
  log "Opened browser confirmation page: ${result_html}"
else
  log "Could not auto-open browser. Open manually: ${result_html}"
fi
