# TODO-FEAT-PENANCE — Discipline Priest "Penance" Talent

**Status:** planning only. No code or DB changes yet.
**Owner:** TBD
**Target branch:** `feature/penance` (new)
**Last updated:** 2026-08-16

---

## 1. What is Penance?

Penance is the **signature Discipline Priest talent** introduced in *World of Warcraft: Wrath of the Lich King* (3.0 / Naxxramas pre-patch). It is a **dual-purpose channeled spell** that fires three Holy-light bolts in two seconds, healing an ally or damaging an enemy. It is the defining ability of the Disc spec — most Disc rotations revolve around it.

**Critical project context:**

- This project runs **VMaNGOS / SuperUI-Core 1.12.1 (Vanilla)** — there is no Penance in the client or in the C++ spell system.
- Vanilla Priests get only Holy/Shadow/Discipline trees' *vanilla* spells. The Penance row of the Disc tree is empty in 1.12.1.
- WotLK reference data (the `mangos`/`characters` DBC dumps from a 3.3.5 client) is **not** bundled in this repo. We will use wowhead.com (via Wayback Machine) as the source-of-truth for the WotLK spell parameters, then verify the field mapping against existing vanilla spells (Mind Flay, Holy Nova) that already have channel or dual-mode behavior.
- `spell_template` overrides are scoped to **build 5875 (1.12.1)** in this project; inserting `build=5875` rows with WotLK spell IDs is fine — mangosd never queries IDs ≥ 40000 unless something references them.

## 2. Research findings (wowhead, via Wayback Machine)

Captured from `web.archive.org/web/2023*/wowhead.com/wotlk/spell=47540/penance`:

| Field | R1 (47540) | R2 (53005) | Notes |
|---|---|---|---|
| Class | Priest | Priest | — |
| School | **Holy (6)** | Holy | Damage is Holy, not Shadow |
| Talent | Discipline (5 ranks) | same | 51 pts talent row |
| Level req | 40 | 70 | Per WotLK talent table |
| Cost | 16% of base mana | 16% | `manaCostPercentage=16` |
| Range | 30 yd (Medium/Long) | 30 yd | `rangeIndex=4` or 6 |
| Cast time | **Channeled** (hidden) | Channeled | `castingTimeIndex`=hidden cast, `durationIndex` for channel |
| Channel duration | **2 sec** | 2 sec | `durationIndex` ≈ 27-29 family |
| Tick pattern | instant + every 1 sec for 2 sec | same | **3 ticks** |
| Cooldown | 12 sec | 12 sec | `recoveryTime=12000`, `categoryRecoveryTime=12000` |
| GCD | 1.5 sec | 1.5 sec | `startRecoveryCategory=133`, `startRecoveryTime=1500` |
| Damage (per tick, R1) | 240 Holy total / 3 ≈ 80 each | 292 total ≈ 97 each | effect1=2 (SCHOOL_DAMAGE) with Holy |
| Healing (per tick, R1) | 670–756 total / 3 ≈ 223-252 each | 805–909 total ≈ 268-303 each | effect2=10 (HEAL) with Holy coefficient |
| Spell coeff (damage) | ~0.857 per tick | higher | WotLK: 100% SP * 1.5s channel / 3 ticks |
| Spell coeff (heal) | ~0.8 per tick | higher | WotLK: 80% SP * 1.5s channel / 3 ticks |
| Effect type | **Dummy + Server-side script** | same | `effect1=3` (DUMMY), `effect2=0` for the heal version |
| Stance req | Cannot be cast while shapeshifted | same | `stances=0`, `stancesNot=1` (forms) |
| Cannot target self | yes (originally) | yes (originally) | verified via `TARGET_UNIT_TARGET_ENEMY` for damage version |
| Dispel | n/a | n/a | — |
| Mechanic | n/a | n/a | — |
| Visual | WotLK SpellVisual.dbc 5326 (rainbow bolts) | same | not in 1.12.1 DBC; client-side patch needed if you want visuals |

**Channel & tick semantics (the part that is NOT in `spell_template` rows):**

The three-tick channel is implemented as a **server-side spell script** in WotLK mangos:
1. Cast finishes (hidden cast time), begins 2 sec channel, applies `SPELL_AURA_PERIODIC_DUMMY` with `effectAmplitude=1000` (1 sec).
2. The aura handler fires immediately on apply → tick 1.
3. The aura fires again at +1 sec → tick 2.
4. The aura fires again at +2 sec → tick 3 (this is also when the channel ends naturally).
5. Each tick resolves to: **Smite-rank-equivalent damage** if the target is hostile; **Greater-Heal-rank-equivalent healing** if the target is friendly.

**Why vanilla spells can't just be cloned:** Mind Flay (15407) is *close* in shape — it channels with `SPELL_AURA_PERIODIC_DAMAGE` and `effectAmplitude=1000` for 3 ticks — but:
- Mind Flay's damage type is Shadow, school=5 (we need Holy school=6).
- Mind Flay's duration is 3 sec / 3 ticks = 1 tick per second — but Penance ticks at 0/1/2 seconds.
- Mind Flay applies the periodic aura directly via `effect1=6` (APPLY_AURA) + `effectApplyAuraName1=3` (PERIODIC_DAMAGE). Penance uses **dummy effect + script** because the **damage-or-heal decision depends on the target's reaction** at cast time.

**Holy Nova (15237)** is a useful reference for "dual target reaction" logic — it's cast on self and damages enemies / heals allies in an 10-yd radius — but it's an instant AOE, not a channel.

The `dummy + script` pattern is the **only** way to express "branch on target reaction" in 1.12.1 spell_template. This is also why we cannot just clone an existing row — the server behavior has to be C++.

## 3. Implementation strategy

Two layers, must both land before Penance works:

### Layer A — Database (WotLK data, vanilla build=5875)

We create the spell rows in the **custom spell range 40000-49999** (already the convention for `PatchController.Generate`). Since this is a vanilla 1.12.1 server, every WotLK ID needs a vanilla-safe mapping.

| New entry | WotLK source | Purpose |
|---|---|---|
| 40010 | 47540 (R1 dmg) | Penance R1 — channeled dummy effect |
| 40011 | 53005 (R2 dmg) | Penance R2 — channeled dummy effect (rank 70) |
| 40012 | 47788 (R1 heal) | Penance R1 heal (separate trigger from R1 dmg in 3.0.2+) |
| 40013 | 52986 (R2 heal) | Penance R2 heal |

Spells 40012/40013 are technically the *same* spell effect (channel → dummy → branch on target reaction) — WotLK just used two different IDs to gate trainer placement (the heal versions were learned at lower levels than the damage versions). We collapse to one entry per rank for simplicity: **`40010` = Penance R1 (damages enemies, heals allies), `40011` = Penance R2** — both use the same C++ handler.

### Layer B — C++ spell script (mandatory)

Add a new file `vendor/SuperUI-Core/src/scripts/spells/spell_penance.cpp` that registers an `EffectScriptTarget` / `OnAuraPeriodic` handler for entry 40010. The handler:

1. Reads `m_caster->GetClass()` — bail if not Priest.
2. Each tick: resolves the target via `m_caster->GetSingleEnemyTargetInRange(30)` if no friendly target was provided at cast time. (Cast-time target selection lives in `HandleCast`.)
3. If target is hostile: deal Smite-rank-equivalent Holy damage scaled by caster's spell power.
4. If target is friendly: heal Greater-Heal-rank-equivalent scaled by spell power + Divine Favor talent check + Grace stacking.
5. Generates threat only if damage tick (heals never generate threat — `attributesEx` includes `SPELL_ATTR_EX_NO_THREAT` for the heal path).
6. Pushes a one-shot `SMSG_SPELL_DAMAGE_LOG` / `SMSG_SPELL_HEAL_LOG` packet to the client so the floating combat text shows "Penance tick X" — vanilla clients don't have the rainbow bolt visual; the numeric damage/heal popup is enough.

Hook into `AI` script registration (`void AddSC_spell_penance()`) and add the call to `scripts/system/ScriptMgr.cpp::LoadDatabase()`.

**This requires a source build** (`docker compose --profile source-build run --rm superui-core-builder`) — prebuilt mangosd has no `SuperUiBots/` and no place to put a new spell script.

### Layer C — Trainer wiring + talent tab placement

Use the existing MCP patch tools to wire 40010/40011 into:
- `skill_line_ability` → `priest_holy` (skill_id=56) or `priest_shadow` (78). Both belong to the Discipline tab visually but Discs don't have a separate skill_id in 1.12.1 — Holy tab is closest.
- `spell_chain` → rank 1 = 40010, rank 2 = 40011 (prev_spell=0 for R1).
- `npc_trainer_template` (template id 8 for Priest class trainers — confirmed via `msui_patch_class_trainer_template_map`).

Cost: 10 silver (1000 copper) at level 40, 1 gold at level 70 — mirrors the Greater Heal / Smite cost curve.

### Layer D — Optional: client-side MPQ patch

The 1.12.1 client has no Penance spell icon, no SpellVisual for rainbow bolts, no cooldown model. If you cast 40010 on the vanilla client:
- The action bar will show a default icon (whatever `spellIconId` we set).
- No "channel" visual will play — just a normal cast bar with the channel progress.
- No floating combat text for ticks — the damage packet alone sends a number popup.

A full visual patch (SpellIcon.dbc, SpellVisual.dbc, SpellVisualKit.dbc edits) requires extracting a 3.3.5 client's DBC files and running them through the `PatchBuilderService` — this is **out of scope** for the v1 of this feature. Document as a follow-up TODO.

## 4. Step-by-step plan

### Phase 0 — Pre-flight (verify env, ~5 min)

- [ ] `msui_home_status` — confirm mangosd + realmd online, RA connected.
- [ ] `msui_process_status` — confirm source-built mangosd (md5 starts with `bc142ad2`). Prebuilt will not accept new spell scripts.
- [ ] `msui_baseline_status` — confirm og_item_template etc. exist (so we can diff Penance spell_template against the baseline if needed — though 40000+ is custom, no baseline needed).

### Phase 1 — DB rows via MCP (no server restart yet) (~10 min)

- [ ] Allocate the next free custom spell IDs. Should be ≥ 40010 to leave room.
  - `msui_item_next_custom_id` is wrong tool (items vs spells) — instead query via Dapper:
    ```sql
    SELECT MAX(entry) + 1 FROM spell_template WHERE entry BETWEEN 40000 AND 49999;
    ```
- [ ] `msui_spell_search` for `mind flay` → confirm Mind Flay exists at 15407 (vanilla reference for channel fields).
- [ ] `msui_spell_save` to insert 40010 with the field values from §2. Key fields:
  - `entry=40010`, `build=5875`
  - `school=6` (Holy)
  - `attributes=65536` (channel flag — see Mind Flay)
  - `attributesEx=16388` (no threat + others)
  - `castingTimeIndex` = 1 (instant — Penance has hidden cast; channel does the work)
  - `durationIndex` = 27 (2 sec channel; Mind Flay R1 uses 27)
  - `recoveryTime=12000`, `categoryRecoveryTime=12000`
  - `manaCostPercentage=16`
  - `rangeIndex=4` (30 yd)
  - `interruptFlags=15`, `channelInterruptFlags=31756`
  - `effect1=3` (DUMMY), `effectImplicitTargetA1=6` (TARGET_UNIT_TARGET_ENEMY)
  - `effectApplyAuraName1=23` (PERIODIC_TRIGGER_SPELL — used as a stub; the C++ handler does the real work)
  - `effectAmplitude1=1000`
  - `effectTriggerSpell1=40010` (self-trigger for the C++ handler to fire each tick)
  - `effectMiscValue1=6` (Holy school mask)
  - `dmgClass=1`, `preventionType=1`
  - `spellLevel=40`, `baseLevel=40`, `maxLevel=39`
  - `spellFamilyName=6` (Priest)
  - `spellFamilyFlags=0x10000000` (Penance flag in WotLK — leave 0 for vanilla; the C++ handler doesn't need it)
  - `description` uses `$o1` template var so the client computes the total damage: `"Launches a volley of holy light at the target, causing $o1 Holy damage to an enemy or healing to an ally over $d."`
  - `spellVisual1=0` (no vanilla visual — fallback to school-colored default)
  - `spellIconId=561` (WotLK Penance icon — won't render in 1.12.1 client, but DBC lookup will fall back gracefully)

- [ ] Same for 40011 (R2): bump `spellLevel=70`, `baseLevel=70`, `maxLevel=69`, slightly higher `effectBasePoints1` / longer description.

- [ ] `msui_spell_save_batch` for both if doing in bulk.

- [ ] Verify via `msui_spell_detail 40010` — fields should round-trip.

### Phase 2 — Trainer + tab wiring (~5 min)

- [ ] `msui_spell_chain` (manual SQL, no MCP tool) — insert rank chain:
  ```sql
  INSERT INTO spell_chain (spell_id, prev_spell, first_spell, rank, req_spell)
  VALUES (40010, 0, 40010, 1, 0),
         (40011, 40010, 40010, 2, 40010);
  ```
- [ ] `msui_patch_register_at_class_trainers` for `40010` with `trainerClass=5` (Priest), `cost=1000`, `reqLevel=40`.
- [ ] Same for `40011` with `cost=10000`, `reqLevel=70`.
- [ ] `msui_patch_skill_tab_map` — confirm `priest_holy` is the right tab. skill_id=56, class_mask=16, spellFamilyName=6.
- [ ] Insert `skill_line_ability` row for 40010/40011 with skill_id=56, class_mask=16, learn_on_get_skill=0 (trainer-only).

### Phase 3 — C++ spell script (~30 min code + ~10 min build)

- [ ] New file: `vendor/SuperUI-Core/src/scripts/spells/spell_penance.cpp`
  - Stub `struct spell_penance : public SpellScript` with three methods:
    - `bool OnEffectExecute(Spell* spell, SpellEffectIndex effIdx)` — called on cast completion
    - `void OnAuraTick(Aura* aura, uint32 tickNumber)` — called each of the 3 ticks (driven by `effectAmplitude=1000`)
    - `void OnChannelFinish(Spell* spell)` — called when channel ends (clean up, refund partial tick if cancelled)
  - Per tick:
    - If target is `CanAttack(m_caster)`: `SpellDamageFn(SPELL_EFFECT_SCHOOL_DAMAGE, school=6, base=m_caster->SpellDamageBonusDone(...))`
    - Else: `SpellHealFn(SPELL_EFFECT_HEAL, base=m_caster->SpellHealBonusDone(...))`
    - Push `SMSG_SPELL_DAMAGE_LOG` or `SMSG_SPELL_HEAL_LOG` with `SpellID=40010/40011`.
  - Register spell in `void AddSC_spell_penance()` via `RegisterSpellScript(40010)` / `RegisterSpellScript(40011)`.
  - Hook `AddSC_spell_penance()` into `src/scripts/system/ScriptMgr.cpp::LoadDatabase()`.
- [ ] Add the file to `src/scripts/CMakeLists.txt` if not auto-picked-up.
- [ ] `docker compose --profile source-build run --rm superui-core-builder` — full rebuild (~2-5 min with ccache warm).
- [ ] `docker compose build mangosd && docker compose up -d mangosd`.
- [ ] Verify no segfault on startup (`docker logs mangos-world-server --tail 50`).

### Phase 4 — Smoke test in-game (~15 min)

- [ ] Log in as the Azure priest (`Azure` is a Priest, per HANDOVER.md).
- [ ] `.character level Azure 60` if not already 60 — Penance trains at 40, so 60+ works.
- [ ] Reload server so trainer caches refresh (custom spell registration happens on DB load).
- [ ] `.character learn 40010 Azure` (or right-click Priest trainer, learn Penance if cost check passes).
- [ ] Bind Penance to action bar.
- [ ] Cast on Azure (or a party member) — verify:
  - Channel starts immediately, 2 sec duration
  - 3 floating combat text popups appear (one per tick)
  - Health goes up by ~225-250 * 3 ≈ 675-750 total
- [ ] Cast on a hostile target — verify:
  - Same channel
  - 3 floating "X Holy damage" popups
  - Damage ≈ 80 * 3 ≈ 240
- [ ] Confirm 12 sec cooldown between casts.
- [ ] Confirm 16% of base mana cost (Azure at L60 priest ≈ 250 mana base = 40 mana per cast).

### Phase 5 — Bot AI integration (optional, ~2 hrs)

- [ ] `msui_bot_brain_status` — confirm brain enabled.
- [ ] Edit `vendor/SuperUI-Core/src/game/SuperUiBots/AiBotAICombat.cpp` (or equivalent priest-specific file):
  - In the spell priority list for Discipline spec, insert Penance 40010 at priority slot 1 (above Smite, Greater Heal).
  - When target is friendly and below 70% HP: prefer Penance over Greater Heal (Penance finishes healing in 2 sec; GH takes 2.5 sec cast + land time).
  - When target is hostile and Penance off-cooldown: prefer Penance over Smite (better scaling).
- [ ] Rebuild via source builder, restart mangosd.
- [ ] Spawn a Disc priest bot: `.bot addai priest human TestDiscBot`.
- [ ] Set task to grind: `msui_bot_set_task_grind` at a grind spot.
- [ ] Verify bot casts Penance every 12 sec (log: `[AI-COMBAT] TestDiscBot: casting Penance`).

### Phase 6 — Commit + docs (~10 min)

- [ ] Commit DB migration: `vendor/sql/migrations/<timestamp>_penance_world.sql` with the spell_template + spell_chain + skill_line_ability + npc_trainer_template rows. **Don't** include the spell_template 40010/40011 rows in the migration — those are operator-created via the MCP patch tool, not source-of-truth schema.
- [ ] Commit C++ source: `vendor/SuperUI-Core/src/scripts/spells/spell_penance.cpp` + the `AddSC_spell_penance()` hook.
- [ ] Update `HANDOVER.md` next-milestone section: "Penance ships — Discipline priest talent added; bot AI uses it as top priority in Disc spec."
- [ ] Bump `TODO.MCP.md` Phase 7+ "lootifier" / "retexture" status to mark Penance visual patch as next-up.
- [ ] Git commit + push:
  ```bash
  git checkout -b feature/penance
  git add vendor/sql/migrations/*penance* vendor/SuperUI-Core/src/scripts/spells/spell_penance.cpp vendor/SuperUI-Core/src/scripts/system/ScriptMgr.cpp
  git commit -m "feat(spells): add Penance (Disc priest) — 40010/40011 + C++ channel handler"
  git push origin feature/penance
  ```

## 5. Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Prebuilt mangosd in `vendor/current/core` is not source-built | medium | C++ script never loads | Verify md5 starts with `bc142ad2` before Phase 3. If prebuilt, run source builder first. |
| `spellIconId=561` crashes the 1.12.1 client | low | Client disconnect on cast | Use `spellIconId=560` (Smite icon, which exists in 1.12.1 DBC) as a safe fallback. The visual is wrong but the spell works. |
| 12 sec cooldown doesn't enforce due to missing category | medium | Cast-spam breaks balance | Set both `recoveryTime=12000` AND `categoryRecoveryTime=12000` AND pick a `category` that doesn't collide with another Disc spell. Verify via `.server info` after cast. |
| Channel ticks at wrong rate | medium | Smite-feel is off | `effectAmplitude=1000` (1 sec) is verified against Mind Flay R1 which ticks 3 times over 3 sec — but Mind Flay applies aura on cast and ticks at 1Hz; Penance needs the C++ handler to fire the *first* tick at t=0 immediately, not at t=1sec. The WotLK impl uses `OnAuraApply` to trigger tick 1 manually. |
| `.character learn 40010` fails — trainer not refreshed | medium | Test blocked | Server restart is mandatory after custom spell registration. `docker compose restart mangosd`. |
| Heal path generates threat | low | Tanks lose aggro | `attributesEx` includes `SPELL_ATTR_EX_NO_THREAT` (bit 0x8000). Verify in `spell_template` after save. |
| Bot AI rotation crashes when Penance is off-cooldown but other Disc spells are mid-cast | medium | Bot stuck | Wrap the new logic in try/catch + feature-flag `CONFIG_BOOL_AI_BOT_USE_PENANCE` (default `true`) so it can be disabled without recompile. |
| Spell AOE arcing from client to server reveals the rainbow-bolt visual is missing | low | Player sees default channel bar | Document in §3 Layer D; full visual patch is a follow-up. |

## 6. Out of scope (explicit)

- **Client-side SpellIcon.dbc / SpellVisual.dbc patch.** Requires extracting DBCs from a 3.3.5 client and running them through `PatchBuilderService`. Document as Phase 7 follow-up; not blocking functional correctness.
- **Talent tree insertion (BIG GAP — see §8).** Penance as a *trainer spell* (not a talent rank) is functional but doesn't match WotLK's "5-rank talent row in the Disc tree" UX. The current v1 ships it as a direct trainer spell — players learn it from a Priest class trainer at level 40 (R1) / level 70 (R2). Adding it to the talent UI requires editing **Talent.dbc + TalentTab.dbc + repackaging as a client MPQ patch** — none of the existing PatchBuilderService methods handle these DBCs.
- **Grace, Borrowed Time, Rapture talent interactions.** WotLK Disc mechanics — vanilla equivalent doesn't exist. The heal path in Phase 3 doesn't stack Grace. Adding it would require a new aura system; punt to v2.
- **Penance cast on self.** WotLK added this in 3.1; we'll skip it for v1 to avoid a unit-test matrix explosion.

## 8. Known gaps after v1 ship (2026-08-16)

After the v1 commit (`891f00a`), user feedback flagged:

1. **Azure didn't have the spell** — `.patch teach_spell` was only called on the bot, not on the player. *Fixed at runtime*: taught 40010/40011/40015/40017 to Azure (guid=2) via `msui_patch_teach_spell`. For a permanent fix, add a `character_create_data` row or grant Penance to all level-40+ Priests on next login.
2. **Trainer didn't have the spell** — `npc_trainer_template` was only populated for entry=8 (Horde priest trainers). Alliance priest trainers (Priestess Anetta, Branstock Khalder, etc.) use `trainer_id=7`. *Fixed at runtime and migration*: added 40010/40011/40015/40017 to both template 7 and 8. Migration updated.
3. **No corresponding talent in the Disc tree** — this is the **untackled gap**. To ship this properly:
   - Add `TalentEntry` / `TalentTabEntry` DBC structures to `PatchBuilderService` (currently only Spell.dbc / SpellVisual.dbc / SpellVisualKit.dbc / SpellVisualEffectName.dbc).
   - Implement DBC write/read for `Talent.dbc` and `TalentTab.dbc`.
   - Insert a new Talent.dbc row with 5 ranks of Penance spell IDs. (WotLK has 5 ranks; vanilla Disc has 6 tiers — we'd insert at tier 5, column N to match WotLK layout.)
   - Reference the new talent's `TalentID` from the existing Discipline `TalentTab.dbc` entry (tab_page=3 — HolDisc 1, or one of the other tabs).
   - Pack into MPQ and ship as a client-side patch.
   - Verify the talent shows up in the Disc tree in-game when the player opens talents.
   - Estimated effort: **2-3 days** of dedicated work — significant scope. Document as a Phase 8 follow-up.

For now, players learn Penance from a Priest class trainer at level 40 / 70. This works but doesn't match WotLK's "5-rank talent row" feel. To improve UX without the full talent patch:
- The C++ side could add a `.learn_penance` GM command and grant it on respec/spec change.
- Bot AI can be told (via rotation profile) to take Penance as the highest-priority spell.

## 9. ROOT CAUSE of "spell isn't in trainer gossip" (found post-v1)

After teaching Azure the spells via `msui_patch_teach_spell`, the spells appeared in her spellbook BUT the trainer gossip menu still didn't list Penance. Found by:

```
grep "npc_trainer_template" /opt/superui-core/logs/mangosd-direct.log
→ Table `npc_trainer_template` for trainer (Entry: 7) has non-learning spell 40010, ignore
→ Table `npc_trainer_template` for trainer (Entry: 7) has non-learning spell 40011, ignore
... (8 lines for the 4 Penance IDs × 2 templates)
```

**Root cause:** vanilla `ObjectMgr::LoadTrainers()` (line 10366) **silently drops** any `npc_trainer_template` row whose spell has `Effect[0] != SPELL_EFFECT_LEARN_SPELL (36)`. My Penance had `Effect[0] = APPLY_AURA (6)` (the channel aura), so every trainer entry was rejected at load time.

**Fix:**

1. Create 4 **wrapper spells** (40018-40021) with `Effect[0] = 36 (LEARN_SPELL)` + `EffectTriggerSpell[0]` pointing at the real Penance spell.
   - `40018` → teaches `40010` (Penance R1 damage)
   - `40019` → teaches `40011` (Penance R2 damage)
   - `40020` → teaches `40015` (Penance R1 heal)
   - `40021` → teaches `40017` (Penance R2 heal)

2. `npc_trainer_template` now references the wrapper IDs (40018-40021) instead of the raw Penance IDs (40010-40017). Player clicks "Learn" → wrapper casts LEARN_SPELL → player learns the underlying Penance spell via its trigger.

3. Deleted the orphan raw-Penance trainer rows.

4. Fixed `spell_chain.req_spell` to 0 for rank-2 entries (was pointing to previous rank, triggering a `required rank spell from same chain` warning in `SpellMgr`).

**Same pattern as vanilla's Arcane Missiles:** wrapper spell 8420 (`Effect[0]=36`) teaches the channel spell 8418. The wrapper pattern is how vanilla trainers work — the actual spell is always wrapped in a LEARN_SPELL entry. I missed this when designing Penance.

Verified:
- `.spell info 40018` → `40018 - Penance, rank 1 enUS [learn]`
- `trainer_template` reloaded: 2762 trainer template spells (8 more than before — 4 wrappers × 2 templates).
- No more `non-learning spell` errors in the log for wrapper IDs.

## 10. Final state — Azure's spellbook

Azure (guid=2, level 60 Priest) now has all 4 real Penance spells in `character_spell`:
- `40010` (Penance R1 damage, school 6/Holy, icon 237/Smite)
- `40011` (Penance R2 damage, level 70 req)
- `40015` (Penance R1 heal, icon 242/Flash Heal)
- `40017` (Penance R2 heal, level 70 req)

When she logs in, her spellbook (priest_holy tab) shows Penance R1 (dmg) and R1 (heal). She can drag them to action bars and cast.

**Trainer gossip state for a level-60 Priest:**
- Penance R1 dmg wrapper (40018): **GRAY** — already known (Azure has 40010)
- Penance R2 dmg wrapper (40019): **RED** — level req 70, Azure is 60
- Penance R1 heal wrapper (40020): **GRAY** — already known (Azure has 40015)
- Penance R2 heal wrapper (40021): **RED** — level req 70

This is the correct vanilla behavior — `ObjectMgr::LoadTrainers` shows GRAY/RED spells in the gossip so the player knows they exist but can't be learned yet. The "not in gossip" complaint was because the wrappers were never in the gossip at all (silent load failure — fixed by switching to LEARN_SPELL wrappers).

To unlock R2, the player needs to ding 70 and have the appropriate level — then the wrappers turn GREEN and can be purchased from the trainer.

## 11. VMaNGOS proper-process notes (research 2026-08-16)

VMaNGOS docs (`github.com/vmangos/wiki`) do **not** document a custom-spell creation process. The project philosophy (Contribution Guide):
> "If it can be done in the database, do it there. When scripting something, it is preferable that you do it using the database scripting engine if possible. ScriptDev is for complex encounters that cannot be done any other way."

For custom spells:
- `spell_template` — DB-side overrides of client DBC data; loaded at startup with `MAX(build <= SUPPORTED_CLIENT_BUILD)`
- `skill_line_ability` — controls which spellbook tab the spell appears in
- `spell_chain` — rank chain (prev/first/rank/req_spell)
- `npc_trainer_template` — must reference a wrapper with `Effect[0] = SPELL_EFFECT_LEARN_SPELL (36)`, NOT the actual spell
- For visual client-side: client `Spell.dbc` must be patched (out of scope for this project — see §6 of this doc)

The wrapper+LEARN_SPELL pattern is the universal vanilla convention — confirmed via Arcane Missiles (5143 channel ↔ 8420 trainer wrapper ↔ 8418 trigger). My v1 missed this; v2 fixed it.

## 7. References

- wowhead WotLK Penance R1: https://web.archive.org/web/20231003070923/https://www.wowhead.com/wotlk/spell=47540/penance
- wowhead WotLK Penance R2 (L70): https://web.archive.org/web/20221127223324/https://www.wowhead.com/wotlk/spell=53005/penance
- Vanilla reference spell — Mind Flay (15407): `msui_spell_detail 15407` — channeled periodic-damage, school=5 Shadow, durationIndex=27, amplitude=1000.
- Vanilla reference spell — Holy Nova (15237): instant dual-target-reaction AOE.
- cmangos/mangos-wotlk DBC Spell.sql: https://github.com/cmangos/mangos-wotlk/blob/master/sql/base/dbc/original_data/Spell.sql
- SuperUI-Core spell script examples: `vendor/SuperUI-Core/src/scripts/spells/spell_priest.cpp` (Mind Flay handler at line 7872 of `SpellAuras.cpp`)
- Patch generation pipeline: `vendor/MangosSuperUI/MangosSuperUI/Controllers/PatchController.cs` and `Services/SpellServices/SpellCreatorService.cs`
- Bot AI spell priority: `vendor/SuperUI-Core/src/game/SuperUiBots/AiBotAICombat.cpp`