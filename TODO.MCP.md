# TODO.MCP — Comprehensive MCP Surface for MangosSuperUI

**Status:** MVP shipped (Phase 1, 25 tools, 4 tool classes).
**Goal:** expose every meaningful MSUI capability to LLM agents over stateless Streamable HTTP, in dependency order, behind capability-scoped auth.
**Last updated:** 2026-08-15

---

## What ships today

```
Mcp/Options/McpOptions.cs                 Mcp / McpAuth / McpAudit options POCO
Mcp/Auth/McpBearerAuthMiddleware.cs       Constant-time bearer-token check (pre-MapMcp)
Mcp/Tools/WoWLookups.cs                   Race/class/GM/playtime tables (internal)
Mcp/Tools/RaTools.cs                      9 tools   (RA + announce + ban + save + shutdown)
Mcp/Tools/PlayerTools.cs                  4 tools   (search + detail + online + account)
Mcp/Tools/ProcessTools.cs                 8 tools   (status + diagnostics + start/stop/restart ×2)
Mcp/Tools/AuditTools.cs                   2 tools   (recent + target_history)
                                          ─────
                                          25 tools total
```

Endpoint: `http://localhost:5000/mcp` (bound to 127.0.0.1 by docker-compose), bearer-token auth via `MCP_AUTH_TOKEN`.

---

## Phasing strategy

Six phases, each independently shippable. Each phase lists the tool class to add, the controllers/services consumed, dependencies on earlier phases, and risk.

| Phase | Title | Tool classes | Tools added | Risk |
|---|---|---|---|---|
| **1** | **Foundations** | — | 0 | low |
| **2** | **Read-only observability** | 7 | ~45 | low |
| **3** | **Content management (moderate)** | 6 | ~30 | medium |
| **4** | **Powerful / long-running operations** | 5 | ~20 | high |
| **5** | **Resources & prompts** | 3 | 3 resources, 4 prompts | low |
| **6** | **Polish** | — | 0 | low |

Total target surface: **~120 tools + 3 resources + 4 prompts** = ~127 MCP primitives.

---

# Phase 1 — Foundations  ▸ low risk

**Goal:** make subsequent phases safe to land. Capability-scoped auth, per-tool audit attribution, telemetry, naming conventions, JSON shape conventions, error envelope, tool-list pagination.

## 1.1 Capability-scoped bearer tokens  ▸ MCP-001
Single shared `MCP_AUTH_TOKEN` is fine for solo use but doesn't scale to "Claude Desktop may announce, my CI bot may only read". Replace with capability-tagged tokens.

```
Mcp.Auth.Tokens = [
  { token = "tk_xxx", label = "claude-desktop", capabilities = ["read", "ra", "process", "announce"] },
  { token = "tk_yyy", label = "ci-readonly",   capabilities = ["read"] }
]
```

Tool attributes get a `[McpCapability("ra")]` (custom attribute or `IEnumerable<string>` in `WithTools<T>` filter). Middleware checks token capabilities before invoking the tool.

**Files:**
- `Mcp/Auth/McpTokenStore.cs` (in-memory list loaded from `Mcp:Auth:Tokens`)
- `Mcp/Auth/CapabilityAttribute.cs`
- `Mcp/Auth/McpBearerAuthMiddleware.cs` (extend with capability resolution, `WWW-Authenticate: Bearer error="insufficient_scope"`)
- `Mcp/Options/McpAuthOptions.cs` (add `Tokens`, `RequireCapabilityMatch`)
- `docker/ui/entrypoint.sh` (render new tokens block)

**Tests:** `tests/Mcp/CapabilityEnforcementTests.cs`

## 1.2 Standard JSON envelope + error contract  ▸ MCP-002
Every tool returns one of two shapes so agents can `try/catch` predictably.

```json
// success
{ "ok": true,  "data": <payload> }

// failure
{ "ok": false, "error": { "code": "RA_DISCONNECTED", "message": "...", "retryable": true, "hint": "ra_reconnect" } }
```

**Files:**
- `Mcp/Common/McpResult.cs` (record types, factory helpers)
- `Mcp/Common/ErrorCodes.cs` (constants — `RA_DISCONNECTED`, `DB_UNAVAILABLE`, `INVALID_INPUT`, `PERMISSION_DENIED`, `NOT_FOUND`, `PARTIAL`, …)
- Update `RaTools.cs`, `PlayerTools.cs`, `ProcessTools.cs`, `AuditTools.cs` to use the envelope (refactor, no behaviour change)

## 1.3 Per-tool audit attribution  ▸ MCP-003
Today every tool stamps `operatorIp = "mcp"`. Replace with `{tokenLabel, sessionId, remoteIp}`. Add an MCP `sessionId` UUID per client (sticky per `Authorization` token, stored in `IMcpSessionRegistry` keyed by hash of token).

**Files:**
- `Mcp/Auth/McpSessionRegistry.cs`
- `Mcp/Auth/McpCallContext.cs` (scoped per tool invocation, injected via DI)
- Update `AuditService.ExecuteAndLogAsync` callers in `RaTools.cs` to pass through `McpCallContext`

## 1.4 Tool-name + namespace conventions  ▸ MCP-004
Lock the naming grid before further tools land:

| Prefix | Domain |
|---|---|
| `player_*`   | characters / accounts / guilds |
| `account_*`  | realmd DB |
| `world_*`    | world DB (creatures, gameobjects, quests, instances) |
| `item_*`     | item_template + sources + retexture |
| `spell_*`    | spell_template + custom spells + DNA |
| `dbc_*`      | DBC lookups |
| `gameobject_*` | gameobject_template + spawns |
| `bot_*`      | BotBridge + BotBrain |
| `rotation_*` | Combat rotations |
| `chat_*`     | BotChat settings |
| `wiki_*`     | Corpus search + browse |
| `source_*`   | C++ source index |
| `log_*`      | logs_* tables |
| `audit_*`    | audit_log + change graph |
| `divergence_*` | live drift vs OG |
| `baseline_*` | OG snapshots |
| `worlds_*`   | suspend / resume / fork / snapshot |
| `config_*`   | mangosd.conf / server-config.json |
| `patch_*`    | patch MPQ lifecycle |
| `comfy_*`    | ComfyUI pool |
| `ollama_*`   | Ollama probe |
| `process_*`  | mangosd / realmd process control |
| `ra_*`       | RemoteAdmin commands |
| `diag_*`     | diagnostics (DB health, ADT, height) |

**Action:** add a `Mcp/Tools/README.md` codifying the grid; reject PRs that violate it.

## 1.5 Tool list pagination + client hint  ▸ MCP-005
When the surface hits ~50 tools the `tools/list` response becomes large. The C# SDK already streams; we just need to make sure we don't accidentally materialise every `JsonSchema` eagerly.

**Files:** none — config-only via `WithTools<T>().WithListToolsHandler(...)`. Verify with `mcp inspector` against a Phase-2 build.

---

# Phase 2 — Read-only observability  ▸ low risk

Pure reads. No DB writes, no RA commands. Each tool class maps to one controller or one service. These are the safest to ship — every agent should start here.

## 2.1 HomeTools — server self-diagnosis  ▸ MCP-010

Wraps `HomeController.Status/DbHealth/Diagnose`.

| Tool | Maps to | Purpose |
|---|---|---|
| `home_status` | `HomeController.Status` | live `.server info` parse + DB counts |
| `home_db_health` | `HomeController.DbHealth` | per-database connectivity, `vmangos_admin` init flag |
| `home_diagnose` | `HomeController.Diagnose` | comprehensive self-diagnosis with fix hints |

**Files:** `Mcp/Tools/HomeTools.cs` (DI: `HomeController`'s deps — re-use `RaService`, `ConnectionFactory`, `AuditService`, `DbInitializationService`, `IConfiguration`, `IOptionsMonitor<VmangosSettings>`, `IOptionsMonitor<RemoteAccessSettings>`, `MpqReaderService`)

## 2.2 DbcTools — DBC lookups  ▸ MCP-011

Wraps `DbcController.Status/ItemIcon/SpellIcon/SpellDurations/SpellCastTimes/SpellRanges` + `DbcService.GetItemIconPath/GetSpellIconPath/GetItemModelInfo/…/GetProfessionOutputs/GetSpellCreatedItem`.

| Tool | Purpose |
|---|---|
| `dbc_status` | load status + path + counts |
| `dbc_item_icon_url` | `displayId → /Icon/Get?name=…` web URL |
| `dbc_spell_icon_url` | `spellIconId → /Icon/Get?name=…` |
| `dbc_item_model_info` | full ItemDisplayInfo (modelNames[2], textureNames[2], bodyTextures[8], geosetGroup[3], helmetGeosetVis[2], itemVisualId) |
| `dbc_spell_duration` | one or many duration rows |
| `dbc_spell_cast_time` | one or many cast-time rows |
| `dbc_spell_range` | one or many range rows |
| `dbc_spell_entry` | `spellId → { name, subtext, school, level, description }` |
| `dbc_professions` | gear-making professions with output items + recipe spells |
| `dbc_reload` | re-read all DBC files from disk |

**Files:** `Mcp/Tools/DbcTools.cs` (DI: `DbcService`)

## 2.3 ItemTools — item DB  ▸ MCP-012

Wraps `ItemsController.Search/Sources/Detail/NextCustomId/IconSearch/DisplayInfoRow`.

| Tool | Purpose |
|---|---|
| `item_search` | paginated item search with all UI filters |
| `item_detail` | full item record + icon URL + model path |
| `item_sources` | every way to obtain an item — calls `ItemSourceResolver.ResolveAsync` (single most useful item tool) |
| `item_icon_search` | icon-filename search |
| `item_next_custom_id` | next free entry in 900000+ |

**Files:** `Mcp/Tools/ItemTools.cs` (DI: `ConnectionFactory`, `DbcService`, `IWebHostEnvironment`)

## 2.4 GameObjectTools — gameobject DB  ▸ MCP-013

Wraps `GameObjectsController.Search/Detail/CustomSummary/NextCustomId/FullRow/QuestName`.

| Tool | Purpose |
|---|---|
| `gameobject_search` | paginated GO search with type filter |
| `gameobject_detail` | full record + spawns + model path |
| `gameobject_custom_summary` | all custom gameobjects grouped by type |
| `gameobject_next_custom_id` | next free entry in 900000+ |
| `gameobject_full_row` | every column (for an LLM to decide edits) |
| `gameobject_quest_name` | `questId → name` |

**Files:** `Mcp/Tools/GameObjectTools.cs`

## 2.5 WorldTools — creatures, quests, instances, world map  ▸ MCP-014

Splits into four small classes because the surface is wide:

### `WorldTools.cs`
- `world_creature_search` — wrap `LootifierController.SearchCreature`
- `world_creature_loot_tree` — wrap `LootifierController.LootTree`
- `world_creature_analyze_item` — wrap `LootifierController.AnalyzeItem`
- `world_lootifier_status` — wrap `LootifierController.Status`
- `world_instance_list` — wrap `InstancesController.List` (uses `InstanceCatalog.All`)
- `world_instance_creatures` — `InstancesController.Creatures`
- `world_instance_loot` — `InstancesController.Loot`
- `world_instance_search_items` — `InstancesController.SearchItems`
- `world_instance_group_info` — `InstancesController.GroupInfo`

### `QuestTools.cs`
- `quest_search` — `QuestLootifierController.SearchQuest`
- `quest_rewards` — `QuestLootifierController.QuestRewards`
- `quest_data_zone_chain` — `QuestDataController.ZoneChain`
- `quest_data_zones` — `QuestDataController.Zones`

### `WorldMapTools.cs`
- `worldmap_available_maps`
- `worldmap_tile_index`
- `worldmap_tile`
- `worldmap_get_height`
- `worldmap_spawns` (bounding box)

**Files:** `Mcp/Tools/WorldTools.cs`, `Mcp/Tools/QuestTools.cs`, `Mcp/Tools/WorldMapTools.cs`

## 2.6 ServerLogTools — server logs  ▸ MCP-015

Wraps `ServerLogsController.Characters/Chat/Trades/Transactions/Warden/Spam/Behavior/Battlegrounds/Overview`.

| Tool | Purpose |
|---|---|
| `log_overview` | row counts per `logs_*` table |
| `log_characters` | login/logout/create/delete/lost socket |
| `log_chat` | say/whisper/group/guild/etc |
| `log_trades` | auction/mail/loot/quest/GM |
| `log_transactions` | transaction log |
| `log_warden` | anti-cheat |
| `log_spam` | spam-detect |
| `log_behavior` | behaviour log |
| `log_battlegrounds` | BG log |

**Files:** `Mcp/Tools/ServerLogTools.cs` (DI: `ConnectionFactory`)

## 2.7 WikiTools + SourceTools — corpus search  ▸ MCP-016 / MCP-017

Wraps `WikiController.*` + `WikiSearchStore` and `SourceMapController.*` + `SourceIndexerService`.

### `WikiTools.cs`
- `wiki_search` — full-text corpus search
- `wiki_page` — render one Markdown page to HTML
- `wiki_tree` — nav tree
- `wiki_stats` — corpus summary
- `wiki_lua_search` — FrameXML catalog
- `wiki_lua_record` — one Lua record
- `wiki_lua_context` — Markdown bundle for pasting into a chat
- `wiki_reindex` — force a rebuild

### `SourceTools.cs`
- `source_stats`
- `source_search`
- `source_smart_search` — `me->IsDead()` → candidate symbols
- `source_get_symbol`
- `source_get_type`
- `source_get_enum`
- `source_get_file`
- `source_inheritance_chain`
- `source_body`
- `source_export_trace`
- `source_topic_explore`
- `source_find_string_references`
- `source_find_member_references`
- `source_fk_research_bundle`
- `source_reindex`

**Files:** `Mcp/Tools/WikiTools.cs`, `Mcp/Tools/SourceTools.cs`

---

# Phase 3 — Content management (moderate risk)  ▸ medium risk

Writes to the world / characters / realmd DB. Every write goes through `AuditService` so the agent identity, before/after state, and timestamp are recorded. **Capability tag:** `write_db`.

## 3.1 AccountWriteTools  ▸ MCP-020

Wraps `AccountsController.Detail` (read), `RealmController.List/Update`.

| Tool | Purpose |
|---|---|
| `account_detail` | full account record + characters + ban history + last 20 audits |
| `account_summary` | totals for filter bar |
| `account_list` | paginated list with filters |
| `account_realm_list` | realm list with online/total stats |
| `account_realm_update` | editable realm fields |

**Files:** `Mcp/Tools/AccountWriteTools.cs`

## 3.2 PlayerWriteTools  ▸ MCP-021

Adds writes that mirror the existing UI's `Players/RaCommand` flow, but with structured inputs.

| Tool | Purpose |
|---|---|
| `player_revive` | sends `.revive` to RA |
| `player_reset_talents` | sends `.reset talents <name>` |
| `player_reset_spells` | sends `.reset spells <name>` |
| `player_reset_all` | sends `.reset all <name>` |
| `player_mute` | sends `.mute <name> <minutes> <reason>` |
| `player_unmute` | sends `.unmute <name>` |
| `player_kick` | already in `RaTools` — keep as canonical, this is just a doc pointer |
| `player_teleport` | sends `.teleport <location>` (named location or coords) |
| `player_gps` | sends `.gps` (current location) |

**Files:** `Mcp/Tools/PlayerWriteTools.cs`

## 3.3 GameObjectWriteTools  ▸ MCP-022

Wraps `GameObjectsController.Save/Delete/NextCustomId`.

| Tool | Purpose |
|---|---|
| `gameobject_create` | insert new (clones an existing entry; returns the new entry id) |
| `gameobject_update` | update one gameobject |
| `gameobject_delete` | delete a custom gameobject + its spawns |

**Files:** `Mcp/Tools/GameObjectWriteTools.cs`

## 3.4 ItemWriteTools  ▸ MCP-023

Wraps `ItemsController.Save/Delete/NextCustomId`.

| Tool | Purpose |
|---|---|
| `item_create` | insert new (900000+) |
| `item_update` | update one item (column whitelist) |
| `item_delete` | delete a custom item |

**Files:** `Mcp/Tools/ItemWriteTools.cs`

## 3.5 SpellWriteTools  ▸ MCP-024

Wraps `SpellsController.Save/SaveBatch` + `SpellCompleterController.SourceInfo/TrainerStatus/ServerStatus/Complete` + `PatchController.DeleteSpell/TeachSpell/UnlearnSpell/RegisterAtTrainer/CopySourceTrainers/RegisterAtClassTrainers`.

| Tool | Purpose |
|---|---|
| `spell_search` | `SpellsController.Search` |
| `spell_detail` | `SpellsController.Detail` (with OG diff) |
| `spell_group_detail` | `SpellsController.GroupDetail` |
| `spell_save` | one spell (column whitelist) |
| `spell_save_batch` | same change to multiple spells |
| `spell_completer_source_info` | `SpellCompleterController.SourceInfo` |
| `spell_completer_trainer_status` | `SpellCompleterController.TrainerStatus` |
| `spell_completer_server_status` | `SpellCompleterController.ServerStatus` |
| `spell_completer_complete` | `SpellCompleterController.Complete` |
| `patch_teach_spell` | `PatchController.TeachSpell` |
| `patch_unlearn_spell` | `PatchController.UnlearnSpell` |
| `patch_register_at_trainer` | one trainer |
| `patch_register_at_class_trainers` | every class trainer |
| `patch_copy_source_trainers` | copy from source spell |
| `patch_delete_spell` | delete custom spell (cascades) |

**Files:** `Mcp/Tools/SpellWriteTools.cs`

## 3.6 InstanceWriteTools  ▸ MCP-025

Wraps `InstancesController.UpdateLoot/MultiplyCreatureLoot/AddLootItem/RemoveLootItem`.

| Tool | Purpose |
|---|---|
| `instance_update_loot` | update one loot row's chance/count |
| `instance_multiply_creature_loot` | bulk multiplier |
| `instance_add_loot_item` | insert a new item into a loot table |
| `instance_remove_loot_item` | delete from a loot table |

**Files:** `Mcp/Tools/InstanceWriteTools.cs`

## 3.7 ConfigTools  ▸ MCP-026

Wraps `ConfigController.Load/Save/Reload` + `SettingsController.Current/Override/Save/Reset`.

| Tool | Purpose |
|---|---|
| `config_load_mangosd` | read & parse `mangosd.conf` |
| `config_save_mangosd` | update one or more settings (creates `.bak.<ts>`) |
| `config_reload_mangosd` | send `.reload config` over RA |
| `settings_current` | merged config view |
| `settings_override` | `server-config.json` contents |
| `settings_save` | upsert `server-config.json` (merge, never overwrite) |
| `settings_reset` | delete override |

**Files:** `Mcp/Tools/ConfigTools.cs`

---

# Phase 4 — Powerful / long-running operations  ▸ high risk

World lifecycle, patch builds, baselines, bot commands, retexture pipelines. Each one can wreck state. **Capability tags:** `worlds`, `bots`, `patches`, `baseline`, `retexture`.

## 4.1 WorldsTools  ▸ MCP-030

Wraps `WorldsController.*` + `WorldStateService.*`.

| Tool | Purpose |
|---|---|
| `worlds_status` | live world + shelf + process flags + stats |
| `worlds_job` | current in-flight suspend/resume |
| `worlds_list` | full registry |
| `worlds_preflight` | validate a snapshot before resume |
| `worlds_create_options` | profile metadata + eligible snapshots |
| `worlds_suspend` | freeze live world (label optional) |
| `worlds_resume` | mount a world |
| `worlds_restore_group` | surgical restore of `world`/`players`/`core` from one snapshot |
| `worlds_create_rts` | offline build of zero-roster RTS |
| `worlds_fork` | branch a new world off a snapshot |
| `worlds_update` | rename / re-flavour / re-note |
| `worlds_snapshot_label` | retitle snapshot |
| `worlds_delete_world` | drop world (ref-counted) |
| `worlds_delete_snapshot` | drop one snapshot |

**Files:** `Mcp/Tools/WorldsTools.cs` (DI: `WorldStateService`, `AuditService`)

## 4.2 BaselineTools  ▸ MCP-031

Wraps `BaselineController.*`.

| Tool | Purpose |
|---|---|
| `baseline_status` | whether OG tables exist + row counts |
| `baseline_initialize` | create OG snapshot tables from `mangos` |
| `baseline_diff_item` | field-level diff vs `og_item_template` |
| `baseline_diff_spell` | field-level diff vs `og_spell_template` |
| `baseline_diff_gameobject` | field-level diff vs `og_gameobject_template` |
| `baseline_diff_creature_loot` | direct + ref-table loot diff |
| `baseline_diff_loot` | diff one loot table entry |
| `baseline_reset_item` | restore one item |
| `baseline_reset_spell` | restore one spell |
| `baseline_reset_gameobject` | restore one gameobject |
| `baseline_reset_creature_loot` | restore all loot for one creature |
| `baseline_reset_instance` | restore all loot for a map |
| `baseline_reset_table` | reset one loot table |
| `baseline_reset_all` | nuclear: restore every OG snapshot |

**Files:** `Mcp/Tools/BaselineTools.cs`

## 4.3 DivergenceTools + ChangeGraphTools  ▸ MCP-032 / MCP-033

Wraps `DivergenceService.*` + `ChangeGraphService.*`. The LLM-facing "what changed, undo it" surface.

### `DivergenceTools.cs`
- `divergence_overview` — per-domain totals (`tracked`/`deep` mode)
- `divergence_tree` — variable-depth drill (bucket → loot-kind → profession/instance → boss → baseitem)
- `divergence_invalidate_cache` — drop the per-surface scan cache

### `ChangeGraphTools.cs`
- `changegraph_overview`
- `changegraph_batches`
- `changegraph_entries`
- `changegraph_entry`
- `changegraph_revert_entry`
- `changegraph_revert_batch`

**Files:** `Mcp/Tools/DivergenceTools.cs`, `Mcp/Tools/ChangeGraphTools.cs`

## 4.4 PatchTools  ▸ MCP-034

Wraps `PatchController.*` + `PatchBuilderService.*` (orchestrator only).

| Tool | Purpose |
|---|---|
| `patch_list` | available patches |
| `patch_generate` | generate a custom spell patch |
| `patch_rebuild_client` | rebuild MPQ client patch |
| `patch_search_source` | source spell search |
| `patch_source_ranks` | rank versions of a source spell |
| `patch_skill_tab_map` | class → skill tab |
| `patch_search_trainers` | trainer search |
| `patch_search_icons` | icon search |
| `patch_generate_icon` | generate a custom icon (Ollama + ComfyUI) |
| `patch_texture_themes` | available themes |
| `patch_generate_textures` | generate textures |
| `patch_reprocess_textures` | reprocess |
| `patch_apply_tuning` | apply tuning preset |
| `patch_experiment_*` | 6 tools from `PatchController.Experiments.cs` |

**Files:** `Mcp/Tools/PatchTools.cs`

## 4.5 BotTools  ▸ MCP-035

Wraps `BotBridgeService.*` + `BotBrainService.*` + `BotDiagnosticsService.*` + `RotationService.*`.

### Read
| Tool | Purpose |
|---|---|
| `bot_list` | all bots (guid, name, level, …) |
| `bot_state` | one bot (full state) |
| `bot_fleet_state` | live fleet projection |
| `bot_brain_state` | decision engine summary |
| `bot_brain_status` | brain on/off + active count + groups |
| `bot_live_state` | one bot context |
| `bot_live_fleet` | all bot contexts |
| `bot_live_log` | cursor-paginated log slice |
| `bot_bot_report` | one bot's quantized report |
| `bot_quest_status` | all quest statuses |
| `bot_inventory` | equipped + bags + backpack + gold |
| `bot_diag` | run `bot_diag.sh <name>` |
| `bot_fleet_report` | run `bot_run_report.sh` |
| `rotation_list` | profiles + assignments |
| `rotation_assignments` | current bot → profile map |

### Write (operator-only)
| Tool | Purpose |
|---|---|
| `bot_spawn` | `.bot addai <cls> <race> <name>` |
| `bot_spawn_all` | `.bot add_all` |
| `bot_move_to` | MOVE_TO |
| `bot_say_text` | SAY_TEXT |
| `bot_accept_quest` | ACCEPT_QUEST |
| `bot_complete_quest` | COMPLETE_QUEST |
| `bot_abandon_quest` | ABANDON_QUEST |
| `bot_learn_spell` | LEARN_SPELL |
| `bot_attack_target` | ATTACK_TARGET |
| `bot_interact_npc` | INTERACT_NPC |
| `bot_take_flight` | TAKE_FLIGHT |
| `bot_set_task_grind` | SET_TASK GRIND |
| `bot_set_task_idle` | SET_TASK IDLE |
| `bot_gear_up` | GEAR_UP |
| `bot_toggle_brain` | enable/disable globally |
| `bot_form_group` | manual group |
| `bot_disband_group` | disband |
| `bot_auto_form_groups` | auto-form |
| `bot_set_grouping_mode` | 0/1/2 |
| `rotation_assign` | assign a profile to a bot |
| `rotation_clear` | clear a bot's rotation |

**Files:** `Mcp/Tools/BotTools.cs`, `Mcp/Tools/RotationTools.cs`

## 4.6 LootifierTools + CraftingLootifierTools + QuestLootifierTools + LootTunerTools + ProfessionTuningTools  ▸ MCP-036 … MCP-040

One tool class per controller. All wrap `*/Preview` + `*/Commit` + `*/Rollback` flows. **Capability tag:** `lootifier`.

### `LootifierTools.cs` (creature)
- `lootifier_meta`, `lootifier_zones`, `lootifier_status`
- `lootifier_preview`, `lootifier_commit`, `lootifier_rollback`
- `lootifier_batch_preview`, `lootifier_batch_sample_preview`, `lootifier_batch_commit`

### `CraftingLootifierTools.cs` (profession recipes)
- `crafting_lootifier_*` (mirror)

### `QuestLootifierTools.cs` (quest rewards)
- `quest_lootifier_*` (mirror)

### `LootTunerTools.cs` (multipliers)
- `loot_tuner_meta`, `loot_tuner_preview`, `loot_tuner_apply`
- `loot_tuner_reset_to_baseline`, `loot_tuner_changelog`, `loot_tuner_stats`

### `ProfessionTuningTools.cs` (reagent counts)
- `profession_tuning_meta`, `profession_tuning_professions`
- `profession_tuning_profession_recipes`, `profession_tuning_apply`
- `profession_tuning_restore_recipe`, `profession_tuning_rollback_all`
- `profession_tuning_status`

**Files:** `Mcp/Tools/LootifierTools.cs`, `Mcp/Tools/CraftingLootifierTools.cs`, `Mcp/Tools/QuestLootifierTools.cs`, `Mcp/Tools/LootTunerTools.cs`, `Mcp/Tools/ProfessionTuningTools.cs`

## 4.7 WorldEditorTools  ▸ MCP-041 (deferred)

The 3D World Editor has 40 endpoints — most are SSE streams for live progress, others are very expensive (regenerate full server data). Not in MVP. Document the deferred list here, ship a minimal subset later:

- `worldeditor_presets`
- `worldeditor_heightmap`
- `worldeditor_doodads`
- `worldeditor_load_placements`
- `worldeditor_save_placement`
- `worldeditor_delete_placement`
- `worldeditor_commit_to_world` ← operator-only, audit
- `worldeditor_dungeon_info`
- `worldeditor_nearby_objects`

## 4.8 ActivityTools  ▸ MCP-042

Wraps `ActivityController.Entries/Summary/Detail`.

| Tool | Purpose |
|---|---|
| `activity_entries` | paginated filterable audit log entries |
| `activity_summary` | category counts, totals, failures, today |
| `activity_detail` | one audit entry detail-card |

**Files:** `Mcp/Tools/ActivityTools.cs`

---

# Phase 5 — Resources & prompts  ▸ low risk

Beyond tools, MCP supports **resources** (file-like content the agent can `@-mention`) and **prompts** (parameterised message templates the user can slash-invoke). Both are first-class in the C# SDK.

## 5.1 Resources  ▸ MCP-050

Each resource has a URI, a name, and a JSON/Markdown body.

### `ServerHealthResource.cs` — `mcp://msui/health`  ▸ MCP-051
Returns the dashboard "Status" view as JSON: live `.server info`, DB health, per-process status, recent alerts.

### `PlayerSnapshotResource.cs` — `mcp://msui/players/{guid}`  ▸ MCP-052
Full player snapshot (combines `PlayerTools.Detail` + `RaTools.connection_status` + last 10 `audit_target_history`).

### `BotFleetResource.cs` — `mcp://msui/bots/fleet`  ▸ MCP-053
Live fleet snapshot (calls `BotBrainService.GetLiveFleet` + `BotDiagnosticsService.RunFleetReportAsync`).

## 5.2 Prompts  ▸ MCP-054

### `InvestigatePlayerPrompt.cs` — `/investigate-player {name}`  ▸ MCP-055
Bundles: search → detail → ban history → online state → recent RA commands → suggests next actions.

### `RestartServerPrompt.cs` — `/restart-server`  ▸ MCP-056
Bundles: world preflight → save_all → shutdown → restart → verify online → health check.

### `TriageGriefingPrompt.cs` — `/triage-griefing {characterName}`  ▸ MCP-057
Bundles: detail → last 50 RA commands against them → chat log last hour → suggested kick/ban/mute.

### `ReviewChangesPrompt.cs` — `/review-changes {domain?}`  ▸ MCP-058
Bundles: divergence overview → change graph batches → revert candidates → suggest revert batch.

---

# Phase 6 — Polish  ▸ low risk

## 6.1 MCP Inspector smoke tests  ▸ MCP-060
Add `scripts/test-mcp.sh` / `.ps1` that:
1. Boots the stack.
2. Lists all tools.
3. Calls a representative sample (one per category) and asserts the response shape.
4. Verifies 401 on missing token, 401 on wrong token, 200 with valid token.

## 6.2 Curl-based integration tests in `tests/Mcp/`  ▸ MCP-061
A small xUnit project that spins up a `WebApplicationFactory<Program>` and exercises the MCP server in-process. Catches:
- tool enumeration matches the registered types
- capability enforcement (Phase 1)
- result envelope shape (Phase 1)
- error codes on common failure paths

## 6.3 Telemetry + structured logs  ▸ MCP-062
- Per-tool latency histogram (counter + duration)
- Per-capability call counter
- Per-error-code counter
- Exposed as `/mcp-debug/stats` (auth-gated) and via OpenTelemetry

## 6.4 OpenAPI-style tool docs page  ▸ MCP-063
Auto-generate `tools.json` (the canonical tool manifest) at build time. Embed in `wwwroot/mcp-tools.json` so the UI can render a "MCP Tool Reference" page. Source of truth for `docs/MCP.md`.

## 6.5 `mcp.json` examples for popular clients  ▸ MCP-064
Already shipped (`docs/examples/vscode-mcp.json`, `claude-desktop-mcp.json`). Add:
- `docs/examples/claude-code-cli.json`
- `docs/examples/cursor-mcp.json`
- `docs/examples/zed-mcp.json`
- `docs/examples/generic-http-client.py` (requests-based reference client)

## 6.6 README update  ▸ MCP-065
- Add a tool count badge ("~120 tools, 3 resources, 4 prompts")
- Add a "Capability matrix" table (`read` / `write_db` / `worlds` / `bots` / `patches` / `baseline` / `lootifier` / `retexture`)
- Add a "What can an LLM agent actually do?" section with 3-5 representative scenarios

---

# Cross-cutting concerns

## Capability matrix (final)

| Capability | Grants |
|---|---|
| `read` | All Phase-2 read-only tools + `audit_*`, `process_status`, `process_diagnostics` |
| `ra` | `ra_*` |
| `write_db` | All Phase-3 write tools |
| `worlds` | `worlds_*`, `baseline_*` |
| `bots` | `bot_*`, `rotation_*` |
| `patches` | `patch_*`, `spell_completer_*` |
| `lootifier` | `lootifier_*`, `crafting_lootifier_*`, `quest_lootifier_*`, `loot_tuner_*`, `profession_tuning_*` |
| `retexture` | `retexture_*` (deferred — separate phase after `VramManager` and `BodyAtlasTextureService` tools land) |
| `process` | `process_start_*` / `process_stop_*` / `process_restart_*` |

## Naming conventions

- Tool names are `snake_case`, max 64 chars
- No verbs in tool names — actions are the parameters
- All tools that touch the DB return `found: bool` (matches existing controller JSON)
- All tools that mutate return the row count affected + the new/updated row
- All RA commands route through `AuditService.ExecuteAndLogAsync` with `McpCallContext` set

## Backwards compat

Every new tool class is additive (`AddSingleton + WithTools<X>` in `Program.cs`). Removing a tool means bumping `Mcp.Version` and emitting a deprecated alias for one minor release. Old clients keep working.

## Submodule conflict management

The MSUI submodule is at `vendor/MangosSuperUI/`. Every MCP file lives under `vendor/MangosSuperUI/MangosSuperUI/Mcp/`. When the user runs `git submodule update --remote`, the upstream will overwrite these files.

**Mitigation (out-of-scope for this plan):**
- Option A: maintain a fork of MSUI
- Option B: keep MCP code in `vendor/` but in a separate, non-submodule `vendor/MSUI-Mcp/` overlay that gets `dotnet publish`'d alongside
- Option C: ship MCP as a sidecar project (`MangosSuperUI.Mcp`) that compiles to a separate DLL and gets loaded into MSUI via reflection or a plugin host

The user already chose **Option 0 (in-submodule)** for MVP; revisit when the next upstream release hits.

---

# Effort estimate (rough)

| Phase | Tool classes | New tools | Lines of C# (est.) | Calendar time |
|---|---|---|---|---|
| 1 — Foundations | — | 0 | ~600 | 3 days |
| 2 — Observability | 7 | ~45 | ~1800 | 4 days |
| 3 — Content mgmt | 6 | ~30 | ~1500 | 4 days |
| 4 — Powerful ops | 6 | ~20 + ~50 bot/lootifier | ~2500 | 6 days |
| 5 — Resources + prompts | 3 | 7 | ~500 | 2 days |
| 6 — Polish | — | 0 | ~400 | 2 days |
| **Total** | **22** | **~125 + 7** | **~7300** | **~21 days** |

---

# Open questions

- [ ] Do we want SSE streaming tools (e.g. world-editor regeneration progress)? The C# SDK supports SSE in stateful mode; in stateless mode we have to use a polling model. **Decision:** keep stateless; expose a `*_job` tool that returns a job id and a `*_job_status` tool that polls.
- [ ] Should we expose the `mcp-resources` and `mcp-prompts` capabilities to anonymous (token-only) callers, or require the same bearer token? **Decision:** same token; capabilities gate tool calls only.
- [ ] Long-running tools (patch build, world regeneration) — block the request, or background + job id? **Decision:** background + job id (matches `WorldStateService.SuspendAsync` pattern).
- [ ] Do we want per-tool rate limits? **Defer** to Phase 6 telemetry; one global rate-limit at the middleware is enough for MVP.

---

# How to use this document

1. Pick a phase.
2. Pick a leaf task (`MCP-XXX`).
3. Open it as a `todowrite` item.
4. Ship it: write the tool class, register it in `Program.cs`, build, test.
5. Update the tool count + capability matrix in `docs/MCP.md` and `README.md`.
6. Repeat until the phase is done. Then move to the next phase.
