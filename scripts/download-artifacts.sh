#!/usr/bin/env bash
# =============================================================================
# Pre-downloads MangosSuperUI and SuperUI-Core release artifacts into ./vendor
# for offline Docker builds. Run on the HOST (Linux/macOS) before build.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR="$(pwd)/vendor"
mkdir -p "$VENDOR"

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
save_artifact "$UI_URL" "$VENDOR/$UI_NAME"

# ---- SuperUI-Core ----
echo
echo "[2/4] SuperUI-Core $SUPERUI_CORE_VERSION"
# SuperUI-Core uses GitHub Actions auto-generated artifact names like 'dev-<sha>.zip'
CORE_URL=$(github_asset_url "Yafrovon/SuperUI-Core" ".zip" "$SUPERUI_CORE_VERSION")
if [[ -z "$CORE_URL" ]]; then
    echo "  WARNING: no .zip asset found. Check https://github.com/Yafrovon/SuperUI-Core/releases"
    echo "  The asset may be named differently."
fi
if [[ -n "$CORE_URL" ]]; then
    CORE_NAME=$(basename "$CORE_URL")
    save_artifact "$CORE_URL" "$VENDOR/$CORE_NAME"
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
echo "=== Done. Run 'docker compose build' to assemble the images. ==="
