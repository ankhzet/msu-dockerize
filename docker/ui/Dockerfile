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

# Bash for the entrypoint script
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Install layout
ENV MANGOSSUPERUI_HOME=/opt/mangossuperui
RUN mkdir -p \
    $MANGOSSUPERUI_HOME \
    $MANGOSSUPERUI_HOME/data \
    /var/mangossuperui/cache

# Vendor expected at /vendor during build
COPY vendor/ /vendor/

# Install the prebuilt zip
RUN set -eux; \
    # Find MangosSuperUI Linux zip (vendor may have multiple zips, skip any
    # that look like SuperUI-Core asset names)
    ZIP=$(ls /vendor/*.zip 2>/dev/null | grep -E 'MSUI|MangosSuperUI' | head -n1); \
    if [[ -z "$ZIP" ]]; then \
        echo "ERROR: no MangosSuperUI Linux zip found in /vendor/"; \
        echo "Run ./scripts/download-artifacts.ps1 on the host first."; \
        exit 1; \
    fi; \
    echo "Extracting $ZIP"; \
    apt-get update && apt-get install -y --no-install-recommends unzip && rm -rf /var/lib/apt/lists/*; \
    unzip -q "$ZIP" -d $MANGOSSUPERUI_HOME; \
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
