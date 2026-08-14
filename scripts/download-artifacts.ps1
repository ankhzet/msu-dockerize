<#
.SYNOPSIS
    Pre-downloads MangosSuperUI and SuperUI-Core release artifacts into ./vendor
    for offline Docker builds.

.DESCRIPTION
    Runs on the host BEFORE `docker compose build`. Avoids any network calls
    during the image build, which keeps the build deterministic and saves
    bandwidth on metered connections.

    After this script completes the artifacts are ready for `docker compose build`.

.PARAMETER Force
    Redownload even if a local cached file already exists.

.PARAMETER SkipWorldDb
    Do not download any world DB archives. They are large (~200MB - 1GB)
    and only needed if you set WORLD_DB_MODE=standard or full.

.EXAMPLE
    .\scripts\download-artifacts.ps1
    .\scripts\download-artifacts.ps1 -Force
    .\scripts\download-artifacts.ps1 -SkipWorldDb
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipWorldDb
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..')

$vendor = Join-Path (Get-Location) 'vendor'
if (-not (Test-Path -LiteralPath $vendor)) {
    New-Item -ItemType Directory -Path $vendor -Force | Out-Null
}

# Load .env (if present) for version pins
$envFile = Join-Path (Get-Location) '.env'
if (Test-Path -LiteralPath $envFile) {
    Get-Content -LiteralPath $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

$MANGOS_SUPER_UI_VERSION = if ($env:MANGOS_SUPER_UI_VERSION) { $env:MANGOS_SUPER_UI_VERSION } else { 'v1.2' }
$SUPERUI_CORE_VERSION    = if ($env:SUPERUI_CORE_VERSION)    { $env:SUPERUI_CORE_VERSION } else { 'latest' }

# GitHub API endpoint for the latest matching release asset URL
function Get-LatestAssetUrl {
    param(
        [Parameter(Mandatory)] [string]$Repo,
        [Parameter(Mandatory)] [string]$AssetPattern,
        [string]$Tag
    )
    $api = if ($Tag -and $Tag -ne 'latest') {
        "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    } else {
        "https://api.github.com/repos/$Repo/releases/latest"
    }
    Write-Host "  Querying: $api"
    $headers = @{ 'User-Agent' = 'MangosSuperUI-Docker' }
    $release = Invoke-RestMethod -Uri $api -Headers $headers
    $asset = $release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    if (-not $asset) {
        # Pre-release: query by tag with /latest (works for pre-releases too)
        $apiPre = "https://api.github.com/repos/$Repo/releases?per_page=20"
        $list = Invoke-RestMethod -Uri $apiPre -Headers $headers
        foreach ($r in $list) {
            $a = $r.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
            if ($a) { $asset = $a; break }
        }
    }
    if (-not $asset) {
        throw "No asset matching '$AssetPattern' found in $Repo (tag=$Tag)"
    }
    return $asset.browser_download_url, $asset.name, $asset.size
}

function Save-Artifact {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$OutPath,
        [long]$ExpectedSize = 0
    )
    if ((Test-Path -LiteralPath $OutPath) -and -not $Force) {
        $existing = (Get-Item -LiteralPath $OutPath).Length
        if ($ExpectedSize -eq 0 -or $existing -eq $ExpectedSize) {
            Write-Host "  [cached] $(Split-Path -Leaf $OutPath) ($([math]::Round($existing/1MB,1)) MB)"
            return
        }
        Write-Host "  [stale] re-downloading (local size mismatch)"
    }
    Write-Host "  Downloading: $Url"
    $tmp = "$OutPath.part"
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    Move-Item -LiteralPath $tmp -Destination $OutPath -Force
    $size = (Get-Item -LiteralPath $OutPath).Length
    Write-Host "  [ok] $(Split-Path -Leaf $OutPath) ($([math]::Round($size/1MB,1)) MB)"
}

Write-Host "=== MangosSuperUI Docker pre-cache ==="
Write-Host "Vendor directory: $vendor"
Write-Host ""

# ---------- MangosSuperUI ----------
Write-Host "[1/4] MangosSuperUI $MANGOS_SUPER_UI_VERSION"
try {
    $uiUrl, $uiName, $uiSize = Get-LatestAssetUrl `
        -Repo 'Yafrovon/MangosSuperUI' `
        -AssetPattern 'MangosSuperUI-linux-x64.zip' `
        -Tag $MANGOS_SUPER_UI_VERSION
    Save-Artifact -Url $uiUrl -OutPath (Join-Path $vendor $uiName) -ExpectedSize $uiSize
} catch {
    Write-Warning "  Failed: $_"
    Write-Warning "  Falling back to direct URL pattern (requires known tag)"
    $fallback = "https://github.com/Yafrovon/MangosSuperUI/releases/download/$MANGOS_SUPER_UI_VERSION/MangosSuperUI-linux-x64.zip"
    Save-Artifact -Url $fallback -OutPath (Join-Path $vendor 'MangosSuperUI-linux-x64.zip')
}

# ---------- SuperUI-Core ----------
Write-Host ""
Write-Host "[2/4] SuperUI-Core $SUPERUI_CORE_VERSION"
try {
    $coreUrl, $coreName, $coreSize = Get-LatestAssetUrl `
        -Repo 'Yafrovon/SuperUI-Core' `
        -AssetPattern '*.tar.gz' `
        -Tag $SUPERUI_CORE_VERSION
    Save-Artifact -Url $coreUrl -OutPath (Join-Path $vendor $coreName) -ExpectedSize $coreSize
} catch {
    Write-Warning "  Failed: $_"
    Write-Warning "  SuperUI-Core prebuilt resolves by tag. Check the latest release:"
    Write-Warning "    https://github.com/Yafrovon/SuperUI-Core/releases"
}

# ---------- SuperUI-Core SQL files ----------
# The init-database.sh needs the realmd/characters/logs SQL schema files.
# These are small (~1MB total) and shipped from the source repository.
# We only download the SQL subset to keep bandwidth low.
Write-Host ""
Write-Host "[3/4] SuperUI-Core SQL schema files (small)"
$sqlTag = if ($SUPERUI_CORE_VERSION -eq 'latest') { 'development' } else { $SUPERUI_CORE_VERSION }
$sqlIndex = "https://api.github.com/repos/Yafrovon/SuperUI-Core/contents/sql/base?ref=$sqlTag"
$sqlDir = Join-Path $vendor 'sql\base'
if (-not (Test-Path -LiteralPath $sqlDir)) {
    New-Item -ItemType Directory -Path $sqlDir -Force | Out-Null
}
try {
    $headers = @{ 'User-Agent' = 'MangosSuperUI-Docker' }
    $files = Invoke-RestMethod -Uri $sqlIndex -Headers $headers
    $wanted = @('logon.sql', 'realmd.sql', 'characters.sql', 'logs.sql', 'mangos.sql')
    foreach ($f in $files) {
        if ($wanted -contains $f.name) {
            $out = Join-Path $sqlDir $f.name
            Save-Artifact -Url $f.download_url -OutPath $out
        }
    }
} catch {
    Write-Warning "  Could not fetch SQL files via API: $_"
    Write-Warning "  The init-database.sh --bare / --standard / --full commands will fail"
    Write-Warning "  until you place realmd.sql/characters.sql/logs.sql in ./vendor/sql/base/"
}

# ---------- World DB (optional) ----------
if (-not $SkipWorldDb) {
    Write-Host ""
    Write-Host "[4/4] World DB archives (skipped by default)"
    Write-Host "  These are big (~200MB - 1GB each). To download on demand use:"
    Write-Host "    ./scripts/init-database.sh --standard"
    Write-Host "  Or place a pre-existing .7z file in ./vendor/ and reference it via"
    Write-Host "    WORLD_DB_MODE=/absolute/path/to/world.7z in .env"
}

Write-Host ""
Write-Host "=== Done. Run 'docker compose build' to assemble the images. ==="
Write-Host "Note: world DB archives are NOT downloaded by this script to save bandwidth."
