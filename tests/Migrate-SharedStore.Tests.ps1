BeforeAll {
    . "$PSScriptRoot\Fixtures.ps1"
}

Describe 'migration tests are isolated from the real machine' {
    It 'never lets $PROFILE point outside the fake home' {
        # install.ps1 writes to $PROFILE, and $PROFILE does NOT follow $HOME -
        # it is fixed at session start from the Documents path. If this ever
        # regresses, the suite rewrites the developer's real profile to
        # dot-source a temp path that teardown then deletes.
        $real = $PROFILE
        $fake = New-LegacyFakeHome
        try {
            $PROFILE | Should -Not -Be $real
            $PROFILE.StartsWith($fake, 'OrdinalIgnoreCase') | Should -BeTrue
        } finally {
            Remove-LegacyFakeHome -Path $fake
        }
        $PROFILE | Should -Be $real
    }
}

Describe 'migrate-shared-store.ps1 discovery' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    It 'finds accounts junctioned into the legacy store' {
        $null = New-LegacyAccount -Name work
        $null = New-LegacyAccount -Name personal

        $out = & $script:Script -DryRun 6>&1 | Out-String -Width 500

        $out | Should -Match '\.claude-work'
        $out | Should -Match '\.claude-personal'
    }

    It 'ignores a ~/.claude-* directory that is not an account' {
        # .claude-mem is plugin data: no projects/ entry and no junction into
        # the legacy store, so neither discovery clause can match it.
        $null = New-LegacyAccount -Name work
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FakeHome '.claude-mem') -Force

        $out = & $script:Script -DryRun 6>&1 | Out-String -Width 500

        $out | Should -Not -Match '\.claude-mem'
    }

    It 'still finds an account whose only junction was already removed' {
        # The interrupted-Phase-2 case: rmdir succeeded, mklink never ran. The
        # narrow rule would skip exactly the account that needs repair.
        $null = New-LegacyAccount -Name work -Dirs @('projects')
        cmd /c rmdir "$(Join-Path $script:FakeHome '.claude-work\projects')" | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\.migrate-shared-store.state') `
                    -Value (Join-Path $script:FakeHome '.claude-work')

        $out = & $script:Script -DryRun 6>&1 | Out-String -Width 500

        $out | Should -Match '\.claude-work'
    }

    It 'writes nothing under -DryRun' {
        $acct = New-LegacyAccount -Name work
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\projects\only-legacy.txt') -Value 'x'

        $null = & $script:Script -DryRun 6>&1

        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\projects\only-legacy.txt') | Should -BeFalse
        (Get-Item -LiteralPath (Join-Path $acct 'projects') -Force).Target |
            Should -Match 'claude-shared'
    }
}

Describe 'migrate-shared-store.ps1 preflight' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    It 'aborts on a divergent account CLAUDE.md without mutating anything' {
        # Editor replace-on-save turns a hardlink into a plain file. If that
        # divergence is not caught up front, Phase 2 retargets the junctions and
        # THEN setup's New-FileLink throws - leaving a half-migrated machine
        # that every re-run fails on identically.
        $acct = New-LegacyAccount -Name work
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'store memory'
        Set-Content -LiteralPath (Join-Path $acct 'CLAUDE.md') -Value 'DIVERGENT account memory'

        { & $script:Script 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*CLAUDE.md*'

        # Nothing mutated: the junction still points at the legacy store and
        # discovery did not persist its interruption manifest.
        (Get-Item -LiteralPath (Join-Path $acct 'projects') -Force).Target |
            Should -Match 'claude-shared'
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\.migrate-shared-store.state') |
            Should -BeFalse
    }

    It 'accepts an account whose CLAUDE.md is a true hardlink peer' {
        $acct = New-LegacyAccount -Name work
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'store memory'
        $null = cmd /c mklink /H "$acct\CLAUDE.md" "$(Join-Path $script:FakeHome '.claude\CLAUDE.md')"

        { & $script:Script -DryRun 6>&1 | Out-Null } | Should -Not -Throw
    }

    It 'accepts an account with no CLAUDE.md at all' {
        $null = New-LegacyAccount -Name work
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'store memory'

        { & $script:Script -DryRun 6>&1 | Out-Null } | Should -Not -Throw
    }

    It 'aborts when only the LEGACY CLAUDE.md has diverged' {
        # The easiest copy to lose: Phase 1 skips CLAUDE.md entirely, so unique
        # content here is never merged, and a clean run would then declare the
        # legacy store safe to delete. ~/.claude-shared/CLAUDE.md is the live
        # shared-memory path today, so it is the likeliest one an editor
        # replaced on save.
        $acct = New-LegacyAccount -Name work
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'store memory'
        $null = cmd /c mklink /H "$acct\CLAUDE.md" "$(Join-Path $script:FakeHome '.claude\CLAUDE.md')"
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\CLAUDE.md') `
                    -Value 'DIVERGENT legacy memory nobody else has'

        { & $script:Script 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*CLAUDE.md*'

        (Get-Item -LiteralPath (Join-Path $acct 'projects') -Force).Target |
            Should -Match 'claude-shared'
    }
}

Describe 'migrate-shared-store.ps1 merge' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
        $null = New-LegacyAccount -Name work
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    It 'copies a file that exists only in the legacy store' {
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\skills\only-legacy.md') -Value 'legacy'

        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\skills\only-legacy.md') |
            Should -Be 'legacy'
    }

    It 'keeps the store copy when a non-transcript file differs' {
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\skills\both.md') -Value 'legacy'
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\skills\both.md')        -Value 'store'

        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\skills\both.md') | Should -Be 'store'
    }

    It 'lets the legacy plugins registry win, including overwrites' {
        # plugins/ is a registry plus a content tree that must stay internally
        # consistent. Never-overwrite would keep a stale registry and leave the
        # freshly copied plugin trees unregistered.
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\plugins\installed_plugins.json') -Value '{"new":1}'
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\plugins\installed_plugins.json')        -Value '{"old":1}'

        & $script:Script 6>&1 | Out-Null

        Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\plugins\installed_plugins.json') |
            Should -Be '{"new":1}'
    }

    It 'copies bin/ and statusline.sh into the store' {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FakeHome '.claude-shared\bin') -Force
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\bin\claude-account-profile.ps1') -Value '# p'
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\statusline.sh') -Value '#!/bin/bash'

        & $script:Script 6>&1 | Out-Null

        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\bin\claude-account-profile.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\statusline.sh')                  | Should -BeTrue
    }
}
