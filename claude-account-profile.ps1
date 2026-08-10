# ---------------------------------------------------------------------------
# Claude Code account switching (CLAUDE_CONFIG_DIR)
#
#   claude-<name>       launch Claude Code as that account (auto-generated)
#   Use-ClaudeAccount   switch this shell without launching
#   Get-ClaudeAccount   show the current account and list available ones
#   Reset-ClaudeAccount go back to the default ~/.claude
#
# A shell that has never called these uses the original ~/.claude.
#
# To add an account:
#   .\setup-claude-accounts.ps1 -Accounts claude1 -SeedInto ''
# then open a new shell (or run Register-ClaudeAccountFunctions) and /login.
# ---------------------------------------------------------------------------

function Get-ClaudeAccountDir {
    # An account dir always has a projects/ entry. This filters out unrelated
    # ~/.claude-* dirs such as .claude-mem (claude-mem plugin data).
    Get-ChildItem -Path $HOME -Directory -Filter '.claude-*' -Force |
        Where-Object {
            $_.Name -ne '.claude-shared' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'projects'))
        }
}

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

function Get-ClaudeAccount {
    if ([string]::IsNullOrEmpty($env:CLAUDE_CONFIG_DIR)) {
        Write-Host "current: (default) $(Join-Path $HOME '.claude')" -ForegroundColor DarkGray
    } else {
        $name = (Split-Path $env:CLAUDE_CONFIG_DIR -Leaf) -replace '^\.claude-', ''
        Write-Host "current: $name  ->  $env:CLAUDE_CONFIG_DIR" -ForegroundColor Cyan
    }

    Write-Host "available:"
    Get-ClaudeAccountDir | ForEach-Object {
        $n = $_.Name -replace '^\.claude-', ''
        $loggedIn = Test-Path -LiteralPath (Join-Path $_.FullName '.credentials.json')
        if ($loggedIn) { $tag = '' } else { $tag = '  (not logged in)' }
        Write-Host ("  $n$tag")
    }
}

function Reset-ClaudeAccount {
    Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    Write-Host "claude account: (default) $(Join-Path $HOME '.claude')" -ForegroundColor DarkGray
}

function Remove-ClaudeAccount {
    # Deletes one account. Never use plain Remove-Item -Recurse on an account
    # dir: it can follow the junctions and delete the SHARED store behind them.
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
    Remove-Item -Path "function:global:claude-$Name" -ErrorAction SilentlyContinue

    # Drop the bare launcher too, but only if it is one of ours.
    $bare = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($bare -and $bare.CommandType -eq 'Function' -and $bare.Definition -match 'Use-ClaudeAccount') {
        Remove-Item -Path "function:global:$Name" -ErrorAction SilentlyContinue
    }
    if ($env:CLAUDE_CONFIG_DIR -eq $dir) { Reset-ClaudeAccount }
    Write-Host "removed account '$Name'" -ForegroundColor Green
}

function Register-ClaudeAccountFunctions {
    # Generate launchers per account, so adding an account needs no edit here -
    # just open a new shell or re-run this function.
    #   claude-<name>  always defined (unambiguous form)
    #   <name>         also defined, unless it would shadow a real command
    Get-ClaudeAccountDir | ForEach-Object {
        $name = $_.Name -replace '^\.claude-', ''
        $body = [scriptblock]::Create("Use-ClaudeAccount '$name'; claude @args")

        Set-Item -Path "function:global:claude-$name" -Value $body

        # Never clobber an existing command (the real `claude`, `git`, ...).
        # Our own previously-generated function is fine to redefine.
        $existing = Get-Command -Name $name -ErrorAction SilentlyContinue
        $isOurs = $existing -and
                  $existing.CommandType -eq 'Function' -and
                  $existing.Definition -match 'Use-ClaudeAccount'

        if (-not $existing -or $isOurs) {
            Set-Item -Path "function:global:$name" -Value $body
        } else {
            Write-Verbose "Skipping bare launcher '$name': shadows an existing $($existing.CommandType)."
        }
    }
}

Register-ClaudeAccountFunctions
