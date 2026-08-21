#Requires -Version 5.1
<#
.SYNOPSIS
    Move ~/.claude-shared into ~/.claude, once.

.DESCRIPTION
    Merges the legacy shared store into ~/.claude, retargets every account's
    junctions, and hands off to setup-claude-accounts.ps1 and install.ps1.

    Never deletes ~/.claude-shared. It is left on disk as a full standby copy;
    deleting it is yours to do once the report says it is safe.

    PRECONDITION: close all Claude Code sessions first. Nothing enforces this;
    Phase 2b detects a write that happened during the run and withholds the
    deletion guidance, but it cannot prevent one.

.EXAMPLE
    .\migrate-shared-store.ps1 -DryRun
    .\migrate-shared-store.ps1
#>
[CmdletBinding()]
param(
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$Legacy       = Join-Path $HOME '.claude-shared'
$Store        = Join-Path $HOME '.claude'
$ManifestPath = Join-Path $Store '.migrate-shared-store.state'
$SharedDirs   = @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins')

function Write-Step { param($Message) Write-Host "  $Message" }
function Write-Head { param($Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Skip { param($Message) Write-Host "  - $Message" -ForegroundColor DarkGray }
function Write-Done { param($Message) Write-Host "  + $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "  ! $Message" -ForegroundColor Yellow }

function Test-JunctionInto {
    # Is $Path a junction whose target sits under $Root?
    param([string] $Path, [string] $Root)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $target = @($item.Target) | Select-Object -First 1
    if (-not $target) { return $false }
    # Resolve-Path keeps a trailing separator and throws on a missing path, so
    # compare trimmed strings rather than resolving.
    return $target.TrimEnd('\', '/').StartsWith($Root.TrimEnd('\', '/'), 'OrdinalIgnoreCase')
}

function Read-MigrationManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $ManifestPath | Where-Object { $_.Trim() })
}

function Write-MigrationManifest {
    # Transient, and deleted on success. This is NOT the account registry the
    # architecture rejects: it lives for one run, is authoritative for nothing,
    # and its presence afterwards means a run did not finish. An account that
    # shares only projects/ has exactly one on-disk signal, and Phase 2 erases
    # it between rmdir and mklink - this is what survives that window.
    param([string[]] $Accounts)
    if ($DryRun) { return }
    [IO.File]::WriteAllText($ManifestPath, ($Accounts -join "`r`n"),
                            (New-Object Text.UTF8Encoding $false))
}

function Get-MigrationAccount {
    # Deliberately WIDER than Get-ClaudeAccountDir: an account counts if it has
    # a projects/ entry OR any junction into the legacy store OR is named in a
    # manifest left by an interrupted run. The narrow rule would skip an account
    # whose projects/ junction was removed but not yet recreated.
    $fromManifest = Read-MigrationManifest
    Get-ChildItem -Path $HOME -Directory -Filter '.claude-*' -Force -ErrorAction SilentlyContinue |
        Where-Object {
            # Both $_ and $PSItem are rebound by the nested Where-Object, so
            # preserve the outer directory before enumerating $SharedDirs.
            $account = $PSItem
            $account.Name -ne '.claude-shared' -and (
                (Test-Path -LiteralPath (Join-Path $account.FullName 'projects')) -or
                (@($SharedDirs | Where-Object {
                    Test-JunctionInto -Path (Join-Path $account.FullName $PSItem) -Root $Legacy
                }).Count -gt 0) -or
                ($fromManifest -contains $account.FullName)
            )
        }
}

# ------------------------------------------------------------ phase 0 --------

Write-Host "Merge ~/.claude-shared into ~/.claude" -ForegroundColor White
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $Legacy)) {
    Write-Host "`nNothing to do: $Legacy does not exist." -ForegroundColor Green
    return
}
if (-not (Test-Path -LiteralPath $Store)) {
    throw "Refusing to run: $Store does not exist. Run setup-claude-accounts.ps1 first."
}

Write-Head "Accounts"
$accounts = @(Get-MigrationAccount)
if ($accounts.Count -eq 0) {
    Write-Skip "none found"
} else {
    foreach ($a in $accounts) { Write-Step $a.Name }
}
Write-MigrationManifest -Accounts @($accounts | ForEach-Object { $_.FullName })
