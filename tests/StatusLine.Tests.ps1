#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# The status line is the one shared thing with no link behind it: Claude Code
# names it by PATH in settings.json, so a single copy in ~/.claude is
# enough and every account's settings.json is pointed at it. What has to be
# tested instead is the EDIT: settings.json is a file Claude Code owns and the
# user hand-edits, so the one key must change and nothing else may - not the
# other keys, not the indentation, not the encoding.
#
# These tests need Git Bash and node on the machine, the same two programs
# statusline.sh itself needs.
#
# The script talks through Write-Host, so its output is on stream 6 and needs
# 6>&1 to be captured at all - and then Out-String -Width, because the default
# wraps at the console width and will fold a line break into the middle of the
# very phrase being matched.

BeforeAll {
    $script:RepoRoot    = Split-Path $PSScriptRoot -Parent
    $script:SetupScript = Join-Path $script:RepoRoot 'setup-claude-accounts.ps1'
    $script:StatusLineScript = Join-Path $script:RepoRoot 'statusline.sh'
    $script:RealHome    = $HOME

    # A settings.json shaped like a real one: nested hooks, a key before the
    # status line and a key after it, and a padding INSIDE statusLine that the
    # user chose and must survive. Written with LF and no BOM, which is what
    # Claude Code writes.
    $script:SampleSettings = @'
{
  "model": "opus",
  "statusLine": {
    "type": "command",
    "command": "node old-statusline.js",
    "padding": 0
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo hi",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "theme": "dark"
}
'@

    function Write-SettingsFile {
        param([string] $Path, [string] $Content)
        [IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    }

    function New-StatusLineFakeHome {
        # Each test mutates its home, so each one gets its own.
        param([switch] $NoSettings)

        $home_ = Join-Path ([IO.Path]::GetTempPath()) ("claude-statusline-test-" + [guid]::NewGuid().ToString('N'))
        $null  = New-Item -ItemType Directory -Path (Join-Path $home_ '.claude') -Force
        Set-Content -LiteralPath (Join-Path $home_ '.claude\CLAUDE.md') -Value '# memory' -Encoding utf8
        if (-not $NoSettings) {
            Write-SettingsFile -Path (Join-Path $home_ '.claude\settings.json') -Content $script:SampleSettings
        }

        # LAST, so a throw above never leaves $HOME pointing at a half-built dir.
        Set-Variable -Name HOME -Value $home_ -Scope Global -Force
        return $home_
    }

    function Remove-StatusLineFakeHome {
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

    function Get-StatusLineCommand {
        param([string] $SettingsPath)
        $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
        return $settings.statusLine.command
    }
}

Describe 'setup-claude-accounts.ps1 shares the status line' {
    BeforeEach { $script:FakeHome = New-StatusLineFakeHome }
    AfterEach  { Remove-StatusLineFakeHome -Path $script:FakeHome }

    It 'keeps one copy of the script in the shared store and points every account at it' {
        $null = & $script:SetupScript -Accounts work,personal -SeedInto work 6>&1

        $shared = Join-Path $script:FakeHome '.claude\statusline.sh'
        Test-Path -LiteralPath $shared | Should -BeTrue
        (Get-FileHash -LiteralPath $shared).Hash |
            Should -Be (Get-FileHash -LiteralPath $script:StatusLineScript).Hash

        # No per-account copy: the setting is a path, so there is nothing to link
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude-work\statusline.sh') | Should -BeFalse

        foreach ($dir in '.claude', '.claude-work', '.claude-personal') {
            $command = Get-StatusLineCommand -SettingsPath (Join-Path $script:FakeHome "$dir\settings.json")
            $command | Should -BeLike '*bash.exe" "*'
            $command | Should -BeLike "*$($shared.Replace('\', '/'))*"
        }
    }

    It 'changes the status line and nothing else in settings.json' {
        $null = & $script:SetupScript -Accounts work -SeedInto work 6>&1

        $settings = Get-Content -LiteralPath (Join-Path $script:FakeHome '.claude-work\settings.json') -Raw |
                    ConvertFrom-Json

        $settings.model                                  | Should -Be 'opus'
        $settings.theme                                  | Should -Be 'dark'
        $settings.hooks.PostToolUse[0].hooks[0].timeout  | Should -Be 5
        # A padding the user set lives inside statusLine, so replacing that
        # object wholesale rather than merging into it would silently drop it.
        $settings.statusLine.padding                     | Should -Be 0
        $settings.statusLine.type                        | Should -Be 'command'
    }

    It 'writes the file the way Claude Code does: no BOM, LF, two-space indent' {
        $null = & $script:SetupScript -Accounts work -SeedInto work 6>&1

        $path  = Join-Path $script:FakeHome '.claude-work\settings.json'
        $bytes = [IO.File]::ReadAllBytes($path)

        # A BOM is not whitespace to JSON.parse - it is a syntax error, so a
        # BOM here would leave every account with an unreadable settings file.
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        ($bytes -join ',') | Should -Not -Match '13,10'

        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match '(?m)^  "model": "opus",$'
        $text | Should -Match "\}\n$"
    }

    It 'is idempotent - a second run reports it is already set and rewrites nothing' {
        $null = & $script:SetupScript -Accounts work -SeedInto work 6>&1

        $path   = Join-Path $script:FakeHome '.claude-work\settings.json'
        $before = (Get-FileHash -LiteralPath $path).Hash

        $out = & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-String -Width 500

        $out | Should -Match 'status line already set'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
    }

    It 'reports the statusline.sh it rewrote in the store rather than claiming nothing changed' {
        # The store IS ~/.claude, so overwriting statusline.sh there modifies it.
        # The copy is recorded in neither list, so a re-run whose ONLY change is
        # that copy printed "Your original ~/.claude was not modified".
        & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\statusline.sh') `
                    -Value '# stale - differs from the repo copy' -Encoding utf8

        # Second run: dirs already seeded, CLAUDE.md already linked, settings.json
        # already correct. Only the status-line copy fires.
        $out = & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-String -Width 500

        # Assert on the change being REPORTED, not on the absence of a phrase -
        # this task deletes that phrase, so a negative-only assertion would pass
        # for the wrong reason.
        $out | Should -Match 'This run changed:.*statusline\.sh'
        $out | Should -Not -Match 'not modified'
    }

    It 'replaces a status line the account already had, and says what it was' {
        $out = & $script:SetupScript -Accounts work -SeedInto work 6>&1 | Out-String -Width 500

        $out | Should -Match 'status line replaced'
        $out | Should -Match 'was: node old-statusline\.js'
    }

    It 'creates a settings.json for an account that has none' {
        # -NoSeed and a home with no settings.json to copy: the account dir
        # exists but is empty, so the file has to be made from nothing.
        Remove-StatusLineFakeHome -Path $script:FakeHome
        $script:FakeHome = New-StatusLineFakeHome -NoSettings

        $null = & $script:SetupScript -Accounts work -NoSeed 6>&1

        $path = Join-Path $script:FakeHome '.claude-work\settings.json'
        Test-Path -LiteralPath $path | Should -BeTrue
        (Get-StatusLineCommand -SettingsPath $path) | Should -BeLike '*statusline.sh*'
    }

    It 'reports creating a settings.json in ~/.claude rather than claiming nothing changed' {
        Remove-StatusLineFakeHome -Path $script:FakeHome
        $script:FakeHome = New-StatusLineFakeHome -NoSettings

        $out = & $script:SetupScript -Accounts work -NoSeed 6>&1 | Out-String -Width 500

        $out | Should -Not -Match 'Nothing in .* was added or changed\.'
        $out | Should -Match 'settings\.json \(created, to hold the status line\)'
    }

    It 'leaves every settings.json alone with -NoStatusLine' {
        $path   = Join-Path $script:FakeHome '.claude\settings.json'
        $before = (Get-FileHash -LiteralPath $path).Hash

        $null = & $script:SetupScript -Accounts work -SeedInto work -NoStatusLine 6>&1

        (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\statusline.sh') | Should -BeFalse
        (Get-StatusLineCommand -SettingsPath (Join-Path $script:FakeHome '.claude-work\settings.json')) |
            Should -Be 'node old-statusline.js'
    }

    It 'writes nothing under -DryRun' {
        $path   = Join-Path $script:FakeHome '.claude\settings.json'
        $before = (Get-FileHash -LiteralPath $path).Hash

        $out = & $script:SetupScript -Accounts work -SeedInto work -DryRun 6>&1 | Out-String -Width 500

        (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\statusline.sh') | Should -BeFalse
        $out | Should -Match 'would copy .*statusline\.sh'
        $out | Should -Match 'would replace the status line'
    }

    It 'throws when -StatusLine names a file that is not there' {
        { & $script:SetupScript -Accounts work -NoSeed -StatusLine (Join-Path $script:FakeHome 'nope.sh') } |
            Should -Throw '*-StatusLine script not found*'
    }
}
