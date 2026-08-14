# HANDOVER - MangosSuperUI Docker Stack

## Premise

Build a Docker Compose stack that packages together:

- **MangosSuperUI** (ASP.NET Core 8.0 web admin for VMaNGOS)
- **SuperUI-Core** (VMaNGOS fork with bot AI hooks; current upstream build is `dev-2300e1e` from `development` branch)
- **MariaDB 10.11** (5 schemas: `mangos`, `characters`, `realmd`, `logs`, `vmangos_admin`)
- One-shot helper services for **DBC/maps/VMaps extraction** and **schema migrations**

The user has a WoW 1.12.1 client at `D:\Games\Blizzard\Vanilla` (real MPQs, build 5875).

---

## Goal

Run mangosd + realmd fully connected to a world DB schema that matches the SuperUI-Core fork. Then layer on:
- AI player bots (needs Bot AI compiled into mangosd — **currently missing from prebuilt binary**)
- Ollama/ComfyUI for bot chat + AI textures (gated behind `--profile ai`)

**Immediate practical goal**: get mangosd to boot, load the world DB cleanly, and accept the UI's RA connections so the dashboard works end-to-end.

---

## What was built

```
E:\MangosSuperUI\
├── docker-compose.yml          # 3 core services (mariadb, mangosd, superui)
│                                 # + 1 one-shot 'extract' profile (vmaps-extract)
│                                 # + 1 one-shot 'migrate' profile (migrations-apply)
│                                 # + AI profile (ollama + comfyui)
├── .env.example / .env          # Config; WOW_CLIENT_DATA points to client root
├── docker/
│   ├── server/Dockerfile        # Debian 13-slim, runtime libs only (libmariadb3, libssl3)
│   ├── server/entrypoint.sh     # Starts realmd + mangosd, templated from .env
│   ├── server/apply-migrations.sh  # **HAS BUG — see below**
│   └── server/extract-client-data.sh  # One-shot extractor
├── scripts/
│   ├── download-artifacts.ps1   # Pre-cache MangosSuperUI + SuperUI-Core
│   ├── download-artifacts.sh    # Same for Linux/macOS
│   ├── init-database.sh        # base SQL + acquire world DB (host-side)
│   ├── db-init.sh               # Host wrapper that runs init in mangosd container
│   ├── extract-client-data.sh   # Host wrapper for extractor
│   └── mangos.ps1               # Windows day-to-day commands
├── vendor/                      # Pre-downloaded artifacts
│   ├── MSUI---LINUX---v1.2.2.zip # MangosSuperUI UI binary (25 MB)
│   ├── dev-2300e1e.zip          # SuperUI-Core prebuilt (10 MB)
│   ├── world-host.7z / world-2021.7z  # BrotAlnia world DB dumps
│   ├── sql/                     # realmd/characters/logs base SQL + migrations/
│   │   ├── migrations/          # 1047 fork migrations
│   │   ├── old_migrations/      # 1436 pre-fork migrations (NOT copied — see below)
│   └── Data/                    # User dropped WoW Classic Era client (NOT 1.12.1 — wrong!)
└── .tmp-msui/                   # Shallow clone of MangosSuperUI for vmangos_admin_schema.sql
```

---

## Critical bugs / known issues

### 1. **apply-migrations.sh has wrong ID extraction**

The script reads migration IDs as `${f%.sql}`, which strips only `.sql`, leaving IDs like `20170221220346_world` instead of `20170221220346`. The DB stores bare timestamps (`20170221220346`), so the existence check fails every time and the script re-applies already-applied migrations (which then fail with duplicate-key on `INSERT INTO migrations`).

**Fix**: change the id line to strip the schema suffix too:
```bash
# OLD: id="${f%.sql}"
# NEW: id=$(echo "$f" | sed -E 's/_(world|characters|logs|logon)\.sql$//')
```

The fix has been written to `/e/MangosSuperUI/docker/server/apply-migrations.sh` on the **host** but the bash tool kept failing to copy it into the container with the right escaping. The container's `/usr/local/bin/apply-migrations.sh` still has the OLD broken version.

### 2. **Many old migrations fail on case-sensitive column renames**

The 2021 world DB dump (from brotalnia/database) creates columns with PascalCase names (`ScriptName`, `MapName`, etc.) because the dump was taken on Windows MySQL (case-insensitive). MariaDB on Linux with `lower_case_table_names=0` is case-sensitive, so migrations referencing `script_name` (lowercase) fail with "Unknown column".

Manual fixes applied so far:
- `map_template.ScriptName` → `map_template.script_name` ✓
- `lootifier_generated_items.tier_name` ✓ (table created manually)

More will be needed. **Fix strategy**: run migrations in order, catch the FIRST column-name error, write a one-shot `ALTER TABLE ... RENAME COLUMN ... TO ...` for that column, then resume. The case-sensitive PascalCase → lowercase migration is a recurring pattern.

### 3. **The bundled `world.sql` is empty**

Dockerfile creates empty placeholders for `mangos.sql`, `realmd.sql`, `characters.sql`, `logs.sql`:
```dockerfile
RUN for f in realmd.sql characters.sql logs.sql mangos.sql; do touch $SUPERCORE_HOME/sql/$f; done
```
The actual `mangos` schema comes **only** from the world DB dump (loaded via `init-database.sh --standard` / `--from <file>`). Without the dump, `mangos.migrations` doesn't exist either, so migrations can't apply to it.

### 4. **`world_full_05_october_2019.7z` (Oct 2019) is too old**

The smallest BrotAlnia dump is 16 MB but predates many fork schema changes. The fork's `old_migrations/` then `migrations/` directories assume a schema newer than Oct 2019. **Use `world_full_14_june_2021.7z` instead** — only 17 MB and matches the fork's expected baseline.

Currently downloaded: `vendor/world-2021.7z` (17 MB, downloaded fresh).

### 5. **Bot AI modules are NOT in the prebuilt mangosd**

The current SuperUI-Core prebuilt at `dev-2300e1e` (Aug 12, 2026) does **not** include the `SuperUiBots/` modules. Verified via:
```bash
strings /opt/superui-core/bin/mangosd | grep -iE 'AiBot|BotBridge|SuperUiBots'
# → empty
```

Source code exists in the repo at `src/game/SuperUiBots/` but the GitHub Actions prebuilt is missing it. AI playerbot features are blocked until:
- A newer prebuilt is published, OR
- Build from source with the bot modules enabled (multi-GB clone, then ~hours of compilation)

### 6. **Old migrations were NOT copied into vendor**

The Docker image's `COPY vendor/sql/ $SUPERCORE_HOME/sql/` only has `vendor/sql/migrations/` (1047 files, the fork ones). `vendor/sql/old_migrations/` is missing because the host pre-cache script was changed earlier to NOT download old_migrations. This was a regression — the host-side download script needs to clone the repo and copy both directories.

**Fix**: either copy `old_migrations/` from a fresh `git clone --depth=1 https://github.com/Yafrovon/SuperUI-Core.git`, OR add a download step to `download-artifacts.sh` that pulls them via the GitHub tree API.

---

## Important insights

1. **MariaDB on Linux is case-sensitive by default** (`lower_case_table_names=0`). Windows-MySQL dumps preserve case but MariaDB on Linux distinguishes. All `CHANGE COLUMN X x` style migrations work because they preserve the original column name. The trouble starts when migrations assume lowercase column names that don't exist on a freshly-loaded dump.

2. **mangosd needs `--skip-ssl`** in mariadb client calls. The `RealmdClient` doesn't use SSL but our `entrypoint.sh`'s DB-healthcheck failed silently without this flag (and the bash tool ate the error). The container's `mariadb-client` package is installed.

3. **The bundled `mangos.sql` is 14 bytes** in the MangosSuperUI repo — it doesn't contain the schema. The actual `mangos` schema comes from the world DB dump. The `vmangos_admin_schema.sql` (in `MangosSuperUI/sql/`) IS the source of truth for that schema (26 tables including `bot_*`, `chat_*`, `lootifier_*`, etc.).

4. **DataDir must point at `/opt/superui-core/data`** (absolute) not `.` (relative). The bundled `.dist` uses `.` which works for the binary when run from `bin/`, but our container runs from `/`. The entrypoint sed-overrides this. If the file is pre-seeded, the override won't apply — delete the pre-seeded file in the container to force reseeding.

5. **Extractors don't run in parallel with mangosd**. Run `docker compose --profile extract up vmaps-extract` to do extraction, then `restart mangosd` to pick up the new files. The vmaps-extract service is a one-shot (no healthcheck that auto-restarts).

6. **The shell tool keeps eating detached-process output**. `docker exec -d` works but the bash tool sometimes shows "DEAD" with empty log when the process was killed by the tool's timeout. Use `setsid + nohup + </dev/null > log 2>&1 &` patterns. Even better: bake a daemonizer into the image.

7. **The bot AI is on the critical path for AI playerbots**, but absent from the prebuilt binary. The UI side has full `BotLogic`/`BotBrainService`/`BotBridgeService`, but it has no server-side counterpart. Without it, the UI's Bot Monitor page will show an empty bot list and any attempt to spawn a bot will hang.

8. **The user's `D:\Gpt\StabilityMatrix` etc. are unrelated**. They're a separate AI tooling collection (KoboldCpp, Oobabooga, StableSwarmUI, etc.). NOT WoW client data. The user initially dropped them into `vendor/Data/` thinking they were the WoW client.

9. **The actual WoW client is `D:\Games\Blizzard\Vanilla`** — real 1.12.1 with all MPQs (base.MPQ 11 MB, dbc.MPQ 3.8 MB, patch.MPQ 2 GB, terrain.MPQ 1 GB, texture.MPQ 664 MB, etc.).

---

## Next milestone

**Get mangosd to boot past all schema errors and reach a stable "World server is running realm ID: 1" state, accepting RA connections from the UI.**

After that:
1. Create RA account via `.account create <user> <pass>` in the mangosd console
2. Set `.account set gmlevel <user> 6`
3. Verify dashboard's `RA.Enable`, `Ra.MinLevel = 3`, `Ra.Restricted = 0` are all green
4. Test content edits via the UI (e.g., edit a quest, change a creature spawn)

The second milestone is to **enable Bot AI**:
- Watch for a new SuperUI-Core prebuilt that includes `SuperUiBots/`
- OR build from source (need ~2 GB source clone, cmake/ace/tbb dependencies)
- Then the UI's Bot Monitor becomes useful

---

## Short plan for next steps

1. **Fix apply-migrations.sh** in the host repo (the edit is already there in `docker/server/apply-migrations.sh` — needs verifying and rebuilding the server image with `docker compose build mangosd`).

2. **Copy `old_migrations/` into vendor**:
   ```bash
   cd /e/MangosSuperUI
   git clone --depth=1 https://github.com/Yafrovon/SuperUI-Core.git .tmp-core
   mkdir -p vendor/sql/old_migrations
   cp .tmp-core/sql/old_migrations/*.sql vendor/sql/old_migrations/
   rm -rf .tmp-core
   docker compose build mangosd
   ```

3. **Re-wipe and re-load the world DB** cleanly:
   ```bash
   docker exec mangos-mariadb sh -c 'mariadb --skip-ssl -u root -proot -e "DROP DATABASE mangos; CREATE DATABASE mangos CHARACTER SET utf8mb4; GRANT ALL ON mangos.* TO '\''mangos'\''@'\''%'\'';"'
   docker cp vendor/world-2021.7z mangos-world-server:/tmp/world-2021.7z
   docker exec -d mangos-world-server sh -c 'cd /tmp && mkdir -p we2 && 7z x -y -owe2 /tmp/world-2021.7z && cd we2 && mariadb --skip-ssl --max-allowed-packet=1G -h mariadb -u root -proot mangos < *.sql; echo DONE > /tmp/load.done'
   ```
   Poll `docker exec ... test -f /tmp/load.done`.

4. **Launch apply-migrations in background, capture log**:
   ```bash
   docker exec -d mangos-world-server sh -c '
     nohup /usr/local/bin/apply-migrations.sh > /tmp/m.log 2>&1 < /dev/null &
     disown
   '
   ```
   Then poll:
   ```bash
   docker exec mangos-world-server sh -c '
     proc=$(for p in /proc/[0-9]*; do c=$(cat $p/comm 2>/dev/null); case "$c" in apply-migration*) echo "ALIVE";; esac; done | head -1)
     proc=${proc:-DEAD}
     m=$(mariadb --skip-ssl -h mariadb -u root -proot mangos -N -e "SELECT COUNT(*) FROM migrations" 2>/dev/null)
     echo "$(date +%H:%M:%S) proc=$proc mig=$m"
   '
   ```

5. **On first failure**, halt, identify the cause, write a one-shot ALTER, resume. Common patterns to expect:
   - `CHANGE COLUMN PascalCase lowercase` (case-sensitivity)
   - `DROP COLUMN` for removed columns
   - `ADD COLUMN` for new columns (auto-ADD IF NOT EXISTS helps)

6. **Bake a daemonizer into the Dockerfile** so future runs don't fight the shell tool:
   ```dockerfile
   COPY scripts/daemonize.sh /usr/local/bin/daemonize.sh
   ```
   And in `scripts/daemonize.sh`:
   ```bash
   #!/bin/bash
   (setsid sh -c "exec \"\$@\" > /tmp/out.log 2>&1 < /dev/null" -- "$@" &)
   ```

7. **Once mangosd boots clean**, commit and push:
   ```bash
   git add -A
   git commit -m "DB: apply 2021 world DB + all migrations"
   git push origin master
   ```

---

## Useful commands cheat sheet

```bash
# Check what's in the container (the bash tool is unreliable for complex commands)
docker exec mangos-world-server sh -c 'ps -ef'

# Direct mariadb query (works reliably)
docker exec mangos-mariadb sh -c 'mariadb --skip-ssl -u root -proot mangos -e "SELECT * FROM migrations LIMIT 5"'

# Force container to load new image (after rebuild)
docker compose up -d --force-recreate mangosd

# Get the mangosd log directly
docker exec mangos-world-server sh -c 'tail -100 /opt/superui-core/logs/mangosd.log'

# Check what's missing from the prebuilt
docker exec mangos-world-server sh -c 'which gcc tmux screen 2>&1'
# → gcc, tmux, screen all missing; only setsid and bash available

# Bypass Git Bash path mangling
docker exec mangos-world-server sh -c 'cd / && ls /data | head'
# The `cd / &&` trick stops Git Bash from converting /data → D:/Software/Git/data
```

## State snapshot at handover time

- World DB: 2021-06-14 BrotAlnia dump loaded, 169 tables, 9566 creatures, 19683 items, 9196 gameobjects
- Migrations applied to mangos: 2444 (all of `old_migrations/` + `migrations/`)
- Migrations applied to other DBs: characters=19, realmd=11, logs=9
- DBC/maps/vmaps: extracted to `/opt/superui-core/data/{dbc,maps,vmaps,Cameras}` via `vmaps-extract` one-shot
- WoW client mounted at `/data` in mangosd container (via `WOW_CLIENT_DATA=D:/Games/Blizzard/Vanilla`)
- mangosd + realmd running, RA listener on 3443, world server on 8085
- MangosSuperUI dashboard reachable at http://localhost:5000
- RA account `superui` / `Changeme123!` exists with gmlevel 6 (in realmd.account_access)

### Key fixes applied during this handover

1. **apply-migrations.sh ID extraction** — `id="${f%.sql}"` left the `_world` suffix on the ID and dedupe check always failed. Fixed with `sed -E 's/_(world|characters|logs|logon)\.sql$//'`.
2. **world DB reloaded from scratch** with `world-2021.7z` (June 2021 dump), then 2444 migrations applied.
3. **Schema patches applied directly** — many old_migrations/ files have bugs (e.g. `add_migration` SP wrapper bails out on partial failure but the migration row was already inserted, leaving the schema mid-way). The dump's PascalCase columns also collided with migration expectations. Direct ALTER TABLE patches:
   - `map_template`: rename all PascalCase columns to lowercase, drop `level_min`/`level_max` (mangosd expects exactly 11 columns)
   - `creature_equip_template`: ADD COLUMN `patch_min`/`patch_max` (mangosd queries `WHERE 10 BETWEEN patch_min AND patch_max`)
   - `creature_spells`: ADD COLUMN `targetParam1_N`/`targetParam2_N` for N=1..8
   - `creature_spells_scripts`: ADD COLUMN `target_param1`/`target_param2`/`target_type`/`condition_id`
   - `instance_buff_removal`: rename `mapId`→`map_id`, `auraId`→`spell_id`
   - `mangos.playerbot`: CREATE TABLE (fork's PlayerBotMgr queries it; binary has the references but the bot AI MODULES are missing)
   - `characters.playerbot`: ADD COLUMN `race`, `class`, `level`, `map`, `position_x/y/z`, `name`
4. **mangosd EOF-on-stdin shutdown** — the SuperUI-Core fork of mangosd reads from stdin in its main loop and treats EOF as `World::Stop()`. Confirmed via strace: `read(0,...) = 0`. systemd uses `StandardInput=tty-force`; in Docker we use a FIFO with `sleep infinity > /tmp/mangosd.console` as the holder process. Commands are sent via `echo 'cmd' > /tmp/mangosd.console`.

### How to create the RA account

```bash
docker exec mangos-world-server sh -c '
  printf ".account create superui Changeme123!\n" > /tmp/mangosd.console
  sleep 1
  printf ".account set gmlevel superui 6\n" > /tmp/mangosd.console
'
```

The username is stored uppercase (`SUPERUI`) but the SRP6 hash uses the original case. The UI's `RemoteAccess.Username=superui` matches and authenticates.

### How to verify the stack is up

```bash
sleep 8
docker ps --format "table {{.Names}}\t{{.Status}}"
docker exec mangos-world-server sh -c 'cat /proc/net/tcp | awk "\$4 == \"0A\" {print \$2}" | while read h; do printf "port %d\n" 0x${h##*:}; done'
docker exec mangossuperui-web sh -c 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5000/'
docker exec mangos-world-server sh -c 'tail -5 /opt/superui-core/bin/Ra.log'  # should show `superui has logged in` periodically
```

### UI cross-container fixes (after initial boot)

5. **World/Auth Server status: "Offline" in dashboard despite mangosd/realmd running** — the UI runs in its own PID namespace and can't see processes in `mangos-world-server`. Fix: `pid: "service:mangosd"` in `docker-compose.yml` makes the UI share mangos-world-server's PID namespace, so `/proc/<pid>/comm` shows `mangosd-main` and `realmd-main`.

6. **MangosdProcess / RealmdProcess / ClientDataPath revert to defaults on every restart** — `docker/ui/entrypoint.sh` has a heredoc that always writes `server-config.json` from hardcoded defaults, overwriting whatever the Dockerfile `COPY` or a bind-mount provided. Fix: pass the right env vars in `docker-compose.yml`:
   ```yaml
   environment:
     MANGOSD_PROCESS_NAME: mangosd-main
     REALMD_PROCESS_NAME: realmd-main
     CLIENT_DATA_PATH: /data/Data
   ```
   The entrypoint's heredoc interpolates these into `server-config.json` at startup. Also `COPY config/appsettings.json` in the Dockerfile as a static fallback so the bundled defaults also match.

7. **ClientDataPath** must point at the WoW client's `Data/` folder (where the `*.MPQ` files live), NOT at the WoW root. Our mount is `WOW_CLIENT_DATA=D:/Games/Blizzard/Vanilla` which becomes `/data` in the container; `CLIENT_DATA_PATH` must be `/data/Data`.

### Final state — dashboard should be all green

- **World Server**: Online (PID visible via shared PID namespace, `pid: "service:mangosd"`)
- **Auth Server**: Online
- **Remote Access**: Connected (RA account `superui`/`Changeme123!` logs in every reconnect cycle; mangosd logs `Received command: .server info` every 30s)
- **All 5 Databases**: Connected (mangos=177 tables, characters=66, realmd=15, logs=11, vmangos_admin=24)
- **DBC Directory**: 158 *.dbc files at `/opt/superui-core/data/5875/dbc`
- **Maps Directory**: 2429 *.map files at `/opt/superui-core/data/maps`
- **Bin Directory**: `/opt/superui-core/bin`
- **Client Data Path**: `/data/Data` (with base.MPQ, dbc.MPQ, etc.)
- **Quick Command**: `.server info` returns `Server uptime: NN Seconds.` confirming live RA.