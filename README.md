# claude-account-switch

Run multiple Claude Code accounts on Windows. Each account keeps its own login;
all accounts share one set of session transcripts, skills, agents, plugins and
one global `CLAUDE.md`.

No admin rights. Nothing is ever deleted from your existing `~/.claude`.

---

## Why not just copy `~/.claude` around

The common approach (and every "multi-account switcher" script built on it) swaps
accounts by doing `rm -rf ~/.claude` and restoring a snapshot. That is destructive
by design: a half-finished copy, a file locked by a running Claude Code process, or
a snapshot taken before your last login all cost you real data.

This repo uses the supported mechanism instead: the `CLAUDE_CONFIG_DIR` environment
variable. Switching accounts becomes setting a variable — no copying, no deleting.

Verified against the Claude Code binary (v2.1.63), every identity-bearing path
follows the config dir:

| Path                | Resolves to                                            | Isolated per account |
| ------------------- | ------------------------------------------------------ | -------------------- |
| config dir          | `CLAUDE_CONFIG_DIR ?? ~/.claude`                       | —                    |
| `.credentials.json` | `join(configDir, ".credentials.json")`                 | yes                  |
| `.claude.json`      | `join(CLAUDE_CONFIG_DIR \|\| homedir, ".claude.json")` | yes                  |
| `projects/`         | `join(configDir, "projects")`                          | yes                  |
| `CLAUDE.md`         | `join(configDir, "CLAUDE.md")`                         | yes                  |

Because `projects/` is isolated too, accounts would not see each other's history.
So the directories that _should_ be common live once in `~/.claude-shared` and are
exposed to every account through an NTFS **directory junction** — one copy of truth,
no syncing, no divergence.

`CLAUDE.md` — your global memory — follows the config dir in exactly the same way,
but it is a _file_, and a junction only links directories. It gets an NTFS
**hardlink** instead: the real file stays in `~/.claude`, and the store and every
account hold additional names for that same inode. Editing it from any account
edits it for all of them, because there is only one of it.

```
~/.claude/                 <- the default config dir, still a working fallback
    CLAUDE.md              <- the real global memory file lives here

~/.claude-shared/          <- the single real copy of everything else
    projects/  skills/  agents/  commands/  hooks/  plugins/  get-shit-done/
    CLAUDE.md -> another name for ~/.claude/CLAUDE.md   (hardlink)
    bin/claude-account-profile.ps1        (installed by install.ps1)

~/.claude-work/            <- account: private login + links
    .credentials.json      (private)
    .claude.json           (private)
    settings.json          (private)
    sessions/  history.jsonl  cache/ ...   (private)
    projects/ -> ~/.claude-shared/projects        (junction)
    skills/   -> ~/.claude-shared/skills          (junction)
    CLAUDE.md -> the same inode as ~/.claude/CLAUDE.md   (hardlink)
    ...

~/.claude-personal/        <- same shape, different login
```

A hardlink has no "original": every name for the file is equal, and deleting one
name never touches the content behind the others. That is why `~/.claude` can keep
the file while every account still reads and writes it.

---

## Requirements

- Windows, PowerShell 5.1 or later
- Claude Code installed and on `PATH`
- No administrator rights (junctions via `mklink /J` and hardlinks via `mklink /H`,
  unlike real symlinks — which is why neither mechanism here is a symlink)
- NTFS, with `~/.claude`, `~/.claude-shared` and the accounts on one volume. A
  hardlink cannot cross volumes; junctions can, but nothing here needs them to.

---

## Setup on a new machine

```powershell
git clone <this-repo> claude-account-switch
cd claude-account-switch
```

**1. See what it would do — changes nothing:**

```powershell
.\setup-claude-accounts.ps1 -DryRun
```

**2. Create the accounts.** `-SeedInto` picks which account inherits your _existing_
login and settings from `~/.claude`:

```powershell
.\setup-claude-accounts.ps1 -Accounts work,personal -SeedInto work
```

If Claude Code is freshly installed and you have no login yet, seed nothing and log
in to both accounts separately:

```powershell
.\setup-claude-accounts.ps1 -Accounts work,personal -SeedInto ''
```

**3. Install the shell functions:**

```powershell
.\install.ps1
```

This copies `claude-account-profile.ps1` to `~/.claude-shared/bin/` and adds a marked
block to your `$PROFILE` that dot-sources it — so the repo checkout can be moved or
deleted afterwards. Re-run `.\install.ps1` after a `git pull` to pick up changes, or
use `.\install.ps1 -FromRepo` to dot-source the repo copy directly and skip that step.

**4. Open a new PowerShell window** and log in to any account that needs it:

```powershell
claude-work        # already logged in if it was the seeded account
claude-personal    # run /login once, then exit
```

That is the whole setup. `/login` uses the normal OAuth flow.

---

## Usage

| Command                              | Effect                                                                   |
| ------------------------------------ | ------------------------------------------------------------------------ |
| `claude-work`                        | Launch Claude Code as `work` (args pass through: `claude-work --resume`) |
| `claude-personal`                    | Launch Claude Code as `personal`                                         |
| `Use-ClaudeAccount work`             | Point this shell at `work` **without** launching                         |
| `Get-ClaudeAccount`                  | Show the current account, list all accounts, flag any not logged in or no longer sharing `CLAUDE.md` |
| `Reset-ClaudeAccount`                | Return this shell to the default `~/.claude`                             |
| `Remove-ClaudeAccount personal`      | Delete an account safely (see warning below)                             |
| `Rename-ClaudeAccount personal work` | Rename an account and its launchers (see below)                          |

A `claude-<name>` function is generated for every `~/.claude-<name>` directory, plus
a bare `<name>` alias when it does not shadow an existing command. Adding an account
needs no edit to the profile — open a new shell, or run
`Register-ClaudeAccountFunctions`.

The variable persists for the life of the shell: after `claude-work`, a plain
`claude` in that same window is still the `work` account. A brand-new shell starts
on the default `~/.claude`.

---

## Continuing a session across accounts

This is the payoff of the shared `projects/` junction.

Session transcripts are stored per **working directory**, not per account:

```
<configDir>/projects/<encoded-cwd>/<session-id>.jsonl
```

Since every account's `projects/` is the same physical folder, a conversation started
on one account can be resumed on another — just `cd` to the same directory first:

```powershell
cd D:\code\myproject
claude-work                  # work on something, exit

claude-personal --resume     # same directory -> the work session is listed
```

There is no server-side binding between a session and an account. Resuming replays
the local transcript and continues under whichever credentials are active.

**Do not resume the same session from two accounts at once** — two processes
appending to one `.jsonl` will interleave.

---

## One global CLAUDE.md for every account

Claude Code reads global memory from `<configDir>/CLAUDE.md`, so without this each
account would have its own — and `/memory` on a fresh account opens an empty file
rather than the instructions you wrote.

Setup hardlinks it, so all of these are one file:

```
~/.claude/CLAUDE.md              <- the real file
~/.claude-shared/CLAUDE.md       <- another name for it
~/.claude-work/CLAUDE.md         <- another name for it
~/.claude-personal/CLAUDE.md     <- another name for it
```

`/memory` from any account edits the shared content directly. So does an editor, a
`git checkout`, or anything else that writes to the path — there is no sync step
and no "primary" copy to remember.

To apply this to accounts that already exist, re-run setup for them. Nothing is
re-seeded and existing junctions are left alone:

```powershell
.\setup-claude-accounts.ps1 -Accounts work,personal -NoSeed
```

Setup will not silently discard memory an account already wrote. It replaces the
account's `CLAUDE.md` only when the file is empty, or is byte-for-byte identical to
the shared one; anything else stops the run with `Refusing to overwrite`, so you can
merge it into the shared file yourself and re-run.

To keep an account's memory private, drop `CLAUDE.md` from `-SharedFiles`:

```powershell
.\setup-claude-accounts.ps1 -Accounts client -NoSeed -SharedFiles @()
```

`-SharedFiles` takes any list of plain file names at the top of the config dir, so
the same mechanism shares anything else that is not a directory.

> **One caveat, and it is the reason `Get-ClaudeAccount` checks.** Some editors save
> by writing a new file and renaming it over the old one. That replaces the link with
> an ordinary file, and the account quietly stops following the shared memory while
> still showing a perfectly readable `CLAUDE.md`. `Get-ClaudeAccount` marks such an
> account `CLAUDE.md not shared`; re-running setup relinks it.

---

## Adding and removing accounts

Add:

```powershell
.\setup-claude-accounts.ps1 -Accounts client -SeedInto ''
# new shell, then:  claude-client   ->  /login
```

Remove:

```powershell
Remove-ClaudeAccount client
```

> **Never delete an account folder with `Remove-Item -Recurse` or Explorer.**
> PowerShell 5.1 can follow junctions while recursing and delete the _contents of the
> shared store_ behind them — taking every account's transcripts and skills with it.
> `Remove-ClaudeAccount` unlinks each junction with `rmdir` first (which removes the
> link, never the target), verifies no reparse points remain, and only then deletes.

Rename:

```powershell
Rename-ClaudeAccount personal work
# then open a NEW shell
```

`~/.claude-personal` becomes `~/.claude-work`, the `personal` launchers are dropped
and the `work` ones generated. The junctions inside are absolute paths into
`~/.claude-shared`, so shared history is unaffected. There is no alias layer — the
directory is the account's name.

Three things to know:

- **Other open shells keep the old launchers.** They loaded the profile into memory
  and nothing on disk can change that. Open a new shell after renaming.
  If you installed with `.\install.ps1` (the default), re-run it after pulling
  changes — `$PROFILE` loads the copy in `~/.claude-shared/bin/`, not the repo.
- **Do not rename an account that has a live Claude Code session.** Claude Code
  writes and closes rather than holding handles, so the rename usually _succeeds_ —
  and the running process, still holding the old `CLAUDE_CONFIG_DIR`, recreates the
  old directory on its next write. That phantom gets a real `projects/` folder
  instead of a junction, so it reappears in `Get-ClaudeAccount` as an account and
  every transcript it writes is invisible from every account, including the renamed
  one. Exit your sessions first.
- **An account configured without a shared `projects` cannot be renamed** until
  Claude Code has run in it once. `Get-ClaudeAccountDir` identifies accounts by
  their `projects/` entry, so such an account has no launchers either — a
  pre-existing limitation of the whole profile, not of rename.
- **Names starting with `claude-` are refused.** An account called `claude-foo`
  would want the bare launcher `claude-foo`, which is already the _prefixed_
  launcher of an account called `foo`. Rename blocks both directions of that
  collision.

---

## Safety notes

- **Nothing in your original `~/.claude` is changed or removed.** Setup only reads
  from it. It stays as a working fallback: any shell without `CLAUDE_CONFIG_DIR` set
  uses it. The one thing setup can _add_ there is an empty `CLAUDE.md`, and only if
  you have none at all — a hardlink needs a real file to be a second name for, and
  `~/.claude` is where that file belongs. Setup says so when it does this.
- **That fallback is also the main gotcha.** A plain `claude` in a fresh shell writes
  sessions to `~/.claude/projects`, which is _not_ the shared store — those sessions
  will not appear on your accounts. Launch through `claude-<name>` to stay consistent.
- **Credentials are plaintext.** Each `~/.claude-<name>/.credentials.json` holds OAuth
  access and refresh tokens, exactly as stock Claude Code does. Having several means
  one leak exposes several accounts. Keep them out of any backup or cloud-sync folder.
- **Shared history is shared in both directions.** If one account is an employer's,
  its transcripts are visible from your personal account and vice versa. To keep a
  particular account separate, remove `projects` from `-SharedDirs` for it — and
  `CLAUDE.md` from `-SharedFiles`, which is shared in both directions for the same
  reason.
- **`Remove-ClaudeAccount` needs no special care for the hardlink.** A hardlink is
  not a reparse point, so it is not in the unlink pass — and it does not need to be.
  Deleting one name for a file never touches the content behind the other names.
- **`claude-<name>` now fails instead of falling back.** Previously, launching an
  account whose directory was missing printed an error and then started Claude Code
  anyway, under whatever config dir the shell held — dropping you into the wrong
  account. The launcher now aborts. A script that calls `claude-work` will stop
  rather than continue.
- **`setup-claude-accounts.ps1` now rejects two kinds of name it used to accept:**
  names containing `[` or `]`, and names ending in a dot. Bracketed names got no
  launchers at all (PowerShell's `function:` provider reads them as wildcards) while
  reporting success; trailing dots are silently stripped by Windows, so the account
  created was never the one asked for. Path characters (`\ / : * ? " < > |`) were
  already rejected — nothing else changes.

---

## Uninstall

```powershell
.\install.ps1 -Uninstall      # remove the profile block only
Remove-ClaudeAccount work     # then each account, if you want them gone
```

`-Uninstall` leaves `~/.claude-shared` and every account directory untouched. Once no
account junctions point at it any more, delete `~/.claude-shared` by hand.

---

## Testing

Pester 5 is required. Windows ships 3.4.0, which is syntactically incompatible.
The upgrade needs two things that are easy to miss: TLS 1.2 (PowerShell 5.1
defaults to TLS 1.0, which PSGallery refuses) and `-SkipPublisherCheck` (the
shipped copy is Microsoft-signed).

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

Import-Module Pester -MinimumVersion 5.0    # both versions stay installed
Invoke-Pester -Path tests -Output Detailed
```

The tests run against a temporary fake `$HOME`; they never touch your real accounts.

---

## Troubleshooting

**`running scripts is disabled on this system`**

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**Scripts blocked after downloading the repo as a ZIP** (not needed for `git clone`):

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

**`Refusing to replace real directory with a junction`**

A real folder already sits where a junction belongs — usually because an account was
created by hand or a previous run was interrupted. Move it aside and re-run:

```powershell
Move-Item ~\.claude-work\projects ~\.claude-work\projects.bak
.\setup-claude-accounts.ps1 -Accounts work -SeedInto ''
```

**An account shows `(not logged in)` in `Get-ClaudeAccount`**

It has no `.credentials.json` yet. Run `claude-<name>` and then `/login`.

**An account shows `(CLAUDE.md not shared)`**

Its `CLAUDE.md` is an ordinary file again — usually because an editor saved it by
writing a new file and renaming it over the link. Anything written to it since is in
that file only. Merge what you want to keep into `~/.claude/CLAUDE.md`, then relink:

```powershell
Remove-Item ~\.claude-work\CLAUDE.md          # only after merging
.\setup-claude-accounts.ps1 -Accounts work -NoSeed
```

Setup relinks an empty or byte-identical file on its own, so if you have not touched
the account's copy, the re-run alone is enough.

**`Refusing to overwrite ...\CLAUDE.md`**

That account wrote memory of its own before `CLAUDE.md` was shared, and setup will
not decide for you which version wins. Merge it into `~/.claude/CLAUDE.md`, delete
the account's copy, and re-run.

**Checking the shared file by hand**

`Target` lists the file's other names. Every account should appear in it:

```powershell
Get-Item ~\.claude\CLAUDE.md -Force | Select-Object LinkType, Target
```

**Sessions from one account are missing on another**

Confirm the junctions are real, and that both point at the same target:

```powershell
Get-ChildItem ~\.claude-work -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
    Select-Object Name, Target
```
