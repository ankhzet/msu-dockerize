# Task: make AiBotAI bots accept BG invites

**Status:** open
**Discovered:** 2026-08-15
**Severity:** functional gap — Alliance bots in Azure's group cannot enter Warsong Gulch (or any BG) automatically

## Symptom

`/AIBOT-PARTY/ Alarsong: boss on map 489 (we are on 0) — instance-follow TeleportTo (1517.6, 1485.4, 352.0)` — bots try to follow Azure into WSG but end up on the **base** WSG map, not the BG instance. No further progress.

`mangosd` log shows Azure on `map=489` (in BG) but no `Battleground: invited … to BG instance` lines for any of the 9 Alliance bots, because they're `AiBotAI` bots and never see the BG invitation flow.

## Root cause

`AiBotAI::UpdateAI` in `src/game/SuperUiBots/AiBotAIMain.cpp` does not call `CombatBotBaseAI::SendBattlefieldPortPacket()`. Only `BattleBotAI::UpdateBattleBot` and `PartyBotAI::UpdateAI` do.

`SendBattlefieldPortPacket()` (in `src/game/PlayerBots/CombatBotBaseAI.cpp`) iterates `BATTLEGROUND_QUEUE_AV..BATTLEGROUND_QUEUE_AB` and for each queue type where `me->IsInvitedForBattleGroundQueueType(...)` is true, calls `WorldSession::HandleBattleFieldPortOpcode` to accept the BG port. This is the only path that turns an in-memory invite into an instance teleport.

`HandleBattleFieldPortOpcode` is per-session. There is no group-leader-accepts-for-all shortcut — every group member needs their own CMSG_BATTLEFIELD_PORT. The Azure-as-leader accept doesn't auto-port the bots.

## Fix

### Source change

In `src/game/SuperUiBots/AiBotAIMain.cpp`:

1. Add the include (AiBotAIBridge.cpp already includes `BattleGround.h`, but `AiBotAIMain.cpp` does not):
   ```cpp
   #include "BattleGround.h"
   ```
2. Inside `void AiBotAI::UpdateAI(uint32 const diff)`, after the existing `UpdateBridgeTick();` call (around line 1013), add:
   ```cpp
   // [BG-ACCEPT] Accept any pending BG invite (one-shot per update tick).
   // Mirrors the BattleBotAI / PartyBotAI pattern; AiBotAI is the only
   // bot AI that omits this, leaving permanent bots stranded on the
   // base WSG / AB / AV map while their group leader enters the BG.
   if (!me->InBattleGround() && !me->InBattleGroundQueue())
   {
       for (uint32 i = BATTLEGROUND_QUEUE_AV; i <= BATTLEGROUND_QUEUE_AB; i++)
       {
           if (me->IsInvitedForBattleGroundQueueType(static_cast<BattleGroundQueueTypeId>(i)))
           {
               SendBattlefieldPortPacket();
               break;
           }
       }
   }
   ```

`SendBattlefieldPortPacket` is already inherited from `CombatBotBaseAI` — no new declarations needed.

### Build

```bash
cd /e/MangosSuperUI/.tmp-msui/.tmp-core-build       # shallow clone of Yafrovon/SuperUI-Core
# Follow the build instructions in docs/BUILD.md
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DACE_INCLUDE_DIR=... -DTBB_INSTALL_DIR=...
cmake --build build --target mangosd -j$(nproc)
```

Replace the bundled `mangosd` in `/opt/superui-core/bin/` and restart `mangos-world-server`.

### Verification

1. Azure queues for WSG via the Battlemaster NPC in Stormwind
2. `mangosd.log` should show 10 `Battleground: invited <botname> to BG instance` lines (Azure + 9 bots)
3. Each bot should run `BattlegroundHandler: ... enters` for `map=489, instance=N`
4. Bots appear in the WSG scoreboard

## Workarounds while the rebuild is pending

The temp battlebots spawned via `.battlebot add warsong horde 60` / `alliance 60` work because `BattleBotAI` has BG handling. For Alliance-vs-Horde WSG without the rebuild:

```bash
./scripts/queue-10-horde-wsg.sh
# Then in the UI: send another .battlebot add warsong alliance 60 from the RA console
# until both sides have 10 (the script only queues Horde)
```

This fills the WSG with random-name BattleBotAI bots. They get BG honor (confirmed: `124+ [BATTLEGROUND] ... honor` events after a few minutes). Not the named Alliance bots in Azure's group, but WSG runs end-to-end.

## Why this isn't already fixed in the upstream fork

`AiBotAI` is the youngest of the four bot AI classes in the fork (the other three are `PlayerBotAI`, `PartyBotAI`, `BattleBotAI`). The bridge (`AiBotAIBridge.cpp`) is the new control surface — it's what made the UI's Bot Monitor work — and BG handling fell out of scope. Likely candidate for a PR upstream once the fix is verified against WSG / AB / AV / Arena.

## Related

- The `.character level` command sets the bot's level but only updates `characters.level` — the bot is still spawned at level 1 by `SpawnNewPlayer` and re-levelled on the first tick by `m_initialized` block. Re-spawning the bot via `.bot reload` after `UPDATE playerbot SET level=60` is a no-op because the bot character already exists at level 1 in `characters.characters`.
- `Battleground.PremadeQueue.MinGroupSize = 6` in `mangosd.conf` — group queue triggers at 6 players.
- Migration `20260815012935_world.sql` (just added) fixes `map_template.map_type = 3` for BGs, which is the **other** half of getting WSG instances to create without crashing the server.
