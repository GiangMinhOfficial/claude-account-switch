# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Three PowerShell scripts and one bash script — no build step, no package manager, no
dependencies beyond the shell. They let one Windows machine run several Claude Code
accounts by pointing `CLAUDE_CONFIG_DIR` at `~/.claude-<name>` per shell, while
everything that should be common lives once in `~/.claude-shared`.

Target shell is **Windows PowerShell 5.1**. No PowerShell 7-only syntax (`??`, `?:`,
`-AsHashtable`, `&&`/`||`). `.gitattributes` pins `.ps1` and `.md` to CRLF and `.sh`
to LF — `statusline.sh` runs under bash, and `text=auto` would otherwise hand it CRLF
on a Windows checkout.

## Commands

Tests need Pester 5+. Windows ships 3.4.0, which is syntactically incompatible, and
loads by default even once 5 is installed — hence the explicit `Import-Module`. The
install needs TLS 1.2 (5.1 defaults to 1.0, which PSGallery refuses) and
`-SkipPublisherCheck` (the shipped copy is Microsoft-signed).

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path tests -Output Detailed

# one file
Invoke-Pester -Path tests\SharedMemoryFile.Tests.ps1 -Output Detailed

# one test, matched against its full "Describe.It" path
Invoke-Pester -Path tests -FullNameFilter '*is idempotent*' -Output Detailed
```

Exercising the scripts themselves:

```powershell
.\setup-claude-accounts.ps1 -DryRun                 # print the plan, write nothing
.\setup-claude-accounts.ps1 -Accounts work -NoSeed  # add or repair one account
.\install.ps1                                       # wire into $PROFILE
. .\claude-account-profile.ps1                      # load the functions in this shell
```

`-DryRun` writes nothing, but it is not inert: `New-Junction` throws
"Refusing to replace real directory" *before* its own `-DryRun` guard, so a dry run
against a real `$HOME` can still abort on a pre-existing directory.

## Architecture

| File | Runs | Role |
| --- | --- | --- |
| `setup-claude-accounts.ps1` | once per account, re-runnable | creates `~/.claude-shared`, the account dirs, and the links between them |
| `claude-account-profile.ps1` | every shell, via `$PROFILE` | `Use-`/`Get-`/`Reset-`/`Rename-`/`Remove-ClaudeAccount` plus generated launchers |
| `install.ps1` | once | copies the profile into `~/.claude-shared/bin` and adds a marked block to `$PROFILE` |
| `statusline.sh` | per status line render, by Claude Code | the bar every account shows; copied into `~/.claude-shared` by setup |

**The directory is the account.** There is no registry, alias table or rename log.
`Get-ClaudeAccountDir` defines an account as a `~/.claude-*` directory that is not
`.claude-shared` and contains a `projects/` entry — that second test is what excludes
unrelated dirs such as `.claude-mem`. It follows that an account Claude Code has never
run in has no `projects/`, so it gets no launchers and cannot be renamed. That is a
known limitation of the whole profile, not a bug in any one function.

**Two link mechanisms, chosen by type, neither needing admin.** Directories listed in
`-SharedDirs` become NTFS junctions (`mklink /J`); files listed in `-SharedFiles`
(default `CLAUDE.md`) become hardlinks (`mklink /H`), because a junction cannot link a
file. Real symlinks are deliberately unused — they require admin or Developer Mode.

The two are not interchangeable in code:

- A junction is a reparse point, so the `ReparsePoint` attribute finds it. A hardlink
  is not; identity is `LinkType -eq 'HardLink'` plus a search of `FileInfo.Target`,
  which lists every *other* name for the inode and can return them volume-relative.
- Removing a junction must go through `cmd /c rmdir`, which removes the link and never
  the target. PowerShell 5.1's `Remove-Item -Recurse` follows junctions and will empty
  the shared store — taking every account's transcripts with it. This applies to test
  teardown as much as to `Remove-ClaudeAccount`.
- Removing a hardlink name is always safe: it never touches the content behind the
  other names. That is why it is deliberately absent from the unlink pass.

A hardlinked file has no "original". `~/.claude/CLAUDE.md`, `~/.claude-shared/CLAUDE.md`
and every account's copy are equal names for one inode; `~/.claude` is the designated
home for it by convention and because it is the fallback config dir, not because the
filesystem privileges it.

**The status line is shared a third way: by path, with no link.** `settings.json` is
private per account, but its `statusLine` key names a *path*, so one copy of
`statusline.sh` in the store serves everyone and setup only has to write that key.
Consequences that shape the code:

- The store copy is a **copy**, overwritten from the repo whenever the two differ.
  It is the one shared thing that can drift, so `Test-SameContent` gates the copy.
- Git Bash is found via `Get-Command git.exe`, never `bash`. With WSL installed,
  `bash` resolves to `C:\Windows\System32\bash.exe`, which starts a Linux VM that
  cannot open `C:/Users/...` — the bar renders empty with no error anywhere.
- `settings.json` is written by **node**, not `ConvertTo-Json`. PowerShell 5.1's JSON
  writer re-indents the whole file into its ladder style, adds a BOM and CRLF; the
  BOM alone makes `JSON.parse` throw. `JSON.stringify(x, null, 2)` is byte for byte
  what Claude Code writes, so the diff stays one line. Reading with
  `ConvertFrom-Json` is fine and is how `Set-StatusLine` decides skip/set/replace.
- `statusLine` is merged, not replaced, so a `padding` the user set survives.
- Setup writes `~/.claude/settings.json` too — it is the template a fresh account's
  settings are copied from, so skipping it would hand the next account the old bar.
  That is the second of exactly two things setup writes into `~/.claude`, and both
  are reported through `$SeedFromAdditions`/`$SeedFromEdits` so the closing summary
  never claims more than it did.

**The invalid-name class is duplicated on purpose.**
`$ClaudeInvalidNameClass = '[\\/:*?"<>|\[\]]'` appears in both the setup script and the
profile rather than being shared, because dot-sourcing the setup script from the profile
would run a whole setup routine at shell start. `tests/Set-ClaudeAccountName.Tests.ps1`
extracts both by regex and asserts they are identical — keep them in sync.

## PowerShell provider hazards this code is built around

Verified behaviours, not defensive superstition; each site says so in a comment. An
account named `a[1]` is legal on NTFS and exercises all of them.

- `Set-Item -Path "function:global:a[1]"` reports success and creates nothing. Writes to
  the `function:` drive always use `-LiteralPath`.
- `Remove-Item -LiteralPath "function:global:a[1]"` silently no-ops — the `global:`
  prefix defeats removal. Dropping it (`function:a[1]`) works, and still removes the
  global entry when called from inside a helper.
- `Get-Command -Name` takes a *wildcard*, so it reports a function genuinely named
  `a[1]` as absent. Launcher lookups go through `Get-ClaudeCommandLiteral`
  (`$ExecutionContext.InvokeCommand.GetCommand($Name, 'All')`) or drive enumeration
  compared with `-eq`.
- `New-Item` has no `-LiteralPath`, which is why link creation shells out to `mklink`
  instead of `New-Item -ItemType HardLink`.
- `Resolve-Path` keeps a trailing separator and throws on a missing path. Comparisons
  `.TrimEnd('\', '/')`, and anything comparing against a path about to be renamed is
  computed *before* the rename.

## Error-handling split

`setup-claude-accounts.ps1` uses `throw` — it is a one-shot run that should abort. The
profile's functions use `Write-Error` + `return`, because they run in the user's
interactive shell. The consequence: a caller that acts on the result must pass
`-ErrorAction Stop`. The generated launchers do, so `claude-work` with a missing
account dir stops rather than starting Claude Code on whatever config dir the shell
happened to hold.

`Remove-ClaudeAccount` sets `ConfirmImpact = 'High'`; `Rename-ClaudeAccount`
deliberately does not, because a rename is reversible and must not prompt.

## Tests

`tests/Fixtures.ps1` plus four `*.Tests.ps1` files.

- Fixtures swap the **global `$HOME`** to a real temp directory — not `TestDrive:`,
  because `mklink` cannot resolve a PSDrive path. It is restored in `AfterAll`/
  `AfterEach`; a throw in the wrong place leaves the session pointing at a temp dir.
- Dot-source `claude-account-profile.ps1` only *after* `$HOME` is faked. It calls
  `Register-ClaudeAccountFunctions` at load and would otherwise register every real
  account on the machine.
- The scripts talk through `Write-Host`, so their output is on stream 6. Capture with
  `6>&1`, then `Out-String -Width 500` — the default wraps at console width and will
  fold a line break into the middle of the phrase being matched.
- Assert on file *identity* rather than content when testing shared files: a stale copy
  left by an older run has identical content and would pass a content check.
- `StatusLine.Tests.ps1` is the exception, and asserts the opposite: there is no link
  behind the status line, so what has to be checked is that the *edit* to
  `settings.json` changed one key and left the encoding, indentation and every other
  key alone. It needs Git Bash and node on the machine, as the feature does.

## Conventions

- Comments carry the *why*, especially the constraint a line exists to satisfy. Several
  are load-bearing arguments against simplifying a guard back out. Match that density
  rather than the usual "no obvious comments" instinct.
- Substantial changes get a design spec and then an implementation plan under
  `docs/superpowers/`, committed before the code — see the `Rename-ClaudeAccount` spec
  and plan, and the review-pass commits that hardened them.
- Nothing account-specific belongs in this repo; account data lives only in
  `~/.claude-<name>` and `~/.claude-shared`.
