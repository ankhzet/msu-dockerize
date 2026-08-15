#!/usr/bin/env bash
# =============================================================================
# Sync vendor/{builds,current} layout
# =============================================================================
# Layout:
#   vendor/builds/core/<files>   Immutable artifact history (gitignored).
#   vendor/builds/ui/<files>     Each new build is appended here.
#   vendor/current/core          Active core archive (hardlink - no extension).
#   vendor/current/core.meta     Sidecar: tells the Dockerfile the format.
#   vendor/current/ui            Active UI archive (hardlink - no extension).
#   vendor/current/ui.meta       Sidecar: tells the Dockerfile the format.
#
# Why hardlinks instead of symlinks: Docker COPY on Windows preserves NTFS
# symlinks as symlinks in the image, but only the symlink - not its target
# (which lives in vendor/builds/, never COPYed). The result is a broken
# symlink inside the image. Hardlinks share the target's inode, so Docker
# COPY treats them as regular files - they always work, on every platform,
# with no special permissions. They behave identically from the script's
# perspective: rm + ln to switch.
#
# .meta format (one KEY=VALUE pair per line):
#   format=tar.gz|zip|tar.xz      REQUIRED: how to extract
#   source=upstream|source-built  optional: provenance
#
# What this script does:
#   1. One-time migration of legacy vendor/*.{zip,tar.gz} into vendor/builds/.
#   2. Picks the freshest artifact in each category and atomically updates
#      the vendor/current/{core,ui} hardlink + .meta sidecar.
#   3. Optionally prunes older artifacts (--keep N).
#
# Idempotent - safe to re-run. Invoked at the end of every build-core.sh /
# build-ui.sh run and at the end of download-artifacts.sh. To pick a
# specific older build interactively, run scripts/switch-build.sh.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
VENDOR="$(pwd)/vendor"
BUILDS="$VENDOR/builds"
CURRENT="$VENDOR/current"
KEEP=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--keep N]

  --keep N   Keep only the N most-recent artifacts per category
             (oldest deleted). Default: keep everything.

With no flags, syncs the current symlinks to the freshest build.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            KEEP="${2:-}"
            [[ -z "$KEEP" ]] && { echo "ERROR: --keep requires an integer"; exit 1; }
            shift 2
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $1"; usage; exit 1
            ;;
    esac
done

mkdir -p "$BUILDS/core" "$BUILDS/ui" "$CURRENT"

# ---------------------------------------------------------------------------
# 1. Migrate legacy vendor/{*.zip,*.tar.gz} into vendor/builds/{core,ui}/.
# ---------------------------------------------------------------------------
migrate_legacy() {
    local category="$1"; shift
    local pattern="$1"; shift
    local moved=0
    for f in $VENDOR/$pattern; do
        [ -e "$f" ] || continue
        case "$f" in "$BUILDS"/*) continue ;; esac
        case "$(basename "$f")" in "SuperUI-Core"|"MangosSuperUI") continue ;; esac
        case "$f" in *.7z|*.tar.xz|*.tar.bz2) continue ;; esac
        local base dest_dir
        base=$(basename "$f")
        dest_dir="$BUILDS/core"
        case "$base" in
            *MSUI*|*msui*|*MangosSuperUI*) dest_dir="$BUILDS/ui" ;;
        esac
        if [[ -e "$dest_dir/$base" ]]; then
            continue
        fi
        echo "  Migrate: $f -> $dest_dir/"
        mv "$f" "$dest_dir/$base"
        moved=$((moved+1))
    done
    if [[ $moved -gt 0 ]]; then
        echo "  ($moved file(s) moved)"
    fi
}

echo "[1/3] Migrating legacy vendor/ files..."
migrate_legacy core 'dev-*.zip'
migrate_legacy core 'dev-*.tar.gz'
migrate_legacy core 'dev-*.tar.xz'
migrate_legacy ui 'MSUI*.zip'
migrate_legacy ui 'msui-*.tar.gz'

# ---------------------------------------------------------------------------
# 2. Pick freshest per category; update symlink + .meta sidecar.
# ---------------------------------------------------------------------------

# Map filename extension -> format key (what the Dockerfile's case statement uses).
detect_format() {
    case "$1" in
        *.zip)    echo zip ;;
        *.tar.gz) echo tar.gz ;;
        *.tar.xz) echo tar.xz ;;
        *)        echo ""; return 1 ;;
    esac
}

_mtime() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

pick_freshest() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local picked
    picked=$( \
        { \
            for f in "$dir"/*.tar.gz "$dir"/*.tar.xz "$dir"/*.zip; do \
                [ -e "$f" ] || continue; \
                local base k
                base=$(basename "$f")
                if [[ "$base" =~ ([0-9]{8,}) ]]; then
                    k="${BASH_REMATCH[1]}"
                else
                    k=$(_mtime "$f")
                fi
                printf '%s\t%s\n' "$k" "$f"; \
            done; \
        } | sort -r | head -n1 | cut -f2- \
    )
    [[ -n "$picked" ]] && echo "$picked"
}

sync_category() {
    local category="$1"
    local dir="$BUILDS/$category"
    local link="$CURRENT/$category"
    local meta="$CURRENT/$category.meta"

    local picked
    picked=$(pick_freshest "$dir")
    if [[ -z "$picked" ]]; then
        echo "[$category] no artifacts in $dir (skip)"
        return 0
    fi

    local fmt
    fmt=$(detect_format "$picked") || {
        echo "ERROR: $picked has unknown extension (expected .zip, .tar.gz, .tar.xz)"
        return 1
    }

    # Relative symlink so the vendor/ tree stays portable.
    local rel
    rel=$(realpath --relative-to="$CURRENT" "$picked" 2>/dev/null \
        || python3 -c "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$picked" "$CURRENT" 2>/dev/null \
        || echo "../builds/$category/$(basename "$picked")")

    # Atomic "swap" of the current pointer. We use a hardlink (ln WITHOUT -s)
    # rather than a symlink because Docker COPY on Windows preserves symlinks
    # as symlinks - if the target isn't in the same COPY, the symlink ends up
    # broken in the image. Hardlinks share the target's inode, so Docker sees
    # a regular file.
    rm -f "$link"
    ln "$picked" "$link"

    # Write sidecar metadata. Overwrite atomically via temp + mv.
    local tmp_meta="$meta.tmp"
    {
        echo "format=$fmt"
        # Provenance hint based on filename pattern (upstream prebuilts
        # vs source-built tarballs).
        case "$(basename "$picked")" in
            dev-*|msui-*) echo "source=source-built" ;;
            *)            echo "source=upstream" ;;
        esac
        # Relative path to the hardlinked target (vendor/builds/<cat>/<file>).
        # Stored so switch-build.sh --current can show it without scanning
        # the filesystem for matching inodes.
        echo "target=$rel"
    } > "$tmp_meta"
    mv -f "$tmp_meta" "$meta"

    echo "[$category] -> $rel   (format=$fmt, hardlink)"
}

echo "[2/3] Updating vendor/current/ symlinks + .meta..."
sync_category core
sync_category ui

# ---------------------------------------------------------------------------
# 3. Optional prune --keep N.
# ---------------------------------------------------------------------------
prune_category() {
    local category="$1"
    local dir="$BUILDS/$category"
    [ -d "$dir" ] || return 0
    ls -1t "$dir"/*.tar.gz "$dir"/*.tar.xz "$dir"/*.zip 2>/dev/null \
        | tail -n +$((KEEP + 1)) \
        | while IFS= read -r f; do
            [ -n "$f" ] || continue
            echo "  Prune: $f"
            rm -f "$f"
        done
}

if [[ -n "$KEEP" ]]; then
    echo "[3/3] Pruning to last $KEEP artifact(s) per category..."
    prune_category core
    prune_category ui
else
    echo "[3/3] No --keep specified, keeping all historical builds."
fi

echo
echo "Current active artifacts:"
for c in core ui; do
    link="$CURRENT/$c"
    meta="$CURRENT/$c.meta"
    if [[ -f "$link" ]]; then
        fmt=""
        [ -f "$meta" ] && fmt=$(grep '^format=' "$meta" | cut -d= -f2)
        size_mb=$(( $(stat -c %s "$link") / 1024 / 1024 ))
        links=$(stat -c %h "$link")
        if [[ "$links" -gt 1 ]]; then
            echo "  $c (hardlink, $links refs, ${size_mb}MB) [format=$fmt]"
        else
            echo "  $c (regular file, ${size_mb}MB) [format=$fmt]"
        fi
    else
        echo "  $c (not set)"
    fi
done
