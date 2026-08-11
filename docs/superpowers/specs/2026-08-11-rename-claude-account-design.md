# Rename-ClaudeAccount — design

Date: 2026-08-11

## Goal

Add `Rename-ClaudeAccount <old> <new>` to `claude-account-profile.ps1`, renaming an
account in place: `~/.claude-<old>` becomes `~/.claude-<new>`, and the generated
launchers follow.

The account directory stays the single source of truth for an account's name. There
is no separate alias layer and no persisted name mapping.

## Findings that shaped the design

Verified on this machine, not assumed. Eight `~/.claude-*` directories exist here; six
are accounts by `Get-ClaudeAccountDir`'s definition, the other two being `.claude-shared`
(the shared store) and `.claude-mem` (claude-mem plugin data).

- **No file inside an account dir references its own directory name.** Scanned
  recursively, skipping reparse points so the walk never crosses into the shared store:
  114 files across the six accounts, 78 of them in `.claude-work`, zero self-references.
  Junction targets are absolute paths into `~/.claude-shared`, so they are unaffected by
  renaming the parent. `Rename-Item -LiteralPath` is therefore sufficient — nothing
  inside needs rewriting.

  This is one machine at one point in time, not a guarantee about the format. If a future
  Claude Code version writes its own config path into the account dir, this design breaks
  silently. The scan is cheap to re-run and worth repeating if rename ever misbehaves.
- **The `function:` provider treats `[` and `]` as wildcards, and NTFS allows them in
  directory names.** Verified, and this is the sharpest hazard in the change:
  - `Set-Item -Path "function:global:a[1]"` **reports success and creates nothing**.
    `Get-Command` and the `function:` drive both show no such function.
  - `Set-Item -LiteralPath ...` creates it correctly.
  - `Remove-Item -Path "function:global:a[2]"` silently no-ops. So does
    `Remove-Item -LiteralPath "function:global:a[2]"` — the `global:` prefix defeats it
    even with `-LiteralPath`. Only `Remove-Item -LiteralPath "function:a[2]"` works.
  - NTFS creates `.claude-a[1]` happily, and `Get-ChildItem -Filter '.claude-*'` matches
    it, so such an account is fully real and fully launcher-less.
- **`Register-ClaudeAccountFunctions` registers the prefixed launcher unconditionally.**
  `claude-account-profile.ps1:106` has no shadow check; only the bare form at line 116
  does. Renaming can therefore overwrite an unrelated command named `claude-<new>`.
- **`Test-Path` is the wrong existence check.** `~/.claude-shared` and `~/.claude-mem`
  both pass it; neither is an account. `~/.claude-shared` even contains a `projects/`
  entry, so only `Get-ClaudeAccountDir`'s explicit name exclusion rules it out.
- **The current launcher body does not abort on error.** `Use-ClaudeAccount '<name>';
  claude @args` writes the error and then launches `claude` anyway, under whatever config
  dir the shell holds. A stale launcher would drop the user into a session on the wrong
  account. Verified both ways.
- **`[scriptblock]::Create` throws on an apostrophe in the interpolated account name**,
  leaving that account with no launcher at all. Verified, and verified fixed by doubling.
- **`SupportsShouldProcess` without a `ShouldProcess` call is not `-WhatIf` support.**
  Verified: the directory was left unrenamed while a variable assignment still ran and a
  success message still printed.
- **Windows silently normalises trailing dots and whitespace in directory names.**
  Verified: `.claude-foo.` was created as `.claude-foo`, `.claude-<space>` as `.claude-`.
- **`Rename-Item -NewName` rejects any path-bearing name outright** — "represents a path
  or device name". Path separators cannot produce traversal; they produce a confusing
  late failure. This bounds the severity of the character-class bug (see Guards).
- **A live session under a given account cannot be detected.** Cross-process environment
  variables are unreadable (`Win32_Process` exposes no environment property), `claude.exe`
  command lines carry no config dir, and `ide/*.lock` files are unreliable — one in
  `~/.claude-work` held a dead pid hours after the session ended, they exist only when an
  IDE extension is attached, and the pid is the IDE's, not the CLI's.
- **An open file blocks renaming its parent directory** (verified, including with
  `FILE_SHARE_DELETE`). That is the only in-use guard, and it is the OS's, not ours. It is
  also incomplete — see Phantom accounts.

## Command behaviour

`Rename-ClaudeAccount` is an advanced function with `SupportsShouldProcess` so `-WhatIf`
works. It does **not** set `ConfirmImpact = 'High'` — unlike `Remove-ClaudeAccount`, a
rename is reversible and should not prompt.

### Guards

Each is an explicit `Write-Error` followed by `return`. All filesystem tests use
`-LiteralPath`; all `function:` provider calls follow the rules in Launcher registration.

**Source**

1. `<old>` is `shared` — refuse, naming the shared store.
2. `<old>` is not a member of `Get-ClaudeAccountDir`. This, not `Test-Path`, is the
   existence check: a bare `Test-Path` admits `~/.claude-shared`, whose absolute path
   every junction in every account targets, and `~/.claude-mem`.

   The error message must be specific, because this check also rejects a **supported**
   configuration. `README.md` advises "to keep a particular account separate, remove
   `projects` from `-SharedDirs` for it", and such an account has no `projects/` entry
   until Claude Code creates one — so `Get-ClaudeAccountDir` never returns it, and it has
   no launcher either. Rename inherits that pre-existing blind spot rather than fixing it.
   The message is therefore "`<name>` is not a recognised account: `~/.claude-<name>` has
   no `projects/` entry", plus a note that an account created without a shared `projects`
   becomes renameable once Claude Code has run in it once. This limitation is documented
   in the README, not silently absorbed.

**Destination**

3. `$NewName` matches the invalid-name class — see Name validation below.
4. `$NewName` has leading or trailing whitespace, or a trailing dot. Windows normalises
   these silently: `.claude-foo.` becomes `.claude-foo`. Without this guard the directory
   created does not match the name requested, defeating guard 7.
5. `$NewName` is `shared`.
6. `<old>` equals `<new>` — PowerShell `-eq` is case-insensitive, so this also rejects
   `work` → `Work`. Case-only renames are out of scope. Must precede guard 7, which would
   otherwise report the misleading "already exists".
7. `~/.claude-<new>` already exists.
8. `claude-<new>` would collide with a command that is not ours. Two cases, both real:
   - An external command — `Register-ClaudeAccountFunctions` registers the prefixed form
     unconditionally, so renaming to `mem` overwrites a `claude-mem` CLI in that shell.
   - Another account's bare launcher — if an account named `claude-foo` exists, renaming
     to `foo` makes both want the name `claude-foo`. `Get-ChildItem` is alphabetical, so
     `.claude-foo` is registered last and wins, and typing `claude-foo` silently opens the
     wrong account. Equivalent to rejecting `<new>` when an account named `claude-<new>`
     exists.

   This guard contains the hazard within rename rather than changing
   `Register-ClaudeAccountFunctions`' unconditional registration, which would give a
   colliding account *no* launcher at all — worse than the current behaviour and a change
   affecting accounts this feature never touches.

### Name validation

The invalid-name class is `[\\/:*?"<>|\[\]]` — the regex literal. Two things beyond the
existing rule:

- **The doubled backslash.** `[\/…]` compiles to an escaped forward slash and admits
  `..\evil`. The severity is bounded — `Rename-Item -NewName` rejects path-bearing names
  outright, so this never produced traversal — but it converts a clean guard rejection
  into a late failure after the `ShouldProcess` prompt, carrying an error message about
  paths and devices. The observable difference is *which error the user sees and when*,
  and the test asserts that, not merely that the rename was refused.
- **Brackets.** These are the genuinely dangerous addition. A bracketed name passes every
  other guard, renames successfully, is matched by `Get-ClaudeAccountDir`, and then
  receives **no launchers at all** while the success path reports success — with no way
  back except renaming by hand in Explorer, since the removal calls no-op too.

This class and the whitespace/trailing-dot rule apply to **both** `Rename-ClaudeAccount`
and `setup-claude-accounts.ps1`. Validating only on rename would let setup manufacture the
exact names rename exists to prevent, and would make the cross-reference comment claim a
parity that does not hold. Tightening setup rejects names it previously accepted; that is
a deliberate behaviour change, listed under Scope.

### ShouldProcess gate

Everything after the guards runs only inside:

```powershell
if (-not $PSCmdlet.ShouldProcess($src, "Rename to .claude-$NewName")) { return }
```

`SupportsShouldProcess` alone is not enough. `Rename-Item` honours `-WhatIf` through
preference propagation, but assigning `$env:CLAUDE_CONFIG_DIR` and writing a success
message do not. Verified: with no gate, `-WhatIf` left the directory unrenamed while
mutating the variable and printing "renamed successfully".

### The rename

`Rename-Item -LiteralPath $src -NewName ".claude-$NewName" -ErrorAction Stop`, inside
`try`/`catch`. Without the `try`, a locked directory would write a non-terminating error
and fall through to the launcher swap, deregistering functions for an account that never
moved.

The catch message must not assert a cause. `Rename-Item` also fails on permissions, path
length, and I/O errors, and claiming "the account is in use" for those sends the user
hunting a process that does not exist. Wording: "Could not rename `<src>`", the underlying
exception message, then in-use offered as a possibility — including the warning from
Phantom accounts about what happens if a session is live.

### After a successful rename

- Call `Unregister-ClaudeAccountLaunchers -Name <old>` (see Reuse).
- Call `Register-ClaudeAccountFunctions` to generate the new launchers.
- Repoint `$env:CLAUDE_CONFIG_DIR` if this shell was on the renamed account. Compare
  **resolved** paths, not the raw string against a reconstructed `Join-Path $HOME ...`.
  A variable exported by hand as `%USERPROFILE%\.claude-work\`, or via a UNC or mapped
  drive, or on a machine where `$HOME` and `$env:USERPROFILE` differ, compares unequal and
  would be left pointing at a directory that no longer exists — the exact outcome this
  step exists to prevent. If the current value no longer resolves after the rename, fall
  back to `Reset-ClaudeAccount`, as `Remove-ClaudeAccount` does.
- Report success, **naming the launchers that actually exist**. The bare launcher is
  skipped when it would shadow an existing command, and only via `Write-Verbose` —
  invisible by default. A flat "renamed" leaves the user typing a name that belongs to
  something else. Rename determines this by calling `Test-OurLauncher <new>` after
  registration; with the predicate extracted this is a call, not another copy of it.

## Launcher registration

`Register-ClaudeAccountFunctions` changes on one line, plus the provider-safety fixes:

```powershell
$safe = $name -replace "'", "''"
$body = [scriptblock]::Create("Use-ClaudeAccount '$safe' -ErrorAction Stop; claude @args")
Set-Item -LiteralPath "function:global:claude-$name" -Value $body
```

- **`-ErrorAction Stop`** makes a stale launcher abort instead of launching on the wrong
  account. `Use-ClaudeAccount` is an advanced function, so the caller's preference makes
  its `Write-Error` terminating and the scriptblock stops before reaching `claude`.
- **Apostrophe doubling.** A single-quoted PowerShell literal interpolates nothing, so
  once the quote cannot be closed early, `$`, backtick and `;` in an account name are
  inert. This is a complete fix, not a partial one, which is why there is no apostrophe
  guard on `$NewName` — a guard would not cover names `setup-claude-accounts.ps1` can
  already create.
- **`-LiteralPath` on every `function:` call**, and removals must use the
  `function:<name>` form without the `global:` prefix, which defeats removal even with
  `-LiteralPath`. Guard 3 rejects bracket names going forward, but existing installs may
  already have one, and the `-Path` forms fail silently rather than loudly.

**Considered: making `Use-ClaudeAccount` throw instead.** Moving the fail-fast into
`Use-ClaudeAccount` so every caller inherits it. Rejected: the launcher body is generated
in exactly one place, so `-ErrorAction Stop` is one edit and not N, and the launcher is
the only call site where the error is followed by a consequential action. A bare
`Use-ClaudeAccount typo` at the prompt already fails harmlessly. The cost is a weaker
contract, so `Use-ClaudeAccount` carries a comment telling callers to pass
`-ErrorAction Stop`.

## Phantom accounts

The OS in-use guard is incomplete, and the failure mode deserves naming rather than a
shrug. Claude Code writes and closes rather than holding handles, so between writes a
rename of a live account succeeds. The running process still has
`CLAUDE_CONFIG_DIR=~/.claude-<old>`, so its next write **recreates that directory** — with
`projects/` as a real directory, not a junction.

The consequences, verified: `Get-ClaudeAccountDir` lists the old name as a live account
again, so it reappears in `Get-ClaudeAccount` after a "successful" rename; and every
transcript written there is invisible from `~/.claude-shared/projects`, meaning invisible
from every account including the renamed one.

This is not fixable from the renaming shell for the reasons under Stale shells. It is
documented in the README rename subsection and referenced in the catch hint.

## Stale shells

Shells already open when the rename runs keep the old profile in memory — old launcher
bodies and the old `Use-ClaudeAccount` alike. Nothing written to disk can change their
behaviour, because the only disk state the loaded code consults is whether the account
directory exists. Documented, not solved: open a new shell after renaming.

## The old alias

Dropped. No redirect shim, no persisted rename log, no compatibility junction.

A compatibility junction was considered and rejected: `Get-ClaudeAccountDir` scans
`~/.claude-*` for a `projects/` entry, so a junction to the new account would list the old
name as a separate account indefinitely, and it would place a junction exactly where
`Remove-ClaudeAccount` expects a real directory.

## Reuse

**Extract `Unregister-ClaudeAccountLaunchers -Name <n>`** into
`claude-account-profile.ps1`, covering both removals: the prefixed launcher and the bare
one when `Test-OurLauncher` says it is ours. `Remove-ClaudeAccount` already does exactly
this at lines 86-92 and rename would duplicate it. Extracting only the ours/not-ours
predicate would leave the removal pair copied in two places — so the bracket-name fix
(`function:<name>`, no `global:`) would have to be applied twice and could be fixed in one
place only.

**Extract `Test-OurLauncher`** as its collaborator: "this command exists, is a Function,
and its definition matches `Use-ClaudeAccount`", currently inline in `Remove-ClaudeAccount`
and `Register-ClaudeAccountFunctions`, and needed by guard 8 and the success report. All
call sites are in the same file.

**The invalid-name class stays duplicated between the two files**, deliberately, now that
both enforce it. Sharing the constant would force `setup-claude-accounts.ps1` to
dot-source the profile — which executes `Register-ClaudeAccountFunctions` at load. That
side effect is worse than the duplication. Each file names it as a constant with a comment
pointing at the other. A third shared file was considered and rejected: it adds an install
step to a repo whose setup script is deliberately standalone.

## Tests

`tests/Rename-ClaudeAccount.Tests.ps1`, Pester 5. Prerequisite, because Windows ships
Pester 3.4.0 and the two are syntactically incompatible:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

`-SkipPublisherCheck` is required: the shipped 3.4.0 is Microsoft-signed.

Fixture: fake `$HOME` set via `Set-Variable -Name HOME -Scope Global -Force` **before**
dot-sourcing the profile, so the load-time `Register-ClaudeAccountFunctions` sees an empty
world rather than registering the real accounts. The fake home is a real temp directory,
not `TestDrive:`, because `mklink /J` cannot resolve a PSDrive path. Each test builds an
account dir with a `projects` junction into a fake shared store holding a sentinel file.

**No test may delete a fixture account directory with a plain `Remove-Item -Recurse`.**
Junctions are unlinked with `cmd /c rmdir` first, in teardown *and* mid-test. On
PowerShell 5.1 the recursion follows the junction and deletes the shared store's contents,
taking the sentinel with it — after which case 2 passes vacuously or fails spuriously for
every test ordered after the offender, and ordering is not pinned.

Cases:

1. Happy path — directory renamed; `claude-<new>` and `<new>` exist; `claude-<old>` and
   `<old>` are gone. The bare-launcher assertion holds only because the fixture picks a
   name that shadows nothing; it must not be written as an unconditional invariant
2. The `projects` junction survives, still resolves to the shared store, and the sentinel
   file is intact — the invariant that must never break
3. Each guard rejects and leaves the directory untouched:
   - source is `shared`
   - source is a `.claude-*` directory with no `projects/` — fixture creates a fake
     `.claude-mem` — and the error names the missing `projects/` entry rather than
     claiming the directory does not exist
   - source does not exist at all
   - destination contains `..\evil` — asserting the *guard's* message, not merely that the
     rename was refused, since `Rename-Item` rejects path-bearing names anyway and a
     refusal alone passes with the buggy regex too
   - destination contains brackets — `a[1]`
   - destination has trailing whitespace or a trailing dot
   - destination is `shared`
   - same name, including the case-only `work` → `Work`
   - destination already exists
   - `claude-<new>` would collide (guard 8), covering both an external command and an
     account named `claude-<new>`
4. `$env:CLAUDE_CONFIG_DIR` is repointed when this shell was on the renamed account, and
   left untouched when it was on a different one. Includes a non-canonical spelling of the
   old path — trailing separator — to prove the comparison resolves paths
5. A bare launcher whose name collides with a non-ours command is not removed
6. `-WhatIf` changes nothing — directory not renamed, `$env:CLAUDE_CONFIG_DIR` unchanged,
   no success output. The env-var assertion is the one that fails without the gate
7. A stale launcher does not launch. Register a launcher, unlink its junction and remove
   its account directory, invoke it, and assert `claude` was never reached — a stub
   `claude` function in the test scope sets a flag and the test asserts the flag stayed
   clear. Regression test for `-ErrorAction Stop`
8. An account named `o'clock` gets a working launcher — regression test for the apostrophe
   fix
9. Renaming to a name that shadows a non-ours command creates the prefixed launcher, does
   not overwrite the existing command, and reports the skip. The fixture registers its own
   stub function whose body does not contain `Use-ClaudeAccount`, rather than reaching for
   a real external command like `git` — a machine or CI image without git would invert
   every assertion in this case, and whether git resolves as an Application or an alias
   would change its meaning

Teardown restores `$HOME`, unlinks fixture junctions, deletes the fake home directory, and
removes the `function:global:` entries the tests generated.

## Documentation

README:

- A `Rename-ClaudeAccount personal work` row in the Usage table
- A Rename subsection under "Adding and removing accounts", covering three things: other
  open shells keep stale launchers, so open a new shell; renaming an account that has a
  live session can resurrect the old name as a phantom account whose transcripts are
  invisible to every account (see Phantom accounts); and accounts configured without a
  shared `projects` cannot be renamed until Claude Code has run in them once
- A note that `claude-<name>` launchers now **fail** on a missing account instead of
  warning and launching on the current config dir. This is a user-visible behaviour change
  to an existing command — a script calling `claude-work` will now abort rather than
  continue — and shipping it unannounced is exactly the "breaking change without warning"
  the project's guidelines forbid
- A note that `setup-claude-accounts.ps1` now rejects account names it previously accepted
- A Testing section with the Pester 5 prerequisite and the run command

`claude-account-profile.ps1` header comment: add `Rename-ClaudeAccount` to the command
list, and `Remove-ClaudeAccount`, which the header already omits. Note that a rename
requires a new shell.

## Scope

In scope, beyond the new function:

- `Register-ClaudeAccountFunctions` — launcher body (`-ErrorAction Stop`, apostrophe
  doubling) and `-LiteralPath` on the `function:` calls. **Alters behaviour**: launchers
  now fail terminating.
- `Remove-ClaudeAccount` — call the extracted helpers; removals switch to the
  `function:<name>` form. **Fixes a silent no-op** on bracket-named launchers.
- `setup-claude-accounts.ps1` — the shared invalid-name class plus the whitespace and
  trailing-dot rule. **Alters behaviour**: rejects names it previously accepted.
- New helpers `Test-OurLauncher` and `Unregister-ClaudeAccountLaunchers`.
- README and the profile header comment.

Out of scope:

- Aliases: multiple names per account
- Case-only renames
- Detecting whether an account has a live session
- Repairing shells that were already open when the rename ran
- Making `Get-ClaudeAccountDir` recognise accounts without a `projects/` entry. This is a
  pre-existing gap that rename inherits and documents; fixing it changes which accounts
  get launchers everywhere, well beyond this feature.
- Adding a `-Name` filter to `Register-ClaudeAccountFunctions` so it can report what it
  registered. Worth doing — it would let `setup-claude-accounts.ps1` give the same
  accurate "then run `claude-<name>`" advice — but it changes an existing function's
  signature for a benefit rename gets from `Test-OurLauncher` alone.
