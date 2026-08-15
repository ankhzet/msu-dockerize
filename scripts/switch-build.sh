#!/usr/bin/env bash
# =============================================================================
# Pick which build is "current" for the runtime images.
# =============================================================================
# Lists artifacts in vendor/builds/{core,ui}/ and updates vendor/current/
# hardlinks + .meta sidecars to point at the chosen file.
#
# Usage:
#   switch-build.sh                       list both, interactive pick
#   switch-build.sh core                  interactive pick for core
#   switch-build.sh ui                    interactive pick for ui
#   switch-build.sh core FILE             set core to FILE (non-interactive)
#   switch-build.sh ui FILE               set ui to FILE (non-interactive)
#   switch-build.sh core latest           set core to the freshest build
#                                         (equivalent to running sync-vendor.sh)
#   switch-build.sh --list                list both categories
#   switch-build.sh --list core           list only core builds
#   switch-build.sh --current             show current active artifacts
#
# Hardlinks vs symlinks: see sync-vendor.sh for the rationale. TL;DR -
# Docker COPY on Windows preserves symlinks as broken symlinks, so we use
# hardlinks (which COPY as regular files).
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
VENDOR="$(pwd)/vendor"
BUILDS="$VENDOR/builds"
CURRENT="$VENDOR/current"

mkdir -p "$BUILDS/core" "$BUILDS/ui" "$CURRENT"

# ---------- format detection ----------
fmt_of() {
    case "$1" in
        *.zip)    echo zip ;;
        *.tar.gz) echo tar.gz ;;
        *.tar.xz) echo tar.xz ;;
        *)        echo "" ;;
    esac
}

# ---------- human size ----------
# Uses awk (POSIX, ships everywhere) instead of bc -l which isn't in
# Git Bash on Windows.
human_size() {
    local bytes
    bytes=$(stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0)
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824)      printf "%.1fG", b/1073741824
        else if (b >= 1048576)    printf "%.1fM", b/1048576
        else if (b >= 1024)       printf "%.1fK", b/1024
        else                      printf "%dB",  b
    }'
}

# ---------- list builds in a category ----------
# Prints lines: "<idx>\t<absolute path>\t<size>\t<mtime-iso>"
list_builds() {
    local category="$1"
    local dir="$BUILDS/$category"
    [ -d "$dir" ] || return 0
    local i=0
    # Newest first.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        i=$((i+1))
        local size mtime
        size=$(human_size "$f")
        # ISO 8601, second precision - portable across GNU/BSD stat.
        mtime=$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1 \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f" 2>/dev/null)
        printf '%d\t%s\t%s\t%s\n' "$i" "$f" "$mtime" "$size"
    done < <(ls -1t "$dir"/*.tar.gz "$dir"/*.tar.xz "$dir"/*.zip 2>/dev/null)
}

print_list() {
    local category="$1"
    echo
    echo "  $category/ ($(ls -1 "$BUILDS/$category" 2>/dev/null | wc -l) build(s))"
    echo "  ─────────────────────────────────────────────────────────────────────"
    printf '  %-4s %-19s  %-12s %-8s  %s\n' "#" "MTIME" "SIZE" "FORMAT" "FILE (newest first)"
    local count=0
    while IFS=$'\t' read -r idx path mtime size; do
        [ -n "$idx" ] || continue
        local base fmt active=""
        base=$(basename "$path")
        fmt=$(fmt_of "$base")
        # Mark currently-active build (compares inode, since current is a hardlink).
        if [[ -f "$CURRENT/$category" ]] && [[ "$(stat -c %i "$path" 2>/dev/null)" == "$(stat -c %i "$CURRENT/$category" 2>/dev/null)" ]]; then
            active=" (active)"
        fi
        printf '  %-4s %-19s  %-12s %-8s  %s%s\n' "[$idx]" "$mtime" "$size" "$fmt" "$base" "$active"
        count=$((count+1))
    done < <(list_builds "$category")
    if [[ $count -eq 0 ]]; then
        echo "    (no builds yet)"
    fi
}

# ---------- show current ----------
print_current() {
    echo "Current active artifacts:"
    for c in core ui; do
        if [[ -f "$CURRENT/$c" ]]; then
            fmt=""
            target=""
            if [[ -f "$CURRENT/$c.meta" ]]; then
                fmt=$(grep '^format=' "$CURRENT/$c.meta" | cut -d= -f2)
                target=$(grep '^target=' "$CURRENT/$c.meta" | cut -d= -f2-)
            fi
            printf '  %-5s -> %-60s [format=%s]\n' "$c" "$target" "$fmt"
        else
            printf '  %-5s (not set)\n' "$c"
        fi
    done
}

# ---------- set current to a specific file ----------
set_current() {
    local category="$1"
    local file="$2"

    # If the user passed a bare filename, look in the category's builds dir.
    if [[ ! -e "$file" ]]; then
        local candidate="$BUILDS/$category/$file"
        if [[ -e "$candidate" ]]; then
            file="$candidate"
        else
            echo "ERROR: $file does not exist (also tried $candidate)"
            exit 1
        fi
    fi

    local fmt
    fmt=$(fmt_of "$file")
    if [[ -z "$fmt" ]]; then
        echo "ERROR: $file has unknown extension (expected .zip/.tar.gz/.tar.xz)"
        exit 1
    fi

    local rel
    rel=$(realpath --relative-to="$CURRENT" "$file" 2>/dev/null \
        || python3 -c "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$file" "$CURRENT" 2>/dev/null \
        || echo "../builds/$category/$(basename "$file")")

    # Use a hardlink (no -s) instead of a symlink. See header comment.
    rm -f "$CURRENT/$category"
    ln "$file" "$CURRENT/$category"
    {
        echo "format=$fmt"
        case "$(basename "$file")" in
            dev-*|msui-*) echo "source=source-built" ;;
            *)            echo "source=upstream" ;;
        esac
        echo "target=$rel"
    } > "$CURRENT/$category.meta"
    echo "[$category] -> $rel   (format=$fmt, hardlink)"
}

# ---------- set current to freshest ----------
set_latest() {
    local category="$1"
    local dir="$BUILDS/$category"
    local picked
    picked=$(ls -1t "$dir"/*.tar.gz "$dir"/*.tar.xz "$dir"/*.zip 2>/dev/null | head -n1 || true)
    if [[ -z "$picked" ]]; then
        echo "ERROR: no builds in $dir"
        exit 1
    fi
    set_current "$category" "$picked"
}

# ---------- interactive picker for one category ----------
interactive_pick() {
    local category="$1"
    print_list "$category"

    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$BUILDS/$category"/*.tar.gz "$BUILDS/$category"/*.tar.xz "$BUILDS/$category"/*.zip 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "  (nothing to pick - run a builder or download-artifacts.sh first)"
        return 1
    fi

    if [[ ! -t 0 ]]; then
        echo "ERROR: stdin is not a TTY. Pass a filename explicitly: switch-build.sh $category <file>"
        return 1
    fi

    local prompt="Pick [$category] (1-${#files[@]}, or 'q' to skip): "
    local choice
    while true; do
        read -r -p "$prompt" choice
        case "$choice" in
            q|Q) echo "  skipped"; return 0 ;;
            ''|0) echo "  skipped"; return 0 ;;
            *)   if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
                      set_current "$category" "${files[$((choice-1))]}"
                      return 0
                  else
                      echo "  invalid choice: $choice"
                  fi ;;
        esac
    done
}

# ---------- arg parsing ----------
usage() {
    sed -n '2,18p' "$0"
}

ACTION=""
CATEGORY=""
ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list|-l)   ACTION="list"; shift ;;
        --current|-c) ACTION="current"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        core|ui)     CATEGORY="$1"; shift
                     if [[ $# -gt 0 ]] && [[ "$1" != -* ]]; then
                         ARG="$1"; shift
                     fi
                     ACTION="${ACTION:-set}" ;;
        *)
            echo "ERROR: unknown arg: $1"; usage; exit 1 ;;
    esac
done

# No args: show help + list everything, then exit (don't enter interactive mode).
if [[ -z "$ACTION" ]]; then
    usage
    print_list core
    print_list ui
    print_current
    exit 0
fi

case "$ACTION" in
    list)
        if [[ -n "$CATEGORY" ]]; then
            print_list "$CATEGORY"
        else
            print_list core
            print_list ui
        fi
        print_current
        ;;
    current)
        print_current
        ;;
    set)
        if [[ -z "$CATEGORY" ]]; then
            # No category given: interactive for both.
            interactive_pick core
            interactive_pick ui
            echo
            print_current
        else
            if [[ "$ARG" == "latest" || -z "$ARG" ]]; then
                if [[ -z "$ARG" ]]; then
                    interactive_pick "$CATEGORY"
                else
                    set_latest "$CATEGORY"
                fi
            else
                set_current "$CATEGORY" "$ARG"
            fi
        fi
        ;;
esac
