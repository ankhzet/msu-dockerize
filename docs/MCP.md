# MCP (Model Context Protocol) Server

MSUI ships with an embedded MCP server that exposes the game server's
RemoteAdmin console, MariaDB queries, and process controls as tools that any
MCP-compatible LLM client can call. The endpoint is mounted on the existing
UI port at `/mcp` and uses the stateless Streamable HTTP transport
(MCP spec 2025-11-25).

> **Why?** An LLM agent with `ra_send_command`, `player_search`, and
> `process_restart_mangosd` can run a WoW 1.12.1 server for you: triage a
> stuck character, kick a griefing player, broadcast a maintenance notice,
> restart the world server. Every action is audited.

## Enabling it

1. Set a token (or a capability-scoped token list) in `.env`:
   ```bash
   # Legacy single superuser token (kept for back-compat):
   MCP_AUTH_TOKEN=$(openssl rand -hex 32)

   # OR preferred: per-token capability allowlist as a JSON array:
   MCP_TOKENS_JSON='[
     {"token":"tk_readonly_xxx","label":"ci-readonly","capabilities":["read"]},
     {"token":"tk_op_xxx","label":"claude-desktop","capabilities":["read","ra","process","write_db"]}
   ]'
   ```
2. Rebuild and restart: `docker compose up -d --build superui`.
3. The endpoint is reachable at `http://localhost:5000/mcp`.

The middleware (`Mcp/Auth/McpAuthMiddleware.cs`) does a constant-time compare
on every request; unauthenticated calls return `401` and never reach the SDK.
A request whose token lacks the capability required by the named tool
returns `403 insufficient_scope`.

## Tools exposed

215 tools, 29 classes. Plus **3 resources** and **4 prompts** (Phase 5).
All live in `vendor/MangosSuperUI/MangosSuperUI/Mcp/{Tools,Resources,Prompts}/`.
The full catalogue is listed below by class. Every tool defaults to
`read` capability unless it mutates world/player/account state.

### RemoteAdmin (`RaTools`) — capability: `ra`
- `ra_send_command` — raw RA command (audit-logged, with state-before/after capture)
- `ra_server_info` — `server info`, parsed into structured fields
- `ra_list_online` — `server plr`, parsed into rows
- `ra_kick_player` — `kick player <name>`
- `ra_ban_account` / `ra_unban_account` — `ban account` with duration + reason
- `ra_announce` — broadcast message to all players
- `ra_save_all` — `saveall` (persist online player data)
- `ra_shutdown` — `shutdown <seconds>`
- `ra_connection_status` — is the RA socket live?

### Players & accounts (`PlayerTools`) — capability: `read`
- `player_search` — LIKE prefix search over `characters.name`
- `player_detail` — full record by guid (race/class names, money broken gold/silver/copper, position, playtime, guild, account metadata)
- `player_list_online` — paginated list of online characters
- `account_lookup` — account metadata + character list by username

### Process control (`ProcessTools`) — capability: `read` (status) / `process` (mutate)
- `process_status` / `process_diagnostics`
- `process_start_mangosd` / `process_stop_mangosd` / `process_restart_mangosd`
- `process_start_realmd` / `process_stop_realmd` / `process_restart_realmd`

### Audit (`AuditTools`) — capability: `read`
- `audit_recent` — last N rows, optional category filter
- `audit_target_history` — actions targeting a specific player/account/guild

### Server self-diagnosis (`HomeTools`) — capability: `read`
- `home_status` — process flags + `.server info` parse + DB row counts
- `home_db_health` — per-database connectivity probe
- `home_diagnose` — comprehensive subsystem checks with fix suggestions

### DBC lookups (`DbcTools`) — capability: `read`
- `dbc_status`, `dbc_reload`
- `dbc_item_icon_url`, `dbc_spell_icon_url`, `dbc_gameobject_model_path`
- `dbc_item_model_info`
- `dbc_spell_entry`, `dbc_spell_duration`, `dbc_spell_cast_time`, `dbc_spell_range`
- `dbc_professions` — recipe spells + output items per profession

### Server logs (`ServerLogTools`) — capability: `read`
- `log_overview`, `log_characters`, `log_chat`, `log_trades`,
  `log_transactions`, `log_warden`, `log_spam`, `log_behavior`,
  `log_battlegrounds`

### Items (`ItemTools`) — capability: `read`
- `item_search` — paginated, all UI filters
- `item_detail` — full record with icon + model info
- `item_sources` — every way to obtain an item (creature, container, vendor, quest, crafting, disenchant)
- `item_icon_search` — find items sharing an icon filename
- `item_next_custom_id` — next free 900000+ entry

### Gameobjects (`GameObjectTools`) — capability: `read`
- `gameobject_search`, `gameobject_detail`
- `gameobject_custom_summary`, `gameobject_next_custom_id`
- `gameobject_full_row`, `gameobject_quest_name`

### World (creatures, loot, instances) (`WorldTools`) — capability: `read`
- `world_creature_search`, `world_creature_loot_tree`
- `world_instance_list`, `world_instance_lookup`

### Quests (`QuestTools`) — capability: `read`
- `quest_zones`, `quest_zone_chain`, `quest_search`

### World map (`WorldMapTools`) — capability: `read`
- `worldmap_available_maps`, `worldmap_tile_index`, `worldmap_get_height`
- `worldmap_spawns`, `worldmap_catalog`

### Wiki corpus (`WikiTools`) — capability: `read`
- `wiki_search`, `wiki_page`, `wiki_tree`, `wiki_stats`
- `wiki_index_status`, `wiki_reindex`

### C++ source code index (`SourceTools`) — capability: `read`
- `source_index_progress`, `source_stats`, `source_reindex`
- `source_search`, `source_smart_search`
- `source_get_symbol`, `source_get_type`, `source_get_enum`, `source_get_file`
- `source_inheritance_chain`, `source_export_trace`, `source_topic_explore`
- `source_find_string_references`, `source_find_member_references`

### Accounts & realms (`AccountWriteTools`) — read: `read`, write: `write_db`
- `account_list` — paginated, filterable (banned/muted/locked/online/gm)
- `account_summary` — totals for the filter bar
- `account_detail` — full record + characters + ban history + recent audit
- `account_realm_list` — realmlist with online counts
- `account_realm_update` — edit a realm's name/address/port/icon/flags/timezone/population (audit-logged)

### Instance loot (`InstanceWriteTools`) — capability: `write_db`
- `instance_update_loot` — change a loot row's chance/count (direct or ref pool)
- `instance_multiply_creature_loot` — bulk chance multiplier on a creature's direct drops
- `instance_add_loot_item` — insert an item into a loot table or ref pool
- `instance_remove_loot_item` — delete a loot row (direct or ref pool)

### Gameobject CRUD (`GameObjectWriteTools`) — capability: `write_db`
- `gameobject_create` — insert custom gameobject (entry >= 900000)
- `gameobject_update` — update editable columns on any entry
- `gameobject_delete` — delete a custom gameobject + its spawns (vanilla refused)

### Item CRUD (`ItemWriteTools`) — capability: `write_db`
- `item_create` — insert custom item (entry >= 900000 for safety)
- `item_update` — update editable columns
- `item_delete` — delete a custom item (vanilla refused)

### Configuration (`ConfigTools`) — read: `read`, write: `write_db`, reload: `ra`
- `config_load_mangosd` — parse `mangosd.conf` into structured sections + settings
- `config_save_mangosd` — edit settings (creates `.bak.<ts>` backup)
- `config_reload_mangosd` — `.reload config` over RA
- `settings_current` — current merged config (appsettings + overlay)
- `settings_override` — `server-config.json` contents (or `{exists:false}`)
- `settings_save` — merge into `server-config.json` (preserves unmanaged sections)
- `settings_reset` — delete `server-config.json`
- `settings_comfy_pool_status` — per-node ComfyUI dispatcher health

### Player actions (`PlayerWriteTools`) — capability: `ra`
- `player_revive` — `.revive <name>`
- `player_reset_talents`, `player_reset_spells`, `player_reset_all`
- `player_mute` — `.mute <name> <minutes> <reason>`
- `player_unmute` — `.unmute <name>`
- `player_teleport` — `.teleport <location> <name>`
- `player_gps` — `.gps` (selected target's position)

### Spells (`SpellWriteTools`) — search/detail: `read`, edits: `write_db`/`patches`
- `spell_search` — paginated with school/mechanic filters
- `spell_detail` — full `spell_template` row
- `spell_save` — edit one spell (column whitelist; ignores entry/build)
- `spell_save_batch` — apply same changes to many spells
- `patch_teach_spell` — teach a spell to a character
- `patch_unlearn_spell` — unlearn a spell from a character
- `patch_register_at_trainer` — register custom spell at one NPC trainer
- `patch_register_at_class_trainers` — register at every class trainer template
- `patch_copy_source_trainers` — copy trainer wiring from a vanilla spell
- `patch_delete_spell` — delete a custom spell (cascades)

### Worlds lifecycle (`WorldsTools`) — read: `read`, mutating: `worlds`
- `worlds_status` — full banner (live world, shelf, job, stats)
- `worlds_job` — current in-flight suspend/resume job
- `worlds_list` — registry dump
- `worlds_preflight` — validate a snapshot before resume
- `worlds_create_options` — eligible snapshots for a new RTS world
- `worlds_suspend` / `worlds_resume` — freeze and mount worlds
- `worlds_restore_group` — restore one `world`/`players`/`core` group
- `worlds_create_rts` — offline build a parked zero-roster RTS world
- `worlds_fork` — branch a new world off a snapshot
- `worlds_update` — rename / re-flavour / re-note
- `worlds_snapshot_label` — relabel a snapshot
- `worlds_delete_world` / `worlds_delete_snapshot`

### OG baseline (`BaselineTools`) — read: `read`, reset: `baseline`
- `baseline_status` — which `og_*` tables exist + row counts
- `baseline_initialize` — create `og_*` tables from current mangos state
- `baseline_diff_item` / `baseline_diff_spell` / `baseline_diff_gameobject` — field-level diffs
- `baseline_diff_creature_loot` / `baseline_diff_loot` — loot-table diffs
- `baseline_reset_item` / `baseline_reset_spell` / `baseline_reset_gameobject` — revert one row
- `baseline_reset_creature_loot` — restore all loot for one creature
- `baseline_reset_table` — reset one loot table wholesale
- `baseline_reset_all` — NUCLEAR: reset every `og_*` table

### Live drift (`DivergenceTools`) — capability: `read`
- `divergence_overview` — per-domain totals (tracked / deep modes)
- `divergence_tree` — variable-depth drill (bucket → boss → baseitem)
- `divergence_invalidate_cache` — drop the 10-min scan cache

### Change graph undo (`ChangeGraphTools`) — read: `read`, revert: `baseline`
- `changegraph_overview` — per-domain rollup
- `changegraph_batches` / `changegraph_entries` / `changegraph_entry` — drill
- `changegraph_revert_entry` / `changegraph_revert_batch` — undo (uses captured before-state)

### Activity log (`ActivityTools`) — capability: `read`
- `activity_entries` / `activity_summary` / `activity_detail`

### Bot fleet (`BotTools`) — read: `read`, commands: `bots`
- Reads: `bot_list` / `bot_state` / `bot_fleet_state` / `bot_brain_state` / `bot_brain_status` / `bot_live_state` / `bot_fleet_report` / `bot_diag`
- Commands: `bot_spawn` / `bot_spawn_all` / `bot_move_to` / `bot_say_text` /
  `bot_accept_quest` / `bot_complete_quest` / `bot_abandon_quest` /
  `bot_learn_spell` / `bot_attack_target` / `bot_interact_npc` /
  `bot_take_flight` / `bot_set_task_grind` / `bot_set_task_idle` /
  `bot_gear_up` / `bot_toggle_brain` / `bot_form_group` / `bot_disband_group` /
  `bot_auto_form_groups` / `bot_set_grouping_mode`

### Combat rotations (`RotationTools`) — read: `read`, write: `bots`
- `rotation_list` / `rotation_assignments` / `rotation_get_profile`
- `rotation_assign` / `rotation_clear`

### Patch metadata (`PatchTools`) — capability: `read`
- `patch_search_source` / `patch_source_ranks` / `patch_skill_tab_map` /
  `patch_class_trainer_template_map` / `patch_search_trainers` /
  `patch_search_icons` / `patch_custom_spells` / `patch_texture_themes`

### Lootifier (`LootifierTools`) — capability: `read`
- `lootifier_meta` / `lootifier_zones` / `lootifier_status`
- `crafting_lootifier_status` / `quest_lootifier_status`

## Resources (MCP primitives you can `@-mention`)

Resources are file-like content addressed by URI. The agent references them
the same way you'd reference a file in chat.

### `mcp://msui/health` — `ServerHealthResource`
Single JSON snapshot of the live server: process flags for mangosd/realmd,
RA connectivity, parsed `.server info` (online/max/uptime/core revision),
DB row counts (accounts, characters, GMs, banned), and per-DB ping from
`home_db_health`. Use to anchor a conversation.

### `mcp://msui/players/{guid}` — `PlayerSnapshotResource`
Full player record (character + guild + account) + the last 20 audit_log
entries targeting them. URI path segment `{guid}` is the character guid
(integer). Useful when investigating a specific report.

### `mcp://msui/bots/fleet` — `BotFleetResource`
Live bot fleet projection: brain enable flag, connected count, total
tracked, then stalled-first list of every bot's live context
(goal/step/why/timers/pos/target/pending/failure/stall/scratch).

## Prompts (slash-invocable message templates)

Prompts are pre-canned system + user message bundles. The host presents
them as `/command-name` slash commands; the agent fills in the arguments
and uses MCP tools to fulfil them.

### `/investigate-player {characterName} [context]`
Bundled system prompt instructs the agent to: search → detail → account →
audit_target_history → log_chat. Synthesises a triage report. **Does
not** propose moderation actions without evidence, and **does not**
execute any RA command without explicit confirmation.

### `/restart-server [delaySeconds=5]`
Bundled safe-restart workflow: worlds_status → confirm with operator →
ra_save_all → ra_shutdown (with delay) → process_restart_mangosd →
home_status + home_diagnose. Reports online player count first and
asks before the destructive step.

### `/triage-griefing {characterName} [reportContext]`
Bundled griefing-triage workflow: gather evidence (player detail, audit,
chat log, account flags), summarise what likely happened, propose
**exactly one** action with its full RA command line, and ask for
confirmation before executing.

### `/review-changes {domain?} [hours=168]`
Bundled change-review workflow: divergence_overview (tracked + deep) →
divergence_tree → changegraph_overview → changegraph_batches →
activity_entries. Proposes a grouped revert plan with `baseline_reset_*`
and `changegraph_revert_*` tool calls, each marked low/medium/high risk.
Never executes a revert — just presents the plan.

### Players & accounts (`PlayerTools`)
- `player_search` — LIKE prefix search over `characters.name`
- `player_detail` — full record by guid (race/class names, money broken
  gold/silver/copper, position, playtime, guild, account metadata)
- `player_list_online` — paginated list of online characters
- `account_lookup` — account metadata + character list by username

### Process control (`ProcessTools`)
- `process_status` / `process_diagnostics`
- `process_start_mangosd` / `process_stop_mangosd` / `process_restart_mangosd`
- `process_start_realmd` / `process_stop_realmd` / `process_restart_realmd`

### Audit (`AuditTools`)
- `audit_recent` — last N rows, optional category filter
- `audit_target_history` — actions targeting a specific player/account/guild

## Wiring your LLM client

### Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS,
`%APPDATA%\Claude\claude_desktop_config.json` on Windows)

```json
{
  "mcpServers": {
    "msui": {
      "type": "http",
      "url": "http://localhost:5000/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

### VS Code (`.vscode/mcp.json` in any workspace)

```json
{
  "servers": {
    "msui": {
      "type": "http",
      "url": "http://localhost:5000/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

### Manual probe

```bash
TOKEN=$(grep MCP_AUTH_TOKEN .env | cut -d= -f2)
curl -sS -X POST http://localhost:5000/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq .
```

## Architecture

```
Browser / Claude Desktop / VS Code / curl
        │            (Streamable HTTP)
        │   Authorization: Bearer <MCP_AUTH_TOKEN>
        ▼
┌──────────────────────────────────────┐
│  MangosSuperUI (ASP.NET Core 8)      │
│                                      │
│  McpBearerAuthMiddleware ──┐         │
│                            │ 401 if  │
│                            │ invalid │
│                            ▼         │
│  MapMcp("/mcp") ──► McpServer        │
│                      ├─ RaTools     │
│                      ├─ PlayerTools │
│                      ├─ ProcessTools│
│                      └─ AuditTools  │
│                                      │
│  delegates to:                       │
│   ├─ RaService ─► mangosd:3443 (RA)  │
│   ├─ ConnectionFactory ─► mariadb    │
│   └─ ProcessManagerService ─► /proc  │
└──────────────────────────────────────┘
```

## Why stateless Streamable HTTP?

- **Horizontal scale** — no session affinity, no in-memory session map
- **Natural backpressure** — POST stays open until the tool returns
- **No SSE legacy** — `EnableLegacySse` is `[Obsolete]` in MCP C# SDK 2.x;
  we deliberately don't enable it
- **Forward-compatible** — `Stateless = true` is the recommended default
  per the [2025-11-25 spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

## Tool response envelope

Every tool returns the same JSON shape so agents can `try/catch` predictably:

```jsonc
// success
{ "ok": true, "data": <tool-defined payload> }

// failure
{ "ok": false, "error": { "code": "INVALID_INPUT", "message": "...",
                          "retryable": false, "hint": "..." } }
```

`code` is from a controlled vocabulary in `Mcp/Common/ErrorCodes.cs`
(`RA_DISCONNECTED`, `DB_UNAVAILABLE`, `INVALID_INPUT`, `PERMISSION_DENIED`,
`NOT_FOUND`, `PARTIAL`, `CONFLICT`, `INTERNAL`, `RATE_LIMITED`).

## Capability matrix

Every tool declares one or more `[McpCapability]` attributes. A token must
hold **all** capabilities a tool requires to invoke it. See the top-level
[README capability matrix](../README.md#capability-matrix) for the
high-level overview.

| Capability | Tools that need it |
|---|---|
| `read`      | All Phase-2 read-only tools + `audit_*`, `process_status`, `process_diagnostics`. Default if no attribute present. |
| `ra`        | All `ra_*` tools. |
| `process`   | `process_start_*` / `process_stop_*` / `process_restart_*`. |
| `write_db`  | Phase-3 content writes (account, item, gameobject, spell, instance, config). |
| `worlds`    | `worlds_*` lifecycle tools. |
| `bots`      | `bot_*` and `rotation_*` (Phase-4). |
| `patches`   | `patch_*` + `spell_completer_*` (Phase-4). |
| `baseline`  | `baseline_*` reset tools (Phase-4). |
| `lootifier` | `lootifier_*` / `crafting_*` / `quest_lootifier_*` / `loot_tuner_*` / `profession_tuning_*` (Phase-4). |
| `retexture` | Retexture pipeline tools (Phase-7+). |

A token with an empty `capabilities` array is a superuser (granted all).
The legacy `MCP_AUTH_TOKEN` env var is treated as a superuser token for
back-compat with Phase-0 deployments.

## Security model

| Concern | Mitigation |
|---|---|
| Unauthenticated access | Bearer token enforced in middleware before MapMcp |
| Token timing leak | `CryptographicOperations.FixedTimeEquals` for compare |
| RA commands | Every command routed through `AuditService.ExecuteAndLogAsync` — same audit trail as the UI |
| DB writes | MVP is read-only; write tools live behind MCP require explicit opt-in later |
| DNS rebinding | Endpoint bound to 127.0.0.1 by docker-compose port mapping |
| DNS rebinding (browser) | CORS is OFF by default; add allowed origins only if you build a browser client |

## What is NOT exposed yet

Phase 5 shipped resources + prompts. Still missing (Phase 6+ in
[`TODO.MCP.md`](../TODO.MCP.md)):

- Lootifier / crafting / quest / profession tuning generation tools
  (preview / commit / rollback) — `lootifier` capability, deferred for
  Phase 7+ because they're complex multi-step mutations
- World editor placements / save / commit / sculpt
- Retexture pipeline (`retexture` capability)
- Tests (`tests/Mcp/`), telemetry hooks, mcp-tools.json generator

Each is one new `[McpServerToolType]` class in `Mcp/Tools/` and one
`WithTools<X>()` call in `Program.cs`, plus a `[McpCapability]` attribute
to gate it on the right token capability. Resources go in
`Mcp/Resources/` with `WithResources<T>()`, prompts in `Mcp/Prompts/`
with `WithPrompts<T>()`.

## Troubleshooting

**401 Unauthorized** — `MCP_AUTH_TOKEN` mismatch. Check the value inside the
container matches what's in `.env`:

```bash
docker compose exec superui printenv MCP_AUTH_TOKEN
```

**Endpoint not found** — `MapMcp("/mcp")` was skipped because the request
hit a controller route. Check `Mcp:Route` in the rendered
`/opt/mangossuperui/server-config.json`.

**Tool returns "RA command failed"** — the auth flow to mangosd's RA failed.
Check `RA_HOST` / `RA_PORT` / `RA_USERNAME` / `RA_PASSWORD` against
`mangosd.conf` (`Ra.MinLevel = 3` is required by VMaNGOS).
