#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# CLAUDE.md is shared by NTFS hardlink, not by junction - a junction links
# directories only. That makes it the one shared thing with no reparse point to
# inspect, so every test here asserts on file IDENTITY (one inode, several
# names) rather than on content matching, which a stale copy would also pass.
#
# The script talks through Write-Host, so its output is on stream 6 and needs
# 6>&1 to be captured at all - and then Out-String -Width, because the default
# wraps at the console width and will fold a line break into the middle of the
# very phrase being matched.

BeforeAll {
    $script:RepoRoot    = Split-Path $PSScriptRoot -Parent
    $script:SetupScript = Join-Path $script:RepoRoot 'setup-claude-accounts.ps1'
    $script:ProfileFile = Join-Path $script:RepoRoot 'claude-account-profile.ps1'
    $script:RealHome    = $HOME

    function New-MemoryFakeHome {
        # Not Initialize-FakeHome: these tests need a ~/.claude to seed from,
        # and each one needs its own home because they mutate it.
        param([switch] $NoMemory)

        $home_ = Join-Path ([IO.Path]::GetTempPath()) ("claude-memory-test-" + [guid]::NewGuid().ToString('N'))
        $null  = New-Item -ItemType Directory -Path (Join-Path $home_ '.claude') -Force
        Set-Content -LiteralPath (Join-Path $home_ '.claude\settings.json')     -Value '{}'      -Encoding utf8
        Set-Content -LiteralPath (Join-Path $home_ '.claude\.credentials.json') -Value '{"t":1}' -Encoding utf8
        if (-not $NoMemory) {
            Set-Content -LiteralPath (Join-Path $home_ '.claude\CLAUDE.md') -Value "# global memory`nseeded line" -Encoding utf8
        }

        # LAST, so a throw above never leaves $HOME pointing at a half-built dir.
        Set-Variable -Name HOME -Value $home_ -Scope Global -Force
        return $home_
    }

    function Remove-MemoryFakeHome {
        param([Parameter(Mandatory = $true)][string] $Path)

        Set-Variable -Name HOME -Value $script:RealHome -Scope Global -Force
        Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                # rmdir removes the link, never the target. A plain
                # Remove-Item -Recurse on 5.1 would follow these into the store.
                Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                    ForEach-Object { cmd /c rmdir "$($_.FullName)" | Out-Null }
            }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }

    function Test-OneInode {
        # Two paths naming one file. Deliberately NOT a content comparison: a
        # copy left behind by an older run of the setup script has identical
        # content and is exactly what these tests must catch.
        param([string] $Path, [string] $Other)

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf))  { return $false }
        if (-not (Test-Path -LiteralPath $Other -PathType Leaf)) { return $false }

        $item      = Get-Item -LiteralPath $Path  -Force
        $otherFull = (Get-Item -LiteralPath $Other -Force).FullName

        if ($item.FullName -eq $otherFull) { return $true }
        if ($item.LinkType -ne 'HardLink') { return $false }

        $peers = @($item.Target) | ForEach-Object {
            if ($_ -notmatch '^[A-Za-z]:\\' -and $_ -notmatch '^\\\\') {
                (Split-Path -Qualifier $item.FullName) + $_
            } else { $_ }
        }
        return [bool]($peers -contains $otherFull)
    }
}

Describe 'setup-claude-accounts.ps1 shares CLAUDE.md' {
    BeforeEach { $script:FakeHome = New-MemoryFakeHome }
    AfterEach  { Remove-MemoryFakeHome -Path $script:FakeHome }

    It 'gives the store and every account a name for the ~/.claude file' {
        & $script:SetupScript -Accounts work, personal -SeedInto work 6>&1 | Out-Null

        $real = Join-Path $script:FakeHome '.claude\CLAUDE.md'
        Test-OneInode (Join-Path $script:FakeHome '.claude-shared\CLAUDE.md')   $real | Should -BeTrue
        Test-OneInode (Join-Path $script:FakeHome '.claude-work\CLAUDE.md')     $real | Should -BeTrue
        Test-OneInode (Join-Path $script:FakeHome '.claude-personal\CLAUDE.md') $real | Should -BeTrue
    }

    It 'makes a write from one account visible from the others' {
        & $script:SetupScript -Accounts work, personal -SeedInto work 6>&1 | Out-Null

        Add-Content -LiteralPath (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') -Value 'added by work'

        (Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude-personal\CLAUDE.md') -Raw) |
            Should -Match 'added by work'
        (Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Raw) |
            Should -Match 'added by work'
        # The seeded content is still there: a link, not an overwrite.
        (Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Raw) |
            Should -Match 'seeded line'
    }

    It 'does not leave the seeded account a robocopy copy' {
        # /XF. Without it the account gets a real file with identical content,
        # and only an identity check can tell the two apart.
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null

        Test-OneInode (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') `
                      (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
        # The rest of the seeding still happened.
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude-work\.credentials.json') | Should -BeTrue
    }

    It 'is idempotent' {
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null
        Add-Content -LiteralPath (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') -Value 'added by work'

        $out = & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-String -Width 500

        $out | Should -Match 'link already present'
        Test-OneInode (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') `
                      (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') -Raw) |
            Should -Match 'added by work'
    }

    It 'relinks an identical copy left by an older run' {
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null

        # What the pre-hardlink script did: robocopy the file in.
        $link = Join-Path $script:FakeHome '.claude-work\CLAUDE.md'
        Remove-Item -LiteralPath $link -Force
        Copy-Item -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Destination $link
        Test-OneInode $link (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeFalse

        $out = & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-String -Width 500

        $out | Should -Match 'replaced identical copy'
        Test-OneInode $link (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
    }

    It 'relinks a file an editor left blank' {
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null

        # /memory on an account with no shared file creates exactly this.
        $link = Join-Path $script:FakeHome '.claude-work\CLAUDE.md'
        Remove-Item -LiteralPath $link -Force
        Set-Content -LiteralPath $link -Value "`r`n`r`n" -Encoding utf8

        $out = & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-String -Width 500

        $out | Should -Match 'replaced empty file'
        Test-OneInode $link (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
    }

    It 'refuses to overwrite an account file with content of its own' {
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null

        $link = Join-Path $script:FakeHome '.claude-work\CLAUDE.md'
        Remove-Item -LiteralPath $link -Force
        Set-Content -LiteralPath $link -Value 'notes only this account has' -Encoding utf8

        { & $script:SetupScript -Accounts work -NoSeed 6>&1 } |
            Should -Throw -ExpectedMessage '*Refusing to overwrite*'

        # Both sides survive the refusal - that is the whole point of it.
        (Get-Content -LiteralPath $link -Raw) | Should -Match 'notes only this account has'
        (Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Raw) |
            Should -Match 'seeded line'
    }

    It 'gives ~/.claude its name back when only the store still has the file' {
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Force

        & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-Null

        # Deleting one name for an inode leaves the content alive under the rest.
        Test-OneInode (Join-Path $script:FakeHome '.claude\CLAUDE.md') `
                      (Join-Path $script:FakeHome '.claude-shared\CLAUDE.md') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Raw) |
            Should -Match 'seeded line'
    }

    It 'shares more than one file when asked' {
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\extra.md') -Value 'extra' -Encoding utf8

        & $script:SetupScript -Accounts work -NoSeed -SharedFiles CLAUDE.md, extra.md 6>&1 | Out-Null

        Test-OneInode (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') `
                      (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
        Test-OneInode (Join-Path $script:FakeHome '.claude-work\extra.md') `
                      (Join-Path $script:FakeHome '.claude\extra.md') | Should -BeTrue
    }

    It 'rejects <File>, which would mean a different path in every account' -ForEach @(
        @{ File = 'sub\CLAUDE.md' }
        @{ File = 'sub/CLAUDE.md' }
        @{ File = '*.md'          }
        @{ File = 'a[1].md'       }
    ) {
        { & $script:SetupScript -Accounts work -NoSeed -SharedFiles $File -DryRun 6>&1 } |
            Should -Throw -ExpectedMessage '*plain file name*'
    }
}

Describe 'setup-claude-accounts.ps1 -DryRun with no CLAUDE.md anywhere' {
    BeforeEach { $script:FakeHome = New-MemoryFakeHome -NoMemory }
    AfterEach  { Remove-MemoryFakeHome -Path $script:FakeHome }

    It 'says it would create the file in ~/.claude, and does not' {
        # ~/.claude gaining a file is the single exception to "nothing in
        # ~/.claude is modified", so a dry run must not claim it already did.
        $out = & $script:SetupScript -Accounts work -NoSeed -DryRun 6>&1 | Out-String -Width 500

        $out | Should -Match 'would create an empty CLAUDE\.md'
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude-shared')    | Should -BeFalse
    }

    It 'creates it for real without -DryRun' {
        & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-Null

        Test-OneInode (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') `
                      (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
    }
}

Describe 'Get-ClaudeAccount reports a CLAUDE.md that stopped being shared' {
    BeforeEach {
        $script:FakeHome = New-MemoryFakeHome
        & $script:SetupScript -Accounts work, personal -SeedInto work 6>&1 | Out-Null
        # Dot-source AFTER $HOME is fake: the profile registers launchers for
        # every account it can see at load time.
        . $script:ProfileFile
    }
    AfterEach { Remove-MemoryFakeHome -Path $script:FakeHome }

    It 'flags the account whose link an editor broke' {
        # Saving by write-new-then-rename replaces the link with a plain file.
        # Nothing else would ever say so: the account keeps a readable
        # CLAUDE.md that silently no longer follows the shared one.
        $link = Join-Path $script:FakeHome '.claude-personal\CLAUDE.md'
        Remove-Item -LiteralPath $link -Force
        Set-Content -LiteralPath $link -Value 'drifted' -Encoding utf8

        $out = Get-ClaudeAccount 6>&1 | Out-String -Width 500

        $out | Should -Match 'personal.*CLAUDE\.md not shared'
        $out | Should -Not -Match 'work.*CLAUDE\.md not shared'
    }

    It 'still reports a missing login, and both tags together' {
        $link = Join-Path $script:FakeHome '.claude-personal\CLAUDE.md'
        Remove-Item -LiteralPath $link -Force
        Set-Content -LiteralPath $link -Value 'drifted' -Encoding utf8

        $out = Get-ClaudeAccount 6>&1 | Out-String -Width 500

        $out | Should -Match 'personal\s+\(not logged in, CLAUDE\.md not shared\)'
    }

    It 'says nothing when CLAUDE.md is not a shared file at all' {
        # Leaving CLAUDE.md out of -SharedFiles is a choice, not a fault, and
        # must not flag every account on the machine.
        Remove-Item -LiteralPath (Join-Path $script:FakeHome '.claude-shared\CLAUDE.md') -Force

        (Get-ClaudeAccount 6>&1 | Out-String -Width 500) | Should -Not -Match 'not shared'
    }
}
