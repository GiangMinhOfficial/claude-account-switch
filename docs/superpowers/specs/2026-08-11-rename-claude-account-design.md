# Rename-ClaudeAccount — design

Date: 2026-08-11

## Goal

Add `Rename-ClaudeAccount <old> <new>` to `claude-account-profile.ps1`, renaming an
account in place: `~/.claude-<old>` becomes `~/.claude-<new>`, and the generated
launchers follow.

The account directory stays the single source of truth for an account's name. There
is no separate alias layer and no persisted name mapping.

## Findings that shaped the design

Established by inspection on a machine with seven live account dirs, not assumed:

- **No file inside an account dir references its own directory name.** Scanned
  *recursively*, skipping reparse points so the walk never crosses into the shared store:
  114 files across six accounts, 78 of them in `.claude-work`, zero self-references.
  Junction targets are absolute paths into `~/.claude-shared`, so they are unaffected by
  renaming the parent. `Rename-Item -LiteralPath` is therefore sufficient — nothing
  inside needs rewriting.

  Caveat on the strength of this evidence: it is one machine's accounts at one point in
  time, not a guarantee about the format. If a future Claude Code version starts writing
  its own config path into the account dir, this design silently breaks. The recursive
  scan is cheap to re-run and worth repeating if rename ever misbehaves.
- **The current launcher body does not abort on error.** `Use-ClaudeAccount '<name>';
  claude @args` writes the error and then launches `claude` anyway, under whatever
  config dir the shell currently holds. A stale launcher after a rename would drop the
  user into a session on the *wrong account*. Adding `-ErrorAction Stop` to the call
  aborts before launch; both behaviours were verified.
- **A live session under a given account cannot be detected.** Cross-process
  environment variables are unreadable (`Win32_Process` exposes no environment
  property; `StartInfo` reflects only the current process), `claude.exe` command lines
  carry no config dir, and `ide/*.lock` files are unreliable — one found in
  `~/.claude-work` held a dead pid hours after the session ended, they are only written
  when an IDE extension is attached, and the pid they carry is the IDE's, not the CLI's.
  In-use detection is therefore out of scope.
- **An open file blocks renaming its parent directory** (verified). Windows alone
  rejects the rename when a process genuinely holds a file open in the account dir.
  That is the only in-use guard, and it is the OS's, not ours.
- **`$HOME` is read-only but overridable** via `Set-Variable -Name HOME -Scope Global
  -Force`, and functions resolve it dynamically at call time. Tests can fake a home
  directory with no test hook in production code.
- **`Test-Path` is the wrong existence check.** `~/.claude-shared` and `~/.claude-mem`
  both pass it; neither is an account. `~/.claude-shared` even contains a `projects/`
  entry, so only `Get-ClaudeAccountDir`'s explicit name exclusion rules it out.
- **`SupportsShouldProcess` without a `ShouldProcess` call is not `-WhatIf` support.**
  Verified: the directory was left unrenamed while a plain variable assignment still ran
  and a success message still printed.
- **Windows silently normalises trailing dots and whitespace in directory names.**
  Verified: `.claude-foo.` was created as `.claude-foo`, and `.claude-<space>` as
  `.claude-`.
- **`[scriptblock]::Create` throws on an apostrophe in the interpolated account name.**
  Verified, and verified fixed by doubling the quote.

## Command behaviour

`Rename-ClaudeAccount` is an advanced function with `SupportsShouldProcess` so `-WhatIf`
works. It does **not** set `ConfirmImpact = 'High'` — unlike `Remove-ClaudeAccount`, a
rename is reversible and should not prompt.

Guards, in order, each an explicit `Write-Error` followed by `return`. All path tests use
`-LiteralPath`, since account names may contain wildcard-significant characters.

**Source guards**

1. `<old>` is `shared` — refuse, with a message naming the shared store explicitly.
2. `<old>` is not a member of `Get-ClaudeAccountDir`. This, not `Test-Path`, is the
   existence check. A bare `Test-Path ~/.claude-<old>` admits two directories that are
   not accounts and must never be renamed:
   - `~/.claude-shared` — the shared store. Every junction in every account targets its
     absolute path, so renaming it dangles all of them at once. It also *contains* a
     `projects/` entry, so a `projects/`-only test does not exclude it; only
     `Get-ClaudeAccountDir`'s explicit name exclusion does. Guard 1 gives the clearer
     message, but this guard is the backstop.
   - `~/.claude-mem` — claude-mem plugin data, present on real machines, with no
     `projects/` entry. `Get-ClaudeAccountDir` already excludes it.

**Destination guards**

3. `$NewName` matches `[\\/:*?"<>|]` — the regex literal, identical to the one in
   `setup-claude-accounts.ps1`. Note the doubled backslash: `[\/…]` would compile to an
   escaped forward slash and let `..\evil` through.
4. `$NewName` has leading or trailing whitespace, or a trailing dot. Windows normalises
   these silently rather than rejecting them — requesting `.claude-foo.` creates
   `.claude-foo`, and `.claude-<space>` creates `.claude-`. Without this guard the
   directory created does not match the name the user asked for, which defeats the
   collision check in guard 7.
5. `$NewName` is `shared` — reserved for the shared store.
6. `<old>` equals `<new>` — PowerShell `-eq` is case-insensitive, so this also rejects
   `work` → `Work`. Case-only renames are out of scope. This check must precede
   guard 7, which would otherwise report the misleading "already exists".
7. `~/.claude-<new>` already exists.

**ShouldProcess gate**

Everything after the guards runs only inside:

```powershell
if (-not $PSCmdlet.ShouldProcess($src, "Rename to .claude-$NewName")) { return }
```

`SupportsShouldProcess` alone is not enough. `Rename-Item` honours `-WhatIf` through
preference propagation, but a plain assignment to `$env:CLAUDE_CONFIG_DIR` and a
`Write-Host` success message do not. Verified: with no gate, `-WhatIf` left the directory
unrenamed while still mutating the variable and printing "renamed successfully".

The rename itself is `Rename-Item -LiteralPath $src -NewName ".claude-$NewName"
-ErrorAction Stop`, inside `try`/`catch`. Without the `try`, a locked directory would
write a non-terminating error and fall through to the launcher swap, deregistering
functions for an account that never moved.

The catch message must not assert a cause. `Rename-Item` also fails on permissions, path
length, and I/O errors, and claiming "the account is in use" for those sends the user
hunting a process that does not exist. The wording is "Could not rename `<src>`", then the
underlying exception message, then a hint — *if Claude Code is running on this account,
close it and retry* — phrased as a possibility rather than a diagnosis.

After a successful rename:

- Remove `function:global:claude-<old>`.
- Remove bare `function:global:<old>` **only if it is ours** — via the extracted
  `Test-OurLauncher` helper (see Reuse), so a rename never eats a real command that
  happens to share the name.
- Call `Register-ClaudeAccountFunctions` to generate `claude-<new>` and, where it does
  not shadow an existing command, bare `<new>`.
- If `$env:CLAUDE_CONFIG_DIR` pointed at the old directory, repoint it at the new one.
  Otherwise the current shell silently holds a dead path.
- Report success, **naming the launchers that actually exist**. `Register-ClaudeAccountFunctions`
  skips the bare launcher when the name would shadow an existing command, and it does so
  via `Write-Verbose` — invisible by default. Renaming an account to `git` or `code`
  therefore yields only `claude-git`, and a flat "renamed" message would leave the user
  typing `git` and getting version control. When the bare launcher is skipped, say so on
  the success path and name the command that took precedence.

## The old alias

Dropped. No redirect shim, no persisted rename log, no compatibility junction.

A compatibility junction on the old name was considered and rejected: `Get-ClaudeAccountDir`
scans `~/.claude-*` for a `projects/` entry, so a junction to the new account would list
the old name as a separate account indefinitely, and it would place a junction exactly
where `Remove-ClaudeAccount` expects a real directory.

## Stale shells

Shells already open when the rename runs keep the old profile in memory — old launcher
bodies and the old `Use-ClaudeAccount` alike. Nothing written to disk can change their
behaviour, because the only disk state the loaded code consults is whether the account
directory exists. This is documented, not solved: open a new shell after renaming.

The one carried-over change limits the damage for *future* renames. In
`Register-ClaudeAccountFunctions`, the generated launcher body becomes:

```powershell
$safe = $name -replace "'", "''"
$body = [scriptblock]::Create("Use-ClaudeAccount '$safe' -ErrorAction Stop; claude @args")
```

Two fixes on one line:

- **`-ErrorAction Stop`** makes a stale launcher abort instead of launching on the wrong
  account. `Use-ClaudeAccount` is an advanced function, so the caller's preference turns
  its `Write-Error` terminating and the scriptblock stops before reaching `claude`.
  Verified both ways.
- **Apostrophe doubling.** The current interpolation breaks on an account named
  `o'clock`: `[scriptblock]::Create` throws a parse error, so the account gets no
  launcher at all. Verified, and verified fixed by doubling. This is a pre-existing bug,
  included because rename is a new way to produce such a name and the fix lands on a line
  this change already edits. A destination guard rejecting apostrophes would not help —
  `setup-claude-accounts.ps1` can already create them.

  Doubling is a complete fix, not a partial one: a single-quoted PowerShell literal
  interpolates nothing, so once the quote cannot be closed early, `$`, backtick and `;`
  in an account name are inert.

**Considered: making `Use-ClaudeAccount` throw instead.** The alternative is to move the
fail-fast into `Use-ClaudeAccount` itself, so every caller inherits it rather than each
launcher opting in. Rejected, on two grounds. The launcher body is generated in exactly
one place, so `-ErrorAction Stop` is one edit and not N — the duplication the objection
assumes is not there. And the launcher is the only call site where the error is followed
by a consequential action; a bare `Use-ClaudeAccount typo` at the prompt already fails
harmlessly, leaving the shell where it was, and making it throw would turn a routine typo
into a terminating error for no safety gain. The cost is a weaker contract: a future
caller of `Use-ClaudeAccount` must remember `-ErrorAction Stop`, so the function carries a
comment saying exactly that.

## Reuse

**Extract `Test-OurLauncher`** into `claude-account-profile.ps1`: the predicate
"this command exists, is a Function, and its definition matches `Use-ClaudeAccount`"
is currently duplicated in `Remove-ClaudeAccount` and `Register-ClaudeAccountFunctions`,
and this change would add a third copy. All three call sites are in the same file, so the
extraction is local and low-risk.

**The invalid-character class stays duplicated**, deliberately. It appears in both
`setup-claude-accounts.ps1` and `claude-account-profile.ps1`, but the two files are
independent by design: setup runs from the repo checkout *before* the profile is
installed, so sharing the constant would force setup to dot-source the profile — which
executes `Register-ClaudeAccountFunctions` at load. That side effect is worse than the
duplication. Each file gets the class as a named constant with a comment pointing at the
other, so the pairing is at least discoverable. This is the one review item not adopted
as suggested.

## Tests

`tests/Rename-ClaudeAccount.Tests.ps1`, Pester 5. Prerequisite, because Windows ships
Pester 3.4.0 and the two are syntactically incompatible:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

`-SkipPublisherCheck` is required: the shipped 3.4.0 is Microsoft-signed.

Fixture: fake `$HOME` set via `Set-Variable -Force` **before** dot-sourcing the profile,
so the load-time `Register-ClaudeAccountFunctions` sees an empty world rather than
registering the real accounts. The fake home is a real temp directory, not `TestDrive:`,
because `mklink /J` cannot resolve a PSDrive path. Each test builds an account dir with a
`projects` junction into a fake shared store holding a sentinel file.

Cases:

1. Happy path — directory renamed; `claude-<new>` and `<new>` exist; `claude-<old>` and
   `<old>` are gone. The `<new>` assertion holds only because the fixture picks a name
   that shadows nothing; it must not be written as an unconditional invariant
2. The `projects` junction survives, still resolves to the shared store, and the sentinel
   file is intact — the invariant that must never break
3. Each guard rejects and leaves the directory untouched:
   - source is `shared`
   - source is a `.claude-*` directory that is not an account — fixture creates a fake
     `.claude-mem` with no `projects/` and asserts it is refused
   - source does not exist at all
   - destination contains a path character, including `..\evil`, which the malformed
     class would have admitted
   - destination has trailing whitespace or a trailing dot
   - destination is `shared`
   - same name, including the case-only `work` → `Work`
   - destination already exists
4. `$env:CLAUDE_CONFIG_DIR` is repointed when it was on the renamed account, and left
   untouched when it was on a different one
5. A bare launcher whose name collides with a real command is not removed
6. `-WhatIf` changes nothing — asserting all three: directory not renamed,
   `$env:CLAUDE_CONFIG_DIR` unchanged, no success output. The env-var assertion is the
   one that fails without the `ShouldProcess` gate
7. A stale launcher does not launch. Register a launcher, remove its account directory,
   invoke it, and assert `claude` was never reached — a stub `claude` function in the
   test scope sets a flag, and the test asserts the flag stayed clear. This is the
   regression test for the `-ErrorAction Stop` change
8. An account named `o'clock` gets a working launcher — regression test for the
   apostrophe fix
9. Renaming to a name that shadows a real command — `git` — creates `claude-git`, leaves
   `git` itself pointing at version control, and reports the skip. The companion to case
   5, and the reason case 1's bare-launcher assertion is not an invariant

Teardown restores `$HOME`, deletes the fake home directory, and removes the
`function:global:` entries the tests generated.

**Teardown must unlink junctions before deleting**, using the same `cmd /c rmdir`
sequence as `Remove-ClaudeAccount`. A plain `Remove-Item -Recurse` on a fixture account
dir is exactly the operation the README warns against: PowerShell 5.1 can follow the
junction and delete the *contents* of the fake shared store behind it. The blast radius is
a temp directory rather than real data, but a test suite that models the unsafe pattern
will eventually be copied into something that isn't a temp directory, and case 2 would
silently stop testing anything once the sentinel is gone.

## Documentation

README changes:

- A `Rename-ClaudeAccount personal work` row in the Usage table
- A Rename subsection under "Adding and removing accounts", stating that other open
  shells keep stale launchers and that the fix is to open a new shell
- A Testing section carrying the Pester 5 prerequisite and the run command

## Out of scope

- Aliases: multiple names per account
- Case-only renames
- Detecting whether an account has a live session
- Repairing shells that were already open when the rename ran
- Behaviour changes to `Remove-ClaudeAccount` or `setup-claude-accounts.ps1`. Two
  mechanical edits to existing code are in scope and nothing more: extracting
  `Test-OurLauncher` (which changes `Remove-ClaudeAccount` and
  `Register-ClaudeAccountFunctions` to call it) and naming the invalid-character class as
  a constant in `setup-claude-accounts.ps1`. Neither alters behaviour.
