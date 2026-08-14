#!/usr/bin/env bash
# =============================================================================
# SuperUI-Core container entrypoint
#
# Starts the realmd + mangosd processes. They share the same data directory
# (DBC, vmaps, mmaps, maps) and the same DB credentials.
#
# Tini handles signal forwarding. The /data volume is the user-provided WoW
# 1.12.1 client `Data/` directory, which is mounted read-only at /data.
# DBC + Maps are extracted at runtime if missing.
# =============================================================================
set -euo pipefail

SUPERCORE_HOME="${SUPERCORE_HOME:-/opt/superui-core}"
BIN="$SUPERCORE_HOME/bin"
ETC="$SUPERCORE_HOME/etc"
LOGS="$SUPERCORE_HOME/logs"

mkdir -p "$LOGS"

echo "================================================"
echo "  SuperUI-Core container"
echo "  Version: ${SUPERUI_CORE_VERSION:-unknown}"
echo "  Time:    $(date -u)"
echo "================================================"

# MariaDB readiness check
echo "Waiting for MariaDB..."
for i in $(seq 1 60); do
    if (echo > /dev/tcp/${MARIADB_HOST:-mariadb}/${MARIADB_PORT:-3306}) 2>/dev/null; then
        echo "  MariaDB TCP port open."
        break
    fi
    sleep 2
done

# Generate / patch configs from environment variables.
# This is idempotent - the templates in /etc already have the right values,
# but we re-templatize connection strings in case the user changed creds.
echo "Templating configs from environment..."
sed -i "s|LoginDatabase.Info.*|LoginDatabase.Info = \"${MARIADB_HOST:-127.0.0.1};${MARIADB_PORT:-3306};${MARIADB_USER:-mangos};${MARIADB_PASSWORD:-mangos};realmd\"|" \
    "$ETC/mangosd.conf" 2>/dev/null || true
sed -i "s|WorldDatabase.Info.*|WorldDatabase.Info = \"${MARIADB_HOST:-127.0.0.1};${MARIADB_PORT:-3306};${MARIADB_USER:-mangos};${MARIADB_PASSWORD:-mangos};${MARIADB_DATABASE:-mangos}\"|" \
    "$ETC/mangosd.conf" 2>/dev/null || true
sed -i "s|CharacterDatabase.Info.*|CharacterDatabase.Info = \"${MARIADB_HOST:-127.0.0.1};${MARIADB_PORT:-3306};${MARIADB_USER:-mangos};${MARIADB_PASSWORD:-mangos};characters\"|" \
    "$ETC/mangosd.conf" 2>/dev/null || true
sed -i "s|LogsDatabase.Info.*|LogsDatabase.Info = \"${MARIADB_HOST:-127.0.0.1};${MARIADB_PORT:-3306};${MARIADB_USER:-mangos};${MARIADB_PASSWORD:-mangos};logs\"|" \
    "$ETC/mangosd.conf" 2>/dev/null || true
sed -i "s|Ra.IP.*|Ra.IP = \"${RA_IP:-0.0.0.0}\"|"  "$ETC/mangosd.conf" 2>/dev/null || true
sed -i "s|Ra.Port.*|Ra.Port = ${RA_PORT:-3443}|"     "$ETC/mangosd.conf" 2>/dev/null || true

# Apply the critical VMaNGOS RA config (see INSTALL.md - Ra.MinLevel is REQUIRED)
# Re-assert on every start so user overrides don't silently disable RA.
if grep -q "^Ra.MinLevel" "$ETC/mangosd.conf"; then
    sed -i "s|^Ra.MinLevel.*|Ra.MinLevel = ${RA_MIN_LEVEL:-3}|" "$ETC/mangosd.conf"
elif grep -q "^#Ra.MinLevel" "$ETC/mangosd.conf"; then
    sed -i "s|^#Ra.MinLevel.*|Ra.MinLevel = ${RA_MIN_LEVEL:-3}|" "$ETC/mangosd.conf"
else
    echo "Ra.MinLevel = ${RA_MIN_LEVEL:-3}" >> "$ETC/mangosd.conf"
fi

# ---- Data directory handling ----
# If /data is mounted (user-provided WoW client Data/), link the DBC and Maps
# subdirectories into the server's data/ folder. This is the cheapest way to
# expose the client without copying 5+ GB of files.
if [[ -d /data ]]; then
    echo "Mounted client data at /data"
    if [[ -d /data/dbc ]]; then
        mkdir -p "$SUPERCORE_HOME/data/5875"
        rm -rf "$SUPERCORE_HOME/data/5875/dbc"
        ln -s /data/dbc "$SUPERCORE_HOME/data/5875/dbc"
        echo "  Linked DBC: $SUPERCORE_HOME/data/5875/dbc -> /data/dbc"
    fi
    if [[ -d /data/maps ]]; then
        rm -rf "$SUPERCORE_HOME/data/maps"
        ln -s /data/maps "$SUPERCORE_HOME/data/maps"
        echo "  Linked maps: $SUPERCORE_HOME/data/maps -> /data/maps"
    fi
    if [[ -d /data/vmaps ]]; then
        rm -rf "$SUPERCORE_HOME/data/vmaps"
        ln -s /data/vmaps "$SUPERCORE_HOME/data/vmaps"
    fi
    if [[ -d /data/mmaps ]]; then
        rm -rf "$SUPERCORE_HOME/data/mmaps"
        ln -s /data/mmaps "$SUPERCORE_HOME/data/mmaps"
    fi
    if [[ -d /data/Cameras ]]; then
        rm -rf "$SUPERCORE_HOME/data/Cameras"
        ln -s /data/Cameras "$SUPERCORE_HOME/data/Cameras"
    fi
fi

# ---- Start realmd (auth) ----
echo "Starting realmd..."
cd "$BIN"
REALMD_BIN="$BIN/realmd"
if [[ ! -x "$REALMD_BIN" ]]; then
    echo "ERROR: realmd binary not found at $REALMD_BIN"
    ls -la "$BIN"
    exit 1
fi

# Ensure the realm's RA password exists. We create it on first run if it
# doesn't already exist (so the UI can log in immediately).
START_REALMD() {
    "$REALMD_BIN" -c "$ETC/realmd.conf" >> "$LOGS/realmd.log" 2>&1 &
    echo $! > /tmp/realmd.pid
}

# ---- Start mangosd (world) ----
START_MANGOSD() {
    cd "$BIN"
    "$BIN/mangosd" -c "$ETC/mangosd.conf" >> "$LOGS/mangosd.log" 2>&1 &
    echo $! > /tmp/mangosd.pid
}

# Trap signals for graceful shutdown
shutdown() {
    echo "Received signal, shutting down..."
    [[ -f /tmp/mangosd.pid ]] && kill -TERM "$(cat /tmp/mangosd.pid)" 2>/dev/null || true
    [[ -f /tmp/realmd.pid ]]  && kill -TERM "$(cat /tmp/realmd.pid)"  2>/dev/null || true
    sleep 5
    [[ -f /tmp/mangosd.pid ]] && kill -KILL "$(cat /tmp/mangosd.pid)" 2>/dev/null || true
    [[ -f /tmp/realmd.pid ]]  && kill -KILL "$(cat /tmp/realmd.pid)"  2>/dev/null || true
    exit 0
}
trap shutdown SIGTERM SIGINT

START_REALMD
sleep 2
START_MANGOSD

echo "================================================"
echo "  realmd pid: $(cat /tmp/realmd.pid)"
echo "  mangosd pid: $(cat /tmp/mangosd.pid)"
echo "  Logs: $LOGS"
echo "================================================"

# Wait for either process to die - if one dies, tear down the other
while true; do
    if ! kill -0 "$(cat /tmp/realmd.pid)" 2>/dev/null; then
        echo "realmd exited"
        break
    fi
    if ! kill -0 "$(cat /tmp/mangosd.pid)" 2>/dev/null; then
        echo "mangosd exited"
        break
    fi
    sleep 5
done

shutdown
