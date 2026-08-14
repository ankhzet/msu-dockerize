#!/usr/bin/env bash
# Apply all SuperUI-Core SQL migrations to bring world DB schema up to date.
# Runs as a one-shot job inside the migrations-apply container.
#
# Applies in order:
#   1. sql/old_migrations/*.sql   (pre-fork history)
#   2. sql/migrations/*.sql       (fork changes up to current)
#
# Error handling:
#   - Writes progress to /tmp/migrate-progress.log
#   - Writes completion marker on success
#   - Writes ERROR marker on catastrophic failure
#   - Continues past non-critical failures (logs them)
set -u

PROGRESS=/tmp/migrate-progress.log
: > "$PROGRESS"

log() { echo "$@" >> "$PROGRESS"; }

cleanup_and_exit() {
    rc=$1
    log ""
    log "EXIT_CODE=$rc"
    if [ $rc -eq 0 ]; then
        log "DONE_MARKER"
    else
        log "ERROR_MARKER exit=$rc"
    fi
    exit $rc
}

trap 'cleanup_and_exit $?' EXIT INT TERM

log "=== Starting migrations apply at $(date) ==="
log ""

cd /opt/superui-core/sql
mkdir -p /tmp/cleaned /tmp/cleaned/failed

# Sanity check
if ! command -v mariadb >/dev/null; then
    log "FATAL: mariadb client not found"
    exit 1
fi

# Test connection
if ! mariadb --skip-ssl -h "${MARIADB_HOST:-mariadb}" -P "${MARIADB_PORT:-3306}" -u "${MARIADB_USER:-root}" -p"${MARIADB_PASSWORD:-root}" -e "SELECT 1" >/dev/null 2>&1; then
    log "FATAL: cannot connect to MariaDB at ${MARIADB_HOST:-mariadb}:${MARIADB_PORT:-3306}"
    exit 1
fi
log "MariaDB connection OK"

apply_dir() {
    local dir="$1"
    local label="$2"
    cd "$dir" || { log "FATAL: cannot cd to $dir"; exit 1; }
    local total
    total=$(ls *.sql 2>/dev/null | wc -l)
    log ""
    log "=== Applying $label ($total files) ==="
    local i=0 fail=0 applied=0
    for f in $(ls *.sql 2>/dev/null); do
        id=$(echo "$f" | sed -E 's/_(world|characters|logs|logon)\.sql$//')
        case "$f" in
            *_logon.sql)      target_db="realmd" ;;
            *_characters.sql) target_db="characters" ;;
            *_logs.sql)       target_db="logs" ;;
            *_world.sql)      target_db="mangos" ;;
            *)                continue ;;
        esac
        already=$(mariadb --skip-ssl --max-allowed-packet=1G -h "${MARIADB_HOST:-mariadb}" -P "${MARIADB_PORT:-3306}" -u "${MARIADB_USER:-root}" -p"${MARIADB_PASSWORD:-root}" "$target_db" -N -e "SELECT 1 FROM migrations WHERE id='$id' LIMIT 1" 2>/dev/null)
        if [ "$already" = "1" ]; then
            continue
        fi
        # Strip `delimiter` lines; use --delimiter option instead
        sed -e '/^delimiter /d' "$f" > "/tmp/cleaned/$f" 2>/dev/null
        # Try with --delimiter=?? first; fall back to plain
        if ! mariadb --skip-ssl --max-allowed-packet=1G --binary-mode --delimiter='??' -h "${MARIADB_HOST:-mariadb}" -P "${MARIADB_PORT:-3306}" -u "${MARIADB_USER:-root}" -p"${MARIADB_PASSWORD:-root}" "$target_db" < "/tmp/cleaned/$f" >/dev/null 2>&1; then
            if ! mariadb --skip-ssl --max-allowed-packet=1G -h "${MARIADB_HOST:-mariadb}" -P "${MARIADB_PORT:-3306}" -u "${MARIADB_USER:-root}" -p"${MARIADB_PASSWORD:-root}" "$target_db" < "/tmp/cleaned/$f" >/dev/null 2>&1; then
                mariadb --skip-ssl --max-allowed-packet=1G -h "${MARIADB_HOST:-mariadb}" -P "${MARIADB_PORT:-3306}" -u "${MARIADB_USER:-root}" -p"${MARIADB_PASSWORD:-root}" "$target_db" < "/tmp/cleaned/$f" > "/tmp/cleaned/failed/$f.err" 2>&1 || true
                fail=$((fail+1))
                if [ $((fail % 20)) -eq 1 ]; then
                    log "  FAIL $fail on $f"
                fi
                continue
            fi
        fi
        i=$((i+1))
        applied=$((applied+1))
        if [ $((i % 100)) -eq 0 ]; then
            log "  applied $i ($f)"
        fi
    done
    log "  -> $label: applied=$applied fails=$fail"
    cd /opt/superui-core/sql
}

apply_dir old_migrations "old_migrations"
apply_dir migrations     "migrations"

log ""
log "=== Final state ==="
for db in mangos characters realmd logs; do
    n=$(mariadb --skip-ssl -h "${MARIADB_HOST:-mariadb}" -P "${MARIADB_PORT:-3306}" -u "${MARIADB_USER:-root}" -p"${MARIADB_PASSWORD:-root}" "$db" -N -e "SELECT COUNT(*) FROM migrations" 2>/dev/null)
    log "$db migrations: $n"
done

# Trap will fire cleanup_and_exit with rc=0
exit 0