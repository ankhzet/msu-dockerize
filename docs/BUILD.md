# BUILD.md — Build reference

## What the build does

The `docker compose build` step assembles **two** images:

1. `mangossuperui/core:<tag>` — SuperUI-Core (the world + auth servers)
2. `mangossuperui/ui:<tag>` — MangosSuperUI (the web admin)

Both images are built using **pre-cached artifacts** in `./vendor/`. No
internet is used during the build (with one documented exception: the SQL
schema bundle for the core image, which is ~5 MB).

## Pre-caching on the host

Run `./scripts/download-artifacts.ps1` (or `.sh`) once on the host before
building. This downloads into `./vendor/`:

* `MangosSuperUI-linux-x64.zip` — the MangosSuperUI binary release
* `superui-core-linux-*.tar.gz` — the SuperUI-Core prebuilt binaries

The BrotAlnia world DB is **not** downloaded by this script. It's acquired
on-demand by `init-database.sh --standard`/`--full` after the stack is up.

## Build flags

The compose file accepts:

| Env var | Default | Effect |
|---|---|---|
| `MANGOS_SUPER_UI_VERSION` | `v1.2` | Tag of the MangosSuperUI release |
| `SUPERUI_CORE_VERSION` | `latest` | Tag of the SuperUI-Core prebuilt |
| `MARIADB_VERSION` | `10.11` | MariaDB version |

## Multi-platform

The Dockerfiles are written for `linux/amd64`. On Apple Silicon or other
ARM hosts, either:

```bash
docker compose build --build-arg TARGETARCH=arm64
```

…or set `platform: linux/amd64` on each service in `docker-compose.yml`.

## Verifying the build

```bash
docker images | grep mangossuperui
```

You should see:

```
mangossuperui/core   latest  <sha>  ~280MB
mangossuperui/ui     v1.2    <sha>  ~340MB
```

## Layer caching

* `vendor/` is `COPY`ed early so changes to the build context don't bust
  the asset extraction layer.
* The base image layers (`aspnet:8.0`, `debian:12-slim`) come from the
  Docker cache and don't re-download.
* The world DB is in a **named volume** (`mariadb-data`) — it's never
  inside an image layer, so it doesn't bloat the image size.

## Without internet (fully offline build)

If your build machine has no internet at all:

1. On an internet-connected machine, run `download-artifacts.ps1` and
   copy the `./vendor/` directory.
2. Either pre-load the base images (`docker pull mcr.microsoft.com/dotnet/aspnet:8.0`,
   etc.) and `docker save` them, then `docker load` on the offline machine.
3. Build as usual.

## Build troubleshooting

### "no MangosSuperUI prebuilt zip found in /vendor/"

You skipped the pre-cache step. Run `./scripts/download-artifacts.ps1`.

### "no SuperUI-Core prebuilt artifact found in /vendor/"

The artifact may be named differently than the script expects. Check
<https://github.com/Yafrovon/SuperUI-Core/releases> for the latest filename
and place it in `./vendor/` manually.

### "sha256 mismatch" / "Layer does not exist"

Delete the dangling cache: `docker builder prune -af`. Re-run the build.

### Bash on Windows during the init step

`init-database.sh` runs inside a Linux container. On Windows, the host
PowerShell wrapper uses WSL or your Git Bash installation. If neither is
present, install [Git for Windows](https://git-scm.com/download/win) which
includes Bash.

## Source-built UI includes the MCP server

When you build MangosSuperUI from source via
`docker compose --profile source-build run --rm mangossuperui-ui-builder`,
the result includes the embedded MCP server in
`vendor/MangosSuperUI/MangosSuperUI/Mcp/`. The published prebuilt
`MangosSuperUI-linux-x64.zip` does **not** include MCP (the upstream
release predates it).

To get MCP in a running UI:

1. Fork `vendor/MangosSuperUI/` to your own GitHub (the submodule
   `.gitmodules` URL points at `Yafrovon/MangosSuperUI` upstream — you
   need write access to push MCP commits).
2. Build the UI from source (the builder reads from your submodule).
3. Set `MCP_AUTH_TOKEN` (or `MCP_TOKENS_JSON`) in `.env`.

For builds using the prebuilt zip (no MCP), set
`MCP_ENABLED=false` in `.env` to suppress the endpoint.
