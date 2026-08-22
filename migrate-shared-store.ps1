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

# ----------------------------------------------------------- phase 0b --------

function Test-SameInode {
    # Two paths, one inode. Hardlinks are symmetric, so FileInfo.Target lists
    # every OTHER name and can return them volume-relative.
    param([string] $Path, [string] $Other)

    if (-not (Test-Path -LiteralPath $Path  -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Other -PathType Leaf)) { return $false }

    $item      = Get-Item -LiteralPath $Path  -Force
    $otherFull = (Get-Item -LiteralPath $Other -Force).FullName
    if ($item.FullName -eq $otherFull) { return $true }
    if ($item.LinkType -ne 'HardLink')  { return $false }

    foreach ($peer in @($item.Target)) {
        if ([string]::IsNullOrWhiteSpace($peer)) { continue }
        if ($peer -notmatch '^[A-Za-z]:\\' -and $peer -notmatch '^\\\\') {
            $peer = (Split-Path -Qualifier $item.FullName) + $peer
        }
        if ($peer -eq $otherFull) { return $true }
    }
    return $false
}

Write-Head "Preflight"

$storeMemory = Join-Path $Store 'CLAUDE.md'
$divergent   = @()

function Test-DivergentMemory {
    # Nonblank, not the same inode as the store's copy, and not byte-identical
    # to it. Anything matching is content that merging would silently drop.
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (Test-SameInode -Path $Path -Other $storeMemory)     { return $false }
    if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $Path -Raw))) { return $false }
    if ((Test-Path -LiteralPath $storeMemory -PathType Leaf) -and
        ((Get-Content -LiteralPath $Path -Raw) -eq
         (Get-Content -LiteralPath $storeMemory -Raw))) { return $false }
    return $true
}

# The LEGACY copy is checked too, and it is the easier one to lose. Phase 1
# skips CLAUDE.md entirely on the grounds that every name is one inode - so if
# ~/.claude-shared/CLAUDE.md has drifted into an independent file, its content
# is never merged, and a clean run would go on to say the legacy store is safe
# to delete. That is the live shared-memory path today, so it is exactly the
# one an editor is most likely to have replaced on save.
if (Test-DivergentMemory -Path (Join-Path $Legacy 'CLAUDE.md')) {
    $divergent += (Join-Path $Legacy 'CLAUDE.md')
}

foreach ($acct in $accounts) {
    $acctMemory = Join-Path $acct.FullName 'CLAUDE.md'
    if (Test-DivergentMemory -Path $acctMemory) { $divergent += $acctMemory }
}

if ($divergent.Count -gt 0) {
    # Refuse BEFORE anything is mutated. setup's New-FileLink would refuse
    # later anyway, but only after Phase 2 had already retargeted the
    # junctions - and every re-run would then fail the same way.
    throw ("Refusing to migrate: these CLAUDE.md files have content of their own`n" +
           ($divergent | ForEach-Object { "         $_" }) -join "`n") + "`n" +
          "       Merge what you want to keep into $storeMemory, delete the copy, then re-run."
}
Write-Done "CLAUDE.md is consistent across every account"

Write-MigrationManifest -Accounts @($accounts | ForEach-Object { $_.FullName })

# ------------------------------------------------------------ phase 1 --------

# Every legacy file this run READ, with the size and timestamp it had at the
# time. Phase 2b re-checks these: a change means something wrote during the run
# and the merge is incomplete.
$script:ReadFiles  = @{}
$script:Conflicts  = @()
$script:Copied     = 0
$script:Overwrote  = 0

function Register-ReadFile {
    param([IO.FileInfo] $Item)
    $script:ReadFiles[$Item.FullName] = [pscustomobject]@{
        Length           = $Item.Length
        LastWriteTimeUtc = $Item.LastWriteTimeUtc
    }
}

function Copy-LegacyTree {
    # Walks one legacy subtree and applies a per-source policy.
    #   Missing      -> copy
    #   Identical    -> skip
    #   Differs      -> $OnConflict decides: 'keep-store' or 'legacy-wins'
    # projects/ is handled separately in Phase 1b: transcripts need classifying,
    # not a flat rule.
    param(
        [string] $Source,
        [string] $Destination,
        [ValidateSet('keep-store', 'legacy-wins')] [string] $OnConflict
    )

    if (-not (Test-Path -LiteralPath $Source)) { return }

    Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Register-ReadFile -Item $_
            $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
            $target   = Join-Path $Destination $relative

            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                if ($DryRun) { Write-Step "would copy $relative"; return }
                $parent = Split-Path $target -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    $null = New-Item -ItemType Directory -Path $parent -Force
                }
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                $script:Copied++
                return
            }

            if ((Get-FileHash -LiteralPath $_.FullName).Hash -eq
                (Get-FileHash -LiteralPath $target).Hash) { return }

            if ($OnConflict -eq 'legacy-wins') {
                if ($DryRun) { Write-Step "would overwrite $relative"; return }
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                $script:Overwrote++
            } else {
                $script:Conflicts += $target
            }
        }
}

Write-Head "Merge"

foreach ($dir in @('skills', 'agents', 'commands', 'hooks')) {
    Copy-LegacyTree -Source (Join-Path $Legacy $dir) -Destination (Join-Path $Store $dir) `
                    -OnConflict 'keep-store'
}

# plugins/ is the one documented exception to never-overwrite. The legacy tree
# is the one the accounts have actually been using, and its registry JSONs know
# about plugins the store's stale copy does not. Overwrite and add; delete
# nothing.
Copy-LegacyTree -Source (Join-Path $Legacy 'plugins') -Destination (Join-Path $Store 'plugins') `
                -OnConflict 'legacy-wins'

# Store-only artifacts: they belong in the store but are never shared into an
# account, so setup excludes them from seeding.
Copy-LegacyTree -Source (Join-Path $Legacy 'bin') -Destination (Join-Path $Store 'bin') `
                -OnConflict 'keep-store'

$legacyStatusLine = Join-Path $Legacy 'statusline.sh'
if (Test-Path -LiteralPath $legacyStatusLine -PathType Leaf) {
    Register-ReadFile -Item (Get-Item -LiteralPath $legacyStatusLine -Force)
    $target = Join-Path $Store 'statusline.sh'
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        if ($DryRun) {
            Write-Step "would copy statusline.sh"
        } else {
            Copy-Item -LiteralPath $legacyStatusLine -Destination $target -Force
            Write-Done "statusline.sh"
        }
    }
}

# CLAUDE.md needs nothing: preflight already proved every name is one inode, so
# the store's copy IS the legacy store's copy.

Write-Done "$($script:Copied) copied, $($script:Overwrote) overwritten (plugins), $($script:Conflicts.Count) conflicts"
