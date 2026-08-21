# Fixture helpers for tests/Rename-ClaudeAccount.Tests.ps1.
#
# The fake home is a real temp directory, not TestDrive:, because mklink /J
# cannot resolve a PSDrive path.

function Initialize-FakeHome {
    # Swap $HOME BEFORE dot-sourcing the profile: it calls
    # Register-ClaudeAccountFunctions at load and would otherwise register
    # every real account on this machine.
    $fake = Join-Path ([IO.Path]::GetTempPath()) ("claude-rename-test-" + [guid]::NewGuid().ToString('N'))
    # The store IS ~/.claude now - it is both the shared store and the config
    # dir a shell with no CLAUDE_CONFIG_DIR falls back to.
    $projects = Join-Path $fake '.claude\projects'
    $null = New-Item -ItemType Directory -Path $projects -Force
    Set-Content -LiteralPath (Join-Path $projects 'sentinel.txt') -Value 'shared-store-sentinel'

    # LAST, and only once everything above succeeded. Setting it first would
    # leave $HOME pointing at a half-built temp dir if New-Item threw - and
    # BeforeAll would abort before $script:FakeHome was ever assigned, so
    # AfterAll could not put it back.
    Set-Variable -Name HOME -Value $fake -Scope Global -Force
    return $fake
}

function New-FixtureAccount {
    param([Parameter(Mandatory = $true)][string] $Name)
    $dir = Join-Path $HOME ".claude-$Name"
    $null = New-Item -ItemType Directory -Path $dir -Force
    $null = cmd /c mklink /J "$dir\projects" "$(Join-Path $HOME '.claude\projects')"
    return $dir
}

function New-FixtureDirOnly {
    # A ~/.claude-* directory with no projects/ entry - what .claude-mem is.
    param([Parameter(Mandatory = $true)][string] $Name)
    $dir = Join-Path $HOME ".claude-$Name"
    $null = New-Item -ItemType Directory -Path $dir -Force
    return $dir
}

function Remove-FixtureAccount {
    # Unlink every junction FIRST. A plain Remove-Item -Recurse on PowerShell
    # 5.1 follows the junction and empties the shared store, taking the
    # sentinel with it and breaking every test ordered after this one.
    param([Parameter(Mandatory = $true)][string] $Name)
    $dir = Join-Path $HOME ".claude-$Name"
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -Force |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
        ForEach-Object { cmd /c rmdir "$($_.FullName)" | Out-Null }
    Remove-Item -LiteralPath $dir -Recurse -Force
}

function Get-FunctionNameList {
    # Enumerate the drive and compare with -eq. Get-Command -Name takes a
    # wildcard, so it cannot see a function genuinely named a[1].
    return @(Get-ChildItem function: | ForEach-Object { $_.Name })
}

function Test-FunctionExists {
    param([Parameter(Mandatory = $true)][string] $Name)
    return [bool](@(Get-FunctionNameList) -contains $Name)
}

function Remove-TestFunction {
    # No global: prefix - it defeats removal of a bracket name.
    param([Parameter(Mandatory = $true)][string] $Name)
    Remove-Item -LiteralPath "function:$Name" -ErrorAction SilentlyContinue
}

function Remove-FakeHome {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $RealHome
    )
    Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                ForEach-Object { cmd /c rmdir "$($_.FullName)" | Out-Null }
        }
    Set-Variable -Name HOME -Value $RealHome -Scope Global -Force
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-LegacyFakeHome {
    # A fake home in the PRE-merge shape: a real ~/.claude-shared holding the
    # shared dirs, accounts junctioned into it, and a ~/.claude that has its own
    # divergent copies. This is what migrate-shared-store.ps1 consumes.
    #
    # $PROFILE IS SWAPPED TOO, and that is not optional. Migration's Phase 3
    # runs install.ps1, which writes to $PROFILE - and $PROFILE is an automatic
    # variable fixed at session start from the Documents path. It does NOT
    # follow $HOME. Verified: swapping $HOME leaves $PROFILE at
    # C:\Users\<you>\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1.
    # Without this line, running the suite rewrites the developer's REAL profile
    # to dot-source a script inside a temp directory that AfterEach then deletes,
    # breaking every new shell they open.
    $fake = Join-Path ([IO.Path]::GetTempPath()) ("claude-migrate-test-" + [guid]::NewGuid().ToString('N'))
    foreach ($d in @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $fake ".claude-shared\$d") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $fake ".claude\$d") -Force
    }

    $global:ClaudeTestRealHome    = $HOME
    $global:ClaudeTestRealProfile = $PROFILE

    # LAST, so a throw above never leaves either variable pointing at a
    # half-built temp dir.
    Set-Variable -Name HOME    -Value $fake -Scope Global -Force
    Set-Variable -Name PROFILE -Value (Join-Path $fake 'FakeProfile.ps1') -Scope Global -Force
    return $fake
}

function Remove-LegacyFakeHome {
    # Restores BOTH swapped variables before deleting anything, so a throw in
    # the cleanup cannot strand the session pointing at a deleted temp dir.
    param([Parameter(Mandatory = $true)][string] $Path)

    if ($global:ClaudeTestRealHome)    { Set-Variable -Name HOME    -Value $global:ClaudeTestRealHome    -Scope Global -Force }
    if ($global:ClaudeTestRealProfile) { Set-Variable -Name PROFILE -Value $global:ClaudeTestRealProfile -Scope Global -Force }

    Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            # rmdir removes the link, never the target. Remove-Item -Recurse on
            # 5.1 follows junctions and would empty the legacy store.
            Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                ForEach-Object { cmd /c rmdir "$($_.FullName)" | Out-Null }
        }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-LegacyAccount {
    # An account junctioned into the LEGACY store, as a pre-merge machine has.
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string[]] $Dirs = @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins')
    )
    $dir = Join-Path $HOME ".claude-$Name"
    $null = New-Item -ItemType Directory -Path $dir -Force
    foreach ($d in $Dirs) {
        $null = cmd /c mklink /J "$dir\$d" "$(Join-Path $HOME ".claude-shared\$d")"
    }
    return $dir
}
