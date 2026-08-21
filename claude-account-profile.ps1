# ---------------------------------------------------------------------------
# Claude Code account switching (CLAUDE_CONFIG_DIR)
#
#   claude-<name>         launch Claude Code as that account (auto-generated)
#   Use-ClaudeAccount     switch this shell without launching
#   Get-ClaudeAccount     show the current account and list available ones
#   Reset-ClaudeAccount   go back to the default ~/.claude
#   Rename-ClaudeAccount  rename an account and its launchers
#   Remove-ClaudeAccount  delete an account (unlinks junctions first)
#
# A shell that has never called these uses the original ~/.claude.
#
# To add an account:
#   .\setup-claude-accounts.ps1 -Accounts claude1 -SeedInto ''
# then open a new shell (or run Register-ClaudeAccountFunctions) and /login.
#
# A rename only affects THIS shell. Others keep the launchers they loaded at
# startup - open a new shell after renaming.
# ---------------------------------------------------------------------------

# Keep this literal identical to setup-claude-accounts.ps1's copy.
# tests/Set-ClaudeAccountName.Tests.ps1 asserts they match.
$script:ClaudeInvalidNameClass = '[\\/:*?"<>|\[\]]'

function Get-ClaudeAccountDir {
    # An account dir always has a projects/ entry. This filters out unrelated
    # ~/.claude-* dirs such as .claude-mem (claude-mem plugin data), and the
    # leftover legacy ~/.claude-shared store that migration leaves on disk.
    Get-ChildItem -Path $HOME -Directory -Filter '.claude-*' -Force |
        Where-Object {
            $_.Name -ne '.claude-shared' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'projects'))
        }
}

# Callers that act on the result must pass -ErrorAction Stop: this writes a
# non-terminating error, so execution otherwise continues past the failure.
function Use-ClaudeAccount {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Name)

    $dir = Join-Path $HOME ".claude-$Name"
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Error "No config dir for account '$Name' ($dir). Run setup-claude-accounts.ps1 first."
        return
    }
    $env:CLAUDE_CONFIG_DIR = $dir
    Write-Host "claude account: $Name" -ForegroundColor Cyan
}

function Test-ClaudeSharedMemory {
    # Is this account's CLAUDE.md the same file as the shared one? Hardlinks
    # are symmetric - every name for an inode is an equal name, with no
    # "original" among them - so FileInfo.Target lists all the OTHER names, and
    # the shared store's name is what we look for there.
    #
    # setup-claude-accounts.ps1 has its own, fuller version of this test. The
    # duplication is deliberate: dot-sourcing that script from here would run a
    # whole setup routine every time a shell opens.
    param([Parameter(Mandatory = $true)][string] $AccountDir)

    $link   = Join-Path $AccountDir 'CLAUDE.md'
    $shared = Join-Path $HOME '.claude\CLAUDE.md'
    if (-not (Test-Path -LiteralPath $link -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) { return $false }

    $item = Get-Item -LiteralPath $link -Force
    if ($item.LinkType -ne 'HardLink') { return $false }

    $sharedFull = (Get-Item -LiteralPath $shared -Force).FullName
    foreach ($peer in @($item.Target)) {
        if ([string]::IsNullOrWhiteSpace($peer)) { continue }
        # Peers can arrive volume-relative. A hardlink cannot cross volumes, so
        # the link's own drive is always the one to put back.
        if ($peer -notmatch '^[A-Za-z]:\\' -and $peer -notmatch '^\\\\') {
            $peer = (Split-Path -Qualifier $item.FullName) + $peer
        }
        if ($peer -eq $sharedFull) { return $true }
    }
    return $false
}

function Get-ClaudeAccount {
    if ([string]::IsNullOrEmpty($env:CLAUDE_CONFIG_DIR)) {
        Write-Host "current: (default) $(Join-Path $HOME '.claude')" -ForegroundColor DarkGray
    } else {
        $name = (Split-Path $env:CLAUDE_CONFIG_DIR -Leaf) -replace '^\.claude-', ''
        Write-Host "current: $name  ->  $env:CLAUDE_CONFIG_DIR" -ForegroundColor Cyan
    }

    # Only worth reporting on when shared memory is set up at all. Without this
    # gate, anyone who left CLAUDE.md out of -SharedFiles gets every account
    # flagged for a thing they chose.
    $memoryIsShared = Test-Path -LiteralPath (Join-Path $HOME '.claude\CLAUDE.md') -PathType Leaf

    Write-Host "available:"
    Get-ClaudeAccountDir | ForEach-Object {
        $n = $_.Name -replace '^\.claude-', ''

        $tags = @()
        if (-not (Test-Path -LiteralPath (Join-Path $_.FullName '.credentials.json'))) {
            $tags += 'not logged in'
        }
        # An editor that saves by writing a new file and renaming it over the
        # old one breaks the hardlink, and nothing else would ever say so: the
        # account keeps a perfectly good CLAUDE.md that no longer follows the
        # shared one. Re-run setup-claude-accounts.ps1 to relink.
        if ($memoryIsShared -and -not (Test-ClaudeSharedMemory -AccountDir $_.FullName)) {
            $tags += 'CLAUDE.md not shared'
        }

        if ($tags.Count -gt 0) { $tag = "  ($($tags -join ', '))" } else { $tag = '' }
        Write-Host ("  $n$tag")
    }
}

function Reset-ClaudeAccount {
    Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    Write-Host "claude account: (default) $(Join-Path $HOME '.claude')" -ForegroundColor DarkGray
}

function Get-ClaudeCommandLiteral {
    # Command lookup by LITERAL name. Get-Command -Name takes a wildcard, so
    # it cannot see a function genuinely called a[1] - and NTFS is happy to
    # host a .claude-a[1] account.
    param([Parameter(Mandatory = $true)][string] $Name)
    return $ExecutionContext.InvokeCommand.GetCommand($Name, 'All')
}

function Test-OurLauncher {
    # "Is the command <Name> one of our generated launchers?" - and nothing
    # else. It cannot answer "would <Name> collide?", because a colliding
    # account's own launcher IS ours. See Rename-ClaudeAccount guard 8.
    param([Parameter(Mandatory = $true)][string] $Name)

    $cmd = Get-ClaudeCommandLiteral -Name $Name
    return [bool]($cmd -and
                  $cmd.CommandType -eq 'Function' -and
                  $cmd.Definition -match 'Use-ClaudeAccount')
}

function Unregister-ClaudeAccountLaunchers {
    # Drops both launchers for an account.
    # Removal uses function:<name> with NO global: prefix - the prefix makes
    # Remove-Item silently no-op on a bracket-containing name even with
    # -LiteralPath. Dropping it still removes the global entry from here.
    param([Parameter(Mandatory = $true)][string] $Name)

    # SilentlyContinue covers "there was no such launcher", which is normal -
    # a bracket-named account may never have had one, and the bare launcher is
    # skipped whenever it would shadow something. It must NOT be allowed to
    # cover "the removal did nothing", which is the exact silent no-op this
    # helper exists to fix, so each removal is verified.
    $wanted = @("claude-$Name")
    if (Test-OurLauncher -Name $Name) { $wanted += $Name }

    foreach ($fn in $wanted) {
        Remove-Item -LiteralPath "function:$fn" -ErrorAction SilentlyContinue

        # -eq against the drive, not Get-Command -Name, which reports a
        # bracket-named function as absent whether or not it survived.
        $survived = @(Get-ChildItem function: | Where-Object { $_.Name -eq $fn })
        if ($survived.Count -gt 0) {
            Write-Error "Could not remove the launcher '$fn'; it is still defined."
        }
    }
}

function Remove-ClaudeAccount {
    # Deletes one account. Never use plain Remove-Item -Recurse on an account
    # dir: it can follow the junctions and delete the SHARED store behind them.
    #
    # The account's hardlinked CLAUDE.md needs no such care and is deliberately
    # not in the unlink loop below - a hardlink is not a reparse point, and
    # deleting one name for an inode never touches the others.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string] $Name)

    $dir = Join-Path $HOME ".claude-$Name"
    if ($Name -eq 'shared') { Write-Error "Refusing to remove the shared store."; return }
    if (-not (Test-Path -LiteralPath $dir)) { Write-Error "No such account: $Name"; return }

    if (-not $PSCmdlet.ShouldProcess($dir, 'Remove Claude account')) { return }

    # Unlink every junction FIRST - rmdir removes the link, never the target.
    Get-ChildItem -LiteralPath $dir -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        ForEach-Object {
            cmd /c rmdir "$($_.FullName)" | Out-Null
            Write-Host "  unlinked $($_.Name)" -ForegroundColor DarkGray
        }

    $left = @(Get-ChildItem -LiteralPath $dir -Force -Recurse |
              Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($left.Count -gt 0) { Write-Error "Reparse points remain, aborting: $($left[0].FullName)"; return }

    Remove-Item -LiteralPath $dir -Recurse -Force
    Unregister-ClaudeAccountLaunchers -Name $Name
    if ($env:CLAUDE_CONFIG_DIR -eq $dir) { Reset-ClaudeAccount }
    Write-Host "removed account '$Name'" -ForegroundColor Green
}

function Rename-ClaudeAccount {
    # Renames ~/.claude-<Name> to ~/.claude-<NewName> in place. The directory
    # is the only record of an account's name - there is no alias layer.
    # No ConfirmImpact: a rename is reversible and must not prompt.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string] $Name,
        [Parameter(Mandatory = $true, Position = 1)][string] $NewName
    )

    $src = Join-Path $HOME ".claude-$Name"
    $dst = Join-Path $HOME ".claude-$NewName"

    # ------------------------------------------------------- source --------

    if ($Name -eq 'shared') {
        Write-Error "Refusing to rename the shared store (~/.claude-shared)."
        return
    }

    # Get-ClaudeAccountDir, not Test-Path: a bare Test-Path admits the leftover
    # legacy ~/.claude-shared store (which old junctions may still target) and
    # ~/.claude-mem.
    $account = Get-ClaudeAccountDir | Where-Object { $_.Name -eq ".claude-$Name" }
    if (-not $account) {
        # Test-Path here picks the MESSAGE, never decides existence. One
        # message cannot serve both: the projects/ wording asserts a directory
        # exists, which sends a user who mistyped hunting for a missing folder.
        if (Test-Path -LiteralPath $src) {
            Write-Error ("'$Name' is not a recognised account: $src has no projects/ entry. " +
                         "An account created without a shared 'projects' becomes renameable " +
                         "once Claude Code has run in it once.")
        } else {
            Write-Error "No such account: $Name"
        }
        return
    }

    # -------------------------------------------------- destination --------

    if ($NewName -match $script:ClaudeInvalidNameClass) {
        Write-Error "Invalid account name (path characters or brackets): '$NewName'"
        return
    }
    # Windows silently normalises these, so the directory created would not be
    # the one requested - which would defeat the already-exists guard below.
    if ($NewName -match '^\s|\s$|\.$') {
        Write-Error ("Invalid account name (leading or trailing whitespace, or a trailing dot): " +
                     "'$NewName'. Windows would silently create a differently-named directory.")
        return
    }
    if ($NewName -eq 'shared') {
        Write-Error "'shared' is reserved for the shared store."
        return
    }
    # -eq is case-insensitive, so this also rejects work -> Work. It must
    # precede the exists check, which would otherwise report "already exists".
    if ($Name -eq $NewName) {
        Write-Error "'$Name' and '$NewName' are the same name. Case-only renames are not supported."
        return
    }
    if (Test-Path -LiteralPath $dst) {
        Write-Error "Already exists: $dst"
        return
    }

    # Two independent collision checks. Collapsing them into one
    # Test-OurLauncher call silently drops the second.
    #
    # Scope note: this contains the hazard within rename. Register-Claude-
    # AccountFunctions still registers the prefixed launcher unconditionally,
    # so setup-claude-accounts.ps1 can still manufacture the same collision.
    # Adding the check there would leave a colliding account with NO launcher
    # at all - worse than today, and a change affecting accounts this feature
    # never touches. Deliberate; do not "fix" it here.
    $clash = Get-ClaudeCommandLiteral -Name "claude-$NewName"
    if ($clash -and -not (Test-OurLauncher -Name "claude-$NewName")) {
        Write-Error ("Renaming to '$NewName' would overwrite an existing " +
                     "$($clash.CommandType) named 'claude-$NewName'.")
        return
    }
    # An account literally called claude-<NewName> already wants that bare
    # launcher. Test-OurLauncher cannot express this: that launcher IS ours,
    # so the predicate says "fine" exactly when the collision is real.
    #
    # A plain directory test, deliberately wider than Get-ClaudeAccountDir:
    # a ~/.claude-claude-<NewName> that has no projects/ entry yet generates no
    # launcher TODAY, but gains one the moment Claude Code runs in it, and the
    # collision would then appear with nothing to announce it. The message
    # below therefore describes the directory, and does not claim a launcher
    # exists - it may not.
    #
    # -ne $src is essential: when renaming claude-foo -> foo, the directory
    # this test finds IS the source, which is about to stop existing. Without
    # it, undoing an accidentally claude-prefixed name is impossible.
    $prefixedDir = Join-Path $HOME ".claude-claude-$NewName"
    if ((Test-Path -LiteralPath $prefixedDir) -and ($prefixedDir -ne $src)) {
        Write-Error ("~/.claude-claude-$NewName exists, so the bare launcher name " +
                     "'claude-$NewName' is already spoken for and would collide with " +
                     "this account's prefixed launcher. Rename or remove that " +
                     "directory first, or pick a different name.")
        return
    }

    # The same collision from the other side: renaming to claude-foo while an
    # account foo exists. Then foo's PREFIXED launcher and claude-foo's BARE
    # launcher are both called 'claude-foo', and Get-ChildItem ordering decides
    # which one you get - silently, and on the wrong credentials.
    if ($NewName -like 'claude-*') {
        $strippedDir = Join-Path $HOME ".claude-$($NewName -replace '^claude-', '')"
        if ((Test-Path -LiteralPath $strippedDir) -and ($strippedDir -ne $src)) {
            Write-Error ("Renaming to '$NewName' would make its bare launcher collide with " +
                         "the prefixed launcher of the account " +
                         "'$($NewName -replace '^claude-', '')'. Both would be called " +
                         "'$NewName'. Pick a name that does not start with 'claude-'.")
            return
        }
    }

    # ------------------------------------------------ this shell? ----------

    # Computed BEFORE the rename on purpose: afterwards $src no longer exists
    # and Resolve-Path throws instead of returning anything to compare, so a
    # post-rename check can never match and every affected shell gets reset.
    $shellIsOnThisAccount = $false
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_CONFIG_DIR)) {
        # Compare RESOLVED paths: a variable exported by hand as
        # %USERPROFILE%\.claude-work, or via a mapped drive, is the same
        # directory spelled differently.
        $current     = Resolve-Path -LiteralPath $env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        $srcResolved = Resolve-Path -LiteralPath $src -ErrorAction SilentlyContinue

        # A variable that does not resolve was already dangling before we
        # started - not this command's to repair.
        if ($current -and $srcResolved) {
            # Resolution is not normalisation: Resolve-Path keeps a trailing
            # separator, so 'C:\x\' and 'C:\x' compare unequal without this.
            $shellIsOnThisAccount = ($current.Path.TrimEnd('\', '/') -eq
                                     $srcResolved.Path.TrimEnd('\', '/'))
        }
    }

    # -------------------------------------------------------- gate ---------

    # SupportsShouldProcess alone is not -WhatIf support. Rename-Item honours
    # -WhatIf by preference propagation, but a variable assignment and a
    # success message do not.
    if (-not $PSCmdlet.ShouldProcess($src, "Rename to .claude-$NewName")) { return }

    # ------------------------------------------------------ rename ---------

    try {
        Rename-Item -LiteralPath $src -NewName ".claude-$NewName" -ErrorAction Stop
    } catch {
        # Do not assert a cause: Rename-Item also fails on permissions, path
        # length and I/O errors.
        Write-Error ("Could not rename $src`n" +
                     "  $($_.Exception.Message)`n" +
                     "  If the account is in use, close every Claude Code session on it first. " +
                     "Renaming an account with a live session can also resurrect the old name " +
                     "as a phantom account whose transcripts no account can see - see the README.")
        return
    }

    # ------------------------------------------------------ after ----------

    Unregister-ClaudeAccountLaunchers -Name $Name
    Register-ClaudeAccountFunctions

    if ($shellIsOnThisAccount) {
        # No existence re-check on $dst. Control only reaches here because
        # Rename-Item completed without throwing, which means $dst is exactly
        # the directory it just created. The spec's belt-and-braces
        # Reset-ClaudeAccount fallback is unreachable, and leaving it in would
        # tell the next reader that Rename-Item can succeed without producing
        # its destination.
        $env:CLAUDE_CONFIG_DIR = $dst
    }

    # Name the launchers that actually exist. The bare one is skipped when it
    # would shadow an existing command, and only via Write-Verbose - a flat
    # "renamed" leaves the user typing a name that belongs to something else.
    $launchers = "claude-$NewName"
    if (Test-OurLauncher -Name $NewName) { $launchers += " and $NewName" }

    Write-Host "renamed '$Name' -> '$NewName'  (launchers: $launchers)" -ForegroundColor Green
    Write-Host "  other open shells still have the old launchers - open a new shell." -ForegroundColor DarkGray
}

function Register-ClaudeAccountFunctions {
    # Generate launchers per account, so adding an account needs no edit here -
    # just open a new shell or re-run this function.
    #   claude-<name>  always defined (unambiguous form)
    #   <name>         also defined, unless it would shadow a real command
    Get-ClaudeAccountDir | ForEach-Object {
        $name = $_.Name -replace '^\.claude-', ''

        # Double the apostrophes. Inside a single-quoted PowerShell literal
        # nothing interpolates, so once the quote cannot be closed early,
        # $ ` and ; in an account name are inert.
        $safe = $name -replace "'", "''"

        # -ErrorAction Stop: a stale launcher must abort. Without it,
        # Use-ClaudeAccount writes the error and `claude` still runs, on
        # whatever config dir the shell happens to hold.
        $body = [scriptblock]::Create("Use-ClaudeAccount '$safe' -ErrorAction Stop; claude @args")

        # -LiteralPath: Set-Item -Path "function:global:a[1]" reports success
        # and creates nothing.
        Set-Item -LiteralPath "function:global:claude-$name" -Value $body

        # Never clobber an existing command (the real `claude`, `git`, ...).
        # Our own previously-generated function is fine to redefine.
        $existing = Get-ClaudeCommandLiteral -Name $name

        if (-not $existing -or (Test-OurLauncher -Name $name)) {
            Set-Item -LiteralPath "function:global:$name" -Value $body
        } else {
            Write-Verbose "Skipping bare launcher '$name': shadows an existing $($existing.CommandType)."
        }
    }
}

Register-ClaudeAccountFunctions
