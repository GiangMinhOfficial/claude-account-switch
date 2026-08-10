# claude-account-switch

Run multiple Claude Code accounts on Windows. Each account keeps its own login;
all accounts share one set of session transcripts, skills, agents and plugins.

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

| Path | Resolves to | Isolated per account |
|---|---|---|
| config dir | `CLAUDE_CONFIG_DIR ?? ~/.claude` | — |
| `.credentials.json` | `join(configDir, ".credentials.json")` | yes |
| `.claude.json` | `join(CLAUDE_CONFIG_DIR \|\| homedir, ".claude.json")` | yes |
| `projects/` | `join(configDir, "projects")` | yes |

Because `projects/` is isolated too, accounts would not see each other's history.
So the directories that *should* be common live once in `~/.claude-shared` and are
exposed to every account through an NTFS **directory junction** — one copy of truth,
no syncing, no divergence.

```
~/.claude-shared/          <- the single real copy
    projects/  skills/  agents/  commands/  hooks/  plugins/  get-shit-done/
    bin/claude-account-profile.ps1        (installed by install.ps1)

~/.claude-work/            <- account: private login + junctions
    .credentials.json      (private)
    .claude.json           (private)
    settings.json          (private)
    sessions/  history.jsonl  cache/ ...   (private)
    projects/ -> ~/.claude-shared/projects        (junction)
    skills/   -> ~/.claude-shared/skills          (junction)
    ...

~/.claude-personal/        <- same shape, different login
```

---

## Requirements

- Windows, PowerShell 5.1 or later
- Claude Code installed and on `PATH`
- No administrator rights (junctions via `mklink /J`, unlike real symlinks)

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

**2. Create the accounts.** `-SeedInto` picks which account inherits your *existing*
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

| Command | Effect |
|---|---|
| `claude-work` | Launch Claude Code as `work` (args pass through: `claude-work --resume`) |
| `claude-personal` | Launch Claude Code as `personal` |
| `Use-ClaudeAccount work` | Point this shell at `work` **without** launching |
| `Get-ClaudeAccount` | Show the current account, list all accounts, flag any not logged in |
| `Reset-ClaudeAccount` | Return this shell to the default `~/.claude` |
| `Remove-ClaudeAccount personal` | Delete an account safely (see warning below) |

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
> PowerShell 5.1 can follow junctions while recursing and delete the *contents of the
> shared store* behind them — taking every account's transcripts and skills with it.
> `Remove-ClaudeAccount` unlinks each junction with `rmdir` first (which removes the
> link, never the target), verifies no reparse points remain, and only then deletes.

---

## Safety notes

- **Your original `~/.claude` is never modified.** Setup only reads from it. It stays
  as a working fallback: any shell without `CLAUDE_CONFIG_DIR` set uses it.
- **That fallback is also the main gotcha.** A plain `claude` in a fresh shell writes
  sessions to `~/.claude/projects`, which is *not* the shared store — those sessions
  will not appear on your accounts. Launch through `claude-<name>` to stay consistent.
- **Credentials are plaintext.** Each `~/.claude-<name>/.credentials.json` holds OAuth
  access and refresh tokens, exactly as stock Claude Code does. Having several means
  one leak exposes several accounts. Keep them out of any backup or cloud-sync folder.
- **Shared history is shared in both directions.** If one account is an employer's,
  its transcripts are visible from your personal account and vice versa. To keep a
  particular account separate, remove `projects` from `-SharedDirs` for it.

---

## Uninstall

```powershell
.\install.ps1 -Uninstall      # remove the profile block only
Remove-ClaudeAccount work     # then each account, if you want them gone
```

`-Uninstall` leaves `~/.claude-shared` and every account directory untouched. Once no
account junctions point at it any more, delete `~/.claude-shared` by hand.

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

**Sessions from one account are missing on another**

Confirm the junctions are real, and that both point at the same target:

```powershell
Get-ChildItem ~\.claude-work -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
    Select-Object Name, Target
```
