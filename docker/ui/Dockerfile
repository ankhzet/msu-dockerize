# =============================================================================
# MangosSuperUI web UI image
# =============================================================================
# Pre-built Linux x64 zip is expected at ./vendor/MangosSuperUI-linux-x64.zip
# =============================================================================

# ---------- 1. SDK stage (only for publishing the appsettings fallback) ----------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS sdk

# ---------- 2. Runtime image ----------
FROM mcr.microsoft.com/dotnet/aspnet:8.0

ARG MANGOS_SUPER_UI_VERSION=v1.2
ENV MANGOS_SUPER_UI_VERSION=${MANGOS_SUPER_UI_VERSION}

LABEL maintainer="MangosSuperUI Docker" \
      version="${MANGOS_SUPER_UI_VERSION}" \
      description="MangosSuperUI web platform"

USER root

# Bash for the entrypoint script + native libs that the published app's
# bundled .so files dynamically load (SkiaSharp needs libfontconfig for
# font discovery; without it SkiaSharp.SKObject's cctor throws and the
# process exits during startup, which restarts the UI in a loop and
# flaps the BotBridge TCP socket).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        tini \
        libfontconfig1 \
        libfreetype6 \
    && rm -rf /var/lib/apt/lists/*

# Install layout
ENV MANGOSSUPERUI_HOME=/opt/mangossuperui
RUN mkdir -p \
    $MANGOSSUPERUI_HOME \
    $MANGOSSUPERUI_HOME/data \
    /var/mangossuperui/cache

# Vendor expected at /vendor during build
COPY vendor/current/ /vendor/current/

# Install the prebuilt UI archive.
# vendor/current/ui is an extensionless symlink to the active archive
# (selected by scripts/sync-vendor.sh or scripts/switch-build.sh on the
# host). vendor/current/ui.meta is a sidecar that tells us the archive's
# format - far simpler than path sniffing.
RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*; \
    META=/vendor/current/ui.meta; \
    ARCHIVE=/vendor/current/ui; \
    if [ ! -f "$META" ] || [ ! -e "$ARCHIVE" ]; then \
        echo "ERROR: $META missing or $ARCHIVE broken."; \
        echo "On the HOST, run ONE of:"; \
        echo "  ./scripts/download-artifacts.sh"; \
        echo "  docker compose --profile source-build run --rm mangossuperui-ui-builder"; \
        exit 1; \
    fi; \
    FMT=$(grep -E '^format=' "$META" | cut -d= -f2 | tr -d '[:space:]'); \
    echo "Installing $ARCHIVE (format=$FMT)"; \
    case "$FMT" in \
        zip)    unzip -q "$ARCHIVE" -d $MANGOSSUPERUI_HOME ;; \
        tar.gz) tar -xzf "$ARCHIVE" -C $MANGOSSUPERUI_HOME ;; \
        tar.xz) tar -xJf "$ARCHIVE" -C $MANGOSSUPERUI_HOME ;; \
        *)      echo "ERROR: unknown format '$FMT' in $META"; exit 1 ;; \
    esac; \
    # Verify the DLL is present
    test -f $MANGOSSUPERUI_HOME/MangosSuperUI.dll || \
        (echo "ERROR: MangosSuperUI.dll not found after extraction"; ls -la $MANGOSSUPERUI_HOME; exit 1); \
    # Create directories the app expects to write to
    mkdir -p $MANGOSSUPERUI_HOME/data \
             $MANGOSSUPERUI_HOME/wwwroot/cache \
             $MANGOSSUPERUI_HOME/wwwroot/patches; \
    chmod -R 755 $MANGOSSUPERUI_HOME

# Drop the default config template
COPY config/server-config.json $MANGOSSUPERUI_HOME/server-config.json
# Override the bundled appsettings.json with our defaults (process names match
# mangosd-main/realmd-main, and ClientDataPath points at /data/Data inside
# the container, which is the bind-mounted WoW client root).
COPY config/appsettings.json $MANGOSSUPERUI_HOME/appsettings.json
COPY docker/ui/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Environment
ENV ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_PRINT_TELEMETRY_MESSAGE=false \
    DOTNET_NOLOGO=true \
    ASPNETCORE_URLS=http://0.0.0.0:5000

WORKDIR $MANGOSSUPERUI_HOME

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost:5000/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
