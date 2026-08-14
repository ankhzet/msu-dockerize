# =============================================================================
# SuperUI-Core (VMaNGOS fork) image
# =============================================================================
# Pre-built artifact is expected at ./vendor/*.tar.gz
# SQL schema files are expected at ./vendor/sql/base/*.sql
# Nothing is downloaded during build.
# =============================================================================

# ---------- 1. Runtime image ----------
FROM debian:12-slim

ARG SUPERUI_CORE_VERSION=latest
ARG DEBIAN_FRONTEND=noninteractive

LABEL maintainer="MangosSuperUI Docker" \
      version="${SUPERUI_CORE_VERSION}" \
      description="SuperUI-Core (VMaNGOS fork) world + auth servers"

# Runtime dependencies:
#   - libboost-* / libace* / libtbb for the C++ binary
#   - libmariadb3 for DB connectivity
#   - p7zip to extract world DB archives managed by the init script
#   - dumb-init to handle PID 1 / signal forwarding
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libboost-system1.74.0 \
        libboost-filesystem1.74.0 \
        libboost-thread1.74.0 \
        libboost-program-options1.74.0 \
        libboost-regex1.74.0 \
        libboost-chrono1.74.0 \
        libboost-iostreams1.74.0 \
        libmariadb3 \
        libssl3 \
        libz3-4 \
        libace-7.0.6 \
        libace-ssl-7.0.6 \
        libtbb12 \
        dumb-init \
        p7zip-full \
        tzdata \
    && ln -sf /usr/share/zoneinfo/${TZ:-UTC} /etc/localtime \
    && rm -rf /var/lib/apt/lists/*

# Layout:
#   /opt/superui-core/bin/   - mangosd, realmd
#   /opt/superui-core/etc/   - mangosd.conf, realmd.conf
#   /opt/superui-core/data/  - DBC, maps, vmaps, mmaps (DBC required)
#   /opt/superui-core/logs/  - server logs
#   /opt/superui-core/sql/   - bundled schema files for init
ENV SUPERCORE_HOME=/opt/superui-core

RUN mkdir -p \
    $SUPERCORE_HOME/bin \
    $SUPERCORE_HOME/etc \
    $SUPERCORE_HOME/data \
    $SUPERCORE_HOME/logs \
    $SUPERCORE_HOME/run

# Vendor expected at /vendor during build (bind mount)
COPY vendor/ /vendor/

# Install prebuilt binaries from the vendor cache
RUN set -eux; \
    if ls /vendor/superui-core-*.tar.gz >/dev/null 2>&1; then \
        CORE_PKG=$(ls /vendor/superui-core-*.tar.gz | head -n1); \
    elif ls /vendor/*.tar.gz >/dev/null 2>&1; then \
        CORE_PKG=$(ls /vendor/*.tar.gz | head -n1); \
    else \
        echo "ERROR: no SuperUI-Core prebuilt artifact found in /vendor/"; \
        echo "Run ./scripts/download-artifacts.ps1 on the host first."; \
        exit 1; \
    fi; \
    echo "Extracting $CORE_PKG"; \
    tar -xzf "$CORE_PKG" -C /tmp/; \
    # Find mangosd/realmd in the extracted tree (layout varies by release)
    SRCS=$(find /tmp -maxdepth 4 -type f \( -name mangosd -o -name realmd \) -executable 2>/dev/null || true); \
    if [ -z "$SRCS" ]; then \
        echo "ERROR: no mangosd/realmd found in $CORE_PKG"; \
        ls -R /tmp; \
        exit 1; \
    fi; \
    for f in $SRCS; do cp "$f" $SUPERCORE_HOME/bin/; done; \
    chmod +x $SUPERCORE_HOME/bin/mangosd $SUPERCORE_HOME/bin/realmd 2>/dev/null || true; \
    # Save any README/docs from the package
    find /tmp -maxdepth 3 -name '*.md' -exec cp {} $SUPERCORE_HOME/ \; 2>/dev/null || true; \
    rm -rf /tmp/*

# Copy bundled SQL files (from download-artifacts.ps1).
# The COPY will succeed even if the directory is empty (placeholder .gitkeep
# is committed). Real files are populated by init-database.sh.
COPY vendor/sql/ $SUPERCORE_HOME/sql/
RUN mkdir -p $SUPERCORE_HOME/sql/base \
    # Create empty schema files if missing (for the bare-init case where the
    # user doesn't need them - init-database.sh creates empty schemas via raw SQL)
    && for f in realmd.sql characters.sql logs.sql mangos.sql; do \
           touch $SUPERCORE_HOME/sql/base/$f; \
       done

# Create empty schema files if missing (for the bare-init case where the user
# doesn't need them - init-database.sh creates empty schemas via raw SQL)
RUN for f in realmd.sql characters.sql logs.sql mangos.sql; do \
        touch $SUPERCORE_HOME/sql/$f; \
    done

# Copy default configs
COPY config/mangosd.conf.dist $SUPERCORE_HOME/etc/mangosd.conf
COPY config/realmd.conf.dist   $SUPERCORE_HOME/etc/realmd.conf

# Entrypoint
COPY docker/server/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV PATH="$SUPERCORE_HOME/bin:$PATH"

WORKDIR $SUPERCORE_HOME

EXPOSE 3443 3444 3724 8085

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD pgrep -x mangosd >/dev/null || pgrep -x realmd >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
