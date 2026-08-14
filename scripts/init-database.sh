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
# When the script is baked into the image at /usr/local/bin/db-init.sh,
# ROOT_DIR resolves to /usr/local which is meaningless. In that case, treat
# /opt/superui-core as the project root.
if [[ "$ROOT_DIR" == "/usr/local" || "$ROOT_DIR" == "/usr/local/bin" || "$ROOT_DIR" == "/" ]]; then
    ROOT_DIR="/opt/superui-core"
fi
VENDOR="$ROOT_DIR/vendor"
INIT_DIR="${INIT_DIR:-$ROOT_DIR/.init}"
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
# If MARIADB_ROOT_PASSWORD is set, use the root account (recommended for init).
# Otherwise fall back to the regular app user (limited to what was GRANTed).
if [ -n "${MARIADB_ROOT_PASSWORD:-}" ]; then
    MARIADB_USER="root"
    MARIADB_PASSWORD="$MARIADB_ROOT_PASSWORD"
else
    MARIADB_USER="${MARIADB_USER:-mangos}"
    MARIADB_PASSWORD="${MARIADB_PASSWORD:-mangos}"
fi
MARIADB_DATABASE="${MARIADB_DATABASE:-mangos}"
MANGOS_ADMIN_DB="${MANGOS_ADMIN_DB:-vmangos_admin}"

# GitHub branch/ref for the SuperUI-Core fork. Used to fetch migrations when
# the world DB is older than the fork's schema.
SUPERUI_CORE_REF="${SUPERUI_CORE_REF:-development}"

# ---- helpers ----
mysql_exec() {
    # Use a large max_allowed_packet so big INSERTs in the world DB dump
    # don't fail. Falls back to mysql client if mariadb is missing.
    mariadb --max-allowed-packet=1G \
        -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
        --skip-ssl --connect-timeout=10 "$@" 2>/dev/null \
    || mysql --max-allowed-packet=1G \
        -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
        --skip-ssl --connect-timeout=10 "$@" 2>/dev/null
}

db_exists() {
    # True if the named database is reachable by the current user.
    local db="$1"
    mysql_exec -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db' LIMIT 1" >/dev/null 2>&1
}

# Source SQL files (realmd, characters, logs) from the SuperUI-Core's sql/ dir
# These are bundled with the server image (or the source repo).
BUNDLED_SQL_DIR="${BUNDLED_SQL_DIR:-/opt/superui-core/sql}"
HOST_SQL_DIR="$INIT_DIR/sql"
HOST_VENDOR_DIR="$ROOT_DIR/vendor/sql"
if [[ -d "$BUNDLED_SQL_DIR" && "$(ls -A "$BUNDLED_SQL_DIR" 2>/dev/null | grep -v 'README\|\.gitkeep')" ]]; then
    SQL_DIR="$BUNDLED_SQL_DIR"
elif [[ -d "$HOST_VENDOR_DIR" && "$(ls -A "$HOST_VENDOR_DIR" 2>/dev/null | grep -v 'README\|\.gitkeep')" ]]; then
    SQL_DIR="$HOST_VENDOR_DIR"
elif [[ -d "$HOST_SQL_DIR" && "$(ls -A "$HOST_SQL_DIR" 2>/dev/null | grep -v 'README\|\.gitkeep')" ]]; then
    SQL_DIR="$HOST_SQL_DIR"
else
    echo "WARNING: no SuperUI-Core SQL directory found."
    echo "Expected either $BUNDLED_SQL_DIR, $HOST_VENDOR_DIR, or $HOST_SQL_DIR."
    echo "Run ./scripts/download-artifacts.ps1 to populate ./vendor/sql/."
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
    # Each upstream SQL file targets a specific schema. We must connect to that
    # schema (not the default mangos DB) so the unprefixed CREATE TABLE
    # statements land in the right place.
    local label="$1" target_db="$2" sql="$3"
    if [[ -z "$SQL_DIR" || ! -f "$SQL_DIR/$sql" ]]; then
        echo "  [skip] $label (no $sql in $SQL_DIR)"
        return 1
    fi
    echo "  [apply] $label -> $target_db ..."
    mysql_exec "$target_db" < "$SQL_DIR/$sql" 2>&1 | tail -n 5
}

# ----------------------------------------------------------------------------
# Migrations
# ----------------------------------------------------------------------------
# Bring realmd / characters / logs / mangos schemas up to the fork's current
# version. mangosd and realmd refuse to start when they detect missing
# migrations. We download the .sql migration files on demand from the fork's
# repository and apply any whose ID isn't already in the corresponding
# `migrations` table.
download_migrations() {
    local mig_dir="$SQL_DIR/migrations"
    mkdir -p "$mig_dir"
    if [[ -d "$mig_dir" ]] && [[ "$(ls -A "$mig_dir" 2>/dev/null | grep -c '\.sql$')" -gt 0 ]]; then
        echo "  Migrations already cached: $(ls "$mig_dir"/*.sql 2>/dev/null | wc -l) files"
        return
    fi
    echo "  Fetching migrations directory from SuperUI-Core@${SUPERUI_CORE_REF}..."
    local api="https://api.github.com/repos/Yafrovon/SuperUI-Core/contents/sql/migrations?ref=$SUPERUI_CORE_REF&per_page=1000"
    local listing
    listing=$(curl -fsSL -H 'User-Agent: MangosSuperUI-Docker' "$api" 2>/dev/null || echo "")
    if [[ -z "$listing" ]]; then
        echo "  WARNING: could not fetch migration listing. Migrations not applied."
        echo "  Run with --skip-migrations later, or pre-populate $mig_dir"
        return
    fi
    echo "$listing" | grep -oE '"download_url"[[:space:]]*:[[:space:]]*"[^"]*\.sql"' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | while read -r url; do
            [[ -z "$url" ]] && continue
            local fname
            fname=$(basename "$url")
            curl -fsSL "$url" -o "$mig_dir/$fname" 2>/dev/null || echo "    [warn] $fname failed"
        done
    echo "  [ok] $(ls "$mig_dir"/*.sql 2>/dev/null | wc -l) migration files cached"
}

apply_migrations() {
    download_migrations
    local mig_dir="$SQL_DIR/migrations"
    [[ ! -d "$mig_dir" ]] && return

    # Apply only migrations whose ID isn't already in the target schema's
    # migrations table. Filename convention from upstream:
    #   <timestamp>_logon.sql       -> realmd
    #   <timestamp>_characters.sql  -> characters
    #   <timestamp>_logs.sql        -> logs
    #   <timestamp>_world.sql       -> world (mangos)
    local counts_realmd=0 counts_chars=0 counts_logs=0 counts_world=0
    for f in "$mig_dir"/*.sql; do
        [[ -f "$f" ]] || continue
        local fname target_db id
        fname=$(basename "$f")
        id="${fname%.sql}"
        case "$fname" in
            *_logon.sql)      target_db="realmd" ;;
            *_characters.sql) target_db="characters" ;;
            *_logs.sql)       target_db="logs" ;;
            *_world.sql)      target_db="$MARIADB_DATABASE" ;;
            *)                target_db="" ;;
        esac
        [[ -z "$target_db" ]] && continue

        # Skip if this migration is already recorded in the target schema
        local already
        already=$(mysql_exec -N -e "SELECT 1 FROM ${target_db}.migrations WHERE id='$id' LIMIT 1" 2>/dev/null || echo "")
        if [[ "$already" == "1" ]]; then
            continue
        fi
        if mysql_exec "$target_db" < "$f" >/dev/null 2>&1; then
            case "$target_db" in
                realmd)     counts_realmd=$((counts_realmd+1)) ;;
                characters) counts_chars=$((counts_chars+1)) ;;
                logs)       counts_logs=$((counts_logs+1)) ;;
                *)          counts_world=$((counts_world+1)) ;;
            esac
        fi
    done
    echo "  [migrations applied] realmd=$counts_realmd characters=$counts_chars logs=$counts_logs mangos=$counts_world"
}

# ----------------------------------------------------------------------------
# World DB acquisition
# ----------------------------------------------------------------------------
acquire_world_db() {
    # Logs to stderr; returns the resulting file path on stdout.
    local source="$1"
    local out_file="$VENDOR/world.7z"
    local out_sql="$VENDOR/world.sql"

    if [[ -f "$out_sql" ]]; then
        echo "  [cached] $out_sql" >&2
        echo "$out_sql"
        return
    fi

    # Local .sql
    if [[ -f "$source" && "$source" == *.sql ]]; then
        echo "  [copy] $source -> $out_sql" >&2
        cp "$source" "$out_sql"
        echo "$out_sql"
        return
    fi

    # Local .7z
    if [[ -f "$source" && "$source" == *.7z ]]; then
        echo "  [copy] $source -> $out_file" >&2
        cp "$source" "$out_file"
        echo "$out_file"
        return
    fi

    # URL
    if [[ "$source" =~ ^https?:// ]]; then
        echo "  [download] $source" >&2
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

# 2. Apply the bundled base SQL (realmd, characters, logs schemas)
echo
echo "Applying base SQL from SuperUI-Core..."
apply_bundled_sql "realmd schema"     realmd     "logon.sql"      || true
apply_bundled_sql "characters schema" characters "characters.sql" || true
apply_bundled_sql "logs schema"       logs       "logs.sql"       || true
# (mangos schema is populated by the world DB dump below)

# 3. World DB
if [[ "$MODE" != "bare" && -n "$WORLD_SOURCE" ]]; then
    echo
    echo "Acquiring world DB..."
    world_artifact=$(acquire_world_db "$WORLD_SOURCE")
    if [[ "$world_artifact" == *.7z ]]; then
        extract_world_db "$world_artifact"
    fi
    if [[ -f "$VENDOR/world.sql" ]]; then
        # Check if the world DB is already loaded (skip reload for idempotency)
        existing_migs=$(mysql_exec -N -e "SELECT COUNT(*) FROM ${MARIADB_DATABASE}.migrations" 2>/dev/null || echo 0)
        if [[ "$existing_migs" -gt 0 ]]; then
            echo "  [skip] world DB already loaded ($existing_migs migrations present)"
        else
            echo "  [load] $VENDOR/world.sql -> $MARIADB_DATABASE"
            echo "    (this may take a few minutes)"
            mysql_exec --force "$MARIADB_DATABASE" < "$VENDOR/world.sql"
            echo "  [ok] world DB loaded"
        fi

        # 3b. Bring the schemas up to the fork's current version. Without this,
        # mangosd / realmd will refuse to start (missing migrations error).
        apply_migrations
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
