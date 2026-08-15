# MSUI MCP catalogue audit (PowerShell) — calls tools/list and asserts
# per-class tool counts. Use after `docker compose up -d` to verify the
# wiring matches the documented surface.
#
# Usage:
#   $env:MCP_TOKEN = "tk_xxx"
#   .\scripts\audit-mcp.ps1
#   $env:MCP_URL = "http://localhost:5000/mcp"   # optional override
#
# Exit code: 0 = every class at expected count, 1 = any mismatch.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$McpUrl  = if ($env:MCP_URL)  { $env:MCP_URL }  else { 'http://localhost:5000/mcp' }
$McpToken = $env:MCP_TOKEN

$script:Pass = 0
$script:Fail = 0

# ----- expected counts (mirror scripts/audit-mcp.sh) -----
$expected = [ordered]@{
    'ra_'              = 10
    'player_'          = 11   # 3 PlayerTools read + 8 PlayerWriteTools
    'account_'         = 6    # 5 AccountWriteTools + 1 (account_lookup in PlayerTools)
    'audit_'           = 2
    'process_'         = 8
    'home_'            = 3
    'dbc_'             = 11
    'log_'             = 9
    'item_'            = 8    # 5 ItemTools + 3 ItemWriteTools (excludes dbc_item_*)
    'gameobject_'      = 9    # 6 GameObjectTools + 3 GameObjectWriteTools
    'world_'           = 4    # WorldTools (excludes worldmap/worlds)
    'quest_'           = 3    # QuestTools only (excludes quest_lootifier_*)
    'worldmap_'        = 5
    'wiki_'            = 6
    'source_'          = 14
    'instance_'        = 4
    'config_'          = 3
    'settings_'        = 5
    'spell_'           = 4    # SpellWriteTools (search/detail + save/save_batch)
    'patch_'           = 14   # 8 read (PatchTools) + 6 write (SpellWriteTools)
    'worlds_'          = 14
    'baseline_'        = 13
    'divergence_'      = 3
    'changegraph_'     = 6
    'activity_'        = 3
    'bot_'             = 27   # 8 reads + 19 commands
    'rotation_'        = 5
    'lootifier_'       = 3
    'crafting_'        = 1
    'quest_lootifier_' = 1
}

# ---- fetch tools/list ----
$headers = @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json, text/event-stream' }
if ($McpToken) { $headers['Authorization'] = "Bearer $McpToken" }
$payload = @{ jsonrpc = '2.0'; id = 1; method = 'tools/list' } | ConvertTo-Json -Compress

try {
    $resp = Invoke-RestMethod -Uri $McpUrl -Method Post -Headers $headers -Body $payload -TimeoutSec 30
} catch {
    Write-Host "tools/list failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Pull the tool names out of the response.
$names = $resp.result.tools | ForEach-Object { $_.name }
$total = $names.Count
Write-Host "Total tools advertised: $total"

foreach ($kv in $expected.GetEnumerator()) {
    $prefix = $kv.Key
    $want = $kv.Value
    $base = $prefix.TrimEnd('_')
    $match = $names | Where-Object { $_ -like "${prefix}*" }
    # Exclusions: prevent `dbc_item_*` counting toward `item_`, etc.
    switch ($base) {
        'item'  { $match = $match | Where-Object { $_ -notlike 'dbc_item_*' } }
        'spell' { $match = $match | Where-Object { $_ -notlike 'dbc_spell_*' } }
        'quest' { $match = $match | Where-Object { $_ -notlike 'quest_lootifier_*' } }
    }
    $got = $match.Count
    if ($got -eq $want) {
        Write-Host ("  OK {0,-22} {1,3} tools" -f $prefix, $got)
        $script:Pass++
    } else {
        Write-Host ("  X  {0,-22} want={1} got={2}" -f $prefix, $want, $got) -ForegroundColor Red
        $script:Fail++
    }
}

Write-Host ""
$expectedTotal = ($expected.Values | Measure-Object -Sum).Sum
Write-Host "Expected total: $expectedTotal  audited total: $total"
Write-Host ""
Write-Host "Results: $($script:Pass) classes matched, $($script:Fail) mismatched"
if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
