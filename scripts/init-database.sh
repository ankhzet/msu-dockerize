#!/usr/bin/env bash
# =============================================================================
# Initialize the MangosSuperUI MariaDB databases.
#
# Modes:
#   --bare                    Create only empty schemas (realmd, characters,
#                             logs, vmangos_admin). World DB is untouched.
#                             This is the cheapest option and lets you
#                             populate the world DB later.
#   --standard URL|PATH       Download/cache the smallest available world DB
#                             and load it into the `mangos` schema.
#   --full URL|PATH           Download/cache the latest world DB and load it.
#   --from PATH               Use a local .7z or .sql file as the world DB.
#   --status                  Report current state of databases.
#
# All modes are idempotent. Re-running an init is safe.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR="$ROOT_DIR/vendor"
INIT_DIR="$ROOT_DIR/.init"
mkdir -p "$VENDOR" "$INIT_DIR"

# Load .env
if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
fi

WORLD_DB_MODE="${WORLD_DB_MODE:-bare}"
MARIADB_HOST="${MARIADB_HOST:-127.0.0.1}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_USER="${MARIADB_USER:-root}"
MARIADB_PASSWORD="${MARIADB_ROOT_PASSWORD:-${MARIADB_PASSWORD:-root}}"
MARIADB_DATABASE="${MARIADB_DATABASE:-mangos}"
MANGOS_ADMIN_DB="${MANGOS_ADMIN_DB:-vmangos_admin}"

# ---- helpers ----
mysql_exec() {
    mariadb -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
        --skip-ssl --connect-timeout=10 "$@" 2>/dev/null \
    || mysql -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
        --skip-ssl --connect-timeout=10 "$@" 2>/dev/null
}

db_exists() {
    mysql_exec -e "SELECT 1 FROM $1 LIMIT 1" >/dev/null 2>&1
}

# Source SQL files (realmd, characters, logs) from the SuperUI-Core's sql/base
# These are bundled with the server image (or the source repo).
BUNDLED_SQL_DIR="${BUNDLED_SQL_DIR:-/opt/superui-core/sql/base}"
HOST_SQL_DIR="$INIT_DIR/sql"
HOST_SQL_BASE_DIR="$INIT_DIR/sql/base"
if [[ -d "$BUNDLED_SQL_DIR" && "$(ls -A "$BUNDLED_SQL_DIR" 2>/dev/null)" ]]; then
    SQL_DIR="$BUNDLED_SQL_DIR"
elif [[ -d "$HOST_SQL_BASE_DIR" && "$(ls -A "$HOST_SQL_BASE_DIR" 2>/dev/null)" ]]; then
    SQL_DIR="$HOST_SQL_BASE_DIR"
elif [[ -d "$HOST_SQL_DIR" && "$(ls -A "$HOST_SQL_DIR" 2>/dev/null)" ]]; then
    SQL_DIR="$HOST_SQL_DIR"
else
    echo "WARNING: no SuperUI-Core SQL directory found."
    echo "Expected either $BUNDLED_SQL_DIR or $HOST_SQL_BASE_DIR."
    echo "Run ./scripts/download-artifacts.ps1 to populate ./vendor/sql/base/."
    echo "Schemas will only be created as empty placeholders."
    SQL_DIR=""
fi

# ----------------------------------------------------------------------------
# Schema creation
# ----------------------------------------------------------------------------
create_empty_schemas() {
    echo "Creating empty schemas..."
    mysql_exec <<EOF
CREATE DATABASE IF NOT EXISTS $MARIADB_DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS characters CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS realmd     CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS logs       CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS $MANGOS_ADMIN_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'mangos'@'%' IDENTIFIED BY '$MARIADB_PASSWORD';
GRANT ALL PRIVILEGES ON $MARIADB_DATABASE.* TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON characters.*    TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON realmd.*        TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON logs.*          TO 'mangos'@'%';
GRANT ALL PRIVILEGES ON $MANGOS_ADMIN_DB.* TO 'mangos'@'%';
FLUSH PRIVILEGES;
EOF
}

apply_bundled_sql() {
    local label="$1" sql="$2"
    if [[ -z "$SQL_DIR" || ! -f "$SQL_DIR/$sql" ]]; then
        echo "  [skip] $label (no $sql in $SQL_DIR)"
        return 1
    fi
    echo "  [apply] $label ..."
    mysql_exec "$MARIADB_DATABASE" < "$SQL_DIR/$sql" 2>/dev/null \
    || mysql_exec "$MARIADB_DATABASE" < "$SQL_DIR/$sql" 2>&1 | tail -n 5
}

# ----------------------------------------------------------------------------
# World DB acquisition
# ----------------------------------------------------------------------------
acquire_world_db() {
    local source="$1"
    local out_file="$VENDOR/world.7z"
    local out_sql="$VENDOR/world.sql"

    if [[ -f "$out_sql" ]]; then
        echo "  [cached] $out_sql"
        echo "$out_sql"
        return
    fi

    # Local .sql
    if [[ -f "$source" && "$source" == *.sql ]]; then
        echo "  [copy] $source -> $out_sql"
        cp "$source" "$out_sql"
        echo "$out_sql"
        return
    fi

    # Local .7z
    if [[ -f "$source" && "$source" == *.7z ]]; then
        echo "  [copy] $source -> $out_file"
        cp "$source" "$out_file"
        echo "$out_file"
        return
    fi

    # URL
    if [[ "$source" =~ ^https?:// ]]; then
        echo "  [download] $source"
        curl -fL --retry 3 --retry-delay 5 -o "${out_file}.part" "$source"
        mv -f "${out_file}.part" "$out_file"
        echo "$out_file"
        return
    fi

    echo "ERROR: cannot resolve world DB source '$source'" >&2
    return 1
}

extract_world_db() {
    local in="$1" out_sql="$VENDOR/world.sql"
    if [[ "$in" == *.7z ]]; then
        if ! command -v 7z >/dev/null; then
            echo "ERROR: p7zip '7z' is required to extract .7z archives" >&2
            echo "  install: sudo apt install p7zip-full" >&2
            return 1
        fi
        echo "  [extract] $in"
        local tmp_dir="$INIT_DIR/extract"
        rm -rf "$tmp_dir"
        mkdir -p "$tmp_dir"
        7z x -y -o"$tmp_dir" "$in" >/dev/null
        # Find the largest .sql in the archive
        local found
        found=$(find "$tmp_dir" -name '*.sql' -type f -printf '%s\t%p\n' | sort -n | tail -n1 | cut -f2-)
        if [[ -z "$found" ]]; then
            echo "ERROR: no .sql file found inside $in" >&2
            return 1
        fi
        mv "$found" "$out_sql"
        echo "  [ok] -> $out_sql"
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
cmd_status() {
    echo "=== Database status ==="
    echo "Host: $MARIADB_HOST:$MARIADB_PORT"
    echo
    if ! mysql_exec -e "SELECT 1" >/dev/null 2>&1; then
        echo "  Cannot connect to MariaDB."
        return 1
    fi
    for db in "$MARIADB_DATABASE" characters realmd logs "$MANGOS_ADMIN_DB"; do
        local exists="no" tables="-"
        if db_exists "$db"; then
            exists="yes"
            tables=$(mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" -sN)
        fi
        printf "  %-15s exists=%s  tables=%s\n" "$db" "$exists" "$tables"
    done
}

case "${1:-}" in
    --status)
        cmd_status
        exit 0
        ;;
    --bare)
        MODE="bare"
        WORLD_SOURCE=""
        ;;
    --standard)
        MODE="standard"
        WORLD_SOURCE="${2:-${WORLD_DB_STANDARD_URL:-}}"
        ;;
    --full)
        MODE="full"
        WORLD_SOURCE="${2:-${WORLD_DB_FULL_URL:-}}"
        ;;
    --from)
        MODE="from"
        WORLD_SOURCE="${2:?missing path}"
        ;;
    -h|--help|help|"")
        sed -n '2,25p' "$0"
        exit 0
        ;;
    *)
        echo "Unknown command: $1" >&2
        exit 1
        ;;
esac

echo "=== MangosSuperUI database init (mode: $MODE) ==="
echo "Connecting to $MARIADB_HOST:$MARIADB_PORT as $MARIADB_USER ..."
if ! mysql_exec -e "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: cannot connect to MariaDB. Is the db service running?" >&2
    exit 1
fi

# 1. Always create empty schemas
create_empty_schemas
echo "  [ok] schemas created"

# 2. Apply the bundled base SQL (realmd, characters, logs, mangos schema)
echo
echo "Applying base SQL from SuperUI-Core..."
apply_bundled_sql "realmd schema"     "logon.sql"      || true
apply_bundled_sql "characters schema" "characters.sql" || true
apply_bundled_sql "logs schema"       "logs.sql"       || true
# The world DB schema is in the .sql we load below
if [[ "$MODE" == "bare" ]]; then
    apply_bundled_sql "mangos schema"  "mangos.sql"     || true
fi

# 3. World DB
if [[ "$MODE" != "bare" && -n "$WORLD_SOURCE" ]]; then
    echo
    echo "Acquiring world DB..."
    world_artifact=$(acquire_world_db "$WORLD_SOURCE")
    if [[ "$world_artifact" == *.7z ]]; then
        extract_world_db "$world_artifact"
    fi
    if [[ -f "$VENDOR/world.sql" ]]; then
        echo "  [load] $VENDOR/world.sql -> $MARIADB_DATABASE"
        echo "    (this may take a few minutes)"
        mysql_exec "$MARIADB_DATABASE" < "$VENDOR/world.sql"
        echo "  [ok] world DB loaded"
    fi
elif [[ "$MODE" == "bare" ]]; then
    echo
    echo "Bare mode: no world DB loaded. Load one later with:"
    echo "  ./scripts/init-database.sh --standard"
    echo "  ./scripts/init-database.sh --from /path/to/world.sql"
fi

# 4. MangosSuperUI admin DB - created at startup by the app, but pre-grant
echo
echo "Granting privileges for MangosSuperUI admin DB..."
mysql_exec <<EOF
GRANT ALL PRIVILEGES ON $MANGOS_ADMIN_DB.* TO 'mangos'@'%';
FLUSH PRIVILEGES;
EOF

echo
echo "=== Init complete ==="
cmd_status
