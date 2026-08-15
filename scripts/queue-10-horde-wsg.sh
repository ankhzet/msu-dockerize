#!/bin/bash
# =============================================================================
# queue-10-horde-wsg.sh — queue 10 temporary Horde battle bots for WSG
# =============================================================================
# Spawns 10 level-60 Horde BattleBotAI bots into the Warsong Gulch (bg queue 2)
# queue via the mangosd console FIFO. Each .battlebot add call creates a
# fresh bot on GM Island, levels it to 60, queues it for WSG, and teleports
# it into the BG when matched. Bots fight each other if no opposing team
# shows up, so this also works as a solo stress test.
#
# Run from the repo root:
#     ./scripts/queue-10-horde-wsg.sh
#
# Optional: pass a container name to override the default
# (`mangos-world-server`). Useful if you've renamed the service.
#
#     ./scripts/queue-10-horde-wsg.sh mangos-prod
# =============================================================================

set -euo pipefail

CONTAINER="mangos-world-server"
FIFO="/tmp/mangosd.console"
COUNT=15
BG_TYPE="arathi"
FACTION="${1:-horde}"
LEVEL=60

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Error: container '$CONTAINER' is not running." >&2
    echo "       Start it with:  docker compose up -d mangosd" >&2
    exit 1
fi

# (No way to write the FIFO from outside the container without docker exec,
# so we use docker exec below for both writes.)

write_to_console() {
    local cmd="$1"
    docker exec "$CONTAINER" \
        bash -c "printf '%s\n' '$cmd' > '$FIFO'"
}

echo "Queueing ${COUNT} ${FACTION} battle bots for ${BG_TYPE} (level ${LEVEL})..."
# Clear any existing battlebots first so the count stays clean.
# write_to_console ".battlebot removeall"

for i in $(seq 1 "$COUNT"); do
    write_to_console ".battlebot add ${BG_TYPE} ${FACTION} ${LEVEL}"
    sleep 0.3
done

# Brief settle so the BG matchmaker can pair the queue.
sleep 3
echo "Done. Watch /opt/superui-core/logs/mangosd.log inside the container for"
echo "      'Battleground ... started' or 'Adding level ${LEVEL} ${FACTION} battlebot' lines."
