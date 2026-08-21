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
