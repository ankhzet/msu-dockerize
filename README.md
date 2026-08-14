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
│   ├── server/                 # SuperUI-Core image
│   │   ├── Dockerfile
│   │   └── entrypoint.sh
│   └── ui/                     # MangosSuperUI image
│       ├── Dockerfile
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
