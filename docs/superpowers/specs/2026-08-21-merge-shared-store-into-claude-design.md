# Merge the shared store into ~/.claude — design

Date: 2026-08-21

## Goal

Eliminate `~/.claude-shared` as a separate directory. `~/.claude` becomes the shared
store: it holds the real `projects`, `skills`, `agents`, `commands`, `hooks`, `plugins`,
the real `CLAUDE.md`, `statusline.sh` and `bin/`, and every `~/.claude-<name>` junctions
the six directories into it and hardlinks `CLAUDE.md` from it.

The link mechanisms do not change. Only the target moves.

Two deliverables:

1. The tool is redesigned so `~/.claude` is the store — `setup-claude-accounts.ps1`,
   `claude-account-profile.ps1`, `install.ps1`, the tests and the docs.
2. A new one-shot `migrate-shared-store.ps1` moves an existing machine over.

## Why

`~/.claude` is the config dir Claude Code falls back to when `CLAUDE_CONFIG_DIR` is
unset. Today it is not junctioned into the store at all, so the fallback shell is a
divergent island. Measured on this machine on 2026-08-21:

| directory | files in `~/.claude` | files in `~/.claude-shared` |
| --- | --- | --- |
| `projects` | 97 | 32 |
| `skills` | 2768 | 2768 |
| `agents` | 0 | 0 |
| `commands` | 0 | 0 |
| `hooks` | 0 | 0 |
| `plugins` | 2000 | 2228 |

The fallback dir holds the *bulk* of the transcripts. That is the divergence this
change removes.

## Findings that shaped the design

Verified against the code and this machine on 2026-08-21, not assumed. Five of these
were found by an adversarial review pass after the first draft of the design, and each
one falsified a claim the draft had made.

- **The store is bigger than the shared set, so seeding leaks.** `Copy-Tree`
  (`setup-claude-accounts.ps1:564`) excludes `$SharedDirs + $SkipDirs` and
  `$SharedFiles`. `$SkipDirs` (`:123`) is
  `shell-snapshots, debug, paste-cache, downloads, cache, backups` — no `bin`. And
  `$SharedFiles` defaults to `CLAUDE.md` alone — no `statusline.sh`. Once the store is
  `~/.claude`, `-SeedInto` therefore copies `bin/` and `statusline.sh` into the new
  account as private files. There is no test for this today.

- **`$memoryIsShared` stops proving anything.** `claude-account-profile.ps1:93` gates
  the "CLAUDE.md not shared" tag on the existence of `.claude-shared/CLAUDE.md`, whose
  presence proves the user *asked* for that file to be shared. The existence of
  `~/.claude/CLAUDE.md` proves only that a memory file exists. A literal path swap would
  make `Get-ClaudeAccount` flag every account for a choice the user deliberately made,
  which `tests/SharedMemoryFile.Tests.ps1:263` exists to prevent.

- **The `CLAUDE.md` recovery branch becomes unreachable, and the fallout is an abort.**
  `setup-claude-accounts.ps1:453` recovers a deleted `~/.claude/CLAUDE.md` by re-linking
  it from the store's surviving name. With `$Shared -eq $SeedFrom`, `$target` and
  `$origin` are one path: if `$origin` is missing, `$target` is missing too, so the
  branch cannot fire. Setup falls through to creating a new *empty* store file, and the
  per-account link pass (`:587`) then calls
  `New-FileLink -Link <account>/CLAUDE.md -Target <store>/CLAUDE.md` against a nonempty
  account file that differs from it. `New-FileLink` **throws** "Refusing to overwrite".
  The run aborts. This is worse than losing a self-repair feature.

- **"Only adds, never overwrites" is false.** `setup-claude-accounts.ps1:512` does
  `Copy-Item -Force` on `statusline.sh` into `$Shared` whenever content differs, and
  `Set-StatusLine` (`:324`) rewrites `settings.json`. Neither is recorded:
  `$SeedFromAdditions`/`$SeedFromEdits` are initialised at `:437`, *after* the shared
  directories are created at `:417`, and the `statusline.sh` copy appends to neither.
  Only the seed `settings.json` edit is recorded (`:536`). So the closing summary at
  `:611` can print "Your original ~/.claude was not modified" after modifying it.

- **Setup cannot retarget an existing junction.** `New-Junction` (`:140`) returns early
  on `Test-Junction`, which checks the `ReparsePoint` attribute and never reads the
  target. Changing `$Shared` therefore does not repair anything: existing junctions keep
  pointing at `.claude-shared` forever. Nor does setup reach every account —
  `Set-StatusLine` touches `$SeedFrom` plus the accounts named in `-Accounts`, whose
  default is `work,personal`. The accounts on this machine are `james` and `minhgh`, and
  all three `settings.json` files currently name
  `"C:/Users/Admin/.claude-shared/statusline.sh"`. Migration must own both.

- **Post-merge identity assertions are tautological if written store-to-home.**
  `Test-SameFile` (`setup-claude-accounts.ps1:176`) and the test helper `Test-OneInode`
  (`tests/SharedMemoryFile.Tests.ps1:64`) both `return $true` on `FullName` equality
  *before* checking `LinkType` or peers. Once the store copy and the designated home are
  the same path, any test comparing them passes unconditionally. Identity must be
  asserted **account ↔ store**.

- **`Test-ClaudeSharedMemory` can never return true for `~/.claude` itself.** A file is
  not its own hardlink peer, and `FileInfo.Target` lists only the *other* names. The
  function is publicly callable with `~/.claude`, but its only caller
  (`claude-account-profile.ps1:107`) iterates `Get-ClaudeAccountDir`, which globs
  `.claude-*` and never yields it. Correct as designed; worth a comment so it is not
  "fixed" later.

- **Two `.claude-shared` guards survive as legacy guards.** Migration leaves the old
  store on disk. `.claude-shared` matches `.claude-*` and has a `projects/` entry, so
  without the exclusion at `claude-account-profile.ps1:30` it would appear as an account
  named `shared`. `Rename-ClaudeAccount`'s refusal (`:218`) likewise still protects a
  real directory.

- **Exactly two files collide, and they are different kinds of collision.** Both are
  `.jsonl` transcripts:
  - `D--Documents/f42acfc0-…jsonl` — the legacy copy (995 lines) is a **strict
    line-prefix** of `~/.claude`'s (2668 lines). Not a conflict; the longer file is the
    continued session.
  - `D--code-…-multi-account-switch/248efaba-…jsonl` — **genuinely forked at line 159**.
    The same session id was resumed under two different config dirs and became two
    different conversations. Neither is a superset. Modification time is misleading: the
    legacy copy is *newer* and *shorter*.

- **The forked transcript can be rescued with a two-pattern text replacement.** The id
  appears 390 times across 276 lines: 264 as top-level `sessionId`, 98 as top-level
  `session_id`, and 28 nested inside other values. All 28 nested occurrences were
  inspected: 26 are paths under `%LOCALAPPDATA%\Temp\claude\<project>\<id>\scratchpad`
  and 2 are lines of an `ls -la` listing. None is in `"key":"<id>"` form, and none names
  anything inside `~/.claude` — the scratchpad is ephemeral temp storage outside the
  store. The legacy project directory also holds **no sibling `<id>/` directory** for
  this transcript; it contains two `.jsonl` files and nothing else. Replacing only
  `"sessionId":"<old>"` and
  `"session_id":"<old>"` therefore rewrites exactly the field occurrences and is
  byte-exact everywhere else. No JSON round-trip is needed, and none is wanted: PowerShell
  5.1's JSON writer re-indents and adds a BOM, and the BOM alone would make the file
  unparseable.

- **`plugins/` cannot follow a flat never-overwrite rule.** Measured: **zero** files
  exist only in `~/.claude/plugins`; 6 trees exist only in `.claude-shared/plugins`
  (`superpowers/6.3.0`, `openai-codex` cache, `openai-codex` marketplace, its data dir,
  and two `.orphaned_at` markers); and 4 files differ — `installed_plugins.json`,
  `known_marketplaces.json`, `plugin-catalog-cache.json` and a sweep throttle. The
  differing files are the **registry**. Under never-overwrite, `~/.claude`'s stale
  registry would win and the freshly copied plugin trees would sit on disk unregistered.
  `~/.claude/plugins` is a stale snapshot of `.claude-shared/plugins`, so nothing is lost
  by letting the legacy tree win outright.

- **`~/.claude` becomes load-bearing for every account.** Today `rm -rf ~/.claude` costs
  the fallback config only. After the merge it destroys every account's transcripts,
  skills and plugins at once, and removes the installed profile under `~/.claude/bin`.
  The review pass reported that Anthropic's uninstall/reset documentation prescribes
  deleting `~/.claude`; **that claim was not independently verified** and should be
  confirmed. The risk is accepted deliberately (see Decisions), mitigated by
  documentation and by retaining `.claude-shared` as a standby copy, not by code.

- **Cleanup policy is per-config but now acts on shared data.** Each config dir has its
  own `settings.json` and its own `.last-cleanup` throttle, so the fallback config's
  `cleanupPeriodDays` can delete transcripts every account depends on. Named accounts
  already have this shared-data/private-policy mismatch; the merge adds the fallback
  config as one more independently configured cleanup actor. Accepted, not engineered
  around.

## Decisions

Made by the user during design; recorded so the plan does not re-open them.

1. **Redesign the tool, then migrate.** Not a hand migration, and not "keep two
   directories with the data merged".
2. **Migration is a separate one-shot script**, not folded into
   `setup-claude-accounts.ps1`. The steady-state script should not carry a transitional
   concern forever.
3. **Never overwrite, but rescue forked transcripts.** `~/.claude`'s copy wins on
   conflict; a genuinely forked `.jsonl` is additionally copied in under a fresh session
   id so both halves are resumable. The rule is about not losing data, so it does not
   apply where the store's copy is a strict prefix of the legacy one — see Phase 1b,
   where the longer file is adopted because nothing can be lost by doing so.
4. **Accept the blast radius, and document it.** `.claude-shared` is retained as a full
   standby copy, and the docs gain an explicit warning that `~/.claude` must not be
   deleted to reset Claude Code.
5. **`plugins/` is an explicit exception to rule 3**: the legacy tree wins on conflict,
   including the four registry files. Precisely — missing files are copied in *and*
   differing files are overwritten from `.claude-shared`; nothing is deleted from
   `~/.claude/plugins`. With zero files unique to `~/.claude/plugins` today the two
   readings coincide, but the rule is "overwrite and add", not "replace the tree".

## Design

### 1. The model

`$Shared` becomes `$HOME/.claude`. `~/.claude` carries two roles — shared store and
fallback config dir — and the split follows the existing shared/private line: the six
directories and `CLAUDE.md` are shared; `.credentials.json`, `.claude.json`,
`settings.json`, `history.jsonl` and the caches stay private to it exactly as they are
private to every account.

Changes required beyond the path literals:

- **Store-only artifacts.** A new concept: `bin/` and the basename of `$StatusLine` are
  part of the store but are *not* shared into accounts. They are added to `Copy-Tree`'s
  exclude sets so `-SeedInto` cannot leak them into an account.
- **`$memoryIsShared` gets a semantic replacement, not a path swap.** Shared memory is
  in play **iff at least one account passes `Test-ClaudeSharedMemory`**. That is the same
  evidence the old sentinel carried, without a registry. It keeps
  `tests/SharedMemoryFile.Tests.ps1:238` and `:251` green — `work` stays linked, so the
  gate opens and `personal` is still flagged — and preserves `:263`'s intent. It is not
  equivalent evidence in one state: when *every* account's link is broken the gate closes
  and the diagnostic goes quiet. See Known limitations.
- **Self-repair moves from the store to the accounts.** When a shared file is missing
  from `$Shared`, setup searches the account directories for a surviving hardlink peer
  and re-links from there before falling through to "create empty". The accounts become
  the recovery handle the separate store used to be. Without this step setup aborts, per
  Findings.
- **The reporting machinery is rewritten.** `$SeedFromAdditions`/`$SeedFromEdits` move
  above the store work and gain entries for the shared-directory creation and the
  `statusline.sh` copy. The line "Your original ~/.claude was not modified" (`:611`) is
  deleted; it can no longer be true.
- **Setup claims no self-repair of links.** `New-Junction` keeps its
  attribute-only check. Retargeting is migration's job.
- `install.ps1`'s `$BinDir` becomes `~/.claude/bin`. An existing `$PROFILE` block keeps
  loading `.claude-shared\bin` until `install.ps1` is re-run.
- `statusline.sh` itself contains no store path and needs no change.

### 2. `migrate-shared-store.ps1`

One-shot, re-runnable, `-DryRun`, `throw` on error — matching setup's error model rather
than the profile's, because it is a script run once and not an interactive function.

Documented precondition: **close all Claude Code sessions first.** Process detection is
deliberately not implemented.

**Phase 0 — discovery.** `$Legacy = ~/.claude-shared`, `$Store = ~/.claude`. Exit clean
if `$Legacy` is absent. Refuse if `$Store` does not exist.

Accounts are discovered on disk, and migration's rule is deliberately **wider** than
`Get-ClaudeAccountDir`'s. A `~/.claude-*` directory that is not `.claude-shared` counts
as an account if it contains a `projects/` entry **or** any of the other five shared
directories as a junction targeting `$Legacy`.

The widening exists because Phase 2 removes a junction before recreating it: an
interruption in that window leaves an account with no `projects/` at all, and the
narrow rule would then skip the very account that needs repair — silently contradicting
the re-runnable recovery this design claims. The extra clause cannot match `.claude-mem`,
which has neither a `projects/` entry nor a junction into the legacy store.

This is what finds `james` and `minhgh` rather than the `work,personal` defaults.

**Phase 1 — merge, with a policy per source:**

| Source | Rule |
| --- | --- |
| `projects/` | never overwrite; irreplaceable and append-only |
| `skills/`, `agents/`, `commands/`, `hooks/` | add if missing |
| `plugins/` | legacy wins on conflict: overwrite differing files, add missing ones, delete nothing (Decision 5) |
| `bin/`, `statusline.sh` | copy in as store-only artifacts |
| `CLAUDE.md` | nothing to do — already one inode under all four names |

**Phase 1b — conflict classification inside `projects/`.** A `.jsonl` present on both
sides is classified before anything is written:

- legacy copy is a strict line-prefix of the store's → *superseded*, skipped. The store
  already holds every line the legacy file has.
- store copy is a strict line-prefix of the legacy's → *continued*, and the **legacy file
  is adopted**, overwriting the store's. This is the one overwrite `projects/` permits,
  and it is safe by construction: the file being replaced is a strict subset of the file
  replacing it, so no line is lost. Without this case a continued session would fall
  through to "reported only" and its extra lines would never enter the merged store.
- neither is a prefix of the other → **genuinely forked**, and **rescued**: copied to
  `<newGuid>.jsonl` with only `"sessionId":"<old>"` and `"session_id":"<old>"` replaced.
- anything else that differs → the store's copy is kept and the path is reported

**Sidecar directories are never renamed.** An earlier draft copied a sibling `<old>/`
directory to `<newGuid>/`, which is incoherent: the transcript's own references to that
path are not session-id fields and would not be rewritten, so they would point at a
directory that no longer exists under that name. Instead the sidecar is left alone —
Phase 1's add-if-missing pass over `projects/` already merges any sidecar files unique to
the legacy side into the store's existing `<old>/`, so the rescued transcript's path
references continue to resolve.

The remaining nested mentions of the old id are left untouched deliberately. All 26 in
the known fork are paths under `%LOCALAPPDATA%\Temp\claude\<project>\<id>\scratchpad` —
ephemeral, outside `~/.claude`, and a historical record of commands that already ran.
Rewriting them would falsify the transcript without making anything resolve.

Rescued files are written with `[IO.File]::WriteAllText` and `UTF8Encoding($false)`.
`Set-Content -Encoding utf8` on PowerShell 5.1 emits a BOM, which is the same hazard the
repository already documents for `settings.json`.

**Phase 2 — retarget junctions.** Per discovered account, per shared directory:

- absent → create the junction
- junction whose target resolves under `$Legacy` → `cmd /c rmdir` the link, then relink
  to `$Store`
- junction already targeting `$Store` → skip
- **real directory → refuse and report; never delete**, matching `New-Junction`'s rule

Removal is `cmd /c rmdir` only. `Remove-Item -Recurse` follows junctions on PowerShell
5.1 and would empty the legacy store, destroying the standby copy. Target comparison
trims trailing separators, because `Resolve-Path` and `FileInfo.Target` do not normalise
them.

**Phase 3 — hand off to setup, then re-install the profile.** The final steps run
`setup-claude-accounts.ps1 -Accounts <discovered> -NoSeed` and then `install.ps1`. Setup
rewrites every `statusLine` from the `.claude-shared` path to the `.claude` one,
re-verifies all links, and serves as the migration's own verification pass. Reusing setup
avoids duplicating `Set-StatusLine`, which must stay node-written.

**`-DryRun` must be forwarded to both.** `-NoSeed` does not make setup inert: it would
still copy `statusline.sh`, rewrite `settings.json` and create links. `CLAUDE.md:47`
states that `-DryRun` writes nothing, and a migration dry run that silently performed the
real setup would violate it.

`install.ps1` is not optional here. The `$PROFILE` block written by a previous install
holds an absolute path into `.claude-shared\bin`; copying `bin/` into the store does not
update it. Without this step a user who follows the Phase 4 guidance and deletes the
legacy store loses every account-switching function in new shells.

Order is merge → retarget → setup → install. Nothing is removed before its replacement
exists.

**Phase 4 — report.** Copied, skipped, superseded, adopted, rescued (old id → new id),
unresolved conflicts, and junctions retargeted.

The closing guidance is **conditional, not an invitation**: `.claude-shared` is kept as a
full standby copy, and it is safe to delete only once `install.ps1` has re-run
successfully and a *new* shell has been opened and confirmed working. Deleting it while
`$PROFILE` still points into `.claude-shared\bin` breaks every account-switching function
in future shells. If Phase 3 did not complete, the report says so and withholds the
deletion guidance entirely.

**Out of scope for migration:** deleting `.claude-shared`; touching `.credentials.json`
or `.claude.json`; reconciling anything inside `plugins/` beyond Decision 5.

### 3. Tests

`tests/Fixtures.ps1:11,27` builds `.claude-shared/projects` in the fake `$HOME` and
`mklink`s accounts to it. Moving that to `.claude` is the root change every other test
file inherits. Existing hazards stay: a real temp directory rather than `TestDrive:`
because `mklink` cannot resolve a PSDrive path, and junction teardown through
`cmd /c rmdir` before any `Remove-Item -Recurse` — now doubly load-bearing, since a
teardown that followed a junction would empty `.claude` inside the fake home.

Rewrites:

- `SharedMemoryFile.Tests.ps1:84,180` — identity assertions become account ↔ store.
- `:172` — rewritten to the new recovery path: delete `~/.claude/CLAUDE.md`, assert setup
  re-links it from a surviving account peer **and does not abort**.
- `:263` — setup changes from deleting the store copy to running setup with `CLAUDE.md`
  left out of `-SharedFiles`.
- `StatusLine.Tests.ps1:104,199,211` — path swap only. Its core assertion, that the
  `settings.json` edit changes one key and leaves encoding, indentation and every other
  key alone, is unaffected.
- `Rename-ClaudeAccount.Tests.ps1:93,197,224` — junction-target and store-survival
  assertions repoint to `.claude`. The `.claude-shared` exclusion test stays and now
  covers a leftover legacy store.
- `Set-ClaudeAccountName.Tests.ps1` — the regex extraction asserting
  `$ClaudeInvalidNameClass` is identical across files gains a third file.

New tests, one per defect plus the migration:

- seed leakage: after `-SeedInto`, `bin/` and `statusline.sh` are absent from the account
- recovery from an account peer, without an abort
- the `$memoryIsShared` gate: setup with `-SharedFiles other.md` flags nothing
- reporting honesty: the summary never claims "not modified" after `statusline.sh` was
  copied
- migration: `-DryRun` writes nothing, **including through the setup and install
  handoffs** · a prefix-superseded `.jsonl` is skipped · a reverse-prefix `.jsonl` is
  adopted and the store's shorter copy replaced · a forked `.jsonl` is rescued under a new
  id with its sidecar directory left untouched · a junction is retargeted from a legacy
  fixture · an account whose `projects/` junction is missing entirely is still discovered
  and repaired · a real directory in the way is refused · `plugins/` legacy-wins

### 4. Docs

- Repo `CLAUDE.md` (7 mentions): architecture table, the two-link-mechanisms section, the
  status-line section, and the duplicated-literal note (now three copies). New: the
  store-only-artifact concept, and the blast-radius warning.
- `README.md` (15 mentions): full pass, plus a migration section.
- `.gitignore`: one comment line.

## Success criteria

1. `Invoke-Pester -Path tests` passes, including every new test above.
2. On this machine, after `migrate-shared-store.ps1`: all six junctions in
   `.claude-james` and `.claude-minhgh` target `~/.claude`; all three `settings.json`
   name `~/.claude/statusline.sh`; `~/.claude/projects` contains the union of both sides;
   the rescued fork is resumable under a new id; `superpowers/6.3.0` and the
   `openai-codex` plugin are present *and registered*.
3. `.claude-shared` still exists and is untouched.
4. A shell with no `CLAUDE_CONFIG_DIR` sees the same `projects/`, `skills/` and
   `plugins/` as `claude-james` and `claude-minhgh`.
5. `setup-claude-accounts.ps1 -Accounts james,minhgh -NoSeed -DryRun` writes nothing on
   the migrated machine and reports no pending work. The account list is explicit on
   purpose: the default `-Accounts work,personal` would propose creating two accounts
   that do not exist here.

## Known limitations

- An account Claude Code has never run in has no `projects/` and no junctions, so even
  migration's widened discovery rule cannot see it and it will not be migrated. This is
  the pre-existing limitation of the whole profile, now inherited by the migration script.

- **The new `$memoryIsShared` gate goes quiet when *every* account's link is broken at
  once.** The old sentinel — the existence of `.claude-shared/CLAUDE.md` — survived that
  state and kept flagging. The replacement infers intent from the links themselves, so
  when none survives it cannot distinguish "sharing broke everywhere" from "sharing was
  never asked for", and reports nothing. This matters most on a single-account machine,
  where one editor replace-on-save is enough to reach it. It is not fixable without
  persisting sharing intent somewhere, which is the registry this architecture exists to
  avoid: **the directory is the account**, and nothing else is a source of truth. The
  regression is accepted as the price of that principle. Restoring the diagnostic would
  mean adding a marker file, and that trade should be made explicitly if the quiet
  failure is ever observed in practice.
- The uninstall-documentation claim behind Decision 4 is unverified.
- Migration is not transactional. It is re-runnable, and the only content it overwrites
  is a strict subset of what replaces it, so a failed run is resumed by running it again.
  An interruption between Phase 1 and Phase 2 leaves accounts pointing at the legacy store
  with the merge already done — harmless. An interruption *inside* Phase 2, between
  removing a junction and recreating it, is the one state that would otherwise be
  unrecoverable, and is what the widened discovery rule in Phase 0 exists to catch.
