#!/usr/bin/env bash
# =============================================================================
# Extract DBC, Maps, VMaps, and (optionally) MMaps from a WoW 1.12.1 client
# and wire them into the running mangosd container.
#
# Usage:
#   ./scripts/extract-client-data.sh                 # uses WOW_CLIENT_DATA env
#   ./scripts/extract-client-data.sh /path/to/wow   # explicit path
#   ./scripts/extract-client-data.sh --no-mmaps      # skip MMaps (saves hours)
#   ./scripts/extract-client-data.sh --no-restart    # don't restart mangosd after
#   ./scripts/extract-client-data.sh --clean         # wipe extracted data first
#
# The script:
#   1. Validates the client path (looks for .MPQ files and DBC)
#   2. Mounts it into the running mangosd container (if not already mounted
#      via WOW_CLIENT_DATA in docker-compose.yml)
#   3. Runs MapExtractor, VMapExtractor, VMapAssembler (and optionally
#      MoveMapGenerator) inside the container
#   4. Moves the extracted data to the persistent core-data volume so it
#      survives container restarts
#   5. Restarts mangosd to pick up the new data
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

CONTAINER="${MANGOS_CONTAINER:-mangos-world-server}"
SKIP_MMAPS=0
DO_RESTART=1
DO_CLEAN=0
CLIENT_PATH=""

usage() {
    sed -n '2,21p' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-mmaps)   SKIP_MMAPS=1 ;;
        --no-restart) DO_RESTART=0 ;;
        --clean)      DO_CLEAN=1 ;;
        -h|--help)    usage ;;
        -*)           echo "Unknown flag: $1" >&2; usage ;;
        *)
            [[ -n "$CLIENT_PATH" ]] && { echo "Multiple paths given"; usage; }
            CLIENT_PATH="$1"
            ;;
    esac
    shift
done

# Resolve client path: arg > env > .env > fail
if [[ -z "$CLIENT_PATH" ]]; then
    CLIENT_PATH="${WOW_CLIENT_DATA:-}"
fi
if [[ -z "$CLIENT_PATH" && -f .env ]]; then
    CLIENT_PATH="$(grep -E '^WOW_CLIENT_DATA=' .env | cut -d= -f2- | tr -d '"' || true)"
fi
if [[ -z "$CLIENT_PATH" ]]; then
    echo "ERROR: no WoW client path. Either:"
    echo "  - pass it as the first argument: $0 /path/to/wow"
    echo "  - or set WOW_CLIENT_DATA= in .env (or the environment)"
    exit 1
fi

# Convert Windows-style paths (e.g. C:\Games\WoW) to Git Bash / Docker mount form
CLIENT_PATH="${CLIENT_PATH//\\/\/}"

if [[ ! -d "$CLIENT_PATH" ]]; then
    echo "ERROR: path does not exist or is not a directory: $CLIENT_PATH"
    exit 1
fi

echo "============================================================"
echo "  WoW 1.12.1 client data extractor"
echo "  Path:    $CLIENT_PATH"
echo "  Skips:   $([[ $SKIP_MMAPS -eq 1 ]] && echo 'MMaps ' || echo '')$([[ $DO_RESTART -eq 0 ]] && echo 'restart' || echo '')"
echo "============================================================"

# --- Validate the client ---
# Detect whether the path is the client root (with Data/ subdir) or just Data/.
has_data_subdir=0
has_mpq=0
if [[ -d "$CLIENT_PATH/Data" ]] || [[ -d "$CLIENT_PATH/data" ]]; then
    has_data_subdir=1
fi
if compgen -G "$CLIENT_PATH/*.MPQ" >/dev/null || compgen -G "$CLIENT_PATH/Data/*.MPQ" >/dev/null || compgen -G "$CLIENT_PATH/data/*.MPQ" >/dev/null; then
    has_mpq=1
fi

# Smell-test: look for known DBC files. In 1.12.1 the DBCs are inside dbc.MPQ
# (not loose), but MPQ archives are the real tell-tale.
dbc_hits=0
for f in Map.dbc CinematicCamera.dbc DBCache.bin dbc.MPQ; do
    [[ -f "$CLIENT_PATH/$f" ]] && dbc_hits=$((dbc_hits+1))
    [[ -f "$CLIENT_PATH/Data/$f" ]] && dbc_hits=$((dbc_hits+1))
done

echo ""
echo "Validation:"
echo "  Client root has 'Data/' subdir: $([[ $has_data_subdir -eq 1 ]] && echo yes || echo no)"
echo "  *.MPQ archives visible:         $([[ $has_mpq -eq 1 ]] && echo yes || echo no)"
echo "  Known DBC files visible:        $dbc_hits / 3"
echo ""

if [[ $has_mpq -eq 0 && $dbc_hits -eq 0 ]]; then
    echo "ERROR: path doesn't look like a WoW 1.12.1 client."
    echo "Expected to find Data/ with .MPQ files (e.g. common.MPQ, expansion.MPQ)"
    echo "or known DBC files (Map.dbc, CinematicCamera.dbc, DBCache.bin)."
    exit 1
fi

if [[ $dbc_hits -eq 0 ]]; then
    echo "WARNING: no DBC files visible. The MapExtractor will fail."
    echo "Continuing in 5 seconds (Ctrl+C to abort)..."
    sleep 5
fi

# --- Verify the mangosd container is running ---
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: container '$CONTAINER' is not running. Start the stack first."
    exit 1
fi

# --- Verify the mangosd container can see the client at /data ---
# (Use `cd / && ...` to dodge Git Bash turning `/data` into `D:/Software/Git/data`.)
if ! docker exec "$CONTAINER" sh -c 'cd / && test -d /data' 2>/dev/null; then
    echo "ERROR: container '$CONTAINER' has no /data directory."
    echo "Set WOW_CLIENT_DATA in .env to your client path and restart the stack:"
    echo "  echo 'WOW_CLIENT_DATA=$CLIENT_PATH' >> .env"
    echo "  docker compose up -d"
    exit 1
fi
echo "  Container sees /data: $(docker exec "$CONTAINER" sh -c 'cd / && ls /data' 2>/dev/null | head -3 | tr '\n' ' ')..."

# --- Run the extraction inside the container ---
echo ""
echo "Running extraction inside the container (this can take 10-30 min for VMaps)..."
docker exec -i "$CONTAINER" sh -c 'cd / && exec bash -s -- '"$((SKIP_MMAPS))"' '"$((DO_CLEAN))"'' <<'REMOTE'
set -e
WORKDIR="/tmp/extract-$$"
CLIENT="/data"
mkdir -p "$WORKDIR"
cp -r /opt/superui-core/bin/Extractors "$WORKDIR/"
cd "$WORKDIR/Extractors"

# Detect the source dir layout (client root vs Data/)
if [[ -d "$CLIENT/Data" ]]; then
    SRC="$CLIENT"
elif [[ -d "$CLIENT/data" ]]; then
    SRC="$CLIENT"
else
    # /data IS the Data/ subdir
    SRC="$(dirname "$CLIENT")"
fi

SKIP_MMAPS="$1"
DO_CLEAN="$2"
DEST="/opt/superui-core/data"

echo "  Source dir: $SRC"
echo "  Output dir: $DEST"

if [[ "$DO_CLEAN" -eq 1 ]]; then
    echo "  --clean: wiping dbc/ maps/ vmaps/ mmaps/ ..."
    rm -rf "$DEST/dbc" "$DEST/maps" "$DEST/vmaps" "$DEST/mmaps" "$DEST/Cameras" "$DEST/dbcache"
fi
rm -f "$DEST/maps/000*.map" 2>/dev/null || true   # safety

echo ""
echo "[1/4] MapExtractor (DBC + Maps, ~1-3 min)"
./MapExtractor -i "$SRC" > "$WORKDIR/MapExtractor.log" 2>&1
m=$?; if [[ $m -ne 0 ]]; then echo "  FAILED (exit $m); tail of log:"; tail -20 "$WORKDIR/MapExtractor.log"; exit $m; fi
echo "  ok"

echo ""
echo "[2/4] VMapExtractor (raw visual maps, ~5-15 min)"
./VMapExtractor -l -d "$SRC" > "$WORKDIR/VMapExtractor.log" 2>&1
v=$?; if [[ $v -ne 0 ]]; then echo "  FAILED (exit $v); tail of log:"; tail -20 "$WORKDIR/VMapExtractor.log"; exit $v; fi
echo "  ok"

echo ""
echo "[3/4] VMapAssembler (assemble tree + tiles, ~2-5 min)"
mkdir -p vmaps
./VMapAssembler vmaps Buildings 1 > "$WORKDIR/VMapAssembler.log" 2>&1 \
    || ./VMapAssembler . Buildings 1 > "$WORKDIR/VMapAssembler.log" 2>&1 \
    || { echo "  FAILED; tail of log:"; tail -20 "$WORKDIR/VMapAssembler.log"; exit 1; }
echo "  ok"

if [[ "$SKIP_MMAPS" -eq 0 ]]; then
    echo ""
    echo "[4/4] MoveMapGenerator (movement maps, hours - use --no-mmaps to skip)"
    mkdir -p mmaps
    ./MoveMapGenerator --help > /dev/null 2>&1 && ./MoveMapGenerator || true
    echo "  (mmaps best run manually: cd $DEST/mmaps && /opt/superui-core/bin/Extractors/MoveMapGenerator)"
else
    echo ""
    echo "[4/4] MoveMapGenerator: SKIPPED (--no-mmaps)"
fi

# --- Move generated data to the persistent volume ---
echo ""
echo "Moving extracted data into $DEST ..."
# MapExtractor outputs to ./dbc, ./maps, ./Cameras; VMapAssembler outputs to ./vmaps
for d in dbc maps Cameras vmaps; do
    if [[ -d "$d" ]]; then
        rm -rf "$DEST/$d"
        mv "$d" "$DEST/"
        echo "  $d -> $DEST/$d ($(du -sh "$DEST/$d" | cut -f1))"
    fi
done
if [[ -d mmaps ]]; then
    rm -rf "$DEST/mmaps"
    mv mmaps "$DEST/"
fi

# Also copy the DBCache.bin if generated (some clients)
[[ -f DBCache.bin ]] && cp DBCache.bin "$DEST/" 2>/dev/null || true

echo ""
echo "Final layout:"
du -sh "$DEST"/* 2>/dev/null | sort -h | tail -20
rm -rf "$WORKDIR"
REMOTE

echo ""
echo "============================================================"
echo "  Done."
echo "============================================================"

if [[ $DO_RESTART -eq 1 ]]; then
    echo "Restarting mangosd..."
    docker compose restart mangosd 2>&1 | tail -2
    sleep 5
    echo ""
    echo "Container status:"
    docker compose ps mangosd
    echo ""
    echo "mangosd log tail (look for 'World server is running'):"
    docker exec "$CONTAINER" sh -c 'tail -25 /opt/superui-core/logs/mangosd.log' 2>&1 | grep -vE '^\[0m\s+20[0-9]{12}$' | tail -10
else
    echo "(Skipped restart per --no-restart. Restart manually: docker compose restart mangosd)"
fi