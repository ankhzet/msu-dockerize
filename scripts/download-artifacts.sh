#!/usr/bin/env bash
# =============================================================================
# Pre-downloads MangosSuperUI and SuperUI-Core release artifacts into
# vendor/builds/{core,ui}/ for offline Docker builds. Run on the HOST
# (Linux/macOS) before build. After downloads, sync-vendor.sh is invoked
# to refresh vendor/current/ symlinks + .meta sidecars.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="$(pwd)/vendor"
BUILDS_CORE="$VENDOR/builds/core"
BUILDS_UI="$VENDOR/builds/ui"
mkdir -p "$VENDOR" "$BUILDS_CORE" "$BUILDS_UI"

# Load .env (if present)
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

MANGOS_SUPER_UI_VERSION="${MANGOS_SUPER_UI_VERSION:-v1.2}"
SUPERUI_CORE_VERSION="${SUPERUI_CORE_VERSION:-latest}"
SKIP_WORLD_DB="${SKIP_WORLD_DB:-1}"
FORCE="${FORCE:-}"

echo "=== MangosSuperUI Docker pre-cache ==="
echo "Vendor directory: $VENDOR"

# ---- helpers ----
github_asset_url() {
    local repo="$1" pattern="$2" tag="$3"
    local api
    if [[ "$tag" == "latest" ]]; then
        api="https://api.github.com/repos/$repo/releases/latest"
    else
        api="https://api.github.com/repos/$repo/releases/tags/$tag"
    fi
    # Try the tag/release first; fall back to listing pre-releases
    local url
    url=$(curl -sSL -H 'User-Agent: MangosSuperUI-Docker' "$api" \
        | grep -oE '"browser_download_url":[[:space:]]*"[^"]*'"$pattern"'[^"]*"' \
        | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [[ -z "$url" ]]; then
        url=$(curl -sSL -H 'User-Agent: MangosSuperUI-Docker' \
            "https://api.github.com/repos/$repo/releases?per_page=20" \
            | grep -oE '"browser_download_url":[[:space:]]*"[^"]*'"$pattern"'[^"]*"' \
            | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    fi
    echo "$url"
}

save_artifact() {
    local url="$1" out="$2"
    if [[ -f "$out" && -z "$FORCE" ]]; then
        local size
        size=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out" 2>/dev/null || echo 0)
        echo "  [cached] $(basename "$out") ($((size/1024/1024)) MB)"
        return
    fi
    echo "  Downloading: $url"
    local tmp="${out}.part"
    curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"
    mv -f "$tmp" "$out"
    local size
    size=$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out" 2>/dev/null || echo 0)
    echo "  [ok] $(basename "$out") ($((size/1024/1024)) MB)"
}

# ---- MangosSuperUI ----
echo
echo "[1/4] MangosSuperUI $MANGOS_SUPER_UI_VERSION"
UI_URL=$(github_asset_url "Yafrovon/MangosSuperUI" "LINUX" "$MANGOS_SUPER_UI_VERSION")
if [[ -z "$UI_URL" ]]; then
    echo "  WARNING: asset not found, trying direct URL"
    UI_URL="https://github.com/Yafrovon/MangosSuperUI/releases/download/${MANGOS_SUPER_UI_VERSION}/MSUI---LINUX---v1.2.2.zip"
fi
# Derive a sensible filename from the URL
UI_NAME=$(basename "$UI_URL")
save_artifact "$UI_URL" "$BUILDS_UI/$UI_NAME"

# ---- SuperUI-Core ----
echo
echo "[2/4] SuperUI-Core $SUPERUI_CORE_VERSION"
# Two paths: prebuilt artifact (default) or compile-from-source (BUILD_FROM_SOURCE=1).
# Source-build path produces vendor/dev-<sha>.tar.gz via the
# superui-core-builder compose service, then the regular server Dockerfile
# picks it up via its existing tar.gz/zip unpack logic.
if [[ "${BUILD_FROM_SOURCE:-0}" == "1" ]]; then
    echo "  BUILD_FROM_SOURCE=1: skipping prebuilt zip download."
    echo "  The source tree is read from vendor/SuperUI-Core (git submodule)."
    echo "  Run on the HOST first:  git submodule update --init vendor/SuperUI-Core"
    echo "  Then build it:"
    echo "    docker compose --profile source-build run --rm superui-core-builder"
    echo "  Then: docker compose build mangosd"
else
    # SuperUI-Core uses GitHub Actions auto-generated artifact names like 'dev-<sha>.zip'
    CORE_URL=$(github_asset_url "Yafrovon/SuperUI-Core" ".zip" "$SUPERUI_CORE_VERSION")
    if [[ -z "$CORE_URL" ]]; then
        echo "  WARNING: no .zip asset found. Check https://github.com/Yafrovon/SuperUI-Core/releases"
        echo "  The asset may be named differently."
    fi
    if [[ -n "$CORE_URL" ]]; then
        CORE_NAME=$(basename "$CORE_URL")
        save_artifact "$CORE_URL" "$BUILDS_CORE/$CORE_NAME"
    fi
fi

# ---- SuperUI-Core SQL files (small, ~few MB) ----
echo
echo "[3/4] SuperUI-Core SQL schema files"
SQL_TAG=$([[ "$SUPERUI_CORE_VERSION" == "latest" ]] && echo "development" || echo "$SUPERUI_CORE_VERSION")
SQL_DIR="$VENDOR/sql"
mkdir -p "$SQL_DIR"
WANTED=("logon.sql" "realmd.sql" "characters.sql" "logs.sql" "mangos.sql")
# Try sql/base/ first, fall back to sql/
for api_path in "sql/base" "sql"; do
    API="https://api.github.com/repos/Yafrovon/SuperUI-Core/contents/$api_path?ref=$SQL_TAG"
    SQL_LIST=$(curl -fsSL -H 'User-Agent: MangosSuperUI-Docker' "$API" 2>/dev/null || echo "")
    if [[ -n "$SQL_LIST" && "$SQL_LIST" != *"Not Found"* ]]; then
        for fname in "${WANTED[@]}"; do
            DL_URL=$(echo "$SQL_LIST" | grep -oE '"download_url"[[:space:]]*:[[:space:]]*"[^"]*'"$fname"'"' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ -n "$DL_URL" ]]; then
                save_artifact "$DL_URL" "$SQL_DIR/$fname"
            fi
        done
        break
    fi
done
if [[ ! -f "$SQL_DIR/logon.sql" ]]; then
    echo "  WARNING: could not fetch SQL files. Place realmd.sql, characters.sql,"
    echo "  logs.sql into ./vendor/sql/ manually if --standard/--full init fails."
fi

# ---- SuperUI-Core SQL migrations (mangosd refuses to start without these) ----
echo
echo "[3b/4] SuperUI-Core SQL migrations (mangosd refuses to start without these)"
# Old pre-fork history (1436 files) + fork changes (1047 files). Without both,
# migrations can fail because the fork assumes the baseline that
# sql/old_migrations/ provides.
fetch_dir_sql() {
    # Fetches every .sql file from a GitHub repo directory using the Tree API,
    # so we don't need a full git clone (~250 MB of historical SQL).
    local ref="$1" remote_dir="$2" out_dir="$3" label="$4"
    mkdir -p "$out_dir"
    local existing
    existing=$(ls "$out_dir"/*.sql 2>/dev/null | wc -l)
    if [[ "$existing" -gt 0 && -z "$FORCE" ]]; then
        echo "  [cached] $label: $existing files"
        return
    fi
    local api="https://api.github.com/repos/Yafrovon/SuperUI-Core/git/trees/$ref?recursive=1"
    echo "  Fetching $label listing from $ref..."
    local listing
    listing=$(curl -fsSL -H 'User-Agent: MangosSuperUI-Docker' "$api" 2>/dev/null || echo "")
    if [[ -z "$listing" ]]; then
        echo "  WARNING: could not fetch listing for $remote_dir; skip."
        return
    fi
    # Extract raw blob URLs for files under <remote_dir>/*.sql
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local path="${line#* }"
        local fname
        fname=$(basename "$path")
        [[ -s "$out_dir/$fname" ]] && continue
        local dl="https://raw.githubusercontent.com/Yafrovon/SuperUI-Core/$ref/$path"
        if ! curl -fsSL --retry 2 --retry-delay 2 "$dl" -o "$out_dir/$fname" 2>/dev/null; then
            echo "    [warn] failed: $fname"
        fi
    done < <(echo "$listing" \
        | grep -oE '"path":[[:space:]]*"'"$remote_dir"'/[0-9]+_[a-z]+\.sql"' \
        | sed -E 's|.*"path":[[:space:]]*"([^"]+)".*|\1|')
    echo "  [ok] $label: $(ls "$out_dir"/*.sql 2>/dev/null | wc -l) files"
}
fetch_dir_sql "$SQL_TAG" "sql/old_migrations" "$SQL_DIR/old_migrations" "old_migrations"
fetch_dir_sql "$SQL_TAG" "sql/migrations"     "$SQL_DIR/migrations"     "migrations"

# ---- World DB ----
echo
if [[ "$SKIP_WORLD_DB" == "1" ]]; then
    echo "[4/4] World DB archives SKIPPED (default). To download on demand:"
    echo "  ./scripts/init-database.sh --standard  # smallest available"
    echo "  ./scripts/init-database.sh --full      # latest available"
    echo "  Or place a .7z file in ./vendor/ and reference it via WORLD_DB_MODE in .env"
else
    echo "[4/4] World DB archives"
    [[ -n "$WORLD_DB_STANDARD_URL" ]] && save_artifact "$WORLD_DB_STANDARD_URL" "$VENDOR/$(basename "$WORLD_DB_STANDARD_URL")"
    [[ -n "$WORLD_DB_FULL_URL" ]]     && save_artifact "$WORLD_DB_FULL_URL"     "$VENDOR/$(basename "$WORLD_DB_FULL_URL")"
fi

echo
echo "=== Done. ==="
echo
echo "Refreshing vendor/current/ symlinks..."
"$(dirname "$0")/sync-vendor.sh"
echo
echo "Next: docker compose build"
