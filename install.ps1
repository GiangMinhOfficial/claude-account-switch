#Requires -Version 5.1
<#
.SYNOPSIS
    Wire the Claude account-switching functions into your PowerShell profile.

.DESCRIPTION
    By default, copies claude-account-profile.ps1 into ~/.claude-shared/bin and adds
    a marked block to $PROFILE that dot-sources it from there. The repo can then be
    moved or deleted without breaking your shell. Re-run this after a `git pull` to
    pick up changes.

    With -FromRepo, the profile dot-sources the script where it sits in the repo
    instead, so a `git pull` takes effect with no re-install - at the cost of the
    repo checkout becoming load-bearing.

    Idempotent. Also absorbs a hand-written dot-source line for this script, so you
    do not end up loading it twice.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -FromRepo
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch] $Uninstall,
    [switch] $FromRepo
)

$ErrorActionPreference = 'Stop'

$BeginMarker = '# >>> claude-account-switch >>>'
$EndMarker   = '# <<< claude-account-switch <<<'
$ProfilePath = $PROFILE
$RepoScript  = Join-Path $PSScriptRoot 'claude-account-profile.ps1'
$BinDir      = Join-Path $HOME '.claude-shared\bin'
$InstalledTo = Join-Path $BinDir 'claude-account-profile.ps1'

if (-not $Uninstall -and -not (Test-Path -LiteralPath $RepoScript)) {
    throw "Cannot find $RepoScript - run this from inside the repo."
}

# --- make sure the profile file exists ---------------------------------------

$profileDir = Split-Path $ProfilePath -Parent
if (-not (Test-Path -LiteralPath $profileDir)) {
    $null = New-Item -ItemType Directory -Path $profileDir -Force
}
if (-not (Test-Path -LiteralPath $ProfilePath)) {
    $null = New-Item -ItemType File -Path $ProfilePath
}

# --- strip anything we previously installed ----------------------------------

$content = Get-Content -LiteralPath $ProfilePath -Raw
if ($null -eq $content) { $content = '' }

$blockPattern = [regex]::Escape($BeginMarker) + '(?s).*?' + [regex]::Escape($EndMarker)
$hadBlock     = [regex]::IsMatch($content, $blockPattern)
$content      = [regex]::Replace($content, $blockPattern, '')

# A hand-written `. "...\claude-account-profile.ps1"` line, so we do not double-load
$barePattern = '(?m)^[ \t]*\.[ \t]+"?[^"\r\n]*claude-account-profile\.ps1"?[ \t]*\r?$'
$hadBare     = [regex]::IsMatch($content, $barePattern)
$content     = [regex]::Replace($content, $barePattern, '').TrimEnd()

if ($Uninstall) {
    Set-Content -LiteralPath $ProfilePath -Value $content -Encoding UTF8
    if ($hadBlock -or $hadBare) {
        Write-Host "Removed the claude-account-switch lines from $ProfilePath" -ForegroundColor Green
    } else {
        Write-Host "Nothing to remove in $ProfilePath" -ForegroundColor DarkGray
    }
    Write-Host "Your account directories and $BinDir were left untouched."
    return
}

# --- place the script ---------------------------------------------------------

if ($FromRepo) {
    $sourceFor = $RepoScript
    Write-Host "Dot-sourcing from the repo: $RepoScript" -ForegroundColor DarkGray
} else {
    if (-not (Test-Path -LiteralPath $BinDir)) {
        $null = New-Item -ItemType Directory -Path $BinDir -Force
    }
    Copy-Item -LiteralPath $RepoScript -Destination $InstalledTo -Force
    $sourceFor = $InstalledTo
    Write-Host "Installed script to $InstalledTo" -ForegroundColor Green
}

# --- write the block ----------------------------------------------------------

$block = "$BeginMarker`r`n. `"$sourceFor`"`r`n$EndMarker"

if ($content.Length -gt 0) { $content = "$content`r`n`r`n$block" } else { $content = $block }
Set-Content -LiteralPath $ProfilePath -Value $content -Encoding UTF8

if ($hadBlock) {
    Write-Host "Updated the claude-account-switch block in $ProfilePath" -ForegroundColor Green
} else {
    Write-Host "Added the claude-account-switch block to $ProfilePath" -ForegroundColor Green
}
if ($hadBare) {
    Write-Host "Absorbed your existing dot-source line (it would have loaded twice)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Open a NEW PowerShell window, then:"
Write-Host "  Get-ClaudeAccount     # list accounts"
Write-Host "  claude-<name>         # launch Claude Code as that account"
Write-Host ""
Write-Host "If the new shell reports 'running scripts is disabled', run once:" -ForegroundColor Yellow
Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
