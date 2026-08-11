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

- **No file inside an account dir references its own directory name.** Scanned every
  top-level file of every `~/.claude-*` dir; zero self-references. Junction targets are
  absolute paths into `~/.claude-shared`, so they are unaffected by renaming the parent.
  A plain `Rename-Item` is therefore sufficient — nothing inside needs rewriting.
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

## Command behaviour

`Rename-ClaudeAccount` is an advanced function with `SupportsShouldProcess` so `-WhatIf`
works. It does **not** set `ConfirmImpact = 'High'` — unlike `Remove-ClaudeAccount`, a
rename is reversible and should not prompt.

Guards, in order, each an explicit `Write-Error` followed by `return`:

1. `$NewName` contains path characters `[\/:*?"<>|]` — same rule as
   `setup-claude-accounts.ps1`
2. `$NewName` is `shared` — reserved for the shared store
3. `~/.claude-<old>` does not exist
4. `<old>` equals `<new>` — PowerShell `-eq` is case-insensitive, so this also rejects
   `work` → `Work`. Case-only renames are out of scope. This check must precede
   guard 5, which would otherwise report the misleading "already exists".
5. `~/.claude-<new>` already exists

The rename runs inside `try`/`catch` with `-ErrorAction Stop`. Without the `try`, a
locked directory would write a non-terminating error and fall through to the launcher
swap, deregistering functions for an account that never moved. On failure the message
names the cause: the account appears to be in use, close Claude Code running on it and
retry, followed by the underlying exception message.

After a successful rename:

- Remove `function:global:claude-<old>`.
- Remove bare `function:global:<old>` **only if it is ours** — reusing the
  `Definition -match 'Use-ClaudeAccount'` check from `Remove-ClaudeAccount`, so a rename
  never eats a real command that happens to share the name.
- Call `Register-ClaudeAccountFunctions` to generate `claude-<new>` and, where it does
  not shadow an existing command, bare `<new>`.
- If `$env:CLAUDE_CONFIG_DIR` pointed at the old directory, repoint it at the new one.
  Otherwise the current shell silently holds a dead path.
- Report success.

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

The one carried-over change limits the damage for *future* renames. The generated
launcher body becomes:

```powershell
Use-ClaudeAccount '<name>' -ErrorAction Stop; claude @args
```

A stale launcher then aborts instead of launching on the wrong account. This is the only
edit outside the new function.

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
   `<old>` are gone
2. The `projects` junction survives, still resolves to the shared store, and the sentinel
   file is intact — the invariant that must never break
3. Each guard rejects and leaves the directory untouched: path characters, `shared`,
   missing account, same name including case-only, target exists
4. `$env:CLAUDE_CONFIG_DIR` is repointed when it was on the renamed account, and left
   untouched when it was on a different one
5. A bare launcher whose name collides with a real command is not removed
6. `-WhatIf` changes nothing

Teardown restores `$HOME` and removes the `function:global:` entries the tests generated.

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
- Any change to `Remove-ClaudeAccount` or `setup-claude-accounts.ps1`
- Repairing shells that were already open when the rename ran
