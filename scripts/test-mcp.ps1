# MSUI MCP smoke test (PowerShell) — exercises the endpoint with a
# representative sample of tools. Use after `docker compose up -d`
# to verify wiring.
#
# Usage:
#   $env:MCP_TOKEN = "tk_xxx"
#   .\scripts\test-mcp.ps1
#   $env:MCP_URL  = "http://localhost:5000/mcp"   # optional override
#
# Exit code: 0 = all assertions passed, 1 = at least one failed.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$McpUrl  = if ($env:MCP_URL)  { $env:MCP_URL }  else { 'http://localhost:5000/mcp' }
$McpToken = $env:MCP_TOKEN

$script:Pass = 0
$script:Fail = 0

function Invoke-McpCall {
    param([string]$Method, [string]$ArgumentsJson)
    $payload = if ($ArgumentsJson) {
        @{ jsonrpc = '2.0'; id = 1; method = $Method; params = ($ArgumentsJson | ConvertFrom-Json) }
    } else {
        @{ jsonrpc = '2.0'; id = 1; method = $Method }
    }
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $headers = @{ 'Content-Type' = 'application/json'; 'Accept' = 'application/json, text/event-stream' }
    if ($McpToken) { $headers['Authorization'] = "Bearer $McpToken" }
    try {
        Invoke-RestMethod -Uri $McpUrl -Method Post -Headers $headers -Body $json -TimeoutSec 30
    } catch {
        Write-Host "    request failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Assert-Ok {
    param([string]$Label, $Response)
    if ($null -eq $Response) { $script:Fail++; Write-Host "  X $Label (no response)"; return }
    $str = ($Response | ConvertTo-Json -Depth 20 -Compress)
    if ($str -match '"ok":\s*true|"result"') {
        $script:Pass++
        Write-Host "  OK $Label"
    } else {
        $script:Fail++
        Write-Host "  X $Label"
        Write-Host "    response: $($str.Substring(0, [Math]::Min(240, $str.Length)))"
    }
}

Write-Host "== MCP endpoint reachability =="
$toolsList = Invoke-McpCall 'tools/list'
if ($null -ne $toolsList -and ($toolsList | Out-String) -match 'ra_send_command') {
    $script:Pass++
    Write-Host "  OK tools/list returns expected tools"
} else {
    $script:Pass-- # don't double-count; we're about to fail
    Write-Host "  X tools/list did not return expected tools (is the server up? is auth disabled?)" -ForegroundColor Red
    exit 1
}

if (-not $McpToken) {
    Write-Host ""
    Write-Host "  (skipping auth checks — no MCP_TOKEN set)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "== RESULTS =="
    Write-Host "  passed: $script:Pass"
    Write-Host "  failed: $script:Fail"
    if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
}

Write-Host ""
Write-Host "== Read-only tools =="
Assert-Ok 'home_status returns ok:true' (Invoke-McpCall 'tools/call' '{"name":"home_status"}')

Write-Host ""
Write-Host "== Capability enforcement =="
$resp = Invoke-McpCall 'tools/call' '{"name":"ra_send_command","arguments":{"command":".server info"}}'
$respStr = if ($resp) { ($resp | ConvertTo-Json -Depth 20 -Compress) } else { '' }
if ($respStr -match '403|insufficient_scope|invalid_token') {
    $script:Pass++
    Write-Host "  OK ra_send_command rejected (token has no 'ra' cap)"
} elseif ($respStr -match '"ok":\s*true') {
    Write-Host "  ~ ra_send_command accepted (token is a superuser)" -ForegroundColor Yellow
} else {
    $script:Fail++
    Write-Host "  X ra_send_command: unexpected response"
    Write-Host "    response: $($respStr.Substring(0, [Math]::Min(240, $respStr.Length)))"
}

Assert-Ok 'ra_list_online returns ok' (Invoke-McpCall 'tools/call' '{"name":"ra_list_online"}')

Write-Host ""
Write-Host "== RESULTS =="
Write-Host "  passed: $script:Pass"
Write-Host "  failed: $script:Fail"
if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
