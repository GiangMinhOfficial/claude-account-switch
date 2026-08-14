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
