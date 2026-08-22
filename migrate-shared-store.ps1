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
    [switch] $DryRun,

    # Test seam: rewrite this legacy file after Phase 1 has recorded it, to
    # exercise the Phase 2b drift check. There is no honest way to race a real
    # Claude Code session from a test.
    [string] $SimulateDriftPath
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

# ----------------------------------------------------------- phase 1b --------

$script:Superseded = 0
$script:Adopted    = 0
$script:Rescued    = @()

function Test-JsonLine {
    param([string] $Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $true }
    try { $null = ConvertFrom-Json $Line; return $true } catch { return $false }
}

function Get-JsonlRelation {
    # 'identical' | 'superseded' | 'continued' | 'forked'
    #
    # superseded: legacy is a strict line-prefix of store  -> store already has it
    # continued : store is a strict line-prefix of legacy  -> legacy has more
    # forked    : neither is a prefix of the other
    param([string] $Store, [string] $Legacy)

    $s = @(Get-Content -LiteralPath $Store  -ErrorAction SilentlyContinue)
    $l = @(Get-Content -LiteralPath $Legacy -ErrorAction SilentlyContinue)
    $shorter = [Math]::Min($s.Count, $l.Count)

    for ($i = 0; $i -lt $shorter; $i++) {
        if ($s[$i] -ne $l[$i]) { return 'forked' }
    }
    if ($s.Count -eq $l.Count) { return 'identical' }
    if ($l.Count -lt $s.Count) { return 'superseded' }
    return 'continued'
}

function Get-RescueId {
    # DETERMINISTIC, not random. A random GUID would make rescue the one
    # non-idempotent step in the script: the legacy and store copies stay forked
    # after a rescue, so the next run classifies them as forked again and writes
    # ANOTHER copy. Every re-run - which is the documented recovery for a drift
    # or conflict abort - would multiply the transcript.
    #
    # Deriving the id from the old id plus the legacy file's content means a
    # re-run computes the same name, finds the file already there, and skips.
    # MD5 is 16 bytes, which is exactly a GUID; it is used here as a
    # content-addressing function, not for security.
    param([string] $OldId, [string] $LegacyPath)

    $seed = $OldId + ':' + (Get-FileHash -LiteralPath $LegacyPath -Algorithm MD5).Hash
    $md5  = [Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))
    } finally {
        $md5.Dispose()
    }
    return ([guid][byte[]]$bytes).ToString()
}

function New-RescuedTranscript {
    # Copy a forked legacy transcript in under a stable rescue id so both halves
    # are resumable. Only the two top-level id FIELDS are rewritten: the other
    # mentions of the id in a transcript are temp scratchpad paths and tool
    # output, which are a historical record and resolve to nothing we own.
    #
    # Sidecar <id>/ directories are deliberately NOT renamed. Phase 1's
    # add-if-missing pass already merged any sidecar files, and renaming one
    # without rewriting the transcript's references to it would break them.
    param([string] $LegacyPath, [string] $Destination, [string] $OldId)

    $newId  = Get-RescueId -OldId $OldId -LegacyPath $LegacyPath
    $target = Join-Path $Destination "$newId.jsonl"

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        # An earlier run already rescued this exact content.
        return $null
    }

    $text = [IO.File]::ReadAllText($LegacyPath)
    $text = $text.Replace("`"sessionId`":`"$OldId`"",  "`"sessionId`":`"$newId`"")
    $text = $text.Replace("`"session_id`":`"$OldId`"", "`"session_id`":`"$newId`"")

    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding $false))
    return $newId
}

function Copy-LegacyProjects {
    $source = Join-Path $Legacy 'projects'
    $dest   = Join-Path $Store  'projects'
    if (-not (Test-Path -LiteralPath $source)) { return }

    Get-ChildItem -LiteralPath $source -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            # switch and the parse-gate pipeline both rebind $_, so preserve the
            # legacy FileInfo before entering either nested scope.
            $legacyFile = $_
            Register-ReadFile -Item $legacyFile
            $relative = $legacyFile.FullName.Substring($source.Length).TrimStart('\')
            $target   = Join-Path $dest $relative

            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                if ($DryRun) { Write-Step "would copy $relative"; return }
                $parent = Split-Path $target -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    $null = New-Item -ItemType Directory -Path $parent -Force
                }
                Copy-Item -LiteralPath $legacyFile.FullName -Destination $target -Force
                $script:Copied++
                return
            }

            if ((Get-FileHash -LiteralPath $legacyFile.FullName).Hash -eq
                (Get-FileHash -LiteralPath $target).Hash) { return }

            if ($legacyFile.Extension -ne '.jsonl') { $script:Conflicts += $target; return }

            switch (Get-JsonlRelation -Store $target -Legacy $legacyFile.FullName) {
                'identical'  { }
                'superseded' { $script:Superseded++ }
                'continued'  {
                    # Validate every ADDED line before letting it replace a file
                    # that currently parses. Strict prefix says nothing about
                    # the suffix, and a truncated tail satisfies it exactly.
                    $storeCount = @(Get-Content -LiteralPath $target).Count
                    $added      = @(Get-Content -LiteralPath $legacyFile.FullName) |
                                      Select-Object -Skip $storeCount
                    if (@($added | Where-Object { -not (Test-JsonLine -Line $_) }).Count -gt 0) {
                        $script:Conflicts += $target
                        Write-Warn "not adopted (malformed added line): $relative"
                        return
                    }
                    if ($DryRun) { Write-Step "would adopt $relative"; return }
                    # Temp file then move, so an interrupted adoption cannot
                    # leave a half-written transcript where a valid one was.
                    $tmp  = "$target.migrating"
                    $text = [IO.File]::ReadAllText($legacyFile.FullName)
                    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
                    Move-Item -LiteralPath $tmp -Destination $target -Force
                    $script:Adopted++
                }
                'forked' {
                    $oldId = [IO.Path]::GetFileNameWithoutExtension($legacyFile.Name)
                    if ($DryRun) { Write-Step "would rescue $relative under a new id"; return }
                    $newId = New-RescuedTranscript -LegacyPath $legacyFile.FullName `
                                                   -Destination (Split-Path $target -Parent) `
                                                   -OldId $oldId
                    # $null means an earlier run already rescued this content.
                    if ($newId) { $script:Rescued += "$oldId -> $newId" }
                }
            }
        }
}

Copy-LegacyProjects
Write-Done "$($script:Copied) copied, $($script:Overwrote) overwritten (plugins), $($script:Conflicts.Count) conflicts"
Write-Done ("projects: {0} superseded, {1} adopted, {2} rescued" -f `
            $script:Superseded, $script:Adopted, $script:Rescued.Count)

# ------------------------------------------------------------ phase 2 --------

Write-Head "Retarget"

$refused = @()

foreach ($acct in $accounts) {
    foreach ($dir in $SharedDirs) {
        $link      = Join-Path $acct.FullName $dir
        $newTarget = Join-Path $Store $dir

        if (-not (Test-Path -LiteralPath $link)) {
            if ($DryRun) { Write-Step "would link $link"; continue }
            $null = cmd /c mklink /J "$link" "$newTarget"
            Write-Done "linked $($acct.Name)\$dir"
            continue
        }

        $item = Get-Item -LiteralPath $link -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            # A real directory with real content. Refuse, exactly as
            # New-Junction does - never delete what we did not create.
            $refused += $link
            Write-Warn "Refusing to replace real directory: $link"
            continue
        }
        if (-not (Test-JunctionInto -Path $link -Root $Legacy)) {
            # Three outcomes, not two. A reparse point that is not the legacy
            # store is NOT automatically the new store: it can point at a
            # backup, a stale path, or anywhere the user aimed it. Calling that
            # "already migrated" would let the final gate bless deleting the
            # legacy store while this account still reads and writes elsewhere -
            # and setup will not catch it either, because New-Junction checks
            # only the reparse-point attribute.
            if (Test-JunctionInto -Path $link -Root $Store) {
                Write-Skip "already points at the store: $($acct.Name)\$dir"
            } else {
                $target = @((Get-Item -LiteralPath $link -Force).Target) | Select-Object -First 1
                $refused += $link
                Write-Warn "Unexpected junction target, leaving it alone: $link -> $target"
            }
            continue
        }
        if ($DryRun) { Write-Step "would retarget $link"; continue }

        # rmdir, never Remove-Item -Recurse: on 5.1 that follows the junction
        # and would empty the legacy store - the standby copy this whole design
        # depends on.
        cmd /c rmdir "$link" | Out-Null
        $null = cmd /c mklink /J "$link" "$newTarget"
        Write-Done "retargeted $($acct.Name)\$dir"
    }
}

# ----------------------------------------------------------- phase 2b --------

if ($SimulateDriftPath) {
    Add-Content -LiteralPath $SimulateDriftPath -Value 'appended during the run'
}

Write-Head "Stability check"

# Re-enumerate the WHOLE legacy tree, rather than only re-checking the files
# Phase 1 happened to read. A live Claude Code session does not just append to
# transcripts it already had - it creates new ones. A file that appeared after
# Phase 1 enumerated the tree is absent from $script:ReadFiles, so a check that
# only walks those keys cannot see it, would report no drift, and would go on to
# bless deleting a legacy store holding a transcript that was never merged.
$script:Drifted = @()
$seenNow        = @{}

Get-ChildItem -LiteralPath $Legacy -Recurse -File -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
        $seenNow[$_.FullName] = $true
        $then = $script:ReadFiles[$_.FullName]
        if ($null -eq $then) {
            # Created during the run, so it was never merged.
            $script:Drifted += $_.FullName
        } elseif ($_.Length -ne $then.Length -or $_.LastWriteTimeUtc -ne $then.LastWriteTimeUtc) {
            $script:Drifted += $_.FullName
        }
    }

foreach ($path in $script:ReadFiles.Keys) {
    # Disappeared during the run. Not a merge gap, but it means the source moved
    # under us and the run's picture of it is stale either way.
    if (-not $seenNow.ContainsKey($path)) { $script:Drifted += $path }
}

if ($script:Drifted.Count -gt 0) {
    # Something wrote to the legacy store while this ran - almost certainly a
    # live Claude Code session. Those lines were never merged, so the merge is
    # incomplete and the standby copy must not be deleted.
    Write-Warn "$($script:Drifted.Count) file(s) changed during this run:"
    foreach ($p in $script:Drifted | Select-Object -First 10) { Write-Step $p }
    Write-Warn "Close all Claude Code sessions and re-run. The merge is idempotent."
} else {
    Write-Done "the legacy store did not change during this run"
}
