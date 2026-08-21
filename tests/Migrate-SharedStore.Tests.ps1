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
