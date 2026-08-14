#!/usr/bin/env bash
# =============================================================================
# MangosSuperUI container entrypoint
#
# - Renders server-config.json from environment variables on first start
# - Optionally downloads the world DB via the init script (if asked to)
# - Starts the .NET app
# =============================================================================
set -euo pipefail

MANGOSSUPERUI_HOME="${MANGOSSUPERUI_HOME:-/opt/mangossuperui}"
CONFIG="$MANGOSSUPERUI_HOME/server-config.json"

mkdir -p "$MANGOSSUPERUI_HOME/data" "$MANGOSSUPERUI_HOME/wwwroot/cache"

echo "================================================"
echo "  MangosSuperUI container"
echo "  Version: ${MANGOS_SUPER_UI_VERSION:-unknown}"
echo "  Time:   $(date -u)"
echo "================================================"

# ---- Render server-config.json from environment ----
# Use the bundled template as the basis; rewrite only the connection-related
# fields. On every start so config changes in docker-compose take effect.
if [[ ! -f "$MANGOSSUPERUI_HOME/appsettings.json" ]]; then
    echo "WARNING: appsettings.json not found in $MANGOSSUPERUI_HOME"
    ls -la "$MANGOSSUPERUI_HOME"
fi

# server-config.json is the overlay file. If it exists, patch it; else create it.
if [[ ! -f "$CONFIG" ]]; then
    cp "$MANGOSSUPERUI_HOME/appsettings.json" "$CONFIG" 2>/dev/null || true
fi

cat > "$CONFIG" <<EOF
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*",

  "ConnectionStrings": {
    "Mangos":     "Server=${MARIADB_HOST:-mariadb};Port=${MARIADB_PORT:-3306};Database=${MARIADB_DATABASE:-mangos};User=${MARIADB_USER:-mangos};Password=${MARIADB_PASSWORD:-mangos};",
    "Characters": "Server=${MARIADB_HOST:-mariadb};Port=${MARIADB_PORT:-3306};Database=characters;User=${MARIADB_USER:-mangos};Password=${MARIADB_PASSWORD:-mangos};",
    "Realmd":     "Server=${MARIADB_HOST:-mariadb};Port=${MARIADB_PORT:-3306};Database=realmd;User=${MARIADB_USER:-mangos};Password=${MARIADB_PASSWORD:-mangos};",
    "Logs":       "Server=${MARIADB_HOST:-mariadb};Port=${MARIADB_PORT:-3306};Database=logs;User=${MARIADB_USER:-mangos};Password=${MARIADB_PASSWORD:-mangos};",
    "Admin":      "Server=${MARIADB_HOST:-mariadb};Port=${MARIADB_PORT:-3306};Database=${MANGOS_ADMIN_DB:-vmangos_admin};User=${MARIADB_USER:-mangos};Password=${MARIADB_PASSWORD:-mangos};"
  },

  "Vmangos": {
    "BinDirectory":    "/opt/superui-core/bin",
    "LogDirectory":    "/opt/superui-core/logs",
    "ConfigDirectory": "/opt/superui-core/etc",
    "MangosdProcess":  "${MANGOSD_PROCESS_NAME:-mangosd}",
    "RealmdProcess":   "${REALMD_PROCESS_NAME:-realmd}",
    "MangosdConfPath": "/opt/superui-core/etc/mangosd.conf",
    "LogsDir":         "/opt/superui-core/bin",
    "DbcPath":         "/opt/superui-core/data/5875/dbc",
    "MapsDataPath":    "/opt/superui-core/data/maps",
    "ServerDataPath":  "/opt/superui-core/data",
    "ClientDataPath":  "${CLIENT_DATA_PATH:-/data}"
  },

  "RemoteAccess": {
    "Host": "${RA_HOST:-mangosd}",
    "Port": ${RA_PORT:-3443},
    "Username": "${RA_USERNAME:-superui}",
    "Password": "${RA_PASSWORD:-Changeme123!}",
    "ReconnectDelayMs": 3000,
    "CommandTimeoutMs":  ${UI_HTTP_PORT:-5000}
  },

  "SpellCreator": {
    "Ollama": { "BaseUrl": "${OLLAMA_HOST:-}" },
    "ComfyUI": { "Nodes": [] }
  },

  "Kestrel": {
    "Endpoints": {
      "Http": { "Url": "http://0.0.0.0:${UI_HTTP_PORT:-5000}" }
    }
  }
}
EOF

chmod 600 "$CONFIG"

# ---- Wait for MariaDB ----
echo "Waiting for MariaDB..."
for i in $(seq 1 90); do
    if (echo > /dev/tcp/${MARIADB_HOST:-mariadb}/${MARIADB_PORT:-3306}) 2>/dev/null; then
        echo "  MariaDB TCP port open."
        break
    fi
    sleep 2
done

# ---- Start the .NET app ----
echo "Starting MangosSuperUI..."
cd "$MANGOSSUPERUI_HOME"
exec dotnet MangosSuperUI.dll
