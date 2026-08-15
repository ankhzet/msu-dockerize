# =============================================================================
# SuperUI-Core builder image
# =============================================================================
# Mirrors the upstream GitHub Actions workflow exactly:
#   https://github.com/Yafrovon/SuperUI-Core/blob/development/.github/workflows/windows-development-release.yaml
#
# That workflow runs on ubuntu-24.04, installs the apt deps below, then
# cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_EXTRACTORS=1,
# cmake --build build --parallel, cmake --install build, and zips the result.
#
# Differences from upstream CI:
#   - ccache is installed and wired as the compiler launcher so incremental
#     builds take seconds instead of half an hour (cache lives in a named
#     docker volume; survives container restarts).
#   - git is left installed at the end (small, but useful when iterating
#     against a pinned SHA).
#
# Output: the build script (docker/server/build-core.sh) produces
#   <host>/vendor/dev-<short-sha>.tar.gz
# which the existing docker/server/Dockerfile already knows how to unpack.
# =============================================================================

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Same package list as the upstream workflow, plus ccache and git for
# ref resolution + cache hits.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        cmake \
        git \
        libace-dev \
        libboost-all-dev \
        libbz2-dev \
        libmariadb-dev \
        libmariadb-dev-compat \
        libreadline-dev \
        libssl-dev \
        libtbb-dev \
        zlib1g-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ccache must see the host's compiler; force absolute paths so the cache
# survives rebuilds even if the launcher is invoked from different cwds.
ENV CCACHE_DIR=/root/.ccache \
    CCACHE_MAXSIZE=5G \
    CMAKE_C_COMPILER_LAUNCHER=ccache \
    CMAKE_CXX_COMPILER_LAUNCHER=ccache

COPY docker/server/build-core.sh /usr/local/bin/build-core.sh
RUN chmod +x /usr/local/bin/build-core.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/build-core.sh"]
