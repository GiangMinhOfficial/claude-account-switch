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
        $legacyFile = Join-Path $script:FakeHome '.claude-shared\projects\only-legacy.txt'
        Set-Content -LiteralPath $legacyFile -Value 'x'
        $before = (Get-FileHash -LiteralPath $legacyFile).Hash

        $null = & $script:Script -DryRun -SimulateDriftPath $legacyFile 6>&1

        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\projects\only-legacy.txt') | Should -BeFalse
        (Get-FileHash -LiteralPath $legacyFile).Hash | Should -Be $before
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
        $personal = New-LegacyAccount -Name personal
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'store memory'
        Set-Content -LiteralPath (Join-Path $acct 'CLAUDE.md') -Value 'DIVERGENT account memory'
        Set-Content -LiteralPath (Join-Path $personal 'CLAUDE.md') -Value 'ANOTHER divergent memory'

        $err = { & $script:Script 6>&1 | Out-Null } |
            Should -Throw -ExpectedMessage '*CLAUDE.md*' -PassThru
        @($err.Exception.Message -split "`r?`n" |
            Where-Object { $_ -match '\.claude-(work|personal)\\CLAUDE\.md' }).Count |
            Should -Be 2

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

Describe 'migrate-shared-store.ps1 transcripts' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
        $null = New-LegacyAccount -Name work
        $script:Proj = 'D--demo'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FakeHome ".claude\projects\$($script:Proj)") -Force
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    BeforeAll {
        function Write-Jsonl {
            param([string] $Path, [string[]] $Lines)
            [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"),
                                    (New-Object Text.UTF8Encoding $false))
        }
    }

    It 'skips a legacy transcript the store already supersedes' {
        $id = 'aaaaaaaa-0000-0000-0000-000000000001'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":2}")
        Write-Jsonl -Path $l -Lines @("{`"sessionId`":`"$id`",`"n`":1}")

        & $script:Script 6>&1 | Out-Null

        (Get-Content -LiteralPath $s).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath (Split-Path $s -Parent) -Filter '*.jsonl').Count | Should -Be 1
    }

    It 'adopts a legacy transcript that continues the store copy' {
        $id = 'aaaaaaaa-0000-0000-0000-000000000002'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}")
        Write-Jsonl -Path $l -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":2}")

        & $script:Script 6>&1 | Out-Null

        (Get-Content -LiteralPath $s).Count | Should -Be 2
    }

    It 'refuses to adopt a continuation whose added line is truncated' {
        # A strict line-prefix proves the EARLIER lines were kept, nothing more.
        # A crashed or still-writing transcript ends mid-line and would
        # otherwise overwrite the canonical, valid copy with a broken one.
        $id = 'aaaaaaaa-0000-0000-0000-000000000003'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}")
        Write-Jsonl -Path $l -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`,`"trunc")

        $out = & $script:Script 6>&1 | Out-String -Width 500

        (Get-Content -LiteralPath $s).Count | Should -Be 1
        $out | Should -Match 'conflict'
    }

    It 'rescues a forked transcript under a new session id' {
        $id = 'aaaaaaaa-0000-0000-0000-000000000004'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":2}")
        Write-Jsonl -Path $l -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":99}")

        & $script:Script 6>&1 | Out-Null

        $files = @(Get-ChildItem -LiteralPath (Split-Path $s -Parent) -Filter '*.jsonl')
        $files.Count | Should -Be 2
        $rescued = $files | Where-Object { $_.Name -ne "$id.jsonl" }
        $newId   = [IO.Path]::GetFileNameWithoutExtension($rescued.Name)
        # Every sessionId field carries the NEW id; the original is gone.
        (Get-Content -LiteralPath $rescued.FullName -Raw) | Should -Match ([regex]::Escape($newId))
        (Get-Content -LiteralPath $rescued.FullName -Raw) | Should -Not -Match ([regex]::Escape($id))
        # And the store's own copy is untouched.
        (Get-Content -LiteralPath $s -Raw) | Should -Match '"n":2'
    }

    It 'keeps a forked transcript sidecar directory under the original session id' {
        $id = 'aaaaaaaa-0000-0000-0000-000000000006'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":2}")
        Write-Jsonl -Path $l -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":99}")
        $legacySidecar = Join-Path (Split-Path $l -Parent) "$id\tool-results"
        $null = New-Item -ItemType Directory -Path $legacySidecar -Force
        [IO.File]::WriteAllText((Join-Path $legacySidecar 'r.txt'), 'tool output',
                                (New-Object Text.UTF8Encoding $false))

        & $script:Script 6>&1 | Out-Null

        $projectDir = Split-Path $s -Parent
        $files      = @(Get-ChildItem -LiteralPath $projectDir -Filter '*.jsonl')
        $rescued    = $files | Where-Object { $_.Name -ne "$id.jsonl" }
        $newId      = [IO.Path]::GetFileNameWithoutExtension($rescued.Name)
        Test-Path -LiteralPath (Join-Path $projectDir $id) -PathType Container |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path $projectDir "$id\tool-results\r.txt") -PathType Leaf |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path $projectDir $newId) |
            Should -BeFalse
    }

    It 'rewrites session id fields without changing nested old-id path mentions' {
        $id = 'aaaaaaaa-0000-0000-0000-000000000007'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        $path = "C:\Temp\claude\proj\$id\scratchpad\x.txt"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":2}")
        Write-Jsonl -Path $l -Lines @(
            "{`"sessionId`":`"$id`",`"n`":1}",
            "{`"sessionId`":`"$id`",`"toolUseResult`":`"C:\\Temp\\claude\\proj\\$id\\scratchpad\\x.txt`"}"
        )
        foreach ($line in @(Get-Content -LiteralPath $l)) {
            { $null = ConvertFrom-Json -InputObject $line } | Should -Not -Throw
        }

        & $script:Script 6>&1 | Out-Null

        $files   = @(Get-ChildItem -LiteralPath (Split-Path $s -Parent) -Filter '*.jsonl')
        $rescued = $files | Where-Object { $_.Name -ne "$id.jsonl" }
        $newId   = [IO.Path]::GetFileNameWithoutExtension($rescued.Name)
        $lines   = @(Get-Content -LiteralPath $rescued.FullName |
                     ForEach-Object { ConvertFrom-Json -InputObject $_ })
        $lines[1].sessionId     | Should -Be $newId
        $lines[1].toolUseResult | Should -Be $path
    }

    It 'rescues a fork exactly once across repeated runs' {
        # Re-running is the documented recovery for a drift or conflict abort,
        # so rescue has to be idempotent. It is not naturally: the legacy and
        # store copies stay forked after a rescue, so a second run classifies
        # them as forked again. A random id would write a second copy every time.
        $id = 'aaaaaaaa-0000-0000-0000-000000000005'
        $s  = Join-Path $script:FakeHome ".claude\projects\$($script:Proj)\$id.jsonl"
        $l  = Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)\$id.jsonl"
        Write-Jsonl -Path $s -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":2}")
        Write-Jsonl -Path $l -Lines @("{`"sessionId`":`"$id`",`"n`":1}", "{`"sessionId`":`"$id`",`"n`":99}")

        & $script:Script 6>&1 | Out-Null
        $after1 = @(Get-ChildItem -LiteralPath (Split-Path $s -Parent) -Filter '*.jsonl' |
                    ForEach-Object { $_.Name } | Sort-Object)

        & $script:Script 6>&1 | Out-Null
        $after2 = @(Get-ChildItem -LiteralPath (Split-Path $s -Parent) -Filter '*.jsonl' |
                    ForEach-Object { $_.Name } | Sort-Object)

        $after1.Count | Should -Be 2
        # Same set, same names - the rescue id is derived from content, not random.
        ($after2 -join ',') | Should -Be ($after1 -join ',')
    }
}

Describe 'migrate-shared-store.ps1 retargeting' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    It 'repoints every junction at the store' {
        $acct = New-LegacyAccount -Name work

        & $script:Script 6>&1 | Out-Null

        foreach ($d in @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins')) {
            $target = @((Get-Item -LiteralPath (Join-Path $acct $d) -Force).Target)[0]
            $target | Should -Match '\.claude\\'
            $target | Should -Not -Match 'claude-shared'
        }
    }

    It 'refuses a real directory instead of deleting it' {
        $acct = New-LegacyAccount -Name work -Dirs @('projects')
        $real = Join-Path $acct 'skills'
        $null = New-Item -ItemType Directory -Path $real -Force
        Set-Content -LiteralPath (Join-Path $real 'mine.md') -Value 'do not delete me'

        $out = & $script:Script 6>&1 | Out-String -Width 500

        Get-Content -LiteralPath (Join-Path $real 'mine.md') | Should -Be 'do not delete me'
        $out | Should -Match 'Refusing'
    }

    It 'reports drift when the legacy store changes mid-run' {
        # Simulated by touching a legacy file after Phase 1 recorded it. In the
        # real failure a live Claude Code session appends to a transcript
        # between merge and retarget and those lines are never merged.
        $null = New-LegacyAccount -Name work
        $f = Join-Path $script:FakeHome '.claude-shared\skills\watched.md'
        Set-Content -LiteralPath $f -Value 'original'

        $out = & $script:Script -SimulateDriftPath $f 6>&1 | Out-String -Width 500

        $out | Should -Match 'changed during this run'
        $out | Should -Not -Match 'safe to delete'
    }

    It 'reports drift for a file CREATED after the merge enumerated the tree' {
        # The likelier shape of the race: a live session starts a new session
        # rather than appending to one this run already saw. Add-Content creates
        # the file, so a path that did not exist at Phase 1 simulates it.
        $null = New-LegacyAccount -Name work
        $new = Join-Path $script:FakeHome '.claude-shared\projects\brand-new.jsonl'

        $out = & $script:Script -SimulateDriftPath $new 6>&1 | Out-String -Width 500

        $out | Should -Match 'changed during this run'
        $out | Should -Not -Match 'safe to delete'
    }

    It 'refuses a junction pointing somewhere that is neither store nor legacy' {
        # Not automatically "already migrated". Treating it as such would let the
        # final gate bless deleting the legacy store while this account still
        # reads and writes to a third location.
        $acct  = New-LegacyAccount -Name work -Dirs @('projects')
        $other = Join-Path $script:FakeHome '.claude-backup\skills'
        $null  = New-Item -ItemType Directory -Path $other -Force
        $null  = cmd /c mklink /J "$acct\skills" "$other"

        $out = & $script:Script 6>&1 | Out-String -Width 500

        $out | Should -Match 'Unexpected junction target'
        $out | Should -Not -Match 'safe to delete'
        @((Get-Item -LiteralPath (Join-Path $acct 'skills') -Force).Target)[0] |
            Should -Match '\.claude-backup'
    }
}

Describe 'migrate-shared-store.ps1 handoff and report' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
        $null = New-LegacyAccount -Name work
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    It 'forwards -DryRun to setup so the handoff writes nothing' {
        # -NoSeed does NOT make setup inert: it still copies statusline.sh,
        # rewrites settings.json and creates links.
        $out = & $script:Script -DryRun 6>&1 | Out-String -Width 500

        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\settings.json') |
            Should -BeFalse
        Test-Path -LiteralPath $PROFILE | Should -BeFalse
        $out | Should -Match 'DRY RUN'
        $out | Should -Match 'would re-run install\.ps1'
    }

    It 'hands stripped account names to setup and re-runs install against the new store' {
        $legacyInstalled = Join-Path $script:FakeHome '.claude-shared\bin\claude-account-profile.ps1'
        $oldBlock = "# >>> claude-account-switch >>>`r`n. `"$legacyInstalled`"`r`n# <<< claude-account-switch <<<"
        [IO.File]::WriteAllText($PROFILE, $oldBlock, (New-Object Text.UTF8Encoding $false))

        $out = & $script:Script 6>&1 | Out-String -Width 500

        $profileText = Get-Content -LiteralPath $PROFILE -Raw
        $newInstalled = Join-Path $script:FakeHome '.claude\bin\claude-account-profile.ps1'
        $out | Should -Match "Account 'work'"
        $profileText | Should -Match ([regex]::Escape($newInstalled))
        $profileText | Should -Not -Match ([regex]::Escape($legacyInstalled))
        Test-Path -LiteralPath $newInstalled -PathType Leaf | Should -BeTrue
    }

    It 'withholds deletion guidance and keeps the manifest when a conflict was reported' {
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\skills\c.md') -Value 'legacy'
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\skills\c.md')        -Value 'store'

        $out = & $script:Script 6>&1 | Out-String -Width 500

        $out | Should -Not -Match 'safe to delete'
        $out | Should -Match 'unresolved'
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\.migrate-shared-store.state') |
            Should -BeTrue
    }

    It 'leaves the legacy store on disk no matter what' {
        & $script:Script 6>&1 | Out-Null
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude-shared') | Should -BeTrue
    }

    It 'removes the manifest on a clean run' {
        & $script:Script 6>&1 | Out-Null
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\.migrate-shared-store.state') |
            Should -BeFalse
    }

    It 'offers only qualified deletion guidance after a clean handoff' {
        $out = & $script:Script 6>&1 | Out-String -Width 500

        $out | Should -Match 'safe to delete ONLY after you open a NEW shell'
        $out | Should -Match 'Get-ClaudeAccount still works'
    }

    It 'offers deletion guidance when the legacy root contains a hardlinked CLAUDE.md' {
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'shared memory'
        $null = cmd /c mklink /H "$(Join-Path $script:FakeHome '.claude-shared\CLAUDE.md')" `
                                    "$(Join-Path $script:FakeHome '.claude\CLAUDE.md')"

        $out = & $script:Script 6>&1 | Out-String -Width 500

        $out | Should -Match 'safe to delete ONLY after you open a NEW shell'
    }

    It 'offers deletion guidance on a second consecutive clean run' {
        $legacyBin = Join-Path $script:FakeHome '.claude-shared\bin'
        $null = New-Item -ItemType Directory -Path $legacyBin -Force
        [IO.File]::WriteAllText(
            (Join-Path $legacyBin 'claude-account-profile.ps1'),
            '# legacy installed profile',
            (New-Object Text.UTF8Encoding $false)
        )

        $first = & $script:Script 6>&1 | Out-String -Width 500
        $second = & $script:Script 6>&1 | Out-String -Width 500

        $first  | Should -Match 'safe to delete ONLY after you open a NEW shell'
        $second | Should -Match 'safe to delete ONLY after you open a NEW shell'
        $second | Should -Not -Match 'unresolved conflict'
    }

    It 'withholds deletion guidance when mandatory install.ps1 is missing' {
        $fakeRepo = Join-Path $script:FakeHome 'repo-without-install'
        $null = New-Item -ItemType Directory -Path $fakeRepo -Force
        $copiedMigration = Join-Path $fakeRepo 'migrate-shared-store.ps1'
        Copy-Item -LiteralPath $script:Script -Destination $copiedMigration

        $stubSetup = @'
[CmdletBinding()]
param([string[]] $Accounts, [switch] $NoSeed, [switch] $DryRun)
'@
        [IO.File]::WriteAllText((Join-Path $fakeRepo 'setup-claude-accounts.ps1'), $stubSetup,
                                (New-Object Text.UTF8Encoding $false))

        $out = & $copiedMigration 6>&1 | Out-String -Width 500

        $out | Should -Match 'cannot find .*install\.ps1'
        $out | Should -Not -Match 'safe to delete'
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\.migrate-shared-store.state') |
            Should -BeTrue
    }
}

Describe 'migrate-shared-store.ps1 handoff with no discovered accounts' {
    BeforeEach {
        $script:FakeHome = New-LegacyFakeHome   # swaps $HOME AND $PROFILE
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-LegacyFakeHome -Path $script:FakeHome }

    It 'still re-runs mandatory install.ps1' {
        $legacyInstalled = Join-Path $script:FakeHome '.claude-shared\bin\claude-account-profile.ps1'
        $oldBlock = "# >>> claude-account-switch >>>`r`n. `"$legacyInstalled`"`r`n# <<< claude-account-switch <<<"
        [IO.File]::WriteAllText($PROFILE, $oldBlock, (New-Object Text.UTF8Encoding $false))
        $settings = Join-Path $script:FakeHome '.claude\settings.json'
        [IO.File]::WriteAllText(
            $settings,
            '{"statusLine":{"type":"command","command":"legacy/.claude-shared/statusline.sh"}}',
            (New-Object Text.UTF8Encoding $false)
        )

        & $script:Script 6>&1 | Out-Null

        $profileText = Get-Content -LiteralPath $PROFILE -Raw
        $settingsText = Get-Content -LiteralPath $settings -Raw
        $newInstalled = Join-Path $script:FakeHome '.claude\bin\claude-account-profile.ps1'
        $profileText | Should -Match ([regex]::Escape($newInstalled))
        $profileText | Should -Not -Match ([regex]::Escape($legacyInstalled))
        $settingsText | Should -Match '\.claude/statusline\.sh'
        $settingsText | Should -Not -Match '\.claude-shared/statusline\.sh'
    }
}
