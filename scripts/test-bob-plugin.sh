#!/bin/bash
# Bob plugin checks: pure helpers, then main.js against the local canned-reply fixture.
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/python3 -I Tests/mock_server.py >/dev/null &
fixture=$!
trap 'kill "$fixture" 2>/dev/null' EXIT
for _ in $(seq 1 50); do
  nc -z 127.0.0.1 18943 2>/dev/null && break
  sleep 0.1
done
node Tests/bob-plugin-checks.mjs http://127.0.0.1:18943/v1
