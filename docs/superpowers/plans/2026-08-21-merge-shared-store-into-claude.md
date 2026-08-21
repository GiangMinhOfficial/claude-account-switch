# Merge the shared store into ~/.claude — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `~/.claude` the shared store instead of `~/.claude-shared`, and ship a one-shot `migrate-shared-store.ps1` that moves an existing machine over without losing data.

**Architecture:** `$Shared` becomes `$HOME/.claude`. Every `~/.claude-<name>` keeps junctioning six directories and hardlinking `CLAUDE.md`, but now into `~/.claude`. The link mechanisms do not change; only the target moves. Because `~/.claude` is simultaneously the store and the fallback config dir, five guards in `setup-claude-accounts.ps1` that assumed the two were distinct must be repaired before the flip is safe. Migration is a separate script that preflights, merges, retargets, rechecks, then hands off to setup and install.

**Tech Stack:** Windows PowerShell 5.1 only. Pester 5+ for tests. `mklink /J` and `mklink /H` via `cmd`, `robocopy` for tree copies, `node` for JSON writes. No PowerShell 7 syntax (`??`, `?:`, `-AsHashtable`, `&&`, `||`).

**Spec:** `docs/superpowers/specs/2026-08-21-merge-shared-store-into-claude-design.md`

## Global Constraints

- **PowerShell 5.1 only.** No `??`, `?:`, `-AsHashtable`, `&&`, `||`. `#Requires -Version 5.1` at the top of every script.
- **Never remove a junction with `Remove-Item -Recurse`.** It follows the junction on 5.1 and empties the target. Always `cmd /c rmdir "<link>"`.
- **Never write JSON with `ConvertTo-Json`.** It adds a BOM and re-indents; the BOM alone makes `JSON.parse` throw. Use `node` with `JSON.stringify(x, null, 2)`. Reading with `ConvertFrom-Json` is fine.
- **Never write text with `Set-Content -Encoding utf8`** where a parser will read it — 5.1 emits a BOM. Use `[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))`.
- **`New-Item` has no `-LiteralPath`.** Link creation shells out to `mklink`.
- **Writes to the `function:` drive always use `-LiteralPath`;** removals drop the `global:` prefix. An account named `a[1]` is a real test case.
- **`.gitattributes` pins `.ps1`/`.md` to CRLF and `.sh` to LF.** Do not change it.
- **Comments carry the *why*,** especially the constraint a line exists to satisfy. Match the existing density — this repo deliberately comments more than "no obvious comments" would suggest.
- **Error model:** scripts (`setup-`, `install`, `migrate-`) use `throw`. Profile functions use `Write-Error` + `return`, so callers acting on the result pass `-ErrorAction Stop`.

**Running the tests** (Pester 3.4.0 ships with Windows and is syntactically incompatible; the explicit `Import-Module` is required):

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path tests -Output Detailed
Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -Output Detailed
Invoke-Pester -Path tests -FullNameFilter '*is idempotent*' -Output Detailed
```

If Pester 5 is not installed:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

## File Structure

| File | Status | Responsibility after this change |
| --- | --- | --- |
| `setup-claude-accounts.ps1` | modify | Creates the store at `~/.claude`, the account dirs, and the links. Gains store-only exclusions, account-peer recovery, honest reporting. |
| `claude-account-profile.ps1` | modify | Two operational paths move to `~/.claude`; `$memoryIsShared` becomes a semantic test. The two `.claude-shared` guards stay as legacy guards. |
| `install.ps1` | modify | `$BinDir` moves to `~/.claude\bin`. |
| `migrate-shared-store.ps1` | **create** | One-shot migration: preflight, merge, retarget, recheck, hand off. |
| `tests/Fixtures.ps1` | modify | Fake home builds the store at `.claude`. Gains a legacy-store fixture for migration tests. |
| `tests/SharedMemoryFile.Tests.ps1` | modify | Identity assertions become account ↔ store; recovery and gate tests rewritten. |
| `tests/StatusLine.Tests.ps1` | modify | Path-only updates. |
| `tests/Rename-ClaudeAccount.Tests.ps1` | modify | Junction-target assertions repoint; `.claude-shared` exclusion test now covers a leftover store. |
| `tests/Migrate-SharedStore.Tests.ps1` | **create** | Migration tests, ordinary and adversarial. |
| `tests/Set-ClaudeAccountName.Tests.ps1` | **unchanged** | Migration takes no account name, so the literal stays duplicated across exactly two files. |
| `README.md`, `CLAUDE.md`, `.gitignore` | modify | Docs pass, migration section, blast-radius warning. |

**Task ordering is not negotiable.** Task 1 flips the path and leaves two known-red tests explicitly skipped; Tasks 3 and 4 un-skip them as their failing-test step. Phase B cannot start before Phase A completes, because migration's Phase 3 calls the repaired setup.

---

## Phase A — Redesign the tool

### Task 1: Flip the store to `~/.claude`

**Files:**
- Modify: `setup-claude-accounts.ps1:120` (the `$Shared` assignment) and the docstring at `:11-33`
- Modify: `claude-account-profile.ps1:62`, `:93`
- Modify: `install.ps1:36`, `:7`
- Modify: `tests/Fixtures.ps1:11,27`
- Modify: `tests/StatusLine.Tests.ps1:104,199,211`
- Modify: `tests/Rename-ClaudeAccount.Tests.ps1:197,224`
- Modify: `tests/SharedMemoryFile.Tests.ps1` (path updates + two `-Skip` markers)

**Interfaces:**
- Consumes: nothing.
- Produces: `$Shared -eq (Join-Path $HOME '.claude')` in setup; `$BinDir -eq (Join-Path $HOME '.claude\bin')` in install. Every later task depends on these.

- [ ] **Step 1: Update the fixture so the fake home's store is `.claude`**

In `tests/Fixtures.ps1`, replace lines 11 and 27.

```powershell
    # The store IS ~/.claude now - it is both the shared store and the config
    # dir a shell with no CLAUDE_CONFIG_DIR falls back to.
    $projects = Join-Path $fake '.claude\projects'
```

```powershell
    $null = cmd /c mklink /J "$dir\projects" "$(Join-Path $HOME '.claude\projects')"
```

- [ ] **Step 2: Run the suite to see exactly what breaks**

Run: `Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests -Output Detailed`
Expected: FAIL. Record the failing test names — the rest of this task is making all of them pass except the two deliberately deferred in Step 6.

- [ ] **Step 3: Flip `$Shared` in setup**

`setup-claude-accounts.ps1:120`, replace:

```powershell
$Shared = Join-Path $HOME '.claude-shared'
```

with:

```powershell
# The store IS ~/.claude. It holds the real shared dirs, CLAUDE.md,
# statusline.sh and bin/, and every account junctions/hardlinks into it.
# It is also the config dir a shell with no CLAUDE_CONFIG_DIR falls back to,
# so $Shared and $SeedFrom are normally the SAME path - several guards below
# exist only because of that overlap and say so.
$Shared = Join-Path $HOME '.claude'
```

- [ ] **Step 4: Flip the profile's two operational paths**

`claude-account-profile.ps1:62`:

```powershell
    $shared = Join-Path $HOME '.claude\CLAUDE.md'
```

`claude-account-profile.ps1:93` — path only for now; Task 3 replaces the whole test:

```powershell
    $memoryIsShared = Test-Path -LiteralPath (Join-Path $HOME '.claude\CLAUDE.md') -PathType Leaf
```

Leave `:30` (the `.claude-shared` exclusion) and `:218` (the rename refusal) **exactly as they are**. Update only their comments to say they now guard a *leftover* legacy store rather than the live one.

**Do not "improve" `New-Junction` while you are here.** It returns early on the `ReparsePoint` attribute without reading the target, so it cannot retarget a junction that points at the old store. That is deliberate: retargeting is migration's job (Task 10), and teaching setup to silently repoint links would make every ordinary `setup` run capable of moving data. Leave `Test-Junction` and `New-Junction` untouched.

- [ ] **Step 5: Flip `install.ps1`**

`install.ps1:36`:

```powershell
$BinDir      = Join-Path $HOME '.claude\bin'
```

And `:7` in the docstring: `~/.claude-shared/bin` becomes `~/.claude/bin`.

- [ ] **Step 6: Update test paths, and skip the two tests that later tasks restore**

In `tests/StatusLine.Tests.ps1` (lines 104, 199, 211) and `tests/Rename-ClaudeAccount.Tests.ps1` (lines 197, 224), replace `.claude-shared\` with `.claude\` in the store paths. **Do not** touch `Rename-ClaudeAccount.Tests.ps1:93` — that is the `.claude-shared` exclusion test, which now covers a leftover store and must keep its old path.

In `tests/SharedMemoryFile.Tests.ps1`, replace `.claude-shared\CLAUDE.md` with `.claude\CLAUDE.md` at lines 84 and 180 — but read Task 4 Step 1 first: those two assertions must become account ↔ store, not store ↔ home. For now make them compare an **account** against the store so they are meaningful:

```powershell
        Test-OneInode (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') `
                      (Join-Path $script:FakeHome '.claude\CLAUDE.md') | Should -BeTrue
```

Then mark the two tests that cannot pass until Tasks 3 and 4:

```powershell
    It 'gives ~/.claude its name back when only the store still has the file' -Skip {
```

```powershell
    It 'says nothing when CLAUDE.md is not a shared file at all' -Skip {
```

Add above each a comment naming the task that restores it, e.g.:

```powershell
    # SKIPPED until Task 4: with the store at ~/.claude the old recovery branch
    # is unreachable, and the replacement recovers from an account peer instead.
```

- [ ] **Step 7: Run the suite**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, with exactly 2 skipped. If anything else fails, the path sweep missed a site — grep for `claude-shared` across `tests/` and fix before committing.

- [ ] **Step 8: Update setup's docstring**

`setup-claude-accounts.ps1:11-33`. The paragraphs describing `~/.claude-shared` and the "writes there in exactly two places" promise are now false. Replace with a description of `~/.claude` as the store, and state the new promise: **setup only ever adds to `~/.claude`; it never deletes.** (Task 5 makes the reporting match this.)

- [ ] **Step 9: Commit**

```bash
git add setup-claude-accounts.ps1 claude-account-profile.ps1 install.ps1 tests/
git commit -m "Point the shared store at ~/.claude

The store and the fallback config dir are now one directory. Link
mechanisms are unchanged; only the target moves. Two tests are skipped
here and restored by Tasks 3 and 4, which replace the guards that
assumed store and home were distinct paths."
```

---

### Task 2: Stop `bin/` and `statusline.sh` leaking into seeded accounts

**Files:**
- Modify: `setup-claude-accounts.ps1:123` (`$SkipDirs`), `:564` (the `Copy-Tree` call)
- Test: `tests/SharedMemoryFile.Tests.ps1` (new `Describe` block, or a new `Seeding.Tests.ps1` — prefer appending to the existing file to avoid a fifth fixture bootstrap)

**Interfaces:**
- Consumes: `$Shared` from Task 1.
- Produces: `$StoreOnlyDirs` (`string[]`, value `@('bin')`) and `$StoreOnlyFiles` (`string[]`, computed as `@([IO.Path]::GetFileName($StatusLine))`). Nothing later consumes these.

- [ ] **Step 1: Write the failing test**

Append to `tests/SharedMemoryFile.Tests.ps1`:

```powershell
Describe 'setup-claude-accounts.ps1 keeps store-only artifacts out of accounts' {
    BeforeEach { $script:FakeHome = New-MemoryFakeHome }
    AfterEach  { Remove-MemoryFakeHome -Path $script:FakeHome }

    It 'does not seed bin/ or statusline.sh into an account' {
        # Both live in the store, and the store is now ~/.claude - the very
        # directory -SeedInto copies from. Without an explicit exclusion every
        # new account gets a private copy of the profile script and the bar.
        $bin = Join-Path $script:FakeHome '.claude\bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        Set-Content -LiteralPath (Join-Path $bin 'claude-account-profile.ps1') -Value '# installed'
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\statusline.sh') -Value '#!/bin/bash'

        & $script:SetupScript -Accounts work -SeedInto work -NoStatusLine 6>&1 | Out-Null

        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude-work\bin')           | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude-work\statusline.sh') | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -FullNameFilter '*store-only artifacts*' -Output Detailed`
Expected: FAIL — both `Should -BeFalse` assertions report `$true`, because `Copy-Tree` excludes neither.

- [ ] **Step 3: Add the store-only sets**

`setup-claude-accounts.ps1`, immediately after `$SkipDirs` at `:123`:

```powershell
# Store-only: these live in the store but are NOT shared into accounts, and the
# store is now the same directory -SeedInto copies from. Without excluding them
# every seeded account gets a private copy of the profile script and the status
# line - the second of which then silently stops tracking the shared one.
$StoreOnlyDirs  = @('bin')
$StoreOnlyFiles = @([IO.Path]::GetFileName($StatusLine))
```

- [ ] **Step 4: Exclude them from the seed copy**

`setup-claude-accounts.ps1:564`, replace:

```powershell
            Copy-Tree -Source $SeedFrom -Destination $acct `
                      -ExcludeDirs ($SharedDirs + $SkipDirs) -ExcludeFiles $SharedFiles
```

with:

```powershell
            Copy-Tree -Source $SeedFrom -Destination $acct `
                      -ExcludeDirs ($SharedDirs + $SkipDirs + $StoreOnlyDirs) `
                      -ExcludeFiles ($SharedFiles + $StoreOnlyFiles)
```

- [ ] **Step 5: Run the test, then the whole suite**

Run: `Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -FullNameFilter '*store-only artifacts*' -Output Detailed`
Expected: PASS

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, 2 skipped.

- [ ] **Step 6: Commit**

```bash
git add setup-claude-accounts.ps1 tests/SharedMemoryFile.Tests.ps1
git commit -m "Keep bin/ and statusline.sh out of seeded accounts

Copy-Tree excluded only the shared dirs and files. Once the store is
~/.claude, the seed source contains the store's own artifacts too."
```

---

### Task 3: Replace the `$memoryIsShared` sentinel with a semantic test

**Files:**
- Modify: `claude-account-profile.ps1:93`
- Modify: `tests/SharedMemoryFile.Tests.ps1` (un-skip and rewrite `:263`)

**Interfaces:**
- Consumes: `Test-ClaudeSharedMemory -AccountDir <string>` returning `[bool]`, already defined at `claude-account-profile.ps1:50`.
- Produces: nothing new.

- [ ] **Step 1: Rewrite the skipped test as the failing test**

In `tests/SharedMemoryFile.Tests.ps1`, remove `-Skip` from `It 'says nothing when CLAUDE.md is not a shared file at all'` and replace its body. The old setup deleted the store copy; with the store at `~/.claude` that deletes the memory file itself, which is a different scenario entirely.

```powershell
    It 'says nothing when CLAUDE.md is not a shared file at all' {
        # Leaving CLAUDE.md out of -SharedFiles is a choice, not a fault, and
        # must not flag every account on the machine. The old sentinel was the
        # existence of ~/.claude-shared/CLAUDE.md; with the store at ~/.claude
        # that file's existence proves only that a memory file exists, so the
        # gate has to infer intent from the links themselves.
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\other.md') -Value 'other'
        & $script:SetupScript -Accounts work,personal -SeedInto work `
                              -SharedFiles other.md -NoStatusLine 6>&1 | Out-Null

        (Get-ClaudeAccount 6>&1 | Out-String -Width 500) | Should -Not -Match 'not shared'
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -FullNameFilter '*not a shared file at all*' -Output Detailed`
Expected: FAIL — `~/.claude/CLAUDE.md` exists (setup created it, or the fixture did), so the path-based gate opens and both accounts are flagged `CLAUDE.md not shared`.

- [ ] **Step 3: Replace the gate**

`claude-account-profile.ps1:93`, replace:

```powershell
    $memoryIsShared = Test-Path -LiteralPath (Join-Path $HOME '.claude\CLAUDE.md') -PathType Leaf
```

with:

```powershell
    # Is CLAUDE.md shared AT ALL on this machine? The old test was the presence
    # of ~/.claude-shared/CLAUDE.md, which proved the user ASKED for it to be
    # shared. With the store at ~/.claude that file's presence proves only that
    # a memory file exists, so intent has to be inferred from the links: if any
    # account still holds a name for the store's inode, sharing was set up.
    #
    # Blind spot, accepted deliberately: when EVERY account's link is broken at
    # once this closes and the tag goes quiet. Distinguishing that from "never
    # shared" needs a marker file, and the directory is the account here.
    $accountDirs    = @(Get-ClaudeAccountDir)
    $memoryIsShared = [bool](@($accountDirs | Where-Object {
        Test-ClaudeSharedMemory -AccountDir $_.FullName
    }).Count)
```

Note `Get-ClaudeAccountDir` is now called twice in `Get-ClaudeAccount` — once here and once for the listing below. Hoist it: assign `$accountDirs` here and change the listing at `:105` from `Get-ClaudeAccountDir | ForEach-Object {` to `$accountDirs | ForEach-Object {`.

- [ ] **Step 4: Run the test, then the whole suite**

Run: `Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -Output Detailed`
Expected: PASS. Confirm `flags the account whose link an editor broke` (`:238`) and `still reports a missing login, and both tags together` (`:251`) both still pass — `work` stays linked, so the gate opens and `personal` is still flagged. These two are the regression guard for this change.

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, 1 skipped.

- [ ] **Step 5: Commit**

```bash
git add claude-account-profile.ps1 tests/SharedMemoryFile.Tests.ps1
git commit -m "Infer shared-memory intent from links, not a store path

The old sentinel proved the user asked for CLAUDE.md to be shared. Once
the store is ~/.claude the same path proves only that a memory file
exists, which would flag every account for a deliberate choice."
```

---

### Task 4: Recover a deleted `CLAUDE.md` from an account peer

**Files:**
- Modify: `setup-claude-accounts.ps1:440-470` (the `$SharedFiles` loop)
- Modify: `tests/SharedMemoryFile.Tests.ps1` (un-skip and rewrite `:172`)

**Interfaces:**
- Consumes: `Test-SameFile`, `New-FileLink`, `Get-LinkPeer` (all already in setup).
- Produces: `Find-SharedFilePeer -FileName <string> -Store <string>` returning the full path of a surviving account copy, or `$null`.

- [ ] **Step 1: Rewrite the skipped test as the failing test**

```powershell
    It 'recovers a deleted store CLAUDE.md from a surviving account copy' {
        # With the store at ~/.claude, the old recovery branch is unreachable:
        # it fired when the store still had the file and ~/.claude did not, and
        # those are now one path. The inode survives under the ACCOUNT names,
        # so that is where the recovery handle has to come from.
        & $script:SetupScript -Accounts work -SeedInto work -NoStatusLine 6>&1 | Out-Null
        $store = Join-Path $script:FakeHome '.claude\CLAUDE.md'
        Set-Content -LiteralPath $store -Value 'memory worth keeping'
        Remove-Item -LiteralPath $store -Force

        # Must NOT throw. Creating an empty store file here would make the
        # per-account link pass refuse to overwrite the account's copy and
        # abort the whole run.
        { & $script:SetupScript -Accounts work -NoSeed -NoStatusLine 6>&1 | Out-Null } |
            Should -Not -Throw

        Test-OneInode $store (Join-Path $script:FakeHome '.claude-work\CLAUDE.md') |
            Should -BeTrue
        (Get-Content -LiteralPath $store -Raw) | Should -Match 'memory worth keeping'
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -FullNameFilter '*surviving account copy*' -Output Detailed`
Expected: FAIL with a throw from `New-FileLink` — "Refusing to overwrite ...CLAUDE.md". That throw is the defect; do not weaken `New-FileLink` to silence it.

- [ ] **Step 3: Add the peer-finding helper**

In `setup-claude-accounts.ps1`, after `Test-BlankFile`:

```powershell
function Find-SharedFilePeer {
    # A surviving name for a shared file's inode, found among the account dirs.
    #
    # When the store was a separate directory it was itself the recovery handle:
    # ~/.claude could lose its copy and be re-linked from ~/.claude-shared. Now
    # that those are one path, the accounts are the only other names, so they
    # are where a deleted store file has to be recovered from.
    param([string] $FileName, [string] $Store)

    $storeFull = (Get-Item -LiteralPath $Store -Force).FullName.TrimEnd('\')
    Get-ChildItem -Path $HOME -Directory -Filter '.claude-*' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.TrimEnd('\') -ne $storeFull } |
        ForEach-Object {
            $candidate = Join-Path $_.FullName $FileName
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
                -not (Test-BlankFile -Path $candidate)) {
                return $candidate
            }
        } | Select-Object -First 1
}
```

- [ ] **Step 4: Use it in the shared-files loop**

`setup-claude-accounts.ps1`, in the `foreach ($file in $SharedFiles)` loop. The `elseif (Test-Path -LiteralPath $target)` branch is now dead when `$Shared -eq $SeedFrom`; leave it in place for a custom `-SeedFrom`, and insert the peer recovery **before** the "create empty" branch:

```powershell
    } elseif ($peer = Find-SharedFilePeer -FileName $file -Store $Shared) {
        # The store's name is gone but the inode is alive under an account's
        # name. Re-link rather than creating an empty file: an empty store file
        # would make the per-account pass below hit New-FileLink's refusal on
        # every account that still has content, aborting the run.
        if ($DryRun) {
            Write-Step "would re-link $file into $Shared from $peer"
        } else {
            New-FileLink -Link $target -Target $peer
            Write-Done "$file (recovered from $peer)"
        }
        $SeedFromAdditions += $file
    } elseif (Test-Path -LiteralPath $SeedFrom) {
```

- [ ] **Step 5: Run the test, then the whole suite**

Run: `Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -Output Detailed`
Expected: PASS

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, 0 skipped. Every deferred test is now restored.

- [ ] **Step 6: Commit**

```bash
git add setup-claude-accounts.ps1 tests/SharedMemoryFile.Tests.ps1
git commit -m "Recover a deleted store CLAUDE.md from an account peer

The old recovery branch is unreachable once store and home are one path,
and falling through to 'create empty' made the per-account link pass
throw and abort mid-run."
```

---

### Task 5: Make the closing summary tell the truth

**Files:**
- Modify: `setup-claude-accounts.ps1:437-438` (move the array init), `:407-433` (record dir creation), `:510-520` (record the statusline copy), `:611` (delete the false line)
- Test: `tests/StatusLine.Tests.ps1` (new `It`)

**Interfaces:**
- Consumes: `$SeedFromAdditions`, `$SeedFromEdits` (`string[]`).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append inside `Describe 'setup-claude-accounts.ps1 shares the status line'` (`tests/StatusLine.Tests.ps1:97`), which already provides `New-StatusLineFakeHome` via its `BeforeEach` and requires Git Bash and node — both of which this test needs, because it must reach the status-line block.

**A single fresh run will not reproduce the bug.** On a first run the shared dirs are created and `Set-StatusLine` edits `settings.json`, so both lists are non-empty and the false line never prints. The failure needs a *second* run whose only change is the `statusline.sh` copy.

```powershell
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Invoke-Pester -Path tests\StatusLine.Tests.ps1 -FullNameFilter '*rather than claiming nothing changed*' -Output Detailed`
Expected: FAIL — the summary prints `Your original ~/.claude was not modified` and never names `statusline.sh`.

- [ ] **Step 3: Move the array initialisation above the store work**

Cut these two lines from `:437-438` and paste them immediately after the `Write-Head "Shared store"` line at `:409`, keeping the comment:

```powershell
# Anything this run puts INTO the store, or changes there. The store is now
# ~/.claude itself, so this covers the shared dirs and statusline.sh as well as
# the shared files - a summary that only counted the last of those could claim
# nothing was modified after modifying it.
$SeedFromAdditions = @()
$SeedFromEdits     = @()
```

- [ ] **Step 4: Record the store writes**

In the `foreach ($dir in $SharedDirs)` loop, after each `Write-Done`:

```powershell
        Write-Done "$dir (copied from current config)"
        $SeedFromAdditions += "$dir/"
```

```powershell
        Write-Done "$dir (created empty)"
        $SeedFromAdditions += "$dir/"
```

In the status-line block, after the copy:

```powershell
            Copy-Item -LiteralPath $StatusLine -Destination $target -Force
            Write-Done "copied $([IO.Path]::GetFileName($StatusLine)) -> $Shared"
            $SeedFromEdits += [IO.Path]::GetFileName($StatusLine)
```

- [ ] **Step 5: Delete the false line**

`setup-claude-accounts.ps1:611`, replace the `else` branch:

```powershell
} else {
    Write-Host "  Nothing in $SeedFrom was added or changed."
}
```

The old text claimed `~/.claude` as a whole was untouched. It is the store now, so the only honest statement is about this run specifically.

- [ ] **Step 6: Run the test, then the whole suite**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, 0 skipped.

- [ ] **Step 7: Commit**

```bash
git add setup-claude-accounts.ps1 tests/StatusLine.Tests.ps1
git commit -m "Report every write into the store

The arrays were initialised after the shared dirs were already created,
and the statusline.sh copy was recorded nowhere, so the summary could
claim ~/.claude was unmodified after modifying it."
```

---

## Phase B — The migration script

### Task 6: `migrate-shared-store.ps1` — discovery, manifest, and `-DryRun` skeleton

**Files:**
- Create: `migrate-shared-store.ps1`
- Create: `tests/Migrate-SharedStore.Tests.ps1`
- Modify: `tests/Fixtures.ps1` (add a legacy-store fixture)

**Interfaces:**
- Consumes: nothing from Phase A at runtime; Phase A must be merged so Task 11's handoff works.
- Produces:
  - `Get-MigrationAccount -Legacy <string>` → `[IO.DirectoryInfo[]]`
  - `$ManifestPath` = `Join-Path $Store '.migrate-shared-store.state'`
  - `Write-MigrationManifest -Accounts <string[]>` / `Read-MigrationManifest` → `[string[]]` of full paths

- [ ] **Step 1: Add the legacy-store fixture**

Append to `tests/Fixtures.ps1`:

```powershell
function New-LegacyFakeHome {
    # A fake home in the PRE-merge shape: a real ~/.claude-shared holding the
    # shared dirs, accounts junctioned into it, and a ~/.claude that has its own
    # divergent copies. This is what migrate-shared-store.ps1 consumes.
    $fake = Join-Path ([IO.Path]::GetTempPath()) ("claude-migrate-test-" + [guid]::NewGuid().ToString('N'))
    foreach ($d in @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $fake ".claude-shared\$d") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $fake ".claude\$d") -Force
    }
    Set-Variable -Name HOME -Value $fake -Scope Global -Force
    return $fake
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
```

Reuse the existing `Remove-FakeHome` for teardown — it already unlinks reparse points before deleting, which is mandatory here.

- [ ] **Step 2: Write the failing discovery tests**

Create `tests/Migrate-SharedStore.Tests.ps1`:

```powershell
. "$PSScriptRoot\Fixtures.ps1"

Describe 'migrate-shared-store.ps1 discovery' {
    BeforeEach {
        $script:RealHome = $HOME
        $script:FakeHome = New-LegacyFakeHome
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome }

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
```

- [ ] **Step 3: Run to verify they fail**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -Output Detailed`
Expected: FAIL — the script does not exist.

- [ ] **Step 4: Write the script skeleton**

Create `migrate-shared-store.ps1`:

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Move ~/.claude-shared into ~/.claude, once.

.DESCRIPTION
    Merges the legacy shared store into ~/.claude, retargets every account's
    junctions, and hands off to setup-claude-accounts.ps1 and install.ps1.

    Never deletes ~/.claude-shared. It is left on disk as a full standby copy;
    deleting it is yours to do once the report says it is safe.

    PRECONDITION: close all Claude Code sessions first. Nothing enforces this;
    Phase 2b detects a write that happened during the run and withholds the
    deletion guidance, but it cannot prevent one.

.EXAMPLE
    .\migrate-shared-store.ps1 -DryRun
    .\migrate-shared-store.ps1
#>
[CmdletBinding()]
param(
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$Legacy       = Join-Path $HOME '.claude-shared'
$Store        = Join-Path $HOME '.claude'
$ManifestPath = Join-Path $Store '.migrate-shared-store.state'
$SharedDirs   = @('projects', 'skills', 'agents', 'commands', 'hooks', 'plugins')

function Write-Step { param($Message) Write-Host "  $Message" }
function Write-Head { param($Message) Write-Host "`n$Message" -ForegroundColor Cyan }
function Write-Skip { param($Message) Write-Host "  - $Message" -ForegroundColor DarkGray }
function Write-Done { param($Message) Write-Host "  + $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "  ! $Message" -ForegroundColor Yellow }

function Test-JunctionInto {
    # Is $Path a junction whose target sits under $Root?
    param([string] $Path, [string] $Root)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $target = @($item.Target) | Select-Object -First 1
    if (-not $target) { return $false }
    # Resolve-Path keeps a trailing separator and throws on a missing path, so
    # compare trimmed strings rather than resolving.
    return $target.TrimEnd('\', '/').StartsWith($Root.TrimEnd('\', '/'), 'OrdinalIgnoreCase')
}

function Read-MigrationManifest {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $ManifestPath | Where-Object { $_.Trim() })
}

function Write-MigrationManifest {
    # Transient, and deleted on success. This is NOT the account registry the
    # architecture rejects: it lives for one run, is authoritative for nothing,
    # and its presence afterwards means a run did not finish. An account that
    # shares only projects/ has exactly one on-disk signal, and Phase 2 erases
    # it between rmdir and mklink - this is what survives that window.
    param([string[]] $Accounts)
    if ($DryRun) { return }
    [IO.File]::WriteAllText($ManifestPath, ($Accounts -join "`r`n"),
                            (New-Object Text.UTF8Encoding $false))
}

function Get-MigrationAccount {
    # Deliberately WIDER than Get-ClaudeAccountDir: an account counts if it has
    # a projects/ entry OR any junction into the legacy store OR is named in a
    # manifest left by an interrupted run. The narrow rule would skip an account
    # whose projects/ junction was removed but not yet recreated.
    $fromManifest = Read-MigrationManifest
    Get-ChildItem -Path $HOME -Directory -Filter '.claude-*' -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne '.claude-shared' -and (
                (Test-Path -LiteralPath (Join-Path $_.FullName 'projects')) -or
                (@($SharedDirs | Where-Object {
                    Test-JunctionInto -Path (Join-Path $_.FullName $PSItem) -Root $Legacy
                }).Count -gt 0) -or
                ($fromManifest -contains $_.FullName)
            )
        }
}

# ------------------------------------------------------------ phase 0 --------

Write-Host "Merge ~/.claude-shared into ~/.claude" -ForegroundColor White
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $Legacy)) {
    Write-Host "`nNothing to do: $Legacy does not exist." -ForegroundColor Green
    return
}
if (-not (Test-Path -LiteralPath $Store)) {
    throw "Refusing to run: $Store does not exist. Run setup-claude-accounts.ps1 first."
}

Write-Head "Accounts"
$accounts = @(Get-MigrationAccount)
if ($accounts.Count -eq 0) {
    Write-Skip "none found"
} else {
    foreach ($a in $accounts) { Write-Step $a.Name }
}
Write-MigrationManifest -Accounts @($accounts | ForEach-Object { $_.FullName })
```

Note the `Where-Object` uses `$PSItem` inside the nested pipeline because `$_` is rebound by the inner `Where-Object`.

- [ ] **Step 5: Run the tests**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -Output Detailed`
Expected: PASS, all 4.

- [ ] **Step 6: Commit**

```bash
git add migrate-shared-store.ps1 tests/Migrate-SharedStore.Tests.ps1 tests/Fixtures.ps1
git commit -m "Add migrate-shared-store.ps1 discovery and dry-run skeleton

Discovery is wider than Get-ClaudeAccountDir's rule and backed by a
transient manifest, so an account interrupted between rmdir and mklink
is still found on the next run."
```

---

### Task 7: Phase 0b — preflight `CLAUDE.md` before any mutation

**Files:**
- Modify: `migrate-shared-store.ps1` (append Phase 0b)
- Modify: `tests/Migrate-SharedStore.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MigrationAccount` from Task 6.
- Produces: `Test-SameInode -Path <string> -Other <string>` → `[bool]`; aborts the script via `throw` on divergence.

- [ ] **Step 1: Write the failing test**

```powershell
Describe 'migrate-shared-store.ps1 preflight' {
    BeforeEach {
        $script:RealHome = $HOME
        $script:FakeHome = New-LegacyFakeHome
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome }

    It 'aborts on a divergent account CLAUDE.md without mutating anything' {
        # Editor replace-on-save turns a hardlink into a plain file. If that
        # divergence is not caught up front, Phase 2 retargets the junctions and
        # THEN setup's New-FileLink throws - leaving a half-migrated machine
        # that every re-run fails on identically.
        $acct = New-LegacyAccount -Name work
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\CLAUDE.md') -Value 'store memory'
        Set-Content -LiteralPath (Join-Path $acct 'CLAUDE.md') -Value 'DIVERGENT account memory'

        { & $script:Script 6>&1 | Out-Null } | Should -Throw -ExpectedMessage '*CLAUDE.md*'

        # Nothing mutated: the junction still points at the legacy store.
        (Get-Item -LiteralPath (Join-Path $acct 'projects') -Force).Target |
            Should -Match 'claude-shared'
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
}
```

- [ ] **Step 2: Run to verify the first test fails**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -FullNameFilter '*divergent account*' -Output Detailed`
Expected: FAIL — no throw, because preflight does not exist yet.

- [ ] **Step 3: Implement Phase 0b**

Append to `migrate-shared-store.ps1`:

```powershell
# ----------------------------------------------------------- phase 0b --------

function Test-SameInode {
    # Two paths, one inode. Hardlinks are symmetric, so FileInfo.Target lists
    # every OTHER name and can return them volume-relative.
    param([string] $Path, [string] $Other)

    if (-not (Test-Path -LiteralPath $Path  -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Other -PathType Leaf)) { return $false }

    $item      = Get-Item -LiteralPath $Path  -Force
    $otherFull = (Get-Item -LiteralPath $Other -Force).FullName
    if ($item.FullName -eq $otherFull) { return $true }
    if ($item.LinkType -ne 'HardLink')  { return $false }

    foreach ($peer in @($item.Target)) {
        if ([string]::IsNullOrWhiteSpace($peer)) { continue }
        if ($peer -notmatch '^[A-Za-z]:\\' -and $peer -notmatch '^\\\\') {
            $peer = (Split-Path -Qualifier $item.FullName) + $peer
        }
        if ($peer -eq $otherFull) { return $true }
    }
    return $false
}

Write-Head "Preflight"

$storeMemory = Join-Path $Store 'CLAUDE.md'
$divergent   = @()

foreach ($acct in $accounts) {
    $acctMemory = Join-Path $acct.FullName 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $acctMemory -PathType Leaf)) { continue }
    if (Test-SameInode -Path $acctMemory -Other $storeMemory)     { continue }
    if ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $acctMemory -Raw))) { continue }
    if ((Test-Path -LiteralPath $storeMemory -PathType Leaf) -and
        ((Get-Content -LiteralPath $acctMemory -Raw) -eq (Get-Content -LiteralPath $storeMemory -Raw))) { continue }
    $divergent += $acctMemory
}

if ($divergent.Count -gt 0) {
    # Refuse BEFORE anything is mutated. setup's New-FileLink would refuse
    # later anyway, but only after Phase 2 had already retargeted the
    # junctions - and every re-run would then fail the same way.
    throw ("Refusing to migrate: these CLAUDE.md files have content of their own`n" +
           ($divergent | ForEach-Object { "         $_" }) -join "`n") + "`n" +
          "       Merge what you want to keep into $storeMemory, delete the copy, then re-run."
}
Write-Done "CLAUDE.md is consistent across every account"
```

- [ ] **Step 4: Run the tests, then the whole suite**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -Output Detailed`
Expected: PASS, all 7.

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add migrate-shared-store.ps1 tests/Migrate-SharedStore.Tests.ps1
git commit -m "Preflight CLAUDE.md before migrating anything

A divergent account copy made setup throw after Phase 2 had already
retargeted, leaving a half-migrated machine no re-run could fix."
```

---

### Task 8: Phase 1 — merge the tree, per-source policy

**Files:**
- Modify: `migrate-shared-store.ps1` (append Phase 1)
- Modify: `tests/Migrate-SharedStore.Tests.ps1`

**Interfaces:**
- Consumes: `$Legacy`, `$Store`, `$SharedDirs`.
- Produces: `$script:ReadFiles` — a `hashtable` keyed by full legacy path with value `[pscustomobject]@{ Length = <long>; LastWriteTimeUtc = <datetime> }`, consumed by Task 10's Phase 2b.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'migrate-shared-store.ps1 merge' {
    BeforeEach {
        $script:RealHome = $HOME
        $script:FakeHome = New-LegacyFakeHome
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
        $null = New-LegacyAccount -Name work
    }
    AfterEach { Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome }

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
```

- [ ] **Step 2: Run to verify they fail**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -FullNameFilter '*merge*' -Output Detailed`
Expected: FAIL — Phase 1 does not exist.

- [ ] **Step 3: Implement Phase 1**

Append to `migrate-shared-store.ps1`:

```powershell
# ------------------------------------------------------------ phase 1 --------

# Every legacy file this run READ, with the size and timestamp it had at the
# time. Phase 2b re-checks these: a change means something wrote during the run
# and the merge is incomplete.
$script:ReadFiles  = @{}
$script:Conflicts  = @()
$script:Copied     = 0
$script:Overwrote  = 0

function Register-ReadFile {
    param([IO.FileInfo] $Item)
    $script:ReadFiles[$Item.FullName] = [pscustomobject]@{
        Length           = $Item.Length
        LastWriteTimeUtc = $Item.LastWriteTimeUtc
    }
}

function Copy-LegacyTree {
    # Walks one legacy subtree and applies a per-source policy.
    #   Missing      -> copy
    #   Identical    -> skip
    #   Differs      -> $OnConflict decides: 'keep-store' or 'legacy-wins'
    # projects/ is handled separately in Phase 1b: transcripts need classifying,
    # not a flat rule.
    param(
        [string] $Source,
        [string] $Destination,
        [ValidateSet('keep-store', 'legacy-wins')] [string] $OnConflict
    )

    if (-not (Test-Path -LiteralPath $Source)) { return }

    Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Register-ReadFile -Item $_
            $relative = $_.FullName.Substring($Source.Length).TrimStart('\')
            $target   = Join-Path $Destination $relative

            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                if ($DryRun) { Write-Step "would copy $relative"; return }
                $parent = Split-Path $target -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    $null = New-Item -ItemType Directory -Path $parent -Force
                }
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                $script:Copied++
                return
            }

            if ((Get-FileHash -LiteralPath $_.FullName).Hash -eq
                (Get-FileHash -LiteralPath $target).Hash) { return }

            if ($OnConflict -eq 'legacy-wins') {
                if ($DryRun) { Write-Step "would overwrite $relative"; return }
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                $script:Overwrote++
            } else {
                $script:Conflicts += $target
            }
        }
}

Write-Head "Merge"

foreach ($dir in @('skills', 'agents', 'commands', 'hooks')) {
    Copy-LegacyTree -Source (Join-Path $Legacy $dir) -Destination (Join-Path $Store $dir) `
                    -OnConflict 'keep-store'
}

# plugins/ is the one documented exception to never-overwrite. The legacy tree
# is the one the accounts have actually been using, and its registry JSONs know
# about plugins the store's stale copy does not. Overwrite and add; delete
# nothing.
Copy-LegacyTree -Source (Join-Path $Legacy 'plugins') -Destination (Join-Path $Store 'plugins') `
                -OnConflict 'legacy-wins'

# Store-only artifacts: they belong in the store but are never shared into an
# account, so setup excludes them from seeding.
Copy-LegacyTree -Source (Join-Path $Legacy 'bin') -Destination (Join-Path $Store 'bin') `
                -OnConflict 'keep-store'

$legacyStatusLine = Join-Path $Legacy 'statusline.sh'
if (Test-Path -LiteralPath $legacyStatusLine -PathType Leaf) {
    Register-ReadFile -Item (Get-Item -LiteralPath $legacyStatusLine -Force)
    $target = Join-Path $Store 'statusline.sh'
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        if ($DryRun) {
            Write-Step "would copy statusline.sh"
        } else {
            Copy-Item -LiteralPath $legacyStatusLine -Destination $target -Force
            Write-Done "statusline.sh"
        }
    }
}

# CLAUDE.md needs nothing: preflight already proved every name is one inode, so
# the store's copy IS the legacy store's copy.

Write-Done "$($script:Copied) copied, $($script:Overwrote) overwritten (plugins), $($script:Conflicts.Count) conflicts"
```

- [ ] **Step 4: Run the tests**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add migrate-shared-store.ps1 tests/Migrate-SharedStore.Tests.ps1
git commit -m "Merge the legacy tree with a policy per source

Never-overwrite everywhere except plugins/, where the legacy registry
must win or the copied plugin trees land unregistered."
```

---

### Task 9: Phase 1b — classify and resolve `projects/` transcripts

**Files:**
- Modify: `migrate-shared-store.ps1` (append Phase 1b)
- Modify: `tests/Migrate-SharedStore.Tests.ps1`

**Interfaces:**
- Consumes: `Register-ReadFile`, `$script:Conflicts` from Task 8.
- Produces: `Get-JsonlRelation -Store <string> -Legacy <string>` returning one of the literal strings `'identical'`, `'superseded'`, `'continued'`, `'forked'`.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'migrate-shared-store.ps1 transcripts' {
    BeforeEach {
        $script:RealHome = $HOME
        $script:FakeHome = New-LegacyFakeHome
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
        $null = New-LegacyAccount -Name work
        $script:Proj = 'D--demo'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FakeHome ".claude-shared\projects\$($script:Proj)") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FakeHome ".claude\projects\$($script:Proj)") -Force
    }
    AfterEach { Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome }

    function Write-Jsonl {
        param([string] $Path, [string[]] $Lines)
        [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"),
                                (New-Object Text.UTF8Encoding $false))
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
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -FullNameFilter '*transcripts*' -Output Detailed`
Expected: FAIL — Phase 1b does not exist, so no `.jsonl` is merged at all.

- [ ] **Step 3: Implement Phase 1b**

Append to `migrate-shared-store.ps1`:

```powershell
# ----------------------------------------------------------- phase 1b --------

$script:Superseded = 0
$script:Adopted    = 0
$script:Rescued    = @()

function Test-JsonLine {
    param([string] $Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $true }
    try { $null = ConvertFrom-Json $Line; return $true } catch { return $false }
}

function Get-JsonlRelation {
    # 'identical' | 'superseded' | 'continued' | 'forked'
    #
    # superseded: legacy is a strict line-prefix of store  -> store already has it
    # continued : store is a strict line-prefix of legacy  -> legacy has more
    # forked    : neither is a prefix of the other
    param([string] $Store, [string] $Legacy)

    $s = @(Get-Content -LiteralPath $Store  -ErrorAction SilentlyContinue)
    $l = @(Get-Content -LiteralPath $Legacy -ErrorAction SilentlyContinue)
    $shorter = [Math]::Min($s.Count, $l.Count)

    for ($i = 0; $i -lt $shorter; $i++) {
        if ($s[$i] -ne $l[$i]) { return 'forked' }
    }
    if ($s.Count -eq $l.Count) { return 'identical' }
    if ($l.Count -lt $s.Count) { return 'superseded' }
    return 'continued'
}

function New-RescuedTranscript {
    # Copy a forked legacy transcript in under a fresh session id so both halves
    # are resumable. Only the two top-level id FIELDS are rewritten: the other
    # mentions of the id in a transcript are temp scratchpad paths and tool
    # output, which are a historical record and resolve to nothing we own.
    #
    # Sidecar <id>/ directories are deliberately NOT renamed. Phase 1's
    # add-if-missing pass already merged any sidecar files, and renaming one
    # without rewriting the transcript's references to it would break them.
    param([string] $LegacyPath, [string] $Destination, [string] $OldId)

    $newId = [guid]::NewGuid().ToString()
    $text  = [IO.File]::ReadAllText($LegacyPath)
    $text  = $text.Replace("`"sessionId`":`"$OldId`"",  "`"sessionId`":`"$newId`"")
    $text  = $text.Replace("`"session_id`":`"$OldId`"", "`"session_id`":`"$newId`"")

    $target = Join-Path $Destination "$newId.jsonl"
    [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding $false))
    return $newId
}

function Copy-LegacyProjects {
    $source = Join-Path $Legacy 'projects'
    $dest   = Join-Path $Store  'projects'
    if (-not (Test-Path -LiteralPath $source)) { return }

    Get-ChildItem -LiteralPath $source -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Register-ReadFile -Item $_
            $relative = $_.FullName.Substring($source.Length).TrimStart('\')
            $target   = Join-Path $dest $relative

            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                if ($DryRun) { Write-Step "would copy $relative"; return }
                $parent = Split-Path $target -Parent
                if (-not (Test-Path -LiteralPath $parent)) {
                    $null = New-Item -ItemType Directory -Path $parent -Force
                }
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                $script:Copied++
                return
            }

            if ((Get-FileHash -LiteralPath $_.FullName).Hash -eq
                (Get-FileHash -LiteralPath $target).Hash) { return }

            if ($_.Extension -ne '.jsonl') { $script:Conflicts += $target; return }

            switch (Get-JsonlRelation -Store $target -Legacy $_.FullName) {
                'identical'  { }
                'superseded' { $script:Superseded++ }
                'continued'  {
                    # Validate every ADDED line before letting it replace a file
                    # that currently parses. Strict prefix says nothing about
                    # the suffix, and a truncated tail satisfies it exactly.
                    $storeCount = @(Get-Content -LiteralPath $target).Count
                    $added      = @(Get-Content -LiteralPath $_.FullName) |
                                      Select-Object -Skip $storeCount
                    if (@($added | Where-Object { -not (Test-JsonLine -Line $_) }).Count -gt 0) {
                        $script:Conflicts += $target
                        Write-Warn "not adopted (malformed added line): $relative"
                        return
                    }
                    if ($DryRun) { Write-Step "would adopt $relative"; return }
                    # Temp file then move, so an interrupted adoption cannot
                    # leave a half-written transcript where a valid one was.
                    $tmp = "$target.migrating"
                    Copy-Item -LiteralPath $_.FullName -Destination $tmp -Force
                    Move-Item -LiteralPath $tmp -Destination $target -Force
                    $script:Adopted++
                }
                'forked' {
                    $oldId = [IO.Path]::GetFileNameWithoutExtension($_.Name)
                    if ($DryRun) { Write-Step "would rescue $relative under a new id"; return }
                    $newId = New-RescuedTranscript -LegacyPath $_.FullName `
                                                   -Destination (Split-Path $target -Parent) `
                                                   -OldId $oldId
                    $script:Rescued += "$oldId -> $newId"
                }
            }
        }
}

Copy-LegacyProjects
Write-Done ("projects: {0} superseded, {1} adopted, {2} rescued" -f `
            $script:Superseded, $script:Adopted, $script:Rescued.Count)
```

Insert the `Copy-LegacyProjects` call **before** the closing `Write-Done` of Phase 1 so the counts print once.

- [ ] **Step 4: Run the tests**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -Output Detailed`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add migrate-shared-store.ps1 tests/Migrate-SharedStore.Tests.ps1
git commit -m "Classify and resolve conflicting transcripts

Superseded skipped, continued adopted only when every added line parses,
forked rescued under a fresh session id. Sidecar dirs are left alone."
```

---

### Task 10: Phase 2 and 2b — retarget junctions, then recheck the source

**Files:**
- Modify: `migrate-shared-store.ps1` (append Phases 2 and 2b)
- Modify: `tests/Migrate-SharedStore.Tests.ps1`

**Interfaces:**
- Consumes: `$accounts`, `Test-JunctionInto`, `$script:ReadFiles`.
- Produces: `$script:Drifted` (`string[]`), consumed by Task 11's report gate.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'migrate-shared-store.ps1 retargeting' {
    BeforeEach {
        $script:RealHome = $HOME
        $script:FakeHome = New-LegacyFakeHome
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
    }
    AfterEach { Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome }

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
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -FullNameFilter '*retargeting*' -Output Detailed`
Expected: FAIL — junctions still point at the legacy store.

- [ ] **Step 3: Add the drift-simulation parameter**

Add to the `param(...)` block at the top of `migrate-shared-store.ps1`:

```powershell
    # Test seam: rewrite this legacy file after Phase 1 has recorded it, to
    # exercise the Phase 2b drift check. There is no honest way to race a real
    # Claude Code session from a test.
    [string] $SimulateDriftPath
```

- [ ] **Step 4: Implement Phases 2 and 2b**

```powershell
# ------------------------------------------------------------ phase 2 --------

Write-Head "Retarget"

$refused = @()

foreach ($acct in $accounts) {
    foreach ($dir in $SharedDirs) {
        $link      = Join-Path $acct.FullName $dir
        $newTarget = Join-Path $Store $dir

        if (-not (Test-Path -LiteralPath $link)) {
            if ($DryRun) { Write-Step "would link $link"; continue }
            $null = cmd /c mklink /J "$link" "$newTarget"
            Write-Done "linked $($acct.Name)\$dir"
            continue
        }

        $item = Get-Item -LiteralPath $link -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            # A real directory with real content. Refuse, exactly as
            # New-Junction does - never delete what we did not create.
            $refused += $link
            Write-Warn "Refusing to replace real directory: $link"
            continue
        }
        if (-not (Test-JunctionInto -Path $link -Root $Legacy)) {
            Write-Skip "already points at the store: $($acct.Name)\$dir"
            continue
        }
        if ($DryRun) { Write-Step "would retarget $link"; continue }

        # rmdir, never Remove-Item -Recurse: on 5.1 that follows the junction
        # and would empty the legacy store - the standby copy this whole design
        # depends on.
        cmd /c rmdir "$link" | Out-Null
        $null = cmd /c mklink /J "$link" "$newTarget"
        Write-Done "retargeted $($acct.Name)\$dir"
    }
}

# ----------------------------------------------------------- phase 2b --------

if ($SimulateDriftPath) {
    Add-Content -LiteralPath $SimulateDriftPath -Value 'appended during the run'
}

Write-Head "Stability check"

$script:Drifted = @()
foreach ($path in $script:ReadFiles.Keys) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $script:Drifted += $path; continue }
    $now  = Get-Item -LiteralPath $path -Force
    $then = $script:ReadFiles[$path]
    if ($now.Length -ne $then.Length -or $now.LastWriteTimeUtc -ne $then.LastWriteTimeUtc) {
        $script:Drifted += $path
    }
}

if ($script:Drifted.Count -gt 0) {
    # Something wrote to the legacy store while this ran - almost certainly a
    # live Claude Code session. Those lines were never merged, so the merge is
    # incomplete and the standby copy must not be deleted.
    Write-Warn "$($script:Drifted.Count) file(s) changed during this run:"
    foreach ($p in $script:Drifted | Select-Object -First 10) { Write-Step $p }
    Write-Warn "Close all Claude Code sessions and re-run. The merge is idempotent."
} else {
    Write-Done "the legacy store did not change during this run"
}
```

- [ ] **Step 5: Run the tests**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -Output Detailed`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add migrate-shared-store.ps1 tests/Migrate-SharedStore.Tests.ps1
git commit -m "Retarget junctions and recheck the legacy store afterwards

Removal is cmd /c rmdir only. A real directory in the way is refused,
never deleted. Drift during the run blocks the deletion guidance."
```

---

### Task 11: Phase 3 and 4 — handoff and the gated report

**Files:**
- Modify: `migrate-shared-store.ps1` (append Phases 3 and 4)
- Modify: `tests/Migrate-SharedStore.Tests.ps1`

**Interfaces:**
- Consumes: `$script:Drifted`, `$script:Conflicts`, `$script:Rescued`, `$refused`, `$ManifestPath`.
- Produces: the script's final output; nothing downstream.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'migrate-shared-store.ps1 handoff and report' {
    BeforeEach {
        $script:RealHome = $HOME
        $script:FakeHome = New-LegacyFakeHome
        $script:Script   = Join-Path (Split-Path $PSScriptRoot -Parent) 'migrate-shared-store.ps1'
        $null = New-LegacyAccount -Name work
    }
    AfterEach { Remove-FakeHome -Path $script:FakeHome -RealHome $script:RealHome }

    It 'forwards -DryRun to setup so the handoff writes nothing' {
        # -NoSeed does NOT make setup inert: it still copies statusline.sh,
        # rewrites settings.json and creates links.
        $out = & $script:Script -DryRun 6>&1 | Out-String -Width 500

        Test-Path -LiteralPath (Join-Path $script:FakeHome '.claude\settings.json') | Should -BeFalse
        $out | Should -Match 'DRY RUN'
    }

    It 'withholds the deletion guidance when a conflict was reported' {
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude-shared\skills\c.md') -Value 'legacy'
        Set-Content -LiteralPath (Join-Path $script:FakeHome '.claude\skills\c.md')        -Value 'store'

        $out = & $script:Script 6>&1 | Out-String -Width 500

        $out | Should -Not -Match 'safe to delete'
        $out | Should -Match 'unresolved'
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
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `Invoke-Pester -Path tests\Migrate-SharedStore.Tests.ps1 -FullNameFilter '*handoff and report*' -Output Detailed`
Expected: FAIL.

- [ ] **Step 3: Implement Phase 3**

```powershell
# ------------------------------------------------------------ phase 3 --------

Write-Head "Setup and install"

$repoRoot   = $PSScriptRoot
$setup      = Join-Path $repoRoot 'setup-claude-accounts.ps1'
$install    = Join-Path $repoRoot 'install.ps1'
$names      = @($accounts | ForEach-Object { $_.Name -replace '^\.claude-', '' })
$phase3Ok   = $false

if ($names.Count -eq 0) {
    Write-Skip "no accounts to hand off"
    $phase3Ok = $true
} elseif (-not (Test-Path -LiteralPath $setup)) {
    Write-Warn "cannot find $setup - skipping the handoff"
} else {
    # -DryRun MUST be forwarded. -NoSeed alone does not make setup inert: it
    # would still copy statusline.sh, rewrite settings.json and create links.
    & $setup -Accounts $names -NoSeed -DryRun:$DryRun
    # install.ps1 is not optional: an existing $PROFILE block holds an absolute
    # path into .claude-shared\bin, and copying bin/ does not update it.
    if (Test-Path -LiteralPath $install) {
        if ($DryRun) { Write-Step "would re-run install.ps1" } else { & $install }
    }
    $phase3Ok = $true
}

# ------------------------------------------------------------ phase 4 --------

Write-Head "Done"
Write-Host "  copied     : $($script:Copied)"
Write-Host "  overwritten: $($script:Overwrote) (plugins registry)"
Write-Host "  superseded : $($script:Superseded)"
Write-Host "  adopted    : $($script:Adopted)"
Write-Host "  rescued    : $($script:Rescued.Count)"
foreach ($r in $script:Rescued) { Write-Step $r }
if ($script:Conflicts.Count -gt 0) {
    Write-Warn "$($script:Conflicts.Count) unresolved conflict(s) - the store's copy was kept:"
    foreach ($c in $script:Conflicts | Select-Object -First 10) { Write-Step $c }
}
if ($refused.Count -gt 0) {
    Write-Warn "$($refused.Count) real director(ies) refused - move them yourself and re-run:"
    foreach ($r in $refused) { Write-Step $r }
}

$clean = ($script:Drifted.Count -eq 0) -and ($script:Conflicts.Count -eq 0) -and
         ($refused.Count -eq 0) -and $phase3Ok

Write-Host ""
if ($DryRun) {
    Write-Host "  Dry run only - nothing was changed."
} elseif ($clean) {
    if (Test-Path -LiteralPath $ManifestPath) { Remove-Item -LiteralPath $ManifestPath -Force }
    Write-Host "  $Legacy is kept as a full standby copy."
    Write-Host "  It is safe to delete ONLY after you open a NEW shell and confirm" -ForegroundColor Green
    Write-Host "  Get-ClaudeAccount still works - your `$PROFILE may still point into it."
} else {
    Write-Warn "Not finished. $Legacy has been left untouched - do NOT delete it."
    Write-Host "  Fix what is listed above and run this again. The merge is idempotent."
}
```

- [ ] **Step 4: Run the tests, then the whole suite**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS across all five test files.

- [ ] **Step 5: Commit**

```bash
git add migrate-shared-store.ps1 tests/Migrate-SharedStore.Tests.ps1
git commit -m "Hand off to setup and install, gate the deletion guidance

-DryRun is forwarded to setup, which -NoSeed alone does not make inert.
Deletion guidance requires a clean preflight, no drift, no unresolved
conflicts and a completed handoff."
```

---

## Phase C — Documentation

### Task 12: Update the docs

**Files:**
- Modify: `CLAUDE.md` (7 `claude-shared` mentions)
- Modify: `README.md` (15 mentions)
- Modify: `.gitignore` (1 comment line)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Update the repo `CLAUDE.md`**

Rewrite these sections to match the shipped code:

- The opening paragraph: `~/.claude-shared` is gone; the store is `~/.claude`.
- The **Architecture** table: add a `migrate-shared-store.ps1` row — "once, to move a pre-merge machine over".
- **The directory is the account**: unchanged as a principle, but add that the migration manifest is transient and authoritative for nothing.
- **Two link mechanisms**: targets move; mechanisms unchanged.
- **The status line is shared a third way**: the store copy now lives at `~/.claude/statusline.sh`.
- **The invalid-name class is duplicated on purpose**: still exactly two copies — say that migration does not need it, so nobody adds a third.
- New subsection **Store-only artifacts**: `bin/` and `statusline.sh` live in the store but are excluded from seeding, because the store is now the seed source.
- New subsection **`~/.claude` is load-bearing**:

```markdown
**~/.claude is load-bearing. Do not delete it to reset Claude Code.**
It is the shared store: deleting it destroys every account's transcripts, skills
and plugins at once, leaves every junction dangling, and removes the installed
profile under `~/.claude/bin`. Before the merge, `rm -rf ~/.claude` cost you the
fallback config and nothing else. That is no longer true.
```

- [ ] **Step 2: Update `README.md`**

Sweep all 15 `claude-shared` mentions, then add a **Migrating from an older setup** section:

````markdown
## Migrating from an older setup

If you already have `~/.claude-shared`, move it into `~/.claude` once:

```powershell
.\migrate-shared-store.ps1 -DryRun   # read the plan first
.\migrate-shared-store.ps1
```

**Close every Claude Code session first.** Nothing enforces it; the script
detects a write that happened during the run and refuses to bless deleting the
old store, but it cannot prevent one.

It never deletes `~/.claude-shared`. The old store stays on disk as a full
standby copy, and the closing report tells you whether it is safe to remove —
only after a clean preflight, no drift, no unresolved conflicts, and a completed
handoff to `setup-claude-accounts.ps1` and `install.ps1`. Open a new shell and
confirm `Get-ClaudeAccount` still works before you delete anything.
````

- [ ] **Step 3: Update `.gitignore`**

```
# Nothing account-specific belongs in this repo.
# Account data lives in ~/.claude and ~/.claude-<name>, never here.
```

- [ ] **Step 4: Verify no stale references remain**

Run:

```bash
grep -rn 'claude-shared' README.md CLAUDE.md .gitignore setup-claude-accounts.ps1 install.ps1
```

Expected: only deliberate mentions — the legacy guards in `claude-account-profile.ps1`, the migration script, and the README migration section. Every other hit is stale.

- [ ] **Step 5: Full verification**

Run: `Invoke-Pester -Path tests -Output Detailed`
Expected: PASS, 0 skipped, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md .gitignore
git commit -m "Document the merged store and the migration path

Adds the load-bearing warning: ~/.claude can no longer be deleted to
reset Claude Code without destroying every account's data."
```

---

## Success criteria

From the spec, verified after Task 12:

1. `Invoke-Pester -Path tests` passes, including every new test.
2. On the real machine, after `migrate-shared-store.ps1`: all six junctions in `.claude-james` and `.claude-minhgh` target `~/.claude`; all three `settings.json` name `~/.claude/statusline.sh`; `~/.claude/projects` holds the union of both sides; the rescued fork is resumable under a new id; `superpowers/6.3.0` and the `openai-codex` plugin are present **and registered**.
3. `.claude-shared` still exists and is untouched.
4. A shell with no `CLAUDE_CONFIG_DIR` sees the same `projects/`, `skills/` and `plugins/` as `claude-james` and `claude-minhgh`.
5. `setup-claude-accounts.ps1 -Accounts james,minhgh -NoSeed -DryRun` writes nothing and reports no pending work.

**Do not run the migration against the real `$HOME` until Task 12 is complete and the suite is green.** Take a copy of `~/.claude` and `~/.claude-shared` first — the standby copy protects the legacy store, not `~/.claude`.
