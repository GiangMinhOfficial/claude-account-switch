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
