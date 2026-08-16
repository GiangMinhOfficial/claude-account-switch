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

    Your global memory file, CLAUDE.md, gets the same treatment. It is a FILE,
    and a junction only links directories, so it is shared with an NTFS
    hardlink instead. The real file stays in ~/.claude; the shared store and
    every account hold additional names for that same inode, so editing
    CLAUDE.md from any account edits it for all of them.

    This script never deletes anything from ~/.claude and rewrites nothing in
    it. Your existing setup stays intact as a fallback: a shell with no
    CLAUDE_CONFIG_DIR set still uses it. The single exception is that an empty
    ~/.claude/CLAUDE.md is created if you have none at all, so that the shared
    memory file has somewhere to live.

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

    # Files shared across all accounts via hardlink. Config-dir top level only -
    # a junction cannot link a file, and a file cannot live inside a junctioned
    # directory without already being shared by it.
    [string[]] $SharedFiles = @('CLAUDE.md'),

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
$Accounts    = @(Split-ListArg $Accounts)
$SharedDirs  = @(Split-ListArg $SharedDirs)
$SharedFiles = @(Split-ListArg $SharedFiles)

foreach ($file in $SharedFiles) {
    # Each name is joined onto every account dir AND onto the store. A path
    # fragment would therefore mean something different in each place, and a
    # wildcard would resolve against whichever dir it was tested in first.
    if ($file -match '[\\/]' -or $file -match '[*?\[\]]') {
        throw "Invalid -SharedFiles entry (must be a plain file name): '$file'"
    }
}

# Keep this literal identical to claude-account-profile.ps1's copy.
# tests/Set-ClaudeAccountName.Tests.ps1 asserts they match. It is duplicated
# rather than shared because dot-sourcing the profile from here would run
# Register-ClaudeAccountFunctions as a side effect.
$ClaudeInvalidNameClass = '[\\/:*?"<>|\[\]]'

foreach ($name in $Accounts) {
    # Brackets: the function: provider treats them as wildcards, so an account
    # named a[1] gets no launchers at all while everything reports success.
    if ($name -match $ClaudeInvalidNameClass) {
        throw "Invalid account name (path characters or brackets): '$name'"
    }
    # Windows silently drops a trailing dot: .claude-foo. is created as
    # .claude-foo, so the account made is not the account asked for.
    if ($name -match '\.$') {
        throw "Invalid account name (trailing dot): '$name' - Windows would create '.claude-$($name.TrimEnd('.'))'"
    }
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

function Get-LinkPeer {
    # The other names for this file's inode. Hardlinks are symmetric - there is
    # no "the link" and "the target", only equal names - so FileInfo.Target
    # lists every name EXCEPT the one it was asked about.
    param([IO.FileInfo] $Item)

    foreach ($peer in @($Item.Target)) {
        if ([string]::IsNullOrWhiteSpace($peer)) { continue }

        # Peers can arrive volume-relative (\Users\me\.claude\CLAUDE.md), the
        # shape fsutil reports. A hardlink cannot cross volumes, so the link's
        # own drive is always the one to put back.
        if ($peer -notmatch '^[A-Za-z]:\\' -and $peer -notmatch '^\\\\') {
            $peer = (Split-Path -Qualifier $Item.FullName) + $peer
        }
        $peer
    }
}

function Test-SameFile {
    # Two paths, one inode? Not "same content" - see Test-SameContent for that.
    param([string] $Path, [string] $Other)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Other -PathType Leaf)) { return $false }

    $item      = Get-Item -LiteralPath $Path  -Force
    $otherFull = (Get-Item -LiteralPath $Other -Force).FullName

    if ($item.FullName -eq $otherFull) { return $true }
    if ($item.LinkType -ne 'HardLink')  { return $false }

    return [bool](@(Get-LinkPeer -Item $item) -contains $otherFull)
}

function Test-BlankFile {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -eq 0) { return $true }
    # A file holding only a BOM and blank lines is what an editor leaves behind
    # after you open a new memory file and save without typing anything.
    return [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $Path -Raw))
}

function Test-SameContent {
    param([string] $Path, [string] $Other)
    if ((Get-Item -LiteralPath $Path -Force).Length -ne (Get-Item -LiteralPath $Other -Force).Length) { return $false }
    return ((Get-FileHash -LiteralPath $Path  -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $Other -Algorithm SHA256).Hash)
}

function New-FileLink {
    # Give $Target a second name at $Link. Both names are then the same file:
    # a write through either is a write to the one inode, and deleting either
    # removes only that name.
    param([string] $Link, [string] $Target)

    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        # Under -DryRun the target is a file an earlier step only SAID it would
        # create, so its absence is expected and not an error.
        if ($DryRun) { Write-Step "would link $Link -> $Target"; return }
        throw "Cannot link $Link - the shared file does not exist: $Target"
    }

    if (Test-SameFile -Path $Link -Other $Target) {
        Write-Skip "link already present: $Link"
        return
    }

    $replacing = $null
    if (Test-Path -LiteralPath $Link) {
        if ((Get-Item -LiteralPath $Link -Force).PSIsContainer) {
            throw "Refusing to replace a directory with a shared file link: $Link"
        }
        # Exactly two kinds of file here can be dropped without losing anything
        # a user wrote: one with nothing in it, and one that already says byte
        # for byte what the shared file says (what a pre-hardlink run of this
        # script copied in). Anything else is somebody's memory - refuse.
        if     (Test-BlankFile   -Path $Link)                 { $replacing = 'replaced empty file' }
        elseif (Test-SameContent -Path $Link -Other $Target)  { $replacing = 'replaced identical copy' }
        else {
            throw "Refusing to overwrite $Link`n" +
                  "       It has content of its own that differs from $Target.`n" +
                  "       Merge what you want to keep into the shared file, then delete this one and re-run."
        }
    }

    if ($DryRun) {
        if ($replacing) { Write-Step "would link $Link -> $Target ($replacing)" }
        else            { Write-Step "would link $Link -> $Target" }
        return
    }

    # Deleting first is safe only because of the guard above: the content of
    # everything we delete here still exists, unchanged, at $Target.
    if ($replacing) { Remove-Item -LiteralPath $Link -Force }

    # mklink /H needs no admin rights, and takes its paths literally - unlike
    # New-Item, which has no -LiteralPath and would read [] in a home
    # directory name as a wildcard.
    $null = cmd /c mklink /H "$Link" "$Target"
    if (-not (Test-SameFile -Path $Link -Other $Target)) {
        throw "Failed to hardlink $Link -> $Target`n" +
              "       A hardlink cannot cross volumes or leave NTFS; both paths must be on the same drive."
    }
    if ($replacing) { Write-Done "link $([IO.Path]::GetFileName($Link)) -> $Target ($replacing)" }
    else            { Write-Done "link $([IO.Path]::GetFileName($Link)) -> $Target" }
}

function Copy-Tree {
    param([string] $Source, [string] $Destination, [string[]] $ExcludeDirs, [string[]] $ExcludeFiles)

    if ($DryRun) { Write-Step "would copy $Source -> $Destination"; return }

    # NB: not $args - that is an automatic variable
    $roboArgs = @($Source, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/R:1', '/W:1')
    if ($ExcludeDirs  -and $ExcludeDirs.Count  -gt 0) { $roboArgs += '/XD'; $roboArgs += $ExcludeDirs }
    if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) { $roboArgs += '/XF'; $roboArgs += $ExcludeFiles }

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
Write-Host "  shared files : $($SharedFiles -join ', ')"

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

# Anything this run puts INTO $SeedFrom, so the closing summary can say so
# rather than repeating a "nothing was modified" line that stopped being true.
$SeedFromAdditions = @()

foreach ($file in $SharedFiles) {
    $target = Join-Path $Shared   $file
    $origin = Join-Path $SeedFrom $file

    # Shared FILES are linked, not copied, so unlike the directories above this
    # is not a one-time seed: the store and $SeedFrom end up as two names for
    # one inode, and there is no second copy that could drift.
    #
    # ~/.claude keeps the real file. It is where the file already lives, where
    # a shell with no CLAUDE_CONFIG_DIR reads it from, and the one location
    # that survives deleting the whole multi-account setup.
    if (Test-Path -LiteralPath $origin) {
        New-FileLink -Link $target -Target $origin
    } elseif (Test-Path -LiteralPath $target) {
        # Re-run after ~/.claude lost its copy. The inode is still alive under
        # the store's name, so give ~/.claude its name back rather than
        # leaving the fallback shell with no memory.
        if (Test-Path -LiteralPath $SeedFrom) {
            New-FileLink -Link $origin -Target $target
            $SeedFromAdditions += $file
        } else {
            Write-Skip "$file (no $SeedFrom to link it back into)"
        }
    } elseif (Test-Path -LiteralPath $SeedFrom) {
        # The one thing this script adds to ~/.claude, and only when you have
        # no $file at all: the shared copy needs a real file to be a name for.
        # Worth being straight about under -DryRun, unlike an empty shared dir.
        if ($DryRun) {
            Write-Step "would create an empty $file in $SeedFrom"
        } else {
            $null = New-Item -ItemType File -Path $origin
            Write-Done "$file (created empty in $SeedFrom)"
        }
        New-FileLink -Link $target -Target $origin
        $SeedFromAdditions += $file
    } elseif ($DryRun) {
        Write-Step "would create an empty $file in the shared store"
    } else {
        $null = New-Item -ItemType File -Path $target
        Write-Done "$file (created empty in the shared store)"
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
            # -ExcludeFiles matters as much as -ExcludeDirs: robocopy would
            # otherwise leave a plain COPY of CLAUDE.md here, and the link step
            # below would have to decide whether the copy or the shared file
            # was the real one.
            Copy-Tree -Source $SeedFrom -Destination $acct `
                      -ExcludeDirs ($SharedDirs + $SkipDirs) -ExcludeFiles $SharedFiles
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

    foreach ($file in $SharedFiles) {
        New-FileLink -Link (Join-Path $acct $file) -Target (Join-Path $Shared $file)
    }
}

# --------------------------------------------------------------- done --------

Write-Head "Done"
if ($SeedFromAdditions.Count -gt 0) {
    $gained = if ($DryRun) { 'would gain' } else { 'gained' }
    Write-Host "  Nothing in $SeedFrom was changed or removed; it $($gained): $($SeedFromAdditions -join ', ')"
    Write-Host "  A shared file needs a real file there to be a second name for." -ForegroundColor DarkGray
} else {
    Write-Host "  Your original ~/.claude was not modified."
}
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
