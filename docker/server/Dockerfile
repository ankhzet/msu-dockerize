# =============================================================================
# SuperUI-Core (VMaNGOS fork) image
# =============================================================================
# Reads the active archive from vendor/current/{core,core.meta} (set by
# scripts/sync-vendor.sh on the host) and SQL schema files from
# vendor/sql/. Nothing is downloaded during build.
#
# Runtime deps determined by `ldd` on the prebuilt mangosd/realmd:
#   - libmariadb.so.3 (libmariadb3)
#   - libcrypto.so.3  (libssl3)
#   - GLIBC >= 2.38, GLIBCXX >= 3.4.32 (Debian 13 / Ubuntu 24.04)
#   - Everything else (boost/ace/tbb) is statically linked.
# =============================================================================

# ---------- Runtime image ----------
FROM debian:13-slim

ARG SUPERUI_CORE_VERSION=latest
ARG DEBIAN_FRONTEND=noninteractive

LABEL maintainer="MangosSuperUI Docker" \
      version="${SUPERUI_CORE_VERSION}" \
      description="SuperUI-Core (VMaNGOS fork) world + auth servers"

# Runtime deps - just the two external shared libs the prebuilt needs
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libmariadb3 \
        libssl3 \
        dumb-init \
        p7zip-full \
        tzdata \
        bash \
        unzip \
        curl \
        mariadb-client \
        procps \
    && ln -sf /usr/share/zoneinfo/${TZ:-UTC} /etc/localtime \
    && rm -rf /var/lib/apt/lists/*

# Layout:
#   /opt/superui-core/bin/    - mangosd, realmd (+ Extractors)
#   /opt/superui-core/etc/    - mangosd.conf, realmd.conf
#   /opt/superui-core/data/   - DBC, maps, vmaps, mmaps (DBC required)
#   /opt/superui-core/logs/   - server logs
#   /opt/superui-core/sql/    - bundled schema files for init
ENV SUPERCORE_HOME=/opt/superui-core

RUN mkdir -p \
    $SUPERCORE_HOME/bin \
    $SUPERCORE_HOME/etc \
    $SUPERCORE_HOME/data \
    $SUPERCORE_HOME/logs \
    $SUPERCORE_HOME/run

# Pull just the two parts of the build context this image actually needs.
# vendor/current/core is a symlink Docker follows into vendor/builds/core/*.
# vendor/sql/ has the schema files (realmd/characters/logs + migrations/).
COPY vendor/current/ /vendor/current/
COPY vendor/sql/    $SUPERCORE_HOME/sql/

# Install prebuilt binaries from the vendor cache.
# vendor/current/core is an extensionless symlink to the active archive
# (selected by scripts/sync-vendor.sh or scripts/switch-build.sh on the
# host). vendor/current/core.meta is a sidecar that tells us the
# archive's format - far simpler than path sniffing.
RUN set -eux; \
    META=/vendor/current/core.meta; \
    ARCHIVE=/vendor/current/core; \
    if [ ! -f "$META" ] || [ ! -e "$ARCHIVE" ]; then \
        echo "ERROR: $META missing or $ARCHIVE broken."; \
        echo "On the HOST, run ONE of:"; \
        echo "  ./scripts/download-artifacts.sh"; \
        echo "  docker compose --profile source-build run --rm superui-core-builder"; \
        exit 1; \
    fi; \
    FMT=$(grep -E '^format=' "$META" | cut -d= -f2 | tr -d '[:space:]'); \
    echo "Installing $ARCHIVE (format=$FMT)"; \
    case "$FMT" in \
        zip)    unzip -q "$ARCHIVE" -d /tmp/ ;; \
        tar.gz) tar -xzf "$ARCHIVE" -C /tmp/ ;; \
        tar.xz) tar -xJf "$ARCHIVE" -C /tmp/ ;; \
        *)      echo "ERROR: unknown format '$FMT' in $META"; exit 1 ;; \
    esac; \
    # Find the bin/ dir regardless of whether the archive had a wrapper dir
    BIN_SRC=$( \
        for d in /tmp/bin /tmp/*/bin; do \
            if [ -d "$d" ] && [ -x "$d/mangosd" ]; then echo "$d"; break; fi; \
        done \
    ); \
    if [ -z "$BIN_SRC" ]; then \
        echo "ERROR: could not locate bin/mangosd in $ARCHIVE"; \
        ls -R /tmp; exit 1; \
    fi; \
    # Find the etc/ dir (may or may not exist in prebuilt)
    ETC_SRC=$( \
        for d in /tmp/etc /tmp/*/etc; do \
            if [ -d "$d" ]; then echo "$d"; break; fi; \
        done \
    ); \
    echo "Found binaries at $BIN_SRC, etc at $ETC_SRC"; \
    # Copy bin/ contents (mangosd, realmd, Extractors, run-mangosd, etc.)
    cp -r "$BIN_SRC/." $SUPERCORE_HOME/bin/; \
    chmod +x $SUPERCORE_HOME/bin/mangosd $SUPERCORE_HOME/bin/realmd 2>/dev/null || true; \
    # Copy bundled etc/*.dist files if present (we ship our own dists as fallback)
    if [ -n "$ETC_SRC" ]; then \
        cp -n "$ETC_SRC"/*.dist $SUPERCORE_HOME/etc/ 2>/dev/null || true; \
    fi; \
    rm -rf /tmp/*

# SQL files were already COPYed from vendor/sql/ above (alongside vendor/current/).
# Create empty schema files if missing (for the bare-init case)
RUN for f in realmd.sql characters.sql logs.sql mangos.sql; do touch $SUPERCORE_HOME/sql/$f; done

# Fall back to our hand-crafted dist files only if the bundled ones are absent
COPY config/mangosd.conf.dist $SUPERCORE_HOME/etc/mangosd.conf.dist.host
COPY config/realmd.conf.dist   $SUPERCORE_HOME/etc/realmd.conf.dist.host
RUN if [ ! -f $SUPERCORE_HOME/etc/mangosd.conf.dist ]; then \
        cp $SUPERCORE_HOME/etc/mangosd.conf.dist.host $SUPERCORE_HOME/etc/mangosd.conf.dist; \
    fi && \
    if [ ! -f $SUPERCORE_HOME/etc/realmd.conf.dist ]; then \
        cp $SUPERCORE_HOME/etc/realmd.conf.dist.host $SUPERCORE_HOME/etc/realmd.conf.dist; \
    fi

# Entrypoint + DB init helper (used by the host wrapper)
COPY docker/server/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/init-database.sh    /usr/local/bin/db-init.sh
COPY docker/server/extract-client-data.sh /usr/local/bin/extract-client-data.sh
COPY docker/server/apply-migrations.sh /usr/local/bin/apply-migrations.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/db-init.sh /usr/local/bin/extract-client-data.sh /usr/local/bin/apply-migrations.sh

ENV PATH="$SUPERCORE_HOME/bin:$PATH"

WORKDIR $SUPERCORE_HOME

EXPOSE 3443 3444 3724 8085

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD pgrep -x mangosd >/dev/null || pgrep -x realmd >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/entrypoint.sh"]