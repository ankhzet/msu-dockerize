#!/usr/bin/env bash
# =============================================================================
# MSUI MCP catalogue audit — enumerates every tool and asserts the expected
# count per class. Use after `docker compose up -d` to verify the wiring
# matches the documented surface.
#
# Usage:
#   MCP_TOKEN=tk_xxx ./scripts/audit-mcp.sh
#   MCP_URL=http://localhost:5000/mcp ./scripts/audit-mcp.sh
#
# Exit code: 0 = every class at expected count, 1 = any mismatch.
# =============================================================================
set -euo pipefail

MCP_URL="${MCP_URL:-http://localhost:5000/mcp}"
TOKEN_HEADER=""
[ -n "${MCP_TOKEN:-}" ] && TOKEN_HEADER="Authorization: Bearer ${MCP_TOKEN}"

# Expected counts per prefix. Add a row for every new class you ship.
# These come straight from vendor/MangosSuperUI/MangosSuperUI/Mcp/Tools/*.cs
# — verify with:
#   grep -rh 'McpServerTool(Name' vendor/MangosSuperUI/MangosSuperUI/Mcp/Tools/*.cs \
#     | grep -oE 'Name = "[^"]+"' | sort -u | awk '{print $3}'
#
# Notes:
#   - `dbc_item_*` / `dbc_spell_*` belong to DbcTools, NOT ItemTools/SpellWriteTools.
#     Counts for item_/spell_ exclude the dbc_* overlap.
#   - `account_lookup` lives in PlayerTools but its name starts with `account_`.
#     It counts toward `account_`, not `player_`.
#   - `quest_search` lives in QuestTools.
#   - `quest_lootifier_status` lives in LootifierTools.
declare -A EXPECTED=(
    [ra_]=10
    [player_]=11                  # 3 PlayerTools read + 8 PlayerWriteTools
    [account_]=6                  # 5 AccountWriteTools + 1 (account_lookup in PlayerTools)
    [audit_]=2
    [process_]=8
    [home_]=3
    [dbc_]=11
    [log_]=9
    [item_]=8                     # 5 ItemTools + 3 ItemWriteTools (excludes dbc_item_*)
    [gameobject_]=9               # 6 GameObjectTools + 3 GameObjectWriteTools
    [world_]=4                    # WorldTools (creature + loot + instance) — not WorldMapTools
    [quest_]=3                    # QuestTools only (excludes quest_lootifier_*)
    [worldmap_]=5
    [wiki_]=6
    [source_]=14
    [instance_]=4
    [config_]=3                   # mangosd.conf read/save/reload (settings_* in ConfigTools)
    [settings_]=5                 # server-config.json current/override/save/reset + comfy pool
    [spell_]=4                    # SpellWriteTools (search/detail + save/save_batch)
    [patch_]=14                   # 8 read (PatchTools) + 6 write (SpellWriteTools)
    [worlds_]=14
    [baseline_]=13
    [divergence_]=3
    [changegraph_]=6
    [activity_]=3
    [bot_]=27                     # 8 reads + 19 commands
    [rotation_]=5
    [lootifier_]=3
    [crafting_]=1
    [quest_lootifier_]=1
)

# ---- fetch tools/list ----
RESP=$(curl -sS -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${TOKEN_HEADER:+-H "$TOKEN_HEADER"} \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')

if [ -z "$RESP" ] || ! echo "$RESP" | grep -q '"name"'; then
    echo "tools/list failed — is the server up? auth configured?"
    echo "$RESP" | head -c 400
    exit 1
fi

# Total count
TOTAL=$(echo "$RESP" | grep -oE '"name":"[a-z_]+_[a-z_]+"' | wc -l | tr -d ' ')
echo "Total tools advertised: $TOTAL"
echo ""

PASS=0
FAIL=0
for prefix in "${!EXPECTED[@]}"; do
    want="${EXPECTED[$prefix]}"
    # Strip the trailing underscore from the key for the regex.
    base="${prefix%_}"
    case "$base" in
        # Exclusions: certain base names are prefixes of longer ones that
        # belong to a different class.
        item)    pat="\"name\":\"item_[a-z_]+\""; exclude='dbc_item' ;;
        spell)   pat="\"name\":\"spell_[a-z_]+\""; exclude='dbc_spell' ;;
        quest)   pat="\"name\":\"quest_[a-z_]+\""; exclude='quest_lootifier' ;;
        *)       pat="\"name\":\"${prefix}[a-z_]+\""; exclude='' ;;
    esac
    if [ -n "$exclude" ]; then
        got=$(echo "$RESP" | grep -oE "$pat" | grep -v "$exclude" | wc -l | tr -d ' ')
    else
        got=$(echo "$RESP" | grep -oE "$pat" | wc -l | tr -d ' ')
    fi
    if [ "$got" = "$want" ]; then
        printf "  \u2713 %-22s %3d tools\n" "$prefix" "$got"
        PASS=$((PASS+1))
    else
        printf "  \u2717 %-22s want=%d got=%d\n" "$prefix" "$want" "$got"
        FAIL=$((FAIL+1))
    fi
done | sort

echo ""
EXPECTED_TOTAL=$(printf '%s\n' "${EXPECTED[@]}" | awk '{s+=$1} END {print s}')
echo "Expected total: $EXPECTED_TOTAL  audited total: $TOTAL"
echo ""
echo "Results: $PASS classes matched, $FAIL mismatched"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
