#!/usr/bin/env bash
# =============================================================================
# Build SuperUI-Core from the local submodule copy.
#
# Mirrors the upstream CI workflow verbatim:
#   https://github.com/Yafrovon/SuperUI-Core/blob/development/.github/workflows/windows-development-release.yaml
#
# The source tree is expected at ./vendor/SuperUI-Core/ (a git submodule
# pointing at https://github.com/Yafrovon/SuperUI-Core.git). To refresh to
# a newer commit, run on the HOST before invoking the builder:
#   git submodule update --remote vendor/SuperUI-Core
#
# Env vars (set in docker-compose.yml or the shell):
#   SRC                   Path to the source tree inside the container.
#                         Default: /work/vendor/SuperUI-Core (the submodule
#                         bind-mounted from the host).
#   CMAKE_BUILD_TYPE      RelWithDebInfo (default; -O2 -g, debug symbols for
#                         gdb/backtraces). Use Release for a smaller binary
#                         without symbols, or Debug for an unoptimized build.
#   BUILD_EXTRACTORS      1 (default) builds MoveMapGenerator / VMapExtractor /
#                         MapExtractor / VMapAssembler. 0 skips them.
#   OUT_NAME              Override the output filename. Default: dev-<short-sha>.tar.gz
#
# Output: $WORK/vendor/builds/core/<name>.tar.gz (or $OUT_NAME).
# On finish, sync-vendor.sh is invoked to update vendor/current/core +
# vendor/current/core.meta so the runtime Dockerfile picks it up.
# =============================================================================
set -euo pipefail

BUILD_TYPE="${CMAKE_BUILD_TYPE:-RelWithDebInfo}"
BUILD_EXTRACTORS="${BUILD_EXTRACTORS:-1}"
WORK="${WORK:-/work}"
SRC="${SRC:-$WORK/vendor/SuperUI-Core}"
OUT_DIR="$WORK/vendor/builds/core"
UPSTREAM_URL="https://github.com/Yafrovon/SuperUI-Core.git"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-development}"

echo "================================================"
echo " SuperUI-Core source build"
echo " Source:  $SRC"
echo " Type:    $BUILD_TYPE"
echo " Extractors: $BUILD_EXTRACTORS"
echo " Work:    $WORK"
echo " Out:     $OUT_DIR"
echo "================================================"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
    echo ""
    echo "ERROR: $SRC is not a SuperUI-Core source tree (no CMakeLists.txt)."
    if [[ -d "$SRC/.git" ]]; then
        echo "  Repo exists but HEAD is detached or branch has been wiped."
        echo "  Run on the HOST:"
        echo "    git submodule update --init vendor/SuperUI-Core"
    else
        echo "  Source directory is empty or missing."
        echo "  Initialising and fetching upstream ($UPSTREAM_URL @ $UPSTREAM_BRANCH)..."
        mkdir -p "$SRC"
        cd "$SRC"
        git init -q
        git remote add origin "$UPSTREAM_URL"
        git fetch --depth=1 origin "$UPSTREAM_BRANCH"
        git checkout -q FETCH_HEAD
        cd - >/dev/null
    fi
    if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
        echo "FATAL: $SRC still doesn't have CMakeLists.txt after fetch."
        exit 1
    fi
fi

cd "$SRC"

# SHA label = HEAD commit; if the working tree has uncommitted changes,
# suffix -wip so consecutive local rebuilds don't collide on filename.
# Only check if we're inside a git repo — git erroring with "not a git
# repository" (exit 128/129) would otherwise be misread as "dirty" and
# stamp every CI build with -wip.
if [[ -d "$SRC/.git" ]]; then
    HEAD_SHA="$(git rev-parse --short=20 HEAD 2>/dev/null || echo unknown)"
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        DIRTY_TAG="${HEAD_SHA}-wip"
        DIRTY_MSG=" (working tree dirty — WIP changes included)"
    else
        DIRTY_TAG="${HEAD_SHA}"
        DIRTY_MSG=""
    fi
else
    HEAD_SHA="no-git"
    DIRTY_TAG="no-git"
    DIRTY_MSG=" (no .git directory — using source as-is)"
fi
echo "==> HEAD: ${HEAD_SHA}${DIRTY_MSG}"

mkdir -p "$OUT_DIR"

JOBS="$(nproc)"
echo "==> Configuring cmake ($JOBS cores, BUILD_EXTRACTORS=$BUILD_EXTRACTORS)"
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX=/install \
    -DBUILD_EXTRACTORS="$BUILD_EXTRACTORS"

echo "==> Building..."
cmake --build build --parallel "$JOBS"

echo "==> Installing to /install"
cmake --install build

OUT_NAME="${OUT_NAME:-dev-$DIRTY_TAG.tar.gz}"
OUT_PATH="$OUT_DIR/$OUT_NAME"

echo "==> Packaging $OUT_PATH"
# Same layout the upstream CI produces (no top-level wrapper dir, just bin/, etc.).
tar -czf "$OUT_PATH" -C /install .

# ccache stats are nice to have - shows hit rate on incremental builds.
if command -v ccache >/dev/null 2>&1; then
    echo "==> ccache stats:"
    ccache --show-stats --verbose || true
fi

echo "================================================"
echo " Built: $OUT_PATH"
echo " Size:  $(du -h "$OUT_PATH" | cut -f1)"

# Update vendor/current/core symlink + .meta so the runtime image picks it up.
if [[ -x "$WORK/scripts/sync-vendor.sh" ]]; then
    echo "==> Updating vendor/current symlinks..."
    "$WORK/scripts/sync-vendor.sh"
fi

echo ""
echo " Next steps:"
echo "   docker compose build mangosd"
echo "   docker compose up -d"
echo "================================================"
