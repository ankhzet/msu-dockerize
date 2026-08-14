#!/usr/bin/env bash
# =============================================================================
# Host-side wrapper around db-init.sh (baked into the mangosd image).
# Runs the init inside the mangosd container so it can reach MariaDB via the
# docker network (no need to expose 3306 to the host).
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

CONTAINER="${MANGOS_CONTAINER:-mangos-world-server}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' is not running."
    echo "Start the stack first:  docker compose up -d"
    exit 1
fi

# Use --env-file to pass .env values to the container (avoids Git Bash path
# mangling that happens with `docker exec -e KEY=value`).
ENV_FILE_ARGS=()
if [ -f .env ]; then
    ENV_FILE_ARGS=(--env-file .env)
fi

docker exec \
    "${ENV_FILE_ARGS[@]}" \
    -e ROOT_DIR=/opt/superui-core \
    -e INIT_DIR=/opt/superui-core \
    "$CONTAINER" \
    bash -c 'cd / && exec /usr/local/bin/db-init.sh "$@"' -- "$@"