# MangosSuperUI Docker Stack

Run a complete **VMaNGOS 1.12.1** server + **MangosSuperUI** web admin in Docker. Optimized for metered connections — no unnecessary downloads.

## What's included

```
┌─────────────────────────────────────────────────────────────┐
│  Browser (http://localhost:5000)                            │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│  superui        MangosSuperUI (ASP.NET Core 8.0)            │
└─────────────────────────────┬───────────────────────────────┘
                              │
       ┌──────────────────────┴──────────────────────┐
       │                                             │
┌───────▼──────────┐                      ┌──────────▼────────┐
│  mangosd         │◄──── RA (TCP 3443) ──►│  realmd           │
│  (SuperUI-Core)  │                      │  (SuperUI-Core)   │
└──────┬───────────┘                      └──────────┬────────┘
       │                                             │
       └─────────────────────┬───────────────────────┘
                             │
                  ┌──────────▼──────────┐
                  │  mariadb            │
                  │  (realmd, chars,    │
                  │   logs, mangos,     │
                  │   vmangos_admin)    │
                  └─────────────────────┘
```

## Quick start

### 0. Prerequisites

* Docker Engine 24+ with Compose v2
* ~1 GB free disk for the base images
* A legitimate **WoW 1.12.1** client (for DBC, maps, vmaps, mmaps) — see [Assets](#assets)
* Linux/macOS/Windows host

### 1. One-time setup

```powershell
# Windows
Copy-Item .env.example .env
.\scripts\download-artifacts.ps1
docker compose build
```

```bash
# Linux/macOS
cp .env.example .env
./scripts/download-artifacts.sh
docker compose build
```

### 2. Bring up the database

```powershell
docker compose --profile core up -d mariadb
```

Wait ~10 seconds for MariaDB to initialize, then:

```powershell
# Cheapest option: empty schemas, no world DB
.\scripts\init-database.sh --bare
```

Or with a world DB:

```powershell
# Smallest available (~200MB, downloads from brotalnia/database)
.\scripts\init-database.sh --standard

# Latest (~1GB)
.\scripts\init-database.sh --full

# Local file
.\scripts\init-database.sh --from C:\path\to\world.7z
```

### 3. Start everything

```powershell
docker compose --profile core up -d
```

### 4. Open the dashboard

Navigate to **http://localhost:5000**.

The dashboard should turn mostly green. Click **Diagnose** if anything is red.

### 5. (Optional) Provide a WoW client

Set `WOW_CLIENT_DATA` in `.env` to your WoW 1.12.1 client path (root or just the `Data/` subdir), then:

```bash
docker compose up -d                           # restart with the new mount
./scripts/extract-client-data.sh              # extract DBC/Maps/VMaps
./scripts/extract-client-data.sh --no-mmaps   # skip MMaps (saves hours)
```

The extractors are bundled in the SuperUI-Core prebuilt. Without this, mangosd boots but reports "map files not found" — the server runs the DB and UI but no clients can connect.

## Asset strategy

This stack is **bare by default** — you decide what to download and when.

| Asset | Default | How to install |
|---|---|---|
| `MangosSuperUI-linux-x64.zip` | Pre-cached during build (`./scripts/download-artifacts.ps1`) | Built into the image |
| SuperUI-Core prebuilt (`*.tar.gz`) | Pre-cached during build | Built into the image |
| `realmd`, `characters`, `logs` SQL | Created by `init-database.sh --bare` | Tiny, ~1 MB total |
| World DB (`mangos` schema) | Empty in `--bare` mode | `--standard` (~200MB) or `--full` (~1GB) on demand |
| WoW 1.12.1 DBC, maps, vmaps, mmaps | **User-provided** | Mount your client `Data/` dir at `WOW_CLIENT_DATA` (see below) |

`WOW_CLIENT_DATA` should point at the directory containing `dbc/`, `maps/`, `vmaps/`, `mmaps/`, `Cameras/`. If you only have the original `Data/` folder (containing the `.MPQ` archives), the UI can read those directly — see `CLIENT_DATA_PATH` env var.

## Build from source (optional)

By default the stack consumes the upstream prebuilt zips (one for SuperUI-Core,
one for MangosSuperUI). If you want to compile them yourself, both repos are
vendored as git submodules and can be built by dedicated compose services.

### SuperUI-Core (the C++ world/auth server)

Upstream has a GitHub Actions workflow that builds Ubuntu 24.04 binaries.
This builder mirrors it verbatim (same apt deps, same cmake flags, same
output layout) but reads the source from the local submodule and drops its
result at `./vendor/dev-<sha>.tar.gz`.

```bash
git submodule update --init vendor/SuperUI-Core

docker compose --profile source-build run --rm superui-core-builder
docker compose build mangosd
docker compose up -d
```

To pick up newer upstream commits:

```bash
git submodule update --remote vendor/SuperUI-Core
docker compose --profile source-build run --rm superui-core-builder
```

* First build: ~20-40 minutes. Subsequent: ~2-5 minutes via persistent `ccache`.

### MangosSuperUI (the ASP.NET Core 8.0 web UI)

Upstream has no build action — the prebuilt zip is published manually via
`dotnet publish` (see `vendor/MangosSuperUI/MangosSuperUI/Properties/PublishProfiles/FolderProfile.pubxml`).
This builder replicates that locally and drops its result at
`./vendor/msui-<sha>.tar.gz`.

```bash
git submodule update --init vendor/MangosSuperUI

docker compose --profile source-build run --rm mangossuperui-ui-builder
docker compose build superui
docker compose up -d
```

To pick up newer upstream commits:

```bash
git submodule update --remote vendor/MangosSuperUI
docker compose --profile source-build run --rm mangossuperui-ui-builder
```

* First build: ~3-5 minutes (downloads NuGet packages). Subsequent: ~30-60 seconds
  via persistent `nuget-packages` volume.

Tunable knobs in `.env`:

| Variable | Default | Notes |
|---|---|---|
| `BUILD_FROM_SOURCE` | `0` | `1` enables the source-build path above |
| `CMAKE_BUILD_TYPE` | `RelWithDebInfo` | SuperUI-Core only. `RelWithDebInfo` (default, with debug symbols) / `Release` (smaller, no symbols) / `Debug` (unoptimized) |
| `BUILD_EXTRACTORS` | `1` | SuperUI-Core only. `0` skips `MoveMapGenerator`/`VMapExtractor`/etc. to save a few minutes |
| `DOTNET_BUILD_CONFIG` | `Release` | MangosSuperUI only. `Release` (matches upstream pubxml) / `Debug` |
| `DOTNET_RUNTIME_ID` | `linux-x64` | MangosSuperUI only. RID passed to `dotnet publish`. The prebuilt zips target this. |

## Configuration

All settings live in `.env`. The most important ones:

| Variable | Default | Notes |
|---|---|---|
| `MARIADB_PASSWORD` | `mangos` | Change for any non-local setup |
| `RA_PASSWORD` | `Changeme123!` | **Change this.** Used by the UI to talk to mangosd. |
| `RA_MIN_LEVEL` | `3` | Critical — see INSTALL.md. Required by VMaNGOS source. |
| `WORLD_DB_MODE` | `bare` | `bare` / `standard` / `full` / path / URL |
| `WOW_CLIENT_DATA` | (unset) | Host path to your extracted WoW client data |
| `UI_HTTP_PORT` | `5000` | Web UI port |
| `MANGOSD_RA_PORT` | `3443` | Bound to `127.0.0.1` only |
| `ENABLE_OLLAMA` | `0` | Set to `1` to enable Ollama profile |
| `ENABLE_COMFYUI` | `0` | Set to `1` to enable ComfyUI profile |
| `OLLAMA_HOST` | (unset) | URL to existing Ollama (e.g. `http://host.docker.internal:11434`) |
| `COMFYUI_HOST` | (unset) | URL to existing ComfyUI (e.g. `http://host.docker.internal:8188`) |

When `OLLAMA_HOST`/`COMFYUI_HOST` are set, the UI uses those instead of the
containerized services. On Windows and macOS, `host.docker.internal` works out
of the box. On Linux, `extra_hosts: host.docker.internal:host-gateway` is
already configured in the compose file.

## Optional: MCP (Model Context Protocol) server

MSUI exposes its RemoteAdmin console, database queries, world/spell/item DB
inspection + edits, server logs, wiki + source-code search, process
controls, config editor, world lifecycle, OG baseline (diff + reset),
divergence + change-graph, bot fleet + brain + rotations, and patch
metadata as **215 MCP tools** plus **3 resources** and **4 prompts**
(stateless Streamable HTTP transport on the existing UI port at `/mcp`).
Set `MCP_AUTH_TOKEN` in `.env` (generate with `openssl rand -hex 32`) and
connect any MCP-compatible client — Claude Desktop, VS Code Copilot, or a
custom agent. Token capabilities can be scoped per-client via
`MCP_TOKENS_JSON` (read-only CI bot, operator token, etc.). See
[docs/MCP.md](docs/MCP.md) for the full tool list and configuration
recipes, and [docs/MCP.md#capability-matrix](docs/MCP.md) for the
capability matrix.

### Smoke test

After `docker compose up -d`, verify the endpoint is reachable and your
token works:

```bash
MCP_TOKEN=tk_xxx ./scripts/test-mcp.sh
# or on Windows:
$env:MCP_TOKEN = "tk_xxx"; .\scripts\test-mcp.ps1
```

The script calls `tools/list`, `home_status`, `ra_list_online`, and
verifies that an `ra_send_command` without the `ra` capability returns
`403 insufficient_scope`.

### Catalogue audit

`scripts/audit-mcp.sh` (and `.ps1`) enumerates every tool and asserts the
expected per-class count — so you catch regressions where a refactor
silently drops a tool. Exit code 1 = at least one class is wrong.

```bash
MCP_TOKEN=tk_xxx ./scripts/audit-mcp.sh
```

The expected counts are pinned to the current surface (215 tools across
30 classes); update the `EXPECTED` dict in the script when you ship
new tool classes.

### Capability matrix

Each MCP tool requires one or more capabilities. A token must hold **all**
of the capabilities a tool requires to invoke it.

| Capability | What it gates |
|---|---|
| `read`      | All Phase 2 read-only tools + activity + audit. Default if no attribute is present. |
| `ra`        | All `ra_*` tools + `player_*` actions + `config_reload_mangosd`. |
| `process`   | `process_start_*` / `process_stop_*` / `process_restart_*`. |
| `write_db`  | Phase 3 content writes (account, item, gameobject, spell, instance, config, player actions). |
| `worlds`    | `worlds_*` lifecycle tools. |
| `bots`      | `bot_*` commands + `rotation_*` writes. |
| `patches`   | `patch_*` generation tools + custom spell trainer wiring + delete. |
| `baseline`  | `baseline_reset_*` (irreversible!) + `changegraph_revert_*`. |
| `lootifier` | Lootifier / crafting-lootifier / quest-lootifier / profession tuning generation tools (Phase 7). |
| `retexture` | Retexture pipeline (Phase 7). |

Tokens with an empty `capabilities` array are superusers (granted all).
The legacy `MCP_AUTH_TOKEN` env var is treated as a superuser for
back-compat with Phase-0 deployments.

## Optional: AI services

Enable with:
```bash
docker compose --profile core --profile ai up -d
```

The Ollama model is **not downloaded at build time**. It's pulled on first run
by the `ollama-puller` sidecar. Override with `OLLAMA_MODEL` in `.env`.

The ComfyUI models are also optional and pulled on first run by the upstream
image's own startup script. To preload a specific model, mount it at
`comfyui-data:/root/ComfyUI/models/checkpoints`.

## Vendor layout (builds + active pointer)

Artifacts live in two layers so you can keep historical builds around for
rollback without bloating the runtime image:

```
vendor/
├── builds/                          # gitignored - every build ever made
│   ├── core/
│   │   ├── dev-2300e1e.zip                 # upstream prebuilt
│   │   ├── dev-2300e1e8c5b0559883e1.tar.gz # source-built
│   │   └── ...
│   └── ui/
│       ├── MSUI---LINUX---v1.2.2.zip
│       ├── msui-1e0e7fcdcc95802dd246.tar.gz
│       └── ...
├── current/                         # in build context - the "active" pointer
│   ├── core                         # hardlink -> active core archive
│   ├── core.meta                    # format=tar.gz / source=source-built
│   ├── ui                           # hardlink -> active UI archive
│   └── ui.meta                      # format=tar.gz / source=source-built
├── sql/                             # schema files (base + migrations/)
├── world-2021.7z                    # world DB (excluded from Docker context)
├── SuperUI-Core/                    # submodule source (excluded from Docker context)
└── MangosSuperUI/                   # submodule source (excluded from Docker context)
```

* `vendor/builds/` is gitignored and excluded from the Docker context.
  Every artifact ever produced (by `download-artifacts.sh` or the source
  builders) lands here and stays until you prune it.
* `vendor/current/core` and `vendor/current/ui` are **hardlinks** (not
  symlinks — Docker COPY on Windows preserves symlinks as broken symlinks
  in the image; hardlinks COPY as regular files). They point at whichever
  archive you currently consider "active".
* `vendor/current/{core,ui}.meta` are tiny sidecars that tell the runtime
  Dockerfiles the archive format (`tar.gz` / `zip` / `tar.xz`) and
  provenance (`source-built` / `upstream`).
* Switching the active build is a single `ln` (atomic) — see
  [`scripts/switch-build.sh`](scripts/switch-build.sh).

### Switching the active build

```bash
# List what you've got
scripts/switch-build.sh --list
scripts/switch-build.sh --current

# Interactive pick (prompts per category)
scripts/switch-build.sh
scripts/switch-build.sh core

# Non-interactive: point at a specific archive
scripts/switch-build.sh core dev-2300e1e.zip
scripts/switch-build.sh ui   msui-1e0e7fc.tar.gz

# Switch to the freshest build in each category (same as sync-vendor.sh)
scripts/switch-build.sh core latest
```

After switching:

```bash
docker compose build        # picks up the new current/core and current/ui
docker compose up -d
```

### Pruning old builds

```bash
# Keep only the 3 most-recent artifacts per category (oldest deleted)
scripts/sync-vendor.sh --keep 3
```

## Bandwidth budget

| Stage | Approx. size | When |
|---|---|---|
| Base images (aspnet, mariadb, debian) | ~300 MB | `docker compose build` |
| MangosSuperUI zip | ~30 MB | `./scripts/download-artifacts.ps1` |
| SuperUI-Core prebuilt | ~120 MB | `./scripts/download-artifacts.ps1` |
| Optional: MariaDB data volume | ~50 MB after first run | first `docker compose up` |
| Optional: world DB (standard) | ~200 MB | `./scripts/init-database.sh --standard` |
| Optional: world DB (full) | ~1 GB | `./scripts/init-database.sh --full` |
| Optional: Ollama model | ~2-8 GB | on first `docker compose --profile ai up` |
| Optional: ComfyUI base | ~5 GB | on first `docker compose --profile ai up` |

**Total at the bare minimum**: ~500 MB.

## Troubleshooting

### "realmd exits immediately" / "mangosd exits immediately"

```bash
docker compose logs mangosd
```

Most common cause: world DB is empty/`--bare` mode but you're trying to log in.
Run `init-database.sh --standard` (or `--full`) and restart.

### "RA authentication failed" in the dashboard

`Ra.MinLevel = 3` is missing from `mangosd.conf`. The image's entrypoint
auto-injects it from `${RA_MIN_LEVEL}`, but if you replaced the conf file
manually, re-add it. See INSTALL.md.

### Dashboard shows "Access denied" for `vmangos_admin`

Re-run `init-database.sh --bare` to re-grant the privileges. The grant is
idempotent.

### "DBC not found" / minimap tiles don't render

Set `WOW_CLIENT_DATA` in `.env` to point at the directory containing your
extracted `.dbc` files. The container's entrypoint symlinks the directory
into the server's data path.

### WoW client mounted but icons still missing

The UI uses the `Data/` directory (containing `.MPQ` archives) to read icons
on demand. Set `CLIENT_DATA_PATH` to that directory inside the container, e.g.:

```yaml
volumes:
  - /your/wow/Data:/data:ro
```

### Container is rebuilding every time

The image builds use the `vendor/` directory as a cache. Make sure
`download-artifacts.ps1` has been run at least once; otherwise the build fails
(it's intentionally strict to avoid silent internet use).

### Reset everything

```powershell
.\scripts\mangos.ps1 reset   # confirms before deleting volumes
```

## File layout

```
MangosSuperUI/
├── docker-compose.yml          # the orchestration
├── .env.example                # configuration template
├── README.md                   # this file
├── scripts/
│   ├── download-artifacts.ps1  # pre-cache binaries (run once)
│   ├── download-artifacts.sh   # Linux equivalent
│   ├── init-database.sh        # bare/standard/full DB init
│   └── mangos.ps1              # day-to-day wrapper
├── docker/
│   ├── server/                 # SuperUI-Core runtime image
│   │   ├── Dockerfile          # runtime: extracts vendor/dev-*.{zip,tar.gz}
│   │   ├── Dockerfile.builder  # builder: ubuntu:24.04, mirrors upstream CI
│   │   ├── build-core.sh       # entrypoint for the builder image
│   │   └── entrypoint.sh
│   └── ui/                     # MangosSuperUI runtime image
│       ├── Dockerfile          # runtime: extracts vendor/{MSUI,msui}-*.{zip,tar.gz}
│       ├── Dockerfile.builder  # builder: dotnet sdk:8.0, dotnet publish
│       ├── build-ui.sh         # entrypoint for the builder image
│       └── entrypoint.sh
├── config/
│   ├── mangosd.conf.dist       # world server config template
│   ├── realmd.conf.dist        # auth server config template
│   └── server-config.json      # UI config template
├── vendor/                     # pre-downloaded artifacts (gitignored)
├── backups/                    # mysqldump output (gitignored)
└── logs/                       # runtime logs (gitignored)
```

## Acknowledgments

This stack bundles and orchestrates:

* [MangosSuperUI](https://github.com/Yafrovon/MangosSuperUI) — the web admin
* [SuperUI-Core](https://github.com/Yafrovon/SuperUI-Core) — the VMaNGOS fork
* [VMaNGOS](https://github.com/vmangos/core) — the underlying emulator
* [brotalnia/database](https://github.com/brotalnia/database) — the world DB
* [MariaDB](https://mariadb.org/) — the database
* [ASP.NET Core](https://dotnet.microsoft.com/) — the UI runtime

No Blizzard assets are included or distributed. You must supply your own
WoW 1.12.1 client for DBC/maps/icons.
