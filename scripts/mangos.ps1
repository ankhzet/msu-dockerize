<#
.SYNOPSIS
    Common MangosSuperUI Docker workflow commands.

.DESCRIPTION
    Thin wrapper around `docker compose` with project-specific defaults. Saves
    typing and prevents forgotten flags.

.PARAMETER Action
    What to do:
        init        - copy .env.example to .env (first time only)
        cache       - run download-artifacts.ps1 (prepopulate vendor/)
        build       - build all images
        up          - start the core stack
        down        - stop the core stack
        restart     - restart the core stack
        status      - show container status
        logs        - tail logs (use -Service to filter)
        db-bare     - create empty DB schemas
        db-std      - download + load smallest world DB
        db-full     - download + load latest world DB
        db-from     - load a local .7z or .sql file
        db-status   - show DB state
        ai          - start with AI profile (Ollama + ComfyUI)
        shell NAME  - open a shell in a running container
        reset       - stop stack AND delete volumes (DESTRUCTIVE)

.EXAMPLE
    .\scripts\mangos.ps1 cache
    .\scripts\mangos.ps1 build
    .\scripts\mangos.ps1 up
    .\scripts\mangos.ps1 db-std
    .\scripts\mangos.ps1 logs -Service superui
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)] [string]$Action,
    [string]$Service,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..')
$Root = (Get-Location).Path

# Always include the env file
$envFile = Join-Path $Root '.env'
$envArgs = @()
if (Test-Path -LiteralPath $envFile) { $envArgs = @('--env-file', $envFile) }

function Compose-Object {
    return (& docker compose version) 2>$null
}

function Run-Compose {
    $args_ = @('compose') + $envArgs + $args
    & docker @args_
}

switch ($Action) {
    'init' {
        if (Test-Path -LiteralPath $envFile) {
            Write-Host ".env already exists. Not overwriting." -ForegroundColor Yellow
        } else {
            Copy-Item -LiteralPath '.env.example' -Destination $envFile
            Write-Host "Created .env. Edit it before continuing." -ForegroundColor Green
        }
    }
    'cache' {
        & (Join-Path $Root 'scripts\download-artifacts.ps1') @PSBoundParameters
    }
    'build' {
        Run-Compose 'build'
    }
    'up' {
        Run-Compose @('up', '-d')
    }
    'down' {
        Run-Compose @('down')
    }
    'restart' {
        Run-Compose @('restart')
    }
    'status' {
        Run-Compose @('ps', '-a')
    }
    'logs' {
        $args_ = @('logs', '-f', '--tail=200')
        if ($Service) { $args_ += $Service }
        Run-Compose @args_
    }
    'db-bare' {
        & bash (Join-Path $Root 'scripts/init-database.sh') '--bare'
    }
    'db-std' {
        & bash (Join-Path $Root 'scripts/init-database.sh') '--standard'
    }
    'db-full' {
        & bash (Join-Path $Root 'scripts/init-database.sh') '--full'
    }
    'db-from' {
        if (-not $Path) { throw "Use -Path C:\path\to\world.7z" }
        & bash (Join-Path $Root 'scripts/init-database.sh') '--from' $Path
    }
    'db-status' {
        & bash (Join-Path $Root 'scripts/init-database.sh') '--status'
    }
    'ai' {
        Run-Compose @('--profile', 'ai', 'up', '-d')
    }
    'shell' {
        if (-not $Service) { throw "Use -Service <container_name>, e.g. -Service superui" }
        & docker exec -it $Service /bin/bash
    }
    'reset' {
        Write-Host "This will DELETE all volumes (mariadb, server data, ui cache)." -ForegroundColor Red
        $confirm = Read-Host "Type 'yes' to confirm"
        if ($confirm -eq 'yes') {
            Run-Compose @('down', '-v')
            Write-Host "Volumes removed." -ForegroundColor Green
        } else {
            Write-Host "Cancelled." -ForegroundColor Yellow
        }
    }
    default {
        Write-Host "Unknown action: $Action" -ForegroundColor Red
        Write-Host "Run:  Get-Help .\scripts\mangos.ps1 -Full" -ForegroundColor Cyan
    }
}
