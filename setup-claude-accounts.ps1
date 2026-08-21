#Requires -Version 5.1
<#
.SYNOPSIS
    Set up isolated Claude Code accounts that share session history.

.DESCRIPTION
    Each account gets its own config dir (~/.claude-<name>) holding its own
    .credentials.json and .claude.json, so logins are fully separate.

    ~/.claude is the shared store as well as the config dir used by a shell
    with no CLAUDE_CONFIG_DIR. Directories that should be common to every
    account (session transcripts, skills, agents, plugins, ...) live there once
    and are exposed to each account through an NTFS directory junction. One
    copy of truth -- no syncing, no divergence.

    Your global memory file, CLAUDE.md, gets the same treatment. It is a FILE,
    and a junction only links directories, so it is shared with an NTFS
    hardlink instead. The real file stays in the ~/.claude store and every
    account holds an additional name for that same inode, so editing CLAUDE.md
    from any account edits it for all of them.

    The status line is shared a third way, because it needs no link at all:
    Claude Code names it by PATH in settings.json. One copy of statusline.sh
    lives in ~/.claude and every account's settings.json points at it,
    so all accounts show the same bar and one edit changes them all.

    Setup only ever adds to ~/.claude; it never deletes. Existing config stays
    usable by the fallback shell while also becoming the one shared store for
    every named account.

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
    [string[]] $SharedDirs = @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins'),

    # Files shared across all accounts via hardlink. Config-dir top level only -
    # a junction cannot link a file, and a file cannot live inside a junctioned
    # directory without already being shared by it.
    [string[]] $SharedFiles = @('CLAUDE.md'),

    # Status line script every account runs. Copied into the shared store and
    # named by absolute path in each settings.json - there is nothing to link
    # here, because the setting IS a path and can point anywhere.
    [string]   $StatusLine = (Join-Path $PSScriptRoot 'statusline.sh'),

    # Leave every settings.json alone.
    [switch]   $NoStatusLine,

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

# The store IS ~/.claude. It holds the real shared dirs, CLAUDE.md,
# statusline.sh and bin/, and every account junctions/hardlinks into it.
# It is also the config dir a shell with no CLAUDE_CONFIG_DIR falls back to,
# so $Shared and $SeedFrom are normally the SAME path - several guards below
# exist only because of that overlap and say so.
$Shared = Join-Path $HOME '.claude'

# Ephemeral/regenerable - not worth copying into the seeded account
$SkipDirs = @('shell-snapshots', 'debug', 'paste-cache', 'downloads', 'cache', 'backups')

# Store-only: these live in the store but are NOT shared into accounts, and the
# store is now the same directory -SeedInto copies from. Without excluding them
# every seeded account gets a private copy of the profile script and the status
# line - the second of which then silently stops tracking the shared one.
$StoreOnlyDirs  = @('bin')
$StoreOnlyFiles = @([IO.Path]::GetFileName($StatusLine))

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

function Find-SharedFilePeer {
    # A surviving name for a shared file's inode, found among the account dirs.
    #
    # When the store was a separate directory it was itself the recovery handle:
    # ~/.claude could lose its copy and be re-linked from ~/.claude-shared. Now
    # that those are one path, the accounts are the only other names, so they
    # are where a deleted store file has to be recovered from.
    param([string] $FileName, [string] $Store)

    $storeFull = (Get-Item -LiteralPath $Store -Force).FullName.TrimEnd('\')
    Get-ChildItem -Path $HOME -Directory -Filter '.claude-*' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.TrimEnd('\') -ne $storeFull } |
        ForEach-Object {
            $candidate = Join-Path $_.FullName $FileName
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
                -not (Test-BlankFile -Path $candidate)) {
                return $candidate
            }
        } | Select-Object -First 1
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

function Get-GitBashPath {
    # Deliberately NOT Get-Command bash: on a machine with WSL installed that
    # resolves to C:\Windows\System32\bash.exe, which starts a Linux VM that
    # cannot open a path like C:/Users/... The status line would then render
    # nothing at all, with no error anywhere to explain why.
    $candidates = @()

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        # ...\Git\cmd\git.exe -> ...\Git\bin\bash.exe. Whichever git the user
        # actually runs is the Git Bash they actually have, portable installs
        # and all, so this goes first.
        $candidates += Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) { $candidates += Join-Path $root 'Git\bin\bash.exe' }
    }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe' }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-StatusLineSetting {
    # The statusLine object out of a settings.json, or $null if there is none.
    # Reading is safe with ConvertFrom-Json; writing is not - see Set-StatusLine.
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        $settings = $raw | ConvertFrom-Json
    } catch {
        throw "Cannot read $Path as JSON: $($_.Exception.Message)`n" +
              "       Fix or remove that file, then re-run."
    }
    return $settings.statusLine
}

function Set-StatusLine {
    # Point one settings.json at $Command. Returns $true if anything changed
    # (or would change, under -DryRun), so the caller can report it.
    param([string] $SettingsPath, [string] $Command)

    $current = Get-StatusLineSetting -Path $SettingsPath
    if ($current -and $current.type -eq 'command' -and $current.command -eq $Command) {
        Write-Skip "status line already set: $SettingsPath"
        return $false
    }

    if ($DryRun) {
        Write-Step "would $(if ($current) { 'replace' } else { 'set' }) the status line in $SettingsPath"
        return $true
    }

    # node does the write, not ConvertTo-Json. PowerShell 5.1's JSON writer
    # re-indents the whole file into its own ladder style, adds a BOM and turns
    # every line ending into CRLF - so a one-key change would arrive as a
    # whole-file rewrite of a config the user hand-edits, and the BOM alone
    # makes JSON.parse throw. JSON.stringify(x, null, 2) is byte for byte what
    # Claude Code itself writes. node is already required to RUN statusline.sh,
    # so this adds no dependency the status line did not already have.
    $script = @"
const fs = require('fs');
const file = $($SettingsPath | ConvertTo-Json);
let settings = {};
if (fs.existsSync(file)) {
  // A settings.json saved by Notepad or Set-Content carries a BOM, and
  // JSON.parse treats it as a syntax error rather than skipping it.
  settings = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}
// Merged, not replaced: statusLine may also carry a padding the user set.
settings.statusLine = Object.assign({}, settings.statusLine, {
  type: 'command',
  command: $($Command | ConvertTo-Json)
});
fs.writeFileSync(file, JSON.stringify(settings, null, 2) + '\n');
"@

    $scriptFile = Join-Path ([IO.Path]::GetTempPath()) ("claude-statusline-" + [guid]::NewGuid().ToString('N') + ".js")
    try {
        # No BOM, for the same reason node has to strip one above.
        [IO.File]::WriteAllText($scriptFile, $script, (New-Object Text.UTF8Encoding($false)))
        # No 2>&1 here: with $ErrorActionPreference = 'Stop', redirecting a
        # native command's stderr in 5.1 turns each line into a terminating
        # NativeCommandError, which would bury the real message. Unredirected,
        # node's own error text goes straight to the console.
        $null = & node $scriptFile
        if ($LASTEXITCODE -ne 0) {
            throw "node failed to write the status line into $SettingsPath (exit $LASTEXITCODE)"
        }
    } finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    }

    if ($current) {
        Write-Done "status line replaced in $SettingsPath"
        Write-Host "      was: $($current.command)" -ForegroundColor DarkGray
    } else {
        Write-Done "status line set in $SettingsPath"
    }
    return $true
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
Write-Host "  status line  : $(if ($NoStatusLine) { '(left alone)' } else { $StatusLine })"

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

# Anything this run puts INTO $SeedFrom, or changes there, so the closing
# summary can say so rather than repeating a "nothing was modified" line that
# stopped being true.
$SeedFromAdditions = @()
$SeedFromEdits     = @()

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
    } elseif ($peer = Find-SharedFilePeer -FileName $file -Store $Shared) {
        # The store's name is gone but the inode is alive under an account's
        # name. Re-link rather than creating an empty file: an empty store file
        # would make the per-account pass below hit New-FileLink's refusal on
        # every account that still has content, aborting the run.
        if ($DryRun) {
            Write-Step "would re-link $file into $Shared from $peer"
        } else {
            New-FileLink -Link $target -Target $peer
            Write-Done "$file (recovered from $peer)"
        }
        $SeedFromAdditions += $file
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

# -------------------------------------------------------- status line --------

# Stays $null when there is no status line to set, which is what tells the
# account loop below to leave every settings.json untouched.
$StatusLineCommand = $null

if (-not $NoStatusLine) {
    Write-Head "Status line"

    if (-not (Test-Path -LiteralPath $StatusLine -PathType Leaf)) {
        throw "-StatusLine script not found: $StatusLine`n" +
              "       Pass -NoStatusLine if you do not want one."
    }

    $bash = Get-GitBashPath
    $node = Get-Command node.exe -ErrorAction SilentlyContinue

    if (-not $bash -or -not $node) {
        # Warn and carry on rather than throw. The status line is decoration;
        # aborting a whole account setup over it would be out of proportion,
        # and everything else here works without either program.
        $missing = @()
        if (-not $bash) { $missing += 'Git Bash (bash.exe)' }
        if (-not $node) { $missing += 'Node.js (node.exe)' }
        Write-Host "  ! skipped - statusline.sh needs $($missing -join ' and '), not found" -ForegroundColor Yellow
        Write-Host "    Install it and re-run, or pass -NoStatusLine to stop looking." -ForegroundColor DarkGray
    } else {
        $target = Join-Path $Shared ([IO.Path]::GetFileName($StatusLine))

        if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Test-SameContent -Path $target -Other $StatusLine)) {
            Write-Skip "up to date $target"
        } elseif ($DryRun) {
            Write-Step "would copy $StatusLine -> $target"
        } else {
            Copy-Item -LiteralPath $StatusLine -Destination $target -Force
            Write-Done "copied $([IO.Path]::GetFileName($StatusLine)) -> $Shared"
        }

        # Forward slashes, and each half quoted: this string is embedded in
        # JSON, where every backslash would have to be escaped, and it is the
        # shape Claude Code's own settings writer uses.
        $StatusLineCommand = '"{0}" "{1}"' -f $bash.Replace('\', '/'), $target.Replace('\', '/')
        Write-Step "command: $StatusLineCommand"

        # ~/.claude gets it too, and gets it FIRST: it is the config dir a shell
        # with no CLAUDE_CONFIG_DIR falls back to, and the template a fresh
        # account's settings.json is copied from below - so setting it here
        # means new accounts are born with the right status line rather than
        # being corrected a moment later.
        if (Test-Path -LiteralPath $SeedFrom) {
            $seedSettings = Join-Path $SeedFrom 'settings.json'
            $seedHadOne   = Test-Path -LiteralPath $seedSettings -PathType Leaf
            if (Set-StatusLine -SettingsPath $seedSettings -Command $StatusLineCommand) {
                $SeedFromEdits += if ($seedHadOne) { 'the statusLine in settings.json' }
                                  else            { 'settings.json (created, to hold the status line)' }
            }
        }
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
                      -ExcludeDirs ($SharedDirs + $SkipDirs + $StoreOnlyDirs) `
                      -ExcludeFiles ($SharedFiles + $StoreOnlyFiles)
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

    if ($StatusLineCommand) {
        $null = Set-StatusLine -SettingsPath (Join-Path $acct 'settings.json') -Command $StatusLineCommand
    }
}

# --------------------------------------------------------------- done --------

Write-Head "Done"
if ($SeedFromAdditions.Count -gt 0 -or $SeedFromEdits.Count -gt 0) {
    Write-Host "  Nothing in $SeedFrom was removed."
    if ($SeedFromAdditions.Count -gt 0) {
        $gained = if ($DryRun) { 'would gain' } else { 'gained' }
        Write-Host "  It $($gained): $($SeedFromAdditions -join ', ')"
        Write-Host "  A shared file needs a real file there to be a second name for." -ForegroundColor DarkGray
    }
    if ($SeedFromEdits.Count -gt 0) {
        $changed = if ($DryRun) { 'would change' } else { 'changed' }
        Write-Host "  This run $($changed): $($SeedFromEdits -join ', ')"
    }
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
