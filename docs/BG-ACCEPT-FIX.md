# Task: make AiBotAI bots accept BG invites

**Status:** closed (implemented + built + deployed 2026-08-15)
**Discovered:** 2026-08-15
**Severity:** functional gap — Alliance bots in Azure's group cannot enter Warsong Gulch (or any BG) automatically
**Fix commit:** `feature/bridge-gear-up` branch (SuperUI-Core submodule)
**Deployed binary:** md5 `78ac1d9013e8555d197d2594f2c7b042` (was `489c28bb...` prebuilt)

## Symptom

`/AIBOT-PARTY/ Alarsong: boss on map 489 (we are on 0) — instance-follow TeleportTo (1517.6, 1485.4, 352.0)` — bots try to follow Azure into WSG but end up on the **base** WSG map, not the BG instance. No further progress.

`mangosd` log shows Azure on `map=489` (in BG) but no `Battleground: invited … to BG instance` lines for any of the 9 Alliance bots, because they're `AiBotAI` bots and never see the BG invitation flow.

## Root cause

`AiBotAI::UpdateAI` in `src/game/SuperUiBots/AiBotAIMain.cpp` does not call `CombatBotBaseAI::SendBattlefieldPortPacket()`. Only `BattleBotAI::UpdateBattleBot` and `PartyBotAI::UpdateAI` do.

`SendBattlefieldPortPacket()` (in `src/game/PlayerBots/CombatBotBaseAI.cpp:3253`) iterates `BATTLEGROUND_QUEUE_AV..BATTLEGROUND_QUEUE_AB` and for each queue type where `me->IsInvitedForBattleGroundQueueType(...)` is true, calls `WorldSession::HandleBattleFieldPortOpcode` to accept the BG port. This is the only path that turns an in-memory invite into an instance teleport.

The packet-level detect is **already there**: `CombatBotBaseAI::OnPacketReceived(SMSG_BATTLEFIELD_STATUS)` at `CombatBotBaseAI.cpp:3391` already inspects the status packet and sets `m_receivedBgInvite = true` when the bot is invited but not yet in the BG. The flag is public (declared at `CombatBotBaseAI.h:560` inside the `public:` section that runs from line 76). `BattleBotAI` and `PartyBotAI` both consume this flag in their `UpdateAI` loops; `AiBotAI` was the lone holdout.

`HandleBattleFieldPortOpcode` is per-session. There is no group-leader-accepts-for-all shortcut — every group member needs their own CMSG_BATTLEFIELD_PORT. The Azure-as-leader accept doesn't auto-port the bots.

## Fix

Three files touched in `SuperUI-Core`:

### 1. `src/game/World.h` — config id

```cpp
enum eConfigBoolValues
{
    ...
    CONFIG_BOOL_TAG_IN_BATTLEGROUNDS,
    CONFIG_BOOL_AI_BOT_AUTO_ACCEPT_BG,   // <-- added
    ...
};
```

### 2. `src/game/World.cpp` — config registration

```cpp
addBoolIfNotExist(CONFIG_BOOL_AI_BOT_AUTO_ACCEPT_BG, "AiBot.AutoAcceptBG", true);
```

Default **on**. `addBoolIfNotExist` makes the config survive upgrades — operators who flip it to `0` keep that off across DB schema migrations.

### 3. `src/game/SuperUiBots/AiBotAIMain.cpp` — the handler

Inside `void AiBotAI::UpdateAI(uint32 const diff)`, between `RefreshDoctrine()` and `UpdateBridgeTick()`:

```cpp
// [BG-ACCEPT] Auto-accept a pending Battleground invitation. The packet-level
// accept (SMSG_BATTLEFIELD_STATUS) is already detected in
// CombatBotBaseAI::OnPacketReceived and sets m_receivedBgInvite = true. The
// helper CombatBotBaseAI::SendBattlefieldPortPacket() walks every queue
// type, finds the one this bot is invited to, and calls
// HandleBattleFieldPortOpcode with action=1 (port in). BattleBotAI and
// PartyBotAI both call this from their UpdateAI — AiBotAI was the lone
// holdout. Without this, the bot stays on the base WSG/AB/AV map while
// its group leader enters the BG instance. Config-gated so ops can turn
// it off for solo content.
if (sWorld.getConfig(CONFIG_BOOL_AI_BOT_AUTO_ACCEPT_BG) && m_receivedBgInvite)
{
    if (!me->InBattleGround() && !me->IsBeingTeleported())
    {
        sLog.Out(LOG_BASIC, LOG_LVL_MINIMAL,
            "[AIBOT-BG] %s: BG invite detected — accepting and porting in",
            me->GetName());
        SendBattlefieldPortPacket();
        m_receivedBgInvite = false;
    }
}
```

This is shorter than the originally suggested snippet because it piggybacks on the existing `m_receivedBgInvite` flag instead of re-iterating `BATTLEGROUND_QUEUE_AV..AB` — the `SendBattlefieldPortPacket()` helper already does that iteration internally. The flag is reset after port to avoid double-accept if the SMSG re-fires.

### Build

Used the existing `superui-core-builder` service:

```bash
cd /e/MangosSuperUI
docker compose --profile source-build run --rm superui-core-builder
docker compose build mangosd
docker compose up -d
```

First build is ~30-40 min cold (ccache fills up). ccache lives in the `ccache-core` named volume, so subsequent rebuilds only recompile changed files. The builder now uses the local source tree (committed or dirty — see commit `b4b94da` for the dirty-WIP detection), no upstream fetch unless the source dir is empty.

### Verification

```bash
# Check the binary picked up the new symbol
docker exec mangos-world-server sh -c \
  'grep -aoE "AIBOT-BG.*BG invite" /opt/superui-core/logs/mangosd.log | head -3'
#   [AIBOT-BG] TestGear: BG invite detected — accepting and porting in
#   [AIBOT-BG] TestGear: BG invite detected — accepting and porting in
#   [AIBOT-BG] TestGear: BG invite detected — accepting and porting in
```

The other half of the BG fix (the `map_template.map_type` assertion crash) is documented in the migration `20260815012935_world.sql` — set `map_type=3` for entries 30, 489, 529, 566, 607.

### Operator override

Set `AiBot.AutoAcceptBG = 0` in `mangosd.conf` to disable the feature fleet-wide. Per-bot overrides aren't exposed — fleet-wide is the right granularity because BG accept is a safety/UX policy, not a per-character setting.

## Why it fell out of scope originally

`AiBotAI` is the youngest of the four bot AI classes in the fork (the other three are `PlayerBotAI`, `PartyBotAI`, `BattleBotAI`). The bridge (`AiBotAIBridge.cpp`) is the new control surface — it's what made the UI's Bot Monitor work — and BG handling was deferred. With this commit the gap is closed.

## Related

- The `.character level` command sets the bot's level but only updates `characters.level` — the bot is still spawned at level 1 by `SpawnNewPlayer` and re-levelled on the first tick by `m_initialized` block. Re-spawning the bot via `.bot reload` after `UPDATE playerbot SET level=60` is a no-op because the bot character already exists at level 1 in `characters.characters`.
- `Battleground.PremadeQueue.MinGroupSize = 6` in `mangosd.conf` — group queue triggers at 6 players.
- Migration `20260815012935_world.sql` fixes `map_template.map_type = 3` for BGs, which is the **other** half of getting WSG instances to create without crashing the server.
- Companion bridge command: `GEAR_UP` (one-shot prep — level, spells, gear, riding, mount) wired through `BotBridgeService.SendGearUpAsync` and the `Gear up` card in the bot control suite. See commits on `feature/bridge-gear-up` for that change set.
