# =============================================================================
# MangosSuperUI (ASP.NET Core 8.0 web UI) builder image
# =============================================================================
# Upstream has no build action — the prebuilt zip is published manually
# by the maintainer (see vendor/MangosSuperUI/MangosSuperUI/Properties/
# PublishProfiles/FolderProfile.pubxml: Release, linux-x64, SelfContained=false).
#
# This builder replicates that locally. Reads the source from the
# submodule at /work/vendor/MangosSuperUI, restores NuGet packages into
# the persistent nuget-packages volume, runs `dotnet publish`, and
# tars the output into /work/vendor/msui-<sha>.tar.gz — which the
# existing docker/ui/Dockerfile already knows how to extract.
# =============================================================================

FROM mcr.microsoft.com/dotnet/sdk:8.0

# Persistent NuGet package cache lives in a named docker volume so
# `dotnet restore` only downloads what changed across rebuilds.
ENV NUGET_PACKAGES=/root/.nuget/packages \
    DOTNET_NOLOGO=true \
    DOTNET_CLI_TELEMETRY_OPTOUT=true

COPY docker/ui/build-ui.sh /usr/local/bin/build-ui.sh
RUN chmod +x /usr/local/bin/build-ui.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/build-ui.sh"]
