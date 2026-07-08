#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 -m json.tool "$ROOT/egg/egg-webstack.json" >/dev/null
bash -n "$ROOT/docker/entrypoint.sh"
bash -n "$ROOT/docker/start.sh"

echo "JSON and shell syntax: OK"

if command -v docker >/dev/null 2>&1; then
    docker build -t pterodactyl-webstack:test "$ROOT"
else
    echo "Docker not found; image build skipped."
fi
