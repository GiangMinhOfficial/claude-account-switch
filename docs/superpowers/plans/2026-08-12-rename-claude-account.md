# Rename-ClaudeAccount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Rename-ClaudeAccount <old> <new>` to `claude-account-profile.ps1`, renaming `~/.claude-<old>` to `~/.claude-<new>` in place and regenerating the launchers, with the provider-safety and fail-fast fixes the rename depends on.

**Architecture:** The account directory stays the only source of truth for a name — no alias layer, no rename log, no compatibility junction. Rename is guard-heavy and does exactly one mutation (`Rename-Item -LiteralPath`), then swaps launchers through two helpers extracted from `Remove-ClaudeAccount`. Every `function:` provider call uses `-LiteralPath`, and every launcher *lookup* avoids `Get-Command -Name`, because both treat `[` and `]` as wildcards while NTFS treats them as ordinary characters.

**Tech Stack:** Windows PowerShell 5.1, Pester 5, NTFS directory junctions (`mklink /J`), `cmd /c rmdir`.

## Global Constraints

- **Target shell:** Windows PowerShell 5.1 (`5.1.22621.6931` on the dev machine). No PowerShell 7-only syntax.
- **Invalid-name class, verbatim, in both files:** `[\\/:*?"<>|\[\]]`
- **Constant name, identical in both files:** `ClaudeInvalidNameClass` (`$script:` in the profile, plain `$` in the setup script). `tests/Set-ClaudeAccountName.Tests.ps1` extracts both by regex and compares them.
- **Never `Get-Command -Name` for a launcher lookup.** `-Name` takes a wildcard, so it cannot see a function genuinely called `a[1]`. Use `$ExecutionContext.InvokeCommand.GetCommand($n, 'All')` (wrapped as `Get-ClaudeCommandLiteral`), `Get-Item -LiteralPath "function:<n>"`, or drive enumeration compared with `-eq`.
- **Never `Remove-Item "function:global:<n>"`.** The `global:` prefix defeats removal of a bracket name even with `-LiteralPath`. Removals use `function:<n>` with no prefix — verified to still remove the global entry when called from inside a helper function.
- **Writes to the `function:` drive always use `Set-Item -LiteralPath`.** `Set-Item -Path "function:global:a[1]"` reports success and creates nothing.
- **Never `Remove-Item -Recurse` an account directory without unlinking its junctions first** (`cmd /c rmdir`). PowerShell 5.1 recurses through the junction and empties the shared store. This applies to test teardown *and* mid-test cleanup.
- **`Rename-ClaudeAccount` does not set `ConfirmImpact = 'High'`.** A rename is reversible; it must not prompt.
- **Every guard is `Write-Error` + `return`.** No silent failure, no `throw` in the profile.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `claude-account-profile.ps1` | Modify | The name-class constant, three new helpers, hardened `Register-ClaudeAccountFunctions`, rewired `Remove-ClaudeAccount`, new `Rename-ClaudeAccount` |
| `setup-claude-accounts.ps1` | Modify | Its own copy of the name class + a trailing-dot guard |
| `tests/Fixtures.ps1` | Create | Fake-`$HOME` fixture helpers shared by the rename tests |
| `tests/Rename-ClaudeAccount.Tests.ps1` | Create | Pester 5 coverage of the helpers, the launcher hardening, and rename |
| `tests/Set-ClaudeAccountName.Tests.ps1` | Create | Pester 5 coverage of the setup script's name validation + the anti-drift check |
| `README.md` | Modify | Usage row, Rename subsection, two behaviour-change notes, Testing section |

## Deviations from the spec (read before starting)

Two things in the spec do not survive contact with the source. Both are resolved here; do not "fix" them back.

1. **The setup script cannot reject leading/trailing whitespace.** `setup-claude-accounts.ps1:52-59` runs every name through `Split-ListArg`, which calls `.Trim()` before validation — so a whitespace-edged name never reaches the guard. Writing that guard would be dead code. **Resolution:** the setup script guards the trailing dot only; test 11 asserts whitespace is *normalised* rather than rejected. `Rename-ClaudeAccount` has no such trimming and rejects both, as specified. The README note names only the genuinely newly-rejected inputs.
2. **A third helper is needed.** The spec names `Test-OurLauncher` and `Unregister-ClaudeAccountLaunchers`, but the shadow check in `Register-ClaudeAccountFunctions` and guard 8a both need "does *any* command with this literal name exist?", which `Test-OurLauncher` (a Function-only predicate) cannot answer and `Get-Command -Name` answers wrongly for bracket names. **Resolution:** a three-line `Get-ClaudeCommandLiteral` wrapping `$ExecutionContext.InvokeCommand.GetCommand($Name, 'All')` — verified to find `a[1]`, to find `git` as an Application, and to return `$null` for a missing name.
3. **Guard 8b needs two corrections the spec does not state.** As specified — a bare `Test-Path` on `~/.claude-claude-<new>` — it (a) fires on its own source directory, making `Rename-ClaudeAccount claude-foo foo` permanently impossible, which is the one way back from an accidentally prefixed name; and (b) covers only one direction, so renaming *to* `claude-foo` while account `foo` exists ships exactly the collision the guard exists to prevent. **Resolution:** exclude `$src`, and add the mirror check. Both have tests.
4. **The `Reset-ClaudeAccount` belt-and-braces fallback is dropped.** The spec asks for a post-assignment resolve check on `$dst`, but control only reaches that line because `Rename-Item` just created `$dst` — it is unreachable. `CLAUDE.md` §2 forbids error handling for impossible scenarios, and keeping it would imply `Rename-Item` can succeed without producing its destination.

---

### Task 1: Repo bootstrap and Pester 5

The working copy is not a git repository (no `.git`), and the only Pester on this machine is the shipped 3.4.0, which is syntactically incompatible with Pester 5. Every later task commits and runs tests, so both are prerequisites.

**Files:**
- Create: `.git/` (via `git init`)
- Modify: none

**Interfaces:**
- Consumes: nothing
- Produces: a git repo with an initial commit; `Pester` 5.x importable

- [ ] **Step 1: Initialise the repository and commit the current state**

```bash
cd /c/Users/minhgh2/Downloads/claude-account-switch-main
git init
git add -A
git commit -m "chore: initial commit of existing working copy"
```

- [ ] **Step 2: Verify the commit exists**

Run: `git log --oneline`
Expected: one line ending `chore: initial commit of existing working copy`

- [ ] **Step 3: Install Pester 5**

```bash
powershell.exe -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

Two non-obvious requirements, both of which fail confusingly if omitted:
- **TLS 1.2** — PowerShell 5.1 defaults to TLS 1.0/SSL3, which PSGallery refuses. Without it the error is `Unable to resolve package source` or `No match was found for the specified search criteria`, neither of which mentions TLS.
- **`-SkipPublisherCheck`** — the shipped 3.4.0 is Microsoft-signed and blocks the upgrade.

- [ ] **Step 4: Verify Pester 5 is importable, not merely listed**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; (Get-Module Pester).Version.ToString()"`
Expected: a `5.x` version. If it errors, Step 3 silently failed — do not continue, because 3.4.0 cannot parse this plan's test files and its errors look nothing like the red-run failures each task predicts.

Both versions stay installed side by side, which is why every test command in this plan pins the version with `Import-Module Pester -MinimumVersion 5.0` rather than relying on autoloading.

- [ ] **Step 5: Create the branch for this work**

```bash
git checkout -b feat/rename-claude-account
```

---

### Task 2: Launcher helpers, and `Remove-ClaudeAccount` rewired onto them

Extracts the ours/not-ours predicate and the removal pair, fixing the silent no-op on bracket-named launchers in the process. `Remove-ClaudeAccount` is the existing caller; rename becomes the second one in Task 6.

**Files:**
- Create: `tests/Fixtures.ps1`
- Create: `tests/Rename-ClaudeAccount.Tests.ps1`
- Modify: `claude-account-profile.ps1` — insert helpers between `Reset-ClaudeAccount` and `Remove-ClaudeAccount`, then replace the launcher-removal block inside `Remove-ClaudeAccount` (match on the code shown in Step 6, not on line numbers — Step 4 shifts them)

**Interfaces:**
- Consumes: `Get-ClaudeAccountDir`, `Reset-ClaudeAccount` (existing, unchanged)
- Produces:
  - `Get-ClaudeCommandLiteral -Name <string>` → `System.Management.Automation.CommandInfo` or `$null`
  - `Test-OurLauncher -Name <string>` → `[bool]`
  - `Unregister-ClaudeAccountLaunchers -Name <string>` → no output
  - Fixture helpers: `Initialize-FakeHome` → `[string]` path; `New-FixtureAccount -Name <string>` → `[string]` dir; `New-FixtureDirOnly -Name <string>` → `[string]` dir; `Remove-FixtureAccount -Name <string>`; `Get-FunctionNameList` → `[string[]]`; `Test-FunctionExists -Name <string>` → `[bool]`; `Remove-FakeHome -Path <string> -RealHome <string>`

- [ ] **Step 1: Write the fixture helpers**

Create `tests/Fixtures.ps1`:

```powershell
# Fixture helpers for tests/Rename-ClaudeAccount.Tests.ps1.
#
# The fake home is a real temp directory, not TestDrive:, because mklink /J
# cannot resolve a PSDrive path.

function Initialize-FakeHome {
    # Swap $HOME BEFORE dot-sourcing the profile: it calls
    # Register-ClaudeAccountFunctions at load and would otherwise register
    # every real account on this machine.
    $fake = Join-Path ([IO.Path]::GetTempPath()) ("claude-rename-test-" + [guid]::NewGuid().ToString('N'))
    $projects = Join-Path $fake '.claude-shared\projects'
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
    $null = cmd /c mklink /J "$dir\projects" "$(Join-Path $HOME '.claude-shared\projects')"
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
```

- [ ] **Step 2: Write the failing tests for the helpers**

Create `tests/Rename-ClaudeAccount.Tests.ps1`. This is the file every later task appends to, so the header block is set up once here:

```powershell
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . "$PSScriptRoot\Fixtures.ps1"

    $script:RealHome = $HOME
    $script:FakeHome = Initialize-FakeHome

    # Dot-sourced AFTER the fake home is in place. The profile's functions read
    # $HOME at call time, so one dot-source serves every test.
    . "$(Split-Path $PSScriptRoot -Parent)\claude-account-profile.ps1"
}

AfterAll {
    Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome
}

Describe 'Test-OurLauncher' {
    # Cleanup lives in AfterEach, never at the end of an It. Pester abandons
    # the rest of a block on the first failed assertion - and the plan
    # prescribes a red run for every one of these - so inline cleanup would
    # leak stub functions into every test that follows and misattribute the
    # resulting failures.
    AfterEach {
        Remove-TestFunction 'claude-a[1]'
        Remove-TestFunction 'zzstub'
    }

    It 'recognises a bracket-named launcher that Get-Command -Name cannot see' {
        $body = [scriptblock]::Create("Use-ClaudeAccount 'a[1]' -ErrorAction Stop; claude @args")
        Set-Item -LiteralPath "function:global:claude-a[1]" -Value $body

        Test-OurLauncher 'claude-a[1]' | Should -BeTrue
        # Pins the reason this helper exists: the obvious lookup is blind here.
        [bool](Get-Command -Name 'claude-a[1]' -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'rejects a function that is not one of ours' {
        Set-Item -LiteralPath "function:global:zzstub" -Value ([scriptblock]::Create("'not ours'"))
        Test-OurLauncher 'zzstub' | Should -BeFalse
    }

    It 'rejects a name with no command at all' {
        Test-OurLauncher 'zz-definitely-absent' | Should -BeFalse
    }
}

Describe 'Unregister-ClaudeAccountLaunchers' {
    AfterEach {
        Remove-TestFunction 'claude-a[1]'
        Remove-TestFunction 'a[1]'
        Remove-TestFunction 'claude-zzstub'
        Remove-TestFunction 'zzstub'
    }

    It 'removes a bracket-named launcher' {
        $body = [scriptblock]::Create("Use-ClaudeAccount 'a[1]' -ErrorAction Stop; claude @args")
        Set-Item -LiteralPath "function:global:claude-a[1]" -Value $body
        Set-Item -LiteralPath "function:global:a[1]" -Value $body

        Unregister-ClaudeAccountLaunchers -Name 'a[1]'

        # Checked by drive enumeration, never Get-Command -Name, which would
        # report "gone" for a function that is still there.
        Test-FunctionExists 'claude-a[1]' | Should -BeFalse
        Test-FunctionExists 'a[1]' | Should -BeFalse
    }

    It 'leaves a bare name alone when it belongs to something else' {
        Set-Item -LiteralPath "function:global:claude-zzstub" -Value `
            ([scriptblock]::Create("Use-ClaudeAccount 'zzstub' -ErrorAction Stop; claude @args"))
        Set-Item -LiteralPath "function:global:zzstub" -Value ([scriptblock]::Create("'not ours'"))

        Unregister-ClaudeAccountLaunchers -Name 'zzstub'

        Test-FunctionExists 'claude-zzstub' | Should -BeFalse
        Test-FunctionExists 'zzstub' | Should -BeTrue
        zzstub | Should -Be 'not ours'
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: FAIL — `The term 'Test-OurLauncher' is not recognized` and `'Unregister-ClaudeAccountLaunchers' is not recognized`

- [ ] **Step 4: Add the helpers to the profile**

In `claude-account-profile.ps1`, insert after `Reset-ClaudeAccount` (currently ending at line 59) and before `Remove-ClaudeAccount`:

```powershell
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 passed, 0 failed

- [ ] **Step 6: Rewire `Remove-ClaudeAccount` onto the helper**

**Match on the code, not on line numbers** — Step 4 of *this* task inserted ~34 lines above `Remove-ClaudeAccount`, so its original line numbers (86-92) now point into the middle of the helper block you just wrote. Following them literally would delete the body of `Unregister-ClaudeAccountLaunchers` and make it call itself.

Inside `Remove-ClaudeAccount`, find this exact block:

```powershell
    Remove-Item -Path "function:global:claude-$Name" -ErrorAction SilentlyContinue

    # Drop the bare launcher too, but only if it is one of ours.
    $bare = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($bare -and $bare.CommandType -eq 'Function' -and $bare.Definition -match 'Use-ClaudeAccount') {
        Remove-Item -Path "function:global:$Name" -ErrorAction SilentlyContinue
    }
```

and replace all of it with a single call:

```powershell
    Unregister-ClaudeAccountLaunchers -Name $Name
```

`Remove-Item -LiteralPath $dir -Recurse -Force` stays immediately above it and `if ($env:CLAUDE_CONFIG_DIR -eq $dir) { Reset-ClaudeAccount }` immediately below.

- [ ] **Step 7: Verify the profile still loads and the whole suite passes**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 passed, 0 failed

Run: `powershell.exe -NoProfile -Command ". ./claude-account-profile.ps1; (Get-Command Remove-ClaudeAccount).Definition -match 'Unregister-ClaudeAccountLaunchers'"`
Expected: `True`

- [ ] **Step 8: Commit**

```bash
git add tests/Fixtures.ps1 tests/Rename-ClaudeAccount.Tests.ps1 claude-account-profile.ps1
git commit -m "feat: extract Test-OurLauncher and Unregister-ClaudeAccountLaunchers

Fixes the silent no-op removing a bracket-named launcher: the global:
prefix defeats Remove-Item -LiteralPath, and Get-Command -Name cannot
see the function at all."
```

---

### Task 3: Harden `Register-ClaudeAccountFunctions`

Three defects in one function: a stale launcher launches `claude` anyway, an apostrophe in an account name throws at scriptblock creation, and both the write and the shadow check are blind to bracket names.

**Files:**
- Modify: `claude-account-profile.ps1` — `Register-ClaudeAccountFunctions` (find it by name; Task 2 shifted it down the file), plus a comment on `Use-ClaudeAccount`
- Modify: `tests/Rename-ClaudeAccount.Tests.ps1` — append two `Describe` blocks

**Interfaces:**
- Consumes: `Get-ClaudeCommandLiteral`, `Test-OurLauncher` (Task 2)
- Produces: launcher bodies of the exact form `Use-ClaudeAccount '<safe>' -ErrorAction Stop; claude @args`, where `<safe>` is the account name with `'` doubled. Task 6's success report depends on the bare launcher still being skipped when it would shadow a foreign command.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Rename-ClaudeAccount.Tests.ps1`:

```powershell
Describe 'Register-ClaudeAccountFunctions' {
    # All teardown lives here. The stub over the real `claude` in the first
    # test is the dangerous one: removed inline, it would survive the red run
    # this task prescribes and shadow `claude` for the rest of the session.
    AfterEach {
        Remove-TestFunction 'claude'
        Remove-TestFunction 'zzstub'
        foreach ($n in @('stale', "o'clock", 'zzstub', 'plain')) {
            Unregister-ClaudeAccountLaunchers -Name $n
        }
        Get-ChildItem -LiteralPath $HOME -Directory -Filter '.claude-*' -Force |
            Where-Object { $_.Name -ne '.claude-shared' } |
            ForEach-Object { Remove-FixtureAccount -Name ($_.Name -replace '^\.claude-', '') }
    }

    It 'generates a launcher that aborts instead of launching on a missing account' {
        # $global:, not $script: - the stub is a global function, so its own
        # script scope is the global one, and $script: here is Pester's.
        $global:ClaudeWasCalled = $false
        Set-Item -LiteralPath "function:global:claude" -Value `
            ([scriptblock]::Create('$global:ClaudeWasCalled = $true'))

        $null = New-FixtureAccount -Name 'stale'
        Register-ClaudeAccountFunctions
        Remove-FixtureAccount -Name 'stale'

        { claude-stale } | Should -Throw
        $global:ClaudeWasCalled | Should -BeFalse
    }

    It "generates a working launcher for an account named o'clock" {
        $null = New-FixtureAccount -Name "o'clock"
        Register-ClaudeAccountFunctions

        Test-FunctionExists "claude-o'clock" | Should -BeTrue
        Test-OurLauncher "claude-o'clock" | Should -BeTrue
        # The apostrophe must arrive doubled, or the literal closes early.
        (Get-Item -LiteralPath "function:claude-o'clock").Definition |
            Should -Match "Use-ClaudeAccount 'o''clock'"
    }

    It 'does not overwrite a foreign command with the bare launcher' {
        Set-Item -LiteralPath "function:global:zzstub" -Value ([scriptblock]::Create("'not ours'"))
        $null = New-FixtureAccount -Name 'zzstub'

        Register-ClaudeAccountFunctions

        Test-FunctionExists 'claude-zzstub' | Should -BeTrue
        zzstub | Should -Be 'not ours'
        Test-OurLauncher 'zzstub' | Should -BeFalse
    }

    It 'redefines its own previously-generated bare launcher' {
        $null = New-FixtureAccount -Name 'plain'
        Register-ClaudeAccountFunctions
        Register-ClaudeAccountFunctions

        Test-FunctionExists 'plain' | Should -BeTrue
        Test-OurLauncher 'plain' | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: FAIL — the stale-launcher test fails on `$global:ClaudeWasCalled | Should -BeFalse` (the launcher warns and launches anyway); the `o'clock` test fails at `New-FixtureAccount`/`Register-ClaudeAccountFunctions` with a scriptblock parse error

- [ ] **Step 3: Rewrite `Register-ClaudeAccountFunctions`**

Replace the whole `Register-ClaudeAccountFunctions` function in `claude-account-profile.ps1` — from the `function Register-ClaudeAccountFunctions {` line to its closing brace, leaving the bare `Register-ClaudeAccountFunctions` call on the last line of the file alone.

**Locate it by name, not by line number.** It sat at lines 97-121 in the pristine file, but Task 2 inserted a helper block and collapsed six lines into one, so those numbers now point somewhere else.

```powershell
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
```

- [ ] **Step 4: Add the caller contract comment to `Use-ClaudeAccount`**

In `claude-account-profile.ps1`, insert directly above `function Use-ClaudeAccount` (line 26):

```powershell
# Callers that act on the result must pass -ErrorAction Stop: this writes a
# non-terminating error, so execution otherwise continues past the failure.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: PASS — 9 passed, 0 failed

- [ ] **Step 6: Commit**

```bash
git add claude-account-profile.ps1 tests/Rename-ClaudeAccount.Tests.ps1
git commit -m "fix: launchers fail fast, survive apostrophes, and use -LiteralPath

BREAKING: claude-<name> now aborts when its account is missing instead
of warning and launching on the current config dir."
```

---

### Task 4: The invalid-name class, in both files

The class gains brackets. `setup-claude-accounts.ps1` gains a trailing-dot guard. The duplication between the two files is deliberate — sharing the constant would force the setup script to dot-source the profile, which runs `Register-ClaudeAccountFunctions` at load — so a test pins the two literals against drift.

**Files:**
- Modify: `claude-account-profile.ps1` — add the constant near the top
- Modify: `setup-claude-accounts.ps1:61-63`
- Create: `tests/Set-ClaudeAccountName.Tests.ps1`

**Interfaces:**
- Consumes: `Initialize-FakeHome` and `Remove-FakeHome` from `tests/Fixtures.ps1` (Task 2)
- Produces: `$script:ClaudeInvalidNameClass` in the profile, read by Task 5's guard 3. Both files declare the literal as `ClaudeInvalidNameClass = '[\\/:*?"<>|\[\]]'`.

- [ ] **Step 1: Write the failing tests**

Create `tests/Set-ClaudeAccountName.Tests.ps1`:

```powershell
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . "$PSScriptRoot\Fixtures.ps1"

    $script:RepoRoot     = Split-Path $PSScriptRoot -Parent
    $script:SetupScript  = Join-Path $script:RepoRoot 'setup-claude-accounts.ps1'
    $script:ProfileFile  = Join-Path $script:RepoRoot 'claude-account-profile.ps1'

    # A fake home is needed even though -DryRun writes nothing: New-Junction
    # (setup-claude-accounts.ps1:89-93) throws "Refusing to replace real
    # directory with a junction" BEFORE its own -DryRun guard. Against a real
    # home where ~/.claude-work/projects is a plain directory - a state the
    # README's Troubleshooting section documents as common - the accept tests
    # below would fail for a reason that has nothing to do with name validation.
    $script:RealHome = $HOME
    $script:FakeHome = Initialize-FakeHome
}

AfterAll {
    Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome
}

Describe 'setup-claude-accounts.ps1 account name validation' {
    # -DryRun writes nothing: every creation in the script is guarded by it.
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a[1]' }
        @{ Name = 'a]1[' }
        @{ Name = 'a\b'  }
        @{ Name = 'a/b'  }
        @{ Name = 'a:b'  }
        @{ Name = 'a*b'  }
        @{ Name = 'a|b'  }
        @{ Name = '..\evil' }
    ) {
        { & $script:SetupScript -Accounts $Name -NoSeed -DryRun } |
            Should -Throw -ExpectedMessage '*Invalid account name*'
    }

    It 'rejects a trailing dot, which Windows would silently strip' {
        { & $script:SetupScript -Accounts 'work.' -NoSeed -DryRun } |
            Should -Throw -ExpectedMessage '*trailing dot*'
    }

    It "accepts work and o'clock - the apostrophe is deliberately not guarded" {
        # Doubling in the launcher body is a complete fix, so guarding here
        # would only reject names that are already safe. This test exists so a
        # later "tighten the class" edit has to argue with it.
        { & $script:SetupScript -Accounts 'work', "o'clock" -NoSeed -DryRun } |
            Should -Not -Throw
    }

    It 'normalises edge whitespace rather than rejecting it' {
        # Split-ListArg trims before validation - by design, so that
        # -Accounts "a, b" works. The name created still matches the name
        # printed, so nothing is silently mismatched.
        $out = & $script:SetupScript -Accounts ' work ' -NoSeed -DryRun 6>&1
        # Anchored on the line break, NOT on $: -match is not multiline, so $
        # only matches end-of-string and more lines follow this one. The line
        # break still discriminates - an untrimmed name would print ':  work '.
        ($out -join "`n") | Should -Match 'accounts\s+: work\r?\n'
    }
}

Describe 'the duplicated invalid-name class' {
    It 'is identical in both files' {
        # This check replaces the shared constant: sharing it would force the
        # setup script to dot-source the profile, which registers launchers at
        # load. Duplication is fine as long as it cannot drift.
        $pattern = "ClaudeInvalidNameClass\s*=\s*'([^']+)'"

        $setupText   = Get-Content -LiteralPath $script:SetupScript -Raw
        $profileText = Get-Content -LiteralPath $script:ProfileFile -Raw

        $setupMatch   = [regex]::Match($setupText, $pattern)
        $profileMatch = [regex]::Match($profileText, $pattern)

        $setupMatch.Success   | Should -BeTrue -Because 'setup-claude-accounts.ps1 must declare ClaudeInvalidNameClass'
        $profileMatch.Success | Should -BeTrue -Because 'claude-account-profile.ps1 must declare ClaudeInvalidNameClass'

        $profileMatch.Groups[1].Value | Should -BeExactly $setupMatch.Groups[1].Value
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Set-ClaudeAccountName.Tests.ps1 -Output Detailed"`
Expected: FAIL — `a[1]`, `a]1[` and the trailing-dot case do not throw; the drift test fails on `setup-claude-accounts.ps1 must declare ClaudeInvalidNameClass`

- [ ] **Step 3: Update the setup script**

In `setup-claude-accounts.ps1`, replace lines 61-63:

```powershell
foreach ($name in $Accounts) {
    if ($name -match '[\\/:*?"<>|]') { throw "Invalid account name (path characters): '$name'" }
}
```

with:

```powershell
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
```

- [ ] **Step 4: Add the profile's copy of the constant**

In `claude-account-profile.ps1`, insert directly above `function Get-ClaudeAccountDir` (line 16):

```powershell
# Keep this literal identical to setup-claude-accounts.ps1's copy.
# tests/Set-ClaudeAccountName.Tests.ps1 asserts they match.
$script:ClaudeInvalidNameClass = '[\\/:*?"<>|\[\]]'
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Set-ClaudeAccountName.Tests.ps1 -Output Detailed"`
Expected: PASS — 12 passed, 0 failed

- [ ] **Step 6: Verify the rename suite still passes**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed"`
Expected: PASS — 21 passed, 0 failed

- [ ] **Step 7: Commit**

```bash
git add setup-claude-accounts.ps1 claude-account-profile.ps1 tests/Set-ClaudeAccountName.Tests.ps1
git commit -m "feat: reject bracketed and trailing-dot account names

BREAKING: setup-claude-accounts.ps1 now rejects names containing [ or ]
and names ending in a dot. Path characters were already rejected."
```

---

### Task 5: `Rename-ClaudeAccount` — guards, ShouldProcess, and the rename itself

Everything up to and including `Rename-Item`. Launchers and `CLAUDE_CONFIG_DIR` come in Task 6, so after this task a rename moves the directory and leaves the launchers stale — deliberately, and covered by Task 6's tests.

**Files:**
- Modify: `claude-account-profile.ps1` — new function after `Remove-ClaudeAccount`
- Modify: `tests/Rename-ClaudeAccount.Tests.ps1` — append three `Describe` blocks

**Interfaces:**
- Consumes: `Get-ClaudeAccountDir`, `Get-ClaudeCommandLiteral`, `Test-OurLauncher`, `$script:ClaudeInvalidNameClass`
- Produces: `Rename-ClaudeAccount -Name <string> -NewName <string>` (positional: `Rename-ClaudeAccount old new`), `SupportsShouldProcess`, no `ConfirmImpact`. Task 6 extends the tail of this same function.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Rename-ClaudeAccount.Tests.ps1`:

```powershell
Describe 'Rename-ClaudeAccount happy path' {
    BeforeEach {
        # Saved here, not inline in the -WhatIf It: that It asserts three times
        # before it would reach an inline restore, and the plan predicts one of
        # those assertions failing during the red run.
        $script:SavedConfigDir = $env:CLAUDE_CONFIG_DIR
        $null = New-FixtureAccount -Name 'src'
    }
    AfterEach {
        foreach ($n in @('src', 'dst', 'a[1]', 'ok')) {
            Remove-FixtureAccount -Name $n
            Unregister-ClaudeAccountLaunchers -Name $n
        }
        if ($null -eq $script:SavedConfigDir) {
            Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_CONFIG_DIR = $script:SavedConfigDir
        }
    }

    It 'renames the directory' {
        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $HOME '.claude-dst') | Should -BeTrue
    }

    It 'renames a legacy bracket-named account off the bad name' {
        # The one path that actually matters for an account that already has
        # brackets. Task 4 stops new ones being created, so rename is the only
        # way out - and it has to survive Get-ClaudeAccountDir's enumeration,
        # the -eq name match, Rename-Item -LiteralPath and the launcher swap.
        # NB: New-Item has no -LiteralPath in PowerShell 5.1, and does not need
        # one - -Path creates '.claude-a[1]' literally (verified).
        $null = New-FixtureAccount -Name 'a[1]'
        Register-ClaudeAccountFunctions

        Rename-ClaudeAccount -Name 'a[1]' -NewName 'ok'

        Test-Path -LiteralPath (Join-Path $HOME '.claude-a[1]') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $HOME '.claude-ok')   | Should -BeTrue
        Test-FunctionExists 'claude-ok'   | Should -BeTrue
        Test-FunctionExists 'claude-a[1]' | Should -BeFalse
    }

    It 'keeps the projects junction pointing at the shared store, sentinel intact' {
        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        $link = Join-Path $HOME '.claude-dst\projects'
        [bool]((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) |
            Should -BeTrue
        Get-Content -LiteralPath (Join-Path $link 'sentinel.txt') | Should -Be 'shared-store-sentinel'
        # And the real store still has it - proof nothing was copied or cut.
        Get-Content -LiteralPath (Join-Path $HOME '.claude-shared\projects\sentinel.txt') |
            Should -Be 'shared-store-sentinel'
    }

    It 'changes nothing under -WhatIf' {
        $env:CLAUDE_CONFIG_DIR = Join-Path $HOME '.claude-src'

        $out = Rename-ClaudeAccount -Name 'src' -NewName 'dst' -WhatIf 6>&1

        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $HOME '.claude-dst') | Should -BeFalse
        # The assertion that fails without an explicit ShouldProcess call:
        # SupportsShouldProcess alone does not stop a variable assignment.
        $env:CLAUDE_CONFIG_DIR | Should -Be (Join-Path $HOME '.claude-src')
        ($out -join "`n") | Should -Not -Match 'renamed'
    }
}

Describe 'Rename-ClaudeAccount source guards' {
    AfterEach {
        Remove-FixtureAccount -Name 'mem'
        Unregister-ClaudeAccountLaunchers -Name 'mem'
    }

    It 'refuses to rename the shared store' {
        { Rename-ClaudeAccount -Name 'shared' -NewName 'dst' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*shared store*'
        Test-Path -LiteralPath (Join-Path $HOME '.claude-shared') | Should -BeTrue
    }

    It 'names the missing projects/ entry for a directory that is not an account' {
        $null = New-FixtureDirOnly -Name 'mem'

        { Rename-ClaudeAccount -Name 'mem' -NewName 'dst' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*projects*'

        Test-Path -LiteralPath (Join-Path $HOME '.claude-mem') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $HOME '.claude-dst') | Should -BeFalse
    }

    It 'says "No such account" - not the projects/ wording - for a name that does not exist' {
        # Paired with the test above. Either one alone passes against a single
        # catch-all message; together they pin the split.
        $err = { Rename-ClaudeAccount -Name 'nosuch' -NewName 'dst' -ErrorAction Stop } |
            Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'No such account'
        $err.Exception.Message | Should -Not -Match 'projects'
    }
}

Describe 'Rename-ClaudeAccount destination guards' {
    BeforeEach {
        $null = New-FixtureAccount -Name 'src'
    }
    # Pure cleanup, no assertions. A failing Should here would abandon the
    # rest of the block and leak fixtures into every later Describe; the
    # "nothing moved" check therefore lives in each It.
    AfterEach {
        Remove-FixtureAccount -Name 'src'
        Remove-FixtureAccount -Name 'taken'
        Remove-FixtureAccount -Name 'claude-foo'
        Remove-FixtureAccount -Name 'foo'
        foreach ($n in @('src', 'taken', 'claude-foo', 'foo')) {
            Unregister-ClaudeAccountLaunchers -Name $n
        }
        Remove-TestFunction 'claude-foreign'
    }

    It 'rejects <NewName> with its own message' -ForEach @(
        @{ NewName = '..\evil'; Expected = '*Invalid account name*' }
        @{ NewName = 'a[1]';    Expected = '*Invalid account name*' }
        @{ NewName = 'a/b';     Expected = '*Invalid account name*' }
        @{ NewName = 'dst ';    Expected = '*whitespace*' }
        @{ NewName = ' dst';    Expected = '*whitespace*' }
        @{ NewName = 'dst.';    Expected = '*whitespace*' }
        @{ NewName = 'shared';  Expected = '*reserved*' }
        @{ NewName = 'src';     Expected = '*same name*' }
        @{ NewName = 'SRC';     Expected = '*same name*' }
    ) {
        # ..\evil asserts the GUARD's message, not merely that the rename was
        # refused: Rename-Item rejects path-bearing names anyway, so a bare
        # refusal would still pass if the class were weakened to [\/...].
        { Rename-ClaudeAccount -Name 'src' -NewName $NewName -ErrorAction Stop } |
            Should -Throw -ExpectedMessage $Expected

        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeTrue
    }

    It 'rejects a destination directory that already exists' {
        $null = New-FixtureAccount -Name 'taken'

        { Rename-ClaudeAccount -Name 'src' -NewName 'taken' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Already exists*'

        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeTrue
    }

    It 'rejects a destination whose prefixed launcher would clobber a foreign command' {
        Set-Item -LiteralPath "function:global:claude-foreign" -Value ([scriptblock]::Create("'not ours'"))

        { Rename-ClaudeAccount -Name 'src' -NewName 'foreign' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*would overwrite*'

        claude-foreign | Should -Be 'not ours'
        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeTrue
    }

    It 'rejects a destination that collides with another account''s bare launcher' {
        # The case Test-OurLauncher cannot catch: .claude-claude-foo's own bare
        # launcher IS ours, so a predicate-based guard answers "fine" and the
        # collision ships. This must be a directory test.
        $null = New-FixtureAccount -Name 'claude-foo'
        Register-ClaudeAccountFunctions

        # '*bare launcher*', not '*already exists*': the destination-exists
        # guard's message would match the looser pattern too, and this test
        # must prove THIS guard fired.
        { Rename-ClaudeAccount -Name 'src' -NewName 'foo' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage "*bare launcher*"

        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeTrue
    }

    It 'rejects the same collision from the other direction' {
        # Renaming TO claude-foo while account foo exists. foo's PREFIXED
        # launcher and claude-foo's BARE launcher would both be 'claude-foo'.
        $null = New-FixtureAccount -Name 'foo'
        Register-ClaudeAccountFunctions

        { Rename-ClaudeAccount -Name 'src' -NewName 'claude-foo' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage "*collide*"

        Test-Path -LiteralPath (Join-Path $HOME '.claude-src') | Should -BeTrue
    }

    It 'still allows undoing an accidentally claude-prefixed name' {
        # Regression test: the .claude-claude-<new> guard finds the SOURCE
        # directory here. Without the -ne $src exclusion this rename is
        # refused forever, and it is the only way back from the mistake.
        Remove-FixtureAccount -Name 'src'
        $null = New-FixtureAccount -Name 'claude-foo'

        Rename-ClaudeAccount -Name 'claude-foo' -NewName 'foo'

        Test-Path -LiteralPath (Join-Path $HOME '.claude-foo')        | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $HOME '.claude-claude-foo') | Should -BeFalse

        # Re-create what BeforeEach made, so AfterEach's teardown is uniform.
        $null = New-FixtureAccount -Name 'src'
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: FAIL — every new test errors with `The term 'Rename-ClaudeAccount' is not recognized`

- [ ] **Step 3: Write `Rename-ClaudeAccount`**

In `claude-account-profile.ps1`, insert after `Remove-ClaudeAccount` and before `Register-ClaudeAccountFunctions`:

```powershell
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

    # Get-ClaudeAccountDir, not Test-Path: a bare Test-Path admits
    # ~/.claude-shared (which every junction targets) and ~/.claude-mem.
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

    Write-Host "renamed '$Name' -> '$NewName'" -ForegroundColor Green
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: PASS — 30 passed, 0 failed

- [ ] **Step 5: Commit**

```bash
git add claude-account-profile.ps1 tests/Rename-ClaudeAccount.Tests.ps1
git commit -m "feat: add Rename-ClaudeAccount guards and the rename itself"
```

---

### Task 6: Launcher swap, `CLAUDE_CONFIG_DIR` repoint, and an accurate success report

The tail of `Rename-ClaudeAccount`. The path comparison is the subtle part: it must be computed *before* `Rename-Item`, because afterwards the old path no longer resolves — and `Resolve-Path` keeps a trailing separator, so both operands need trimming.

**Files:**
- Modify: `claude-account-profile.ps1` — `Rename-ClaudeAccount`, from the ShouldProcess gate down
- Modify: `tests/Rename-ClaudeAccount.Tests.ps1` — append one `Describe`, extend the happy-path `Describe`

**Interfaces:**
- Consumes: `Unregister-ClaudeAccountLaunchers`, `Register-ClaudeAccountFunctions`, `Test-OurLauncher`, `Reset-ClaudeAccount`
- Produces: final behaviour of `Rename-ClaudeAccount`. The success line reads `renamed '<old>' -> '<new>'  (launchers: claude-<new>)` or `... (launchers: claude-<new> and <new>)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Rename-ClaudeAccount.Tests.ps1`:

```powershell
Describe 'Rename-ClaudeAccount launcher swap' {
    BeforeEach {
        $null = New-FixtureAccount -Name 'src'
        Register-ClaudeAccountFunctions
    }
    AfterEach {
        Remove-FixtureAccount -Name 'src'
        Remove-FixtureAccount -Name 'dst'
        Remove-FixtureAccount -Name 'zzstub'
        Unregister-ClaudeAccountLaunchers -Name 'src'
        Unregister-ClaudeAccountLaunchers -Name 'dst'
        Unregister-ClaudeAccountLaunchers -Name 'zzstub'
        Remove-TestFunction 'zzstub'
    }

    It 'creates the new launchers and drops the old ones' {
        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        Test-FunctionExists 'claude-dst' | Should -BeTrue
        # Holds only because 'dst' shadows nothing in this fixture - it is not
        # an unconditional invariant of rename.
        Test-FunctionExists 'dst'        | Should -BeTrue
        Test-FunctionExists 'claude-src' | Should -BeFalse
        Test-FunctionExists 'src'        | Should -BeFalse
    }

    It 'reports only the launchers that actually exist' {
        Set-Item -LiteralPath "function:global:zzstub" -Value ([scriptblock]::Create("'not ours'"))

        $out = (Rename-ClaudeAccount -Name 'src' -NewName 'zzstub' 6>&1) -join "`n"

        Test-FunctionExists 'claude-zzstub' | Should -BeTrue
        zzstub | Should -Be 'not ours'
        $out | Should -Match 'claude-zzstub'
        $out | Should -Not -Match 'and zzstub'
    }
}

Describe 'Rename-ClaudeAccount CLAUDE_CONFIG_DIR handling' {
    BeforeEach {
        $script:SavedConfigDir = $env:CLAUDE_CONFIG_DIR
        $null = New-FixtureAccount -Name 'src'
        $null = New-FixtureAccount -Name 'other'
        Register-ClaudeAccountFunctions
    }
    AfterEach {
        Remove-FixtureAccount -Name 'src'
        Remove-FixtureAccount -Name 'dst'
        Remove-FixtureAccount -Name 'other'
        Unregister-ClaudeAccountLaunchers -Name 'src'
        Unregister-ClaudeAccountLaunchers -Name 'dst'
        Unregister-ClaudeAccountLaunchers -Name 'other'
        if ($null -eq $script:SavedConfigDir) {
            Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_CONFIG_DIR = $script:SavedConfigDir
        }
    }

    It 'repoints this shell when it was on the renamed account' {
        $env:CLAUDE_CONFIG_DIR = Join-Path $HOME '.claude-src'

        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        # Fails against a naive post-rename comparison: by then the old path
        # no longer resolves, so every affected shell would be reset instead.
        $env:CLAUDE_CONFIG_DIR | Should -Be (Join-Path $HOME '.claude-dst')
    }

    It 'repoints when the variable carries a trailing separator' {
        $env:CLAUDE_CONFIG_DIR = (Join-Path $HOME '.claude-src') + '\'

        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        # Resolve-Path alone is not enough here: it returns the trailing
        # backslash intact, so the operands compare unequal without TrimEnd.
        $env:CLAUDE_CONFIG_DIR.TrimEnd('\', '/') | Should -Be (Join-Path $HOME '.claude-dst')
    }

    It 'leaves this shell alone when it was on a different account' {
        $env:CLAUDE_CONFIG_DIR = Join-Path $HOME '.claude-other'

        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        $env:CLAUDE_CONFIG_DIR | Should -Be (Join-Path $HOME '.claude-other')
    }

    It 'leaves an already-dangling variable alone' {
        $env:CLAUDE_CONFIG_DIR = Join-Path $HOME '.claude-was-deleted-long-ago'

        Rename-ClaudeAccount -Name 'src' -NewName 'dst'

        # Resetting someone else's broken variable is not this command's job.
        $env:CLAUDE_CONFIG_DIR | Should -Be (Join-Path $HOME '.claude-was-deleted-long-ago')
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests/Rename-ClaudeAccount.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Test-FunctionExists 'claude-dst'` is `False`, and `$env:CLAUDE_CONFIG_DIR` still holds the old path

- [ ] **Step 3: Record the shell's state before the rename**

In `claude-account-profile.ps1`, inside `Rename-ClaudeAccount`, insert between the last destination guard and the `ShouldProcess` gate:

```powershell
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
```

- [ ] **Step 4: Replace the success message with the launcher swap and report**

In `claude-account-profile.ps1`, replace the last line of `Rename-ClaudeAccount`:

```powershell
    Write-Host "renamed '$Name' -> '$NewName'" -ForegroundColor Green
```

with:

```powershell
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed"`
Expected: PASS — 48 passed, 0 failed (the count is a guide; `0 failed` is the gate)

- [ ] **Step 6: Commit**

```bash
git add claude-account-profile.ps1 tests/Rename-ClaudeAccount.Tests.ps1
git commit -m "feat: swap launchers and repoint CLAUDE_CONFIG_DIR on rename"
```

---

### Task 7: Documentation

Two of the changes shipped above are user-visible behaviour changes to commands people already run. Shipping them unannounced is the "breaking change without warning" the project's guidelines forbid.

**Files:**
- Modify: `README.md` — Usage table, "Adding and removing accounts", Safety notes, new Testing section
- Modify: `claude-account-profile.ps1` — header comment (still the first 14 lines; nothing earlier in the file was touched)

**Interfaces:**
- Consumes: everything from Tasks 2-6
- Produces: nothing consumed by later tasks

**Use the textual anchors, not line numbers.** Each step below inserts text into `README.md`, so every step shifts the ones after it. The anchors ("after the `Remove-ClaudeAccount personal` row", "before `## Troubleshooting`") stay correct; line numbers would not.

Outer fences in Steps 2 and 4 are ```` ```` ```` (four backticks) because the content itself contains a ```` ``` ```` block. Copy the *inside* of the four-backtick fence into the README verbatim, three-backtick blocks included.

- [ ] **Step 1: Add the Usage table row**

In `README.md`, insert after the `Remove-ClaudeAccount personal` row:

```markdown
| `Rename-ClaudeAccount personal work` | Rename an account and its launchers (see below) |
```

- [ ] **Step 2: Add the Rename subsection**

In `README.md`, insert in "Adding and removing accounts" after the `Remove-ClaudeAccount client` block and its blockquote, before the `---`:

````markdown
Rename:

```powershell
Rename-ClaudeAccount personal work
# then open a NEW shell
```

`~/.claude-personal` becomes `~/.claude-work`, the `personal` launchers are dropped
and the `work` ones generated. The junctions inside are absolute paths into
`~/.claude-shared`, so shared history is unaffected. There is no alias layer — the
directory is the account's name.

Three things to know:

- **Other open shells keep the old launchers.** They loaded the profile into memory
  and nothing on disk can change that. Open a new shell after renaming.
- **Do not rename an account that has a live Claude Code session.** Claude Code
  writes and closes rather than holding handles, so the rename usually *succeeds* —
  and the running process, still holding the old `CLAUDE_CONFIG_DIR`, recreates the
  old directory on its next write. That phantom gets a real `projects/` folder
  instead of a junction, so it reappears in `Get-ClaudeAccount` as an account and
  every transcript it writes is invisible from every account, including the renamed
  one. Exit your sessions first.
- **An account configured without a shared `projects` cannot be renamed** until
  Claude Code has run in it once. `Get-ClaudeAccountDir` identifies accounts by
  their `projects/` entry, so such an account has no launchers either — a
  pre-existing limitation of the whole profile, not of rename.
- **Names starting with `claude-` are refused.** An account called `claude-foo`
  would want the bare launcher `claude-foo`, which is already the *prefixed*
  launcher of an account called `foo`. Rename blocks both directions of that
  collision.
````

- [ ] **Step 3: Add the two behaviour-change notes**

In `README.md`, append to the "Safety notes" bullet list:

```markdown
- **`claude-<name>` now fails instead of falling back.** Previously, launching an
  account whose directory was missing printed an error and then started Claude Code
  anyway, under whatever config dir the shell held — dropping you into the wrong
  account. The launcher now aborts. A script that calls `claude-work` will stop
  rather than continue.
- **`setup-claude-accounts.ps1` now rejects two kinds of name it used to accept:**
  names containing `[` or `]`, and names ending in a dot. Bracketed names got no
  launchers at all (PowerShell's `function:` provider reads them as wildcards) while
  reporting success; trailing dots are silently stripped by Windows, so the account
  created was never the one asked for. Path characters (`\ / : * ? " < > |`) were
  already rejected — nothing else changes.
```

- [ ] **Step 4: Add the Testing section**

In `README.md`, insert a new section before `## Troubleshooting`:

````markdown
## Testing

Pester 5 is required. Windows ships 3.4.0, which is syntactically incompatible.
The upgrade needs two things that are easy to miss: TLS 1.2 (PowerShell 5.1
defaults to TLS 1.0, which PSGallery refuses) and `-SkipPublisherCheck` (the
shipped copy is Microsoft-signed).

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

Import-Module Pester -MinimumVersion 5.0    # both versions stay installed
Invoke-Pester -Path tests -Output Detailed
```

The tests run against a temporary fake `$HOME`; they never touch your real accounts.

---
````

- [ ] **Step 5: Re-install the profile**

The repo copy is not the copy your shells load. `install.ps1` copies
`claude-account-profile.ps1` into `~/.claude-shared/bin/` and `$PROFILE` dot-sources
it from *there*, so without this step a new shell still has the old profile —
no `Rename-ClaudeAccount`, and launchers that still fall back instead of failing.

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./install.ps1
```

Expected: `Installed script to C:\Users\<you>\.claude-shared\bin\claude-account-profile.ps1`

(Anyone who installed with `-FromRepo` dot-sources the repo directly and can skip this.)

- [ ] **Step 6: Add the re-install note to the README**

In `README.md`, in the Rename subsection added in Step 2, append to the "Other open shells keep the old launchers" bullet:

```markdown
  If you installed with `.\install.ps1` (the default), re-run it after pulling
  changes — `$PROFILE` loads the copy in `~/.claude-shared/bin/`, not the repo.
```

- [ ] **Step 7: Update the profile header comment**

In `claude-account-profile.ps1`, replace the header comment block — the first 14 lines, from `# ---...` down to and including the closing `# ---...` line — with:

```powershell
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
```

- [ ] **Step 8: Verify the docs match the code**

Run: `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed"`
Expected: PASS — 0 failed

Run: `powershell.exe -NoProfile -Command ". ./claude-account-profile.ps1; Get-Command Rename-ClaudeAccount, Remove-ClaudeAccount, Test-OurLauncher, Unregister-ClaudeAccountLaunchers, Get-ClaudeCommandLiteral | Select-Object -ExpandProperty Name"`
Expected: all five names listed

Confirm the installed copy is the new one:

Run: `powershell.exe -NoProfile -Command "Select-String -Path ~/.claude-shared/bin/claude-account-profile.ps1 -Pattern 'function Rename-ClaudeAccount' -SimpleMatch"`
Expected: one match. No match means Step 5 was skipped.

Read `README.md` and confirm every command named in the new sections exists in the output above.

- [ ] **Step 9: Commit**

```bash
git add README.md claude-account-profile.ps1
git commit -m "docs: document Rename-ClaudeAccount and both behaviour changes"
```

---

## Verification checklist

Run before declaring the work complete:

- [ ] `powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed"` → 48 passed, 0 failed (count is a guide; `0 failed` is the gate)
- [ ] `powershell.exe -NoProfile -Command ". ./claude-account-profile.ps1"` → loads with no output beyond the launchers it registers
- [ ] `powershell.exe -NoProfile -Command ". ./setup-claude-accounts.ps1 -DryRun -NoSeed"` → prints the plan, creates nothing
- [ ] `git status --short` → clean
- [ ] The installed copy is current (Task 7 Step 5 ran): `powershell.exe -NoProfile -Command "Select-String -Path ~/.claude-shared/bin/claude-account-profile.ps1 -Pattern 'function Rename-ClaudeAccount' -SimpleMatch"` → one match
- [ ] Your real accounts still list correctly **in a new shell**: `powershell.exe -Command "Get-ClaudeAccount; Get-Command Rename-ClaudeAccount | Select-Object -ExpandProperty Name"` — deliberately without `-NoProfile`, so it loads `$PROFILE` and therefore the *installed* copy. Without the re-install this is the check that catches it.
