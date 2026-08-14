# =============================================================================
# SuperUI-Core (VMaNGOS fork) image
# =============================================================================
# Pre-built artifact is expected at ./vendor/dev-*.zip (or *.tar.gz)
# SQL schema files are expected at ./vendor/sql/*.sql
# Nothing is downloaded during build.
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

# Vendor expected at /vendor during build (bind mount)
COPY vendor/ /vendor/

# Install prebuilt binaries from the vendor cache
RUN set -eux; \
    CORE_PKG=$( \
        ls /vendor/*.zip  2>/dev/null | grep -v 'MSUI' | head -n1; \
        ls /vendor/*.tar.gz 2>/dev/null | head -n1; \
        ls /vendor/*.tar.xz 2>/dev/null | head -n1; \
    ); \
    if [ -z "$CORE_PKG" ]; then \
        echo "ERROR: no SuperUI-Core prebuilt artifact found in /vendor/"; \
        echo "Run ./scripts/download-artifacts.sh on the host first."; \
        exit 1; \
    fi; \
    echo "Extracting $CORE_PKG"; \
    case "$CORE_PKG" in \
        *.zip)      unzip -q "$CORE_PKG" -d /tmp/ ;; \
        *.tar.gz)   tar -xzf "$CORE_PKG" -C /tmp/ ;; \
        *.tar.xz)   tar -xJf "$CORE_PKG" -C /tmp/ ;; \
        *)          echo "Unsupported archive: $CORE_PKG"; exit 1 ;; \
    esac; \
    # Find the bin/ dir regardless of whether the archive had a wrapper dir
    BIN_SRC=$( \
        for d in /tmp/bin /tmp/*/bin; do \
            if [ -d "$d" ] && [ -x "$d/mangosd" ]; then echo "$d"; break; fi; \
        done \
    ); \
    if [ -z "$BIN_SRC" ]; then \
        echo "ERROR: could not locate bin/mangosd in $CORE_PKG"; \
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

# Copy bundled SQL files (from download-artifacts.sh).
COPY vendor/sql/ $SUPERCORE_HOME/sql/
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