#Requires -Version 5.1
<#
.SYNOPSIS
    Set up isolated Claude Code accounts that share session history.

.DESCRIPTION
    Each account gets its own config dir (~/.claude-<name>) holding its own
    .credentials.json and .claude.json, so logins are fully separate.

    Directories that should be common to every account (session transcripts,
    skills, agents, plugins, ...) live once in ~/.claude-shared and are exposed
    to each account through an NTFS directory junction. One copy of truth --
    no syncing, no divergence.

    This script NEVER deletes or modifies ~/.claude. Your existing setup stays
    intact as a fallback: a shell with no CLAUDE_CONFIG_DIR set still uses it.

.EXAMPLE
    .\setup-claude-accounts.ps1 -DryRun
    .\setup-claude-accounts.ps1
    .\setup-claude-accounts.ps1 -Accounts work,personal,client -SeedInto work
#>
[CmdletBinding()]
param(
    # Account names -> ~/.claude-<name>
    [string[]] $Accounts = @('work', 'personal'),

    # Which account inherits your CURRENT login and config from ~/.claude.
    # Pass '' when ADDING accounts to an existing setup - nothing is re-seeded.
    [string]   $SeedInto = 'work',

    # Where the current config lives
    [string]   $SeedFrom = (Join-Path $HOME '.claude'),

    # Directories shared across all accounts via junction
    [string[]] $SharedDirs = @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins', 'get-shit-done'),

    # Add accounts without seeding any of them from ~/.claude.
    # (Prefer this over -SeedInto '': powershell.exe -File drops empty args.)
    [switch]   $NoSeed,

    # Print the plan without changing anything
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

if ($NoSeed) { $SeedInto = '' }

# powershell.exe -File passes every argument as a literal string, so
# "-Accounts a,b" arrives as one element "a,b" rather than two. Normalise.
function Split-ListArg {
    param([string[]] $Value)
    $Value | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
}
$Accounts   = @(Split-ListArg $Accounts)
$SharedDirs = @(Split-ListArg $SharedDirs)

foreach ($name in $Accounts) {
    if ($name -match '[\\/:*?"<>|]') { throw "Invalid account name (path characters): '$name'" }
}

$Shared = Join-Path $HOME '.claude-shared'

# Ephemeral/regenerable - not worth copying into the seeded account
$SkipDirs = @('shell-snapshots', 'debug', 'paste-cache', 'downloads', 'cache', 'backups')

function Write-Step { param($Message) Write-Host "  $Message" }
function Write-Head { param($Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Skip { param($Message) Write-Host "  - $Message" -ForegroundColor DarkGray }
function Write-Done { param($Message) Write-Host "  + $Message" -ForegroundColor Green }

function Test-Junction {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function New-Junction {
    param([string] $Link, [string] $Target)

    if (Test-Junction $Link) {
        Write-Skip "junction already present: $Link"
        return
    }
    if (Test-Path -LiteralPath $Link) {
        # A real directory is in the way. Refuse rather than delete anything.
        throw "Refusing to replace real directory with a junction: $Link`n" +
              "       Move or remove it yourself, then re-run."
    }
    if ($DryRun) { Write-Step "would junction $Link -> $Target"; return }

    # mklink /J needs no admin rights (unlike a true symlink)
    $null = cmd /c mklink /J "$Link" "$Target"
    if (-not (Test-Junction $Link)) { throw "Failed to create junction: $Link" }
    Write-Done "junction $([IO.Path]::GetFileName($Link)) -> $Target"
}

function Copy-Tree {
    param([string] $Source, [string] $Destination, [string[]] $ExcludeDirs)

    if ($DryRun) { Write-Step "would copy $Source -> $Destination"; return }

    # NB: not $args - that is an automatic variable
    $roboArgs = @($Source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/R:1', '/W:1')
    if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) { $roboArgs += '/XD'; $roboArgs += $ExcludeDirs }

    $null = robocopy @roboArgs
    # robocopy: 0-7 = success (files copied / nothing to do), 8+ = real failure
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $Source -> $Destination" }
    $global:LASTEXITCODE = 0
}

# ---------------------------------------------------------------- plan --------

Write-Host "Claude Code multi-account setup" -ForegroundColor White
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  accounts     : $($Accounts -join ', ')"
Write-Host "  seeded from  : $SeedFrom  ->  $SeedInto"
Write-Host "  shared store : $Shared"
Write-Host "  shared dirs  : $($SharedDirs -join ', ')"

if ($SeedInto -and ($Accounts -notcontains $SeedInto)) {
    throw "-SeedInto '$SeedInto' is not in -Accounts ($($Accounts -join ', ')). " +
          "Pass -SeedInto '' if you are only adding accounts."
}

# ------------------------------------------------------- shared store --------

Write-Head "Shared store"

if (-not (Test-Path -LiteralPath $Shared)) {
    if (-not $DryRun) { $null = New-Item -ItemType Directory -Path $Shared -Force }
    Write-Done "created $Shared"
} else {
    Write-Skip "exists $Shared"
}

foreach ($dir in $SharedDirs) {
    $target = Join-Path $Shared $dir
    $origin = Join-Path $SeedFrom $dir

    if (Test-Path -LiteralPath $target) {
        Write-Skip "$dir (already seeded)"
        continue
    }
    if (Test-Path -LiteralPath $origin) {
        Copy-Tree -Source $origin -Destination $target
        Write-Done "$dir (copied from current config)"
    } else {
        if (-not $DryRun) { $null = New-Item -ItemType Directory -Path $target -Force }
        Write-Done "$dir (created empty)"
    }
}

# ----------------------------------------------------------- accounts --------

foreach ($name in $Accounts) {
    $acct = Join-Path $HOME ".claude-$name"
    Write-Head "Account '$name'  ->  $acct"

    if (-not (Test-Path -LiteralPath $acct)) {
        if (-not $DryRun) { $null = New-Item -ItemType Directory -Path $acct -Force }
        Write-Done "created $acct"
    } else {
        Write-Skip "exists $acct"
    }

    if ($SeedInto -and $name -eq $SeedInto) {
        # Inherit the current login + everything that is not shared
        if (Test-Path -LiteralPath $SeedFrom) {
            Copy-Tree -Source $SeedFrom -Destination $acct -ExcludeDirs ($SharedDirs + $SkipDirs)
            Write-Done "config + credentials copied from $SeedFrom"
        }
        $srcJson = Join-Path $HOME '.claude.json'
        $dstJson = Join-Path $acct '.claude.json'
        if ((Test-Path -LiteralPath $srcJson) -and -not (Test-Path -LiteralPath $dstJson)) {
            if (-not $DryRun) { Copy-Item -LiteralPath $srcJson -Destination $dstJson }
            Write-Done ".claude.json copied"
        }
    } else {
        # Fresh account: carry settings only, log in separately
        $srcSettings = Join-Path $SeedFrom 'settings.json'
        $dstSettings = Join-Path $acct 'settings.json'
        if ((Test-Path -LiteralPath $srcSettings) -and -not (Test-Path -LiteralPath $dstSettings)) {
            if (-not $DryRun) { Copy-Item -LiteralPath $srcSettings -Destination $dstSettings }
            Write-Done "settings.json copied (no credentials - you will log in)"
        }
    }

    foreach ($dir in $SharedDirs) {
        New-Junction -Link (Join-Path $acct $dir) -Target (Join-Path $Shared $dir)
    }
}

# --------------------------------------------------------------- done --------

Write-Head "Done"
Write-Host "  Your original ~/.claude was not modified."
Write-Host ""
Write-Host "  Next - open a NEW shell, then:"
if ($SeedInto) {
    Write-Host "    claude-$SeedInto".PadRight(24) -NoNewline
    Write-Host "# inherits your existing login"
}
foreach ($name in $Accounts | Where-Object { $_ -ne $SeedInto }) {
    Write-Host "    claude-$name".PadRight(24) -NoNewline
    Write-Host "# run /login once"
}
