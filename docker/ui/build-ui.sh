#!/usr/bin/env bash
# =============================================================================
# Build MangosSuperUI from the local submodule copy.
#
# Upstream has no CI workflow — the prebuilt zip is published manually via
#   vendor/MangosSuperUI/MangosSuperUI/Properties/PublishProfiles/FolderProfile.pubxml
# which sets: Release / linux-x64 / SelfContained=false. We replicate that
# here using `dotnet publish`.
#
# The source tree is expected at ./vendor/MangosSuperUI/ (a git submodule
# pointing at https://github.com/Yafrovon/MangosSuperUI.git). To refresh to
# a newer commit, run on the HOST before invoking the builder:
#   git submodule update --remote vendor/MangosSuperUI
#
# Env vars (set in docker-compose.yml or the shell):
#   SRC                  Path to the source tree inside the container.
#                        Default: /work/vendor/MangosSuperUI.
#   DOTNET_BUILD_CONFIG  Release (default) / Debug.
#   DOTNET_RUNTIME_ID    linux-x64 (default, matches upstream's pubxml).
#   OUT_NAME             Override the output filename. Default: msui-<short-sha>.tar.gz
#
# Output: $WORK/vendor/builds/ui/<name>.tar.gz (or $OUT_NAME).
# On finish, sync-vendor.sh updates vendor/current/ui + vendor/current/ui.meta
# so the runtime Dockerfile picks it up.
# =============================================================================
set -euo pipefail

WORK="${WORK:-/work}"
SRC="${SRC:-$WORK/vendor/MangosSuperUI}"
OUT_DIR="$WORK/vendor/builds/ui"
BUILD_CONFIG="${DOTNET_BUILD_CONFIG:-Release}"
RID="${DOTNET_RUNTIME_ID:-linux-x64}"

echo "================================================"
echo " MangosSuperUI source build"
echo " Source:   $SRC"
echo " Config:   $BUILD_CONFIG"
echo " Runtime:  $RID"
echo " Work:     $WORK"
echo " Out:      $OUT_DIR"
echo "================================================"

if [[ ! -f "$SRC/MangosSuperUI.sln" ]]; then
    echo ""
    echo "ERROR: $SRC is not a MangosSuperUI source tree (no MangosSuperUI.sln)."
    echo "On the HOST, run:"
    echo "  git submodule update --init vendor/MangosSuperUI"
    echo "or, to pull the latest upstream commit:"
    echo "  git submodule update --remote vendor/MangosSuperUI"
    echo ""
    exit 1
fi

cd "$SRC"
SHA="$(git -C "$SRC" rev-parse --short=20 HEAD 2>/dev/null || echo unknown)"
echo "==> HEAD: $SHA"

mkdir -p "$OUT_DIR"

# Wipe the project outputs so we never carry a stale obj/project.assets.json
# from a previous plain (RID-less) restore. Without --runtime on restore,
# the assets file only knows about `net8.0` and `dotnet publish -r linux-x64`
# fails with NETSDK1047 ("Assets file doesn't have a target for net8.0/linux-x64").
PUBLISH_OUT="/publish"
rm -rf "$PUBLISH_OUT" "$SRC/MangosSuperUI/obj" "$SRC/MangosSuperUI/bin"

# Restore with --runtime so the assets file is populated for net8.0/linux-x64.
# Package binaries land in the persistent NUGET_PACKAGES volume.
echo "==> Restoring NuGet packages (RID-aware, -r $RID)..."
dotnet restore MangosSuperUI/MangosSuperUI.csproj --runtime "$RID"

echo "==> Publishing (-c $BUILD_CONFIG -r $RID)..."
dotnet publish MangosSuperUI/MangosSuperUI.csproj \
    -c "$BUILD_CONFIG" \
    -r "$RID" \
    --no-restore \
    -o "$PUBLISH_OUT" \
    /p:UseAppHost=false

# Sanity check before we tar it up.
if [[ ! -f "$PUBLISH_OUT/MangosSuperUI.dll" ]]; then
    echo "ERROR: MangosSuperUI.dll not found after publish"
    ls -la "$PUBLISH_OUT"
    exit 1
fi

OUT_NAME="${OUT_NAME:-msui-$SHA.tar.gz}"
OUT_PATH="$OUT_DIR/$OUT_NAME"

echo "==> Packaging $OUT_PATH"
tar -czf "$OUT_PATH" -C "$PUBLISH_OUT" .

echo "================================================"
echo " Built: $OUT_PATH"
echo " Size:  $(du -h "$OUT_PATH" | cut -f1)"

# Update vendor/current/ui symlink + .meta so the runtime image picks it up.
if [[ -x "$WORK/scripts/sync-vendor.sh" ]]; then
    echo "==> Updating vendor/current symlinks..."
    "$WORK/scripts/sync-vendor.sh"
fi

echo ""
echo " Next steps:"
echo "   docker compose build superui"
echo "   docker compose up -d"
echo "================================================"
