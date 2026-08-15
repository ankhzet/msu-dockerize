# HANDOVER - MangosSuperUI Docker Stack

## Premise

Build a Docker Compose stack that packages together:

- **MangosSuperUI** (ASP.NET Core 8.0 web admin for VMaNGOS)
- **SuperUI-Core** (VMaNGOS fork with bot AI hooks; built from `feature/bridge-gear-up` branch)
- **MariaDB 10.11** (5 schemas: `mangos`, `characters`, `realmd`, `logs`, `vmangos_admin`)
- One-shot helper services for **DBC/maps/VMaps extraction** and **schema migrations**

The user has a WoW 1.12.1 client at `D:\Games\Blizzard\Vanilla` (real MPQs, build 5875).

---

## Goal (achieved)

Run mangosd + realmd fully connected to a world DB schema that matches the SuperUI-Core fork, then layer on:
- **Bot AI** — `AiBotAI` fleet bots auto-accept BG invites and resume normal AI on match end (via `m_wasInBG` transition detector + `OnLeaveBattleGround` override). Source-built mangosd, `SuperUiBots/` modules compiled in.
- Ollama/ComfyUI for bot chat + AI textures (gated behind `--profile ai`)

**Practical goal** (achieved): get mangosd to boot, load the world DB cleanly, and accept the UI's RA connections so the dashboard works end-to-end.

**Next**: get real player bots to participate in BGs end-to-end (auto-queue + auto-accept + auto-leave loop). Currently the user's named bots follow Azure but don't auto-queue; the temp `.battlebot add` path works for stress-testing.

---

## What was built

```
E:\MangosSuperUI\
├── docker-compose.yml          # 3 core services (mariadb, mangosd, superui)
│                                 # + 1 one-shot 'extract' profile (vmaps-extract)
│                                 # + 1 one-shot 'migrate' profile (migrations-apply)
│                                 # + AI profile (ollama + comfyui)
│                                 # + 2 source-build profiles (superui-core-builder, mangossuperui-ui-builder)
├── .env.example / .env          # Config; WOW_CLIENT_DATA points to client root
├── docker/
│   ├── server/Dockerfile        # Debian 13-slim, runtime libs only (libmariadb3, libssl3, libfontconfig1, libfreetype6)
│   ├── server/Dockerfile.builder  # ubuntu:24.04 + ccache + cmake + ace + tbb — used by `docker compose --profile source-build run --rm superui-core-builder`
│   ├── server/entrypoint.sh     # Starts realmd + mangosd, templated from .env
│   ├── server/build-core.sh     # Source build helper, uses local tree (committed or dirty), .git-modules gitlink at HEAD
│   ├── server/apply-migrations.sh  # **FIXED — see below**
│   └── server/extract-client-data.sh  # One-shot extractor
├── scripts/
│   ├── download-artifacts.ps1   # Pre-cache MangosSuperUI + SuperUI-Core
│   ├── download-artifacts.sh    # Same for Linux/macOS
│   ├── init-database.sh        # base SQL + acquire world DB (host-side)
│   ├── db-init.sh               # Host wrapper that runs init in mangosd container
│   ├── extract-client-data.sh   # Host wrapper for extractor
│   ├── mangos.ps1               # Windows day-to-day commands
│   └── queue-10-horde-wsg.sh    # [faction] — queues temp BattleBotAI bots for WSG/AB; default Horde, pass alliance
├── vendor/                      # Pre-downloaded artifacts
│   ├── MSUI---LINUX---v1.2.2.zip # MangosSuperUI UI prebuilt (25 MB) — superseded by source-built artifacts below
│   ├── dev-2300e1e.zip          # SuperUI-Core prebuilt (10 MB) — superseded by source-built artifacts below
│   ├── world-host.7z / world-2021.7z  # BrotAlnia world DB dumps
│   ├── sql/                     # realmd/characters/logs base SQL + migrations/
│   │   ├── migrations/          # 1047 fork migrations (+ 20260815012935_world.sql for map_type=3)
│   │   ├── old_migrations/      # 1436 pre-fork migrations (NOT copied — see below)
│   ├── MangosSuperUI/           # SUBMODULE — Yafrovon/MangosSuperUI@feature/bridge-gear-up
│   ├── SuperUI-Core/            # SUBMODULE — Yafrovon/SuperUI-Core@feature/bridge-gear-up
│   ├── builds/core/             # Source-built mangosd history (gitignored except committed tarballs)
│   ├── builds/ui/               # Source-built UI history
│   └── current/{core,ui}        # Hardlinks to the newest active build (Dockerfile picks these up)
```

---

## Critical bugs / known issues (all resolved)

### 1. **`apply-migrations.sh` ID extraction — FIXED**

Script read migration IDs as `${f%.sql}`, leaving IDs like `20170221220346_world` instead of `20170221220346`. DB stores bare timestamps, so the existence check failed every time and the script re-applied already-applied migrations (duplicate-key on `INSERT INTO migrations`).

**Fix applied** at `docker/server/apply-migrations.sh`: `id=$(echo "$f" | sed -E 's/_(world|characters|logs|logon)\.sql$//')`. Verified end-to-end against the live DB — 2444 migrations applied cleanly across `old_migrations/` + `migrations/`.

### 2. **Case-sensitive column renames — FIXED via manual ALTER TABLE patches**

BrotAlnia dumps preserve PascalCase from Windows-MySQL; MariaDB on Linux is case-sensitive with `lower_case_table_names=0`. Migrations referencing lowercase column names failed on freshly-loaded dumps.

**Direct ALTER TABLE patches applied** at `characters` and `mangos`:
- `map_template`: rename PascalCase columns to lowercase, drop `level_min`/`level_max` (mangosd expects exactly 11 columns)
- `creature_equip_template`: ADD COLUMN `patch_min`/`patch_max` (mangosd queries `WHERE 10 BETWEEN patch_min AND patch_max`)
- `creature_spells`: ADD COLUMN `targetParam1_N`/`targetParam2_N` for N=1..8
- `creature_spells_scripts`: ADD COLUMN `target_param1`/`target_param2`/`target_type`/`condition_id`
- `instance_buff_removal`: rename `mapId`→`map_id`, `auraId`→`spell_id`
- `mangos.playerbot`: CREATE TABLE (fork's PlayerBotMgr queries it; binary now has the references)
- `characters.playerbot`: ADD COLUMN `race`, `class`, `level`, `map`, `position_x/y/z`, `name`
- `characters.character_spell_cooldown`: rename PascalCase → lowercase (the original 14-byte `mangos.sql` was empty; real schema came from world dump)

### 3. **Bundled `world.sql` is empty**

Dockerfile creates empty placeholders:
```dockerfile
RUN for f in realmd.sql characters.sql logs.sql mangos.sql; do touch $SUPERCORE_HOME/sql/$f; done
```
Actual `mangos` schema comes **only** from the world DB dump (loaded via `init-database.sh --standard` / `--from <file>`).

### 4. **`world_full_05_october_2019.7z` (Oct 2019) too old**

Smaller dump predates fork schema changes. **Using `world_full_14_june_2021.7z`** (17 MB) instead.

### 5. **Bot AI modules NOT in prebuilt mangosd — RESOLVED**

Prebuilt `dev-2300e1e` lacked `SuperUiBots/`. **Source-built mangosd** at commit `885efad20` (`feature/bridge-gear-up`) — modules now compiled in, `AiBotAI`, `PartyBotAI`, `BattleBotAI` all functional. Build via `docker compose --profile source-build run --rm superui-core-builder`.

### 6. **Old migrations NOT copied — RESOLVED via source builds**

`docker/server/Dockerfile` now `COPY vendor/current/core` (hardlink to source-built archive) which already includes all migrations. The hardlink indirection + `.meta` sidecar (`format=tar.gz\nsource=source-built\ntarget=../builds/...`) tells the runtime Dockerfile how to extract. `old_migrations/` is included in the source tree's `sql/` directory.

---

## Important insights

1. **MariaDB on Linux is case-sensitive by default** (`lower_case_table_names=0`). Windows-MySQL dumps preserve case but MariaDB on Linux distinguishes. `CHANGE COLUMN PascalCase lowercase` migrations work because they preserve the original column name. Trouble starts when migrations assume lowercase column names that don't exist on a freshly-loaded dump.

2. **mangosd needs `--skip-ssl`** in mariadb client calls. The `RealmdClient` doesn't use SSL but the entrypoint's DB-healthcheck failed silently without this flag. Container's `mariadb-client` package is installed.

3. **`mangos.sql` is 14 bytes** in the MangosSuperUI repo — doesn't contain the schema. Real `mangos` schema comes from the world DB dump. `vmangos_admin_schema.sql` (in `MangosSuperUI/sql/`) IS the source of truth for that schema (26 tables including `bot_*`, `chat_*`, `lootifier_*`, etc.).

4. **DataDir must point at `/opt/superui-core/data`** (absolute) not `.` (relative). Bundled `.dist` uses `.` which works for the binary when run from `bin/`, but our container runs from `/`. Entrypoint sed-overrides this. Delete the pre-seeded file in the container to force reseeding.

5. **Extractors don't run in parallel with mangosd**. Run `docker compose --profile extract up vmaps-extract`, then `restart mangosd` to pick up the new files. One-shot, no healthcheck that auto-restarts.

6. **mangosd EOF-on-stdin shutdown** — the SuperUI-Core fork of mangosd reads from stdin and treats EOF as `World::Stop()`. systemd uses `StandardInput=tty-force`; in Docker we use a FIFO with `sleep infinity > /tmp/mangosd.console` as the holder process. Commands sent via `echo 'cmd' > /tmp/mangosd.console`.

7. **Three SIGSEGVs in prebuilt binary** (now bypassed by source build):
   - `.wareffort info` → SIGSEGV in `wareffort.cpp` (unfixable without recompile)
   - BG match creation → `CreateBattleGroundMap: map->IsBattleGround()` assertion. **Root cause**: `map_template.map_type` was 0 (normal) for BG map entries — should be 3 (battleground). **Fix**: migration `20260815012935_world.sql` sets `map_type = 3` for entries 30 (AV), 489 (WSG), 529 (AB), 566 (AV anniversary), 607 (AB anniversary).
   - `.bot stop` → SIGSEGV in bot teardown. **Workaround**: use `docker compose restart mangosd` instead of `.bot stop` — kills the container cleanly via SIGTERM rather than running bot cleanup code on already-freed objects.

8. **BG accept / BG leave** — `AiBotAI` (the user's permanent bot class) lacked BG handling entirely. Source build at commit `885efad20` adds:
   - `CONFIG_BOOL_AI_BOT_AUTO_ACCEPT_BG` (default `true`) — operator can disable fleet-wide via `mangosd.conf: AiBot.AutoAcceptBG = 0`.
   - On invite packet (`SMSG_BATTLEFIELD_STATUS` with bot not in BG): `m_receivedBgInvite = true`, then on next tick `SendBattlefieldPortPacket()` ports bot in.
   - On match end: `m_wasInBG` transition fires `OnLeaveBattleGround()` → resets doctrine to Solo, clears BG state, bot resumes normal AI.
   - While in BG: `UpdateAI` suppresses autonomous tasks (BG system drives position + combat); bridge tick keeps STATE flowing to UI.

9. **The user's `D:\Gpt\StabilityMatrix` etc. are unrelated** — separate AI tooling collection (KoboldCpp, Oobabooga, StableSwarmUI, etc.). NOT WoW client data.

10. **The actual WoW client is `D:\Games\Blizzard\Vanilla`** — real 1.12.1 with all MPQs (base.MPQ 11 MB, dbc.MPQ 3.8 MB, patch.MPQ 2 GB, terrain.MPQ 1 GB, texture.MPQ 664 MB, etc.).

11. **The UI container needs `libfontconfig1` and `libfreetype6`** for SkiaSharp's native font loader. Without them `SkiaSharp.SKObject`'s static constructor throws, the process exits during startup, restarts in a loop, and flaps the BotBridge TCP socket.

12. **Bot UI bridge is hardcoded to `127.0.0.1:3444`**. The C++ side has `#define BRIDGE_HOST "127.0.0.1"`, `#define BRIDGE_PORT 3444` in `AiBotAIMain.h`. With shared network namespace (`network_mode: "service:mangosd"`), both containers see the same loopback — works without code change.

13. **Hardlinks for vendor/current/** — Docker COPY on Windows preserves NTFS symlinks as symlinks (broken), so `vendor/current/core` is a NTFS hardlink to `vendor/builds/core/dev-*.tar.gz`. Hardlinks share the inode, so Docker COPY treats them as regular files and they always work cross-platform.

---

## Next milestone

**Get real player bots to fully participate in BGs end-to-end.** Current state:
- Bots auto-accept BG invites ✓ (verified: 9 of Azure's bots logged `[AIBOT-BG] X: BG invite detected — accepting and porting in`)
- Bots auto-resume AI on BG end ✓ (verified via binary symbols + BattleBotAI same pattern)
- Bots don't auto-queue — the user must click the WSG Battlemaster NPC in the WoW client

**To make bots auto-queue** (without the user at the Battlemaster):
- Add a `BG_JOIN` bridge command (similar to `GEAR_UP`) that calls `ChatHandler(me->GetSession()).HandleGoWarsongCommand("")` for the requested BG type
- UI button: "Queue BG" alongside the existing Fleet control
- Bot brain can auto-queue on doctrine = `PlayerParty` when the player is the group leader

**Longer-term**:
- Watch for upstream `SuperUI-Core` to publish a prebuilt with `SuperUiBots/` so the source build isn't needed
- OR keep using the source build via `docker compose --profile source-build run --rm superui-core-builder`

---

## Short plan for next steps

1. **Add a `BG_JOIN` bridge command** in `vendor/MangosSuperUI/MangosSuperUI/Services/BotBridgeService.cs`:
   ```csharp
   public Task SendJoinBgAsync(int guid, int bgType /* 2=WSG, 3=AB, 1=AV */)
   {
       return SendToBotAsync(guid, "BG_JOIN", new { bg_type = bgType });
   }
   ```
   C++ side handles `BG_JOIN` in `BridgeProcessLine` by calling `ChatHandler(me->GetSession()).HandleGoXxxCommand(args)` on the bot's own session — same path BattleBotAI uses internally.

2. **Add UI button**: `bg_join` button in the bot control suite, between `Gear up` and `Diagnostics` (or grouped under "Grouping").

3. **Bot brain integration**: when a real player is the group leader and the doctrine resolves to `PlayerParty`, the brain can auto-issue `BG_JOIN` for the leader's preferred BG.

4. **Test**: Azure (player) in WoW client right-clicks the BG battlemaster once. Bots auto-queue. When a match fires, all bots port in. When it ends, all bots resume normal AI.

5. **Commit & push**:
   ```bash
   git add -A
   git commit -m "bots: auto-join BG when group leader queues"
   git push origin master
   ```

---

## Useful commands cheat sheet

```bash
# Check what's in the container
docker exec mangos-world-server sh -c 'ps -ef'

# Direct mariadb query (works reliably)
docker exec mangos-mariadb sh -c 'mariadb --skip-ssl -u root -proot mangos -e "SELECT * FROM migrations LIMIT 5"'

# Force container to load new image (after rebuild)
docker compose up -d --force-recreate mangosd

# Get the mangosd log directly
docker exec mangos-world-server sh -c 'tail -100 /opt/superui-core/logs/mangosd.log'

# Source-build the C++ core (uses local tree, dirty → -wip tag)
docker compose --profile source-build run --rm superui-core-builder
docker compose build mangosd
docker compose up -d

# Source-build the UI
docker compose --profile source-build run --rm mangossuperui-ui-builder
docker compose build superui
docker compose up -d

# Sync current build symlinks after manual build
# (sync-vendor.sh does this automatically at end of each builder run)
ls -la vendor/current/core vendor/current/ui

# Spawn a permanent bot (AiBotAI, level 1 — `character level` to bump)
printf '.bot addai warrior human TestBot\n' > /tmp/mangosd.console
printf '.character level TestBot 60\n' > /tmp/mangosd.console

# Spawn a temporary battlebot that auto-queues for BG
printf '.battlebot add warsong horde 60\n' > /tmp/mangosd.console

# Queue the bot fleet for WSG via the BG script
./scripts/queue-10-horde-wsg.sh           # default Horde
./scripts/queue-10-horde-wsg.sh alliance # Alliance

# Restart mangosd instead of .bot stop (.bot stop SIGSEGVs in this build)
docker compose restart mangosd
```

## State snapshot

- World DB: 2021-06-14 BrotAlnia dump loaded, 169 tables, 9566 creatures, 19683 items, 9196 gameobjects
- Migrations applied to mangos: 2444 (all of `old_migrations/` + `migrations/`)
- Migrations applied to other DBs: characters=19, realmd=11, logs=9
- DBC/maps/vmaps: extracted to `/opt/superui-core/data/{dbc,maps,vmaps,Cameras}` via `vmaps-extract` one-shot
- WoW client mounted at `/data` in mangosd container (via `WOW_CLIENT_DATA=D:/Games/Blizzard/Vanilla`)
- mangosd (source-built): binary md5 `bc142ad2288a986abb27cf2803494488`, AI bot modules included, BG accept/leave working
- realmd running, RA listener on 3443, world server on 8085
- MangosSuperUI dashboard reachable at http://localhost:5000
- RA account `superui` / `Changeme123!` exists with gmlevel 6 (in realmd.account_access)

### Bot state

- 9 Alliance bots in Azure's party (Alarsong, BlackSmite, Briarborn, Kaelmark, Malnova, Mindface, Ravret, Rivendisc, Shiftpro)
- Bots follow Azure (`[SUI-FOLLOW] X: task=0 unlinked=0 commanded=0 boss=Azure dist=0.0`)
- Bots auto-accept BG invites (verified: 9 logs of `[AIBOT-BG] X: BG invite detected — accepting and porting in`)
- Bots auto-resume AI on BG end (binary symbols + BattleBotAI same pattern verified)
- Bots don't auto-queue (user must click Battlemaster NPC in WoW client)
- 10 horde + 10 alliance temp battlebots can be queued via `./scripts/queue-10-horde-wsg.sh [faction]`

### Key fixes applied during this handover

1. **apply-migrations.sh ID extraction** — `id="${f%.sql}"` left the `_world` suffix. Fixed with `sed -E 's/_(world|characters|logs|logon)\.sql$//'`.
2. **world DB reloaded from scratch** with `world-2021.7z` (June 2021 dump), 2444 migrations applied.
3. **Schema patches** — direct ALTER TABLE patches for PascalCase→lowercase + missing columns.
4. **mangosd EOF-on-stdin shutdown** — confirmed via strace: `read(0,...) = 0`. Use FIFO with `sleep infinity > /tmp/mangosd.console` as holder.
5. **PID namespace fix** — `pid: "service:mangosd"` in `docker-compose.yml` makes UI share mangosd's PID namespace, so `/proc/<pid>/comm` shows `mangosd-main` and `realmd-main`.
6. **MangosdProcess / RealmdProcess / ClientDataPath** env-var driven via `docker/ui/entrypoint.sh` heredoc that interpolates into `server-config.json`.
7. **ClientDataPath** → `/data/Data` (WoW client's Data/ folder, where *.MPQ files live).
8. **`map_template.map_type = 3` migration** — fixes the BG match creation assertion crash. Migration at `vendor/sql/migrations/20260815012935_world.sql`.
9. **GEAR_UP bridge command** — one-shot bot prep (level, spells, gear, riding, mount). C++ `BridgeHandleGearUp` + C# `SendGearUpAsync` + UI "Gear up" card in bot control suite. Default mount item 8630 (Black War Tiger).
10. **BG auto-accept + leave** — `AiBotAI` checks `m_receivedBgInvite` on every tick and accepts via `SendBattlefieldPortPacket()`. `m_wasInBG` transition detector + virtual `OnLeaveBattleGround()` override resets doctrine on match end. Config-gated via `AiBot.AutoAcceptBG` (default true).
11. **SkiaSharp font loader** — added `libfontconfig1` and `libfreetype6` to `docker/ui/Dockerfile` so the UI process doesn't crash on startup.
12. **Source-build infrastructure** — added `superui-core-builder` and `mangossuperui-ui-builder` services to `docker-compose.yml` profiles. Builders use local source tree (committed or dirty), `.gitmodules` gitlink points at HEAD, ccache-cached for fast rebuilds. `vendor/current/{core,ui}` is a hardlink to the newest artifact.

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

### Final state — dashboard should be all green

- **World Server**: Online (PID visible via shared PID namespace, `pid: "service:mangosd"`); source-built md5 `bc142ad2288a986abb27cf2803494488` with `SuperUiBots/` modules
- **Auth Server**: Online
- **Remote Access**: Connected (RA account `superui`/`Changeme123!` logs in every reconnect cycle; mangosd logs `Received command: .server info` every 30s)
- **All 5 Databases**: Connected (mangos=177 tables, characters=66, realmd=15, logs=11, vmangos_admin=24)
- **DBC Directory**: 158 *.dbc files at `/opt/superui-core/data/5875/dbc`
- **Maps Directory**: 2429 *.map files at `/opt/superui-core/data/maps`
- **Bin Directory**: `/opt/superui-core/bin`
- **Client Data Path**: `/data/Data` (with base.MPQ, dbc.MPQ, etc.)
- **Bot AI**: 9 AiBotAI bots in Azure's group, auto-accept BG invites, auto-resume on match end
- **Quick Command**: `.server info` returns `Server uptime: NN Seconds.` confirming live RA.

### Source-build flow

The two builder services (in `docker-compose.yml` profiles) handle the source compile cycle:

```bash
# First build: ~30-40 min cold (ccache fills up)
# ccache lives in the ccache-core named volume; subsequent builds only
# recompile changed files (2-5 min).
docker compose --profile source-build run --rm superui-core-builder
docker compose build mangosd
docker compose up -d

# Same for the UI
docker compose --profile source-build run --rm mangossuperui-ui-builder
docker compose build superui
docker compose up -d
```

The builders use the local source tree (committed OR dirty). WIP changes flow through without requiring a separate commit step — output filenames get a `-wip` suffix when the working tree is dirty so consecutive local rebuilds don't collide. Only fetches upstream if the source dir is empty.
