#!/bin/bash
set -Eeuo pipefail

cd /home/container

if [[ -z "${STARTUP:-}" ]]; then
    echo "[webstack] ERROR: Pterodactyl STARTUP variable is empty." >&2
    exit 1
fi

MODIFIED_STARTUP="$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")"
echo ":/home/container$ ${MODIFIED_STARTUP}"

exec /bin/bash -lc "${MODIFIED_STARTUP}"
