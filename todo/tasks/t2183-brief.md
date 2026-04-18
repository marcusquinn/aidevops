<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2183 — r913 launchd scheduler install

- Origin: interactive (marcusquinn)
- Tier: standard
- Parent: t2174 (routine delivered in v3.8.69 but without a scheduler wiring)

## What

Wire r913 (`opencode-db-maintenance-helper.sh`) into the platform scheduler so
it actually fires on its declared "Weekly Sunday 04:00 local" cadence. Today
the routine is registered in `core-routines.sh`, has a GitHub tracking issue
(`marcusquinn/aidevops-routines#17`), and has a state directory — but
`~/Library/LaunchAgents/sh.aidevops.opencode-db-maintenance.plist` does not
exist and no systemd/cron equivalent is installed. It only runs when someone
invokes it manually.

**Deliverable**: after `aidevops update` on a supported platform, the routine
becomes self-firing without further user action. On macOS the LaunchAgent is
installed, loaded, and visible in `launchctl list`. On Linux a systemd user
timer or cron entry is installed.

## Why

t2174 delivered the helper, the routine entry, the tests, the doc, and the
GitHub tracking issue. The scheduler installer was the missing piece —
caught during the interactive handoff by inspection of
`~/Library/LaunchAgents/sh.aidevops.*.plist` vs the routine declaration. The
routine was declared `weekly(sun@04:00)` but nothing reads that declaration
and installs the platform timer. Every other shipped routine
(r903/r904/r907/r908/r909/r910/r911) has its own installer in
`setup-modules/schedulers.sh`.

## How

Two files change.

### `.agents/scripts/opencode-db-maintenance-helper.sh` (EDIT)

Add three subcommands, modelled on the pattern in
`.agents/scripts/repo-sync-helper.sh:144-626`:

- `install` — generate `~/Library/LaunchAgents/sh.aidevops.opencode-db-maintenance.plist`,
  diff against any existing content, `launchctl load -w` only if changed.
  Plist uses `StartCalendarInterval` (not `StartInterval`) with
  `Weekday=0 Hour=4 Minute=0` to match the declared wall-clock schedule.
  Logs to `$HOME/.aidevops/.agent-workspace/logs/opencode-db-maintenance.log`.
- `uninstall` — `launchctl unload` + `rm -f` the plist. Idempotent (ok if
  already absent / not loaded).
- `status` (nice-to-have, low cost) — report "installed/loaded/next-run" via
  `launchctl list` for diagnostic symmetry with the existing `check` /
  `report` / `maintain` / `auto` subcommands.

Also update `usage()` and the README-style comment block at the top of the
helper to mention the new subcommands.

### `setup-modules/schedulers.sh` (EDIT)

Add a `setup_opencode_db_maintenance()` function at the end of the file
(near `setup_profile_readme`), modelled on `setup_profile_readme` at
`setup-modules/schedulers.sh:1656-1697` and
`_install_profile_readme_launchd` at `:1571-1628`.

- **Readiness guard**: only proceed if
  `$HOME/.aidevops/agents/scripts/opencode-db-maintenance-helper.sh`
  exists and is executable. No opencode-presence check here — the helper
  itself already no-ops when `~/.local/share/opencode/opencode.db` is
  absent, so installing the plist on a non-opencode machine is harmless
  (the routine wakes up weekly, sees no DB, and exits 0 silently).
- **macOS**: delegate to `bash "$script" install`. Let the helper own its
  own plist generation (Approach B, same as `repo-sync-helper.sh`). This
  keeps the plist shape co-located with the routine it drives.
- **Linux**: call `_install_scheduler_linux` with a weekly cron spec
  (`0 4 * * 0` — Sunday 04:00). Same shape used by other weekly routines.
- **Windows**: not required for this iteration; opencode on Windows is rare
  and the helper already handles missing opencode gracefully. Leave a
  `# TODO(t2183-followup)` marker.

Call `setup_opencode_db_maintenance` from the main scheduler entry point —
search for the block that sequences `setup_contribution_watch`,
`setup_profile_readme`, `setup_oauth_token_refresh`, `setup_repo_sync`
(likely `setup_schedulers` or similar in this file or its caller).

## Verification

Local (on the author's Mac):

1. `./setup.sh --non-interactive` in the canonical repo.
2. `ls ~/Library/LaunchAgents/sh.aidevops.opencode-db-maintenance.plist`
   — file exists.
3. `launchctl list | grep opencode-db-maintenance` — loaded.
4. `plutil -p ~/Library/LaunchAgents/sh.aidevops.opencode-db-maintenance.plist`
   — shows `StartCalendarInterval => { Weekday => 0, Hour => 4, Minute => 0 }`.
5. `bash ~/.aidevops/agents/scripts/opencode-db-maintenance-helper.sh uninstall`
   — plist removed + unloaded.
6. Re-run `install` — idempotent, no error on re-install.

Regression:

- Existing `.agents/scripts/tests/test-opencode-db-maintenance.sh` must still
  pass 11/11 (install/uninstall commands should not affect the
  check/report/maintain/auto sandboxed tests).
- ShellCheck clean on both modified files.
- Complexity gate: new `cmd_install` / `cmd_uninstall` must fit under the
  100-line per-function cap. If the plist HEREDOC pushes `cmd_install` over,
  extract a `_generate_plist_content` helper the same way
  `repo-sync-helper.sh:_generate_plist` does.

## Acceptance

- [x] `cmd_install` + `cmd_uninstall` subcommands present, shellcheck clean,
      under per-function complexity cap.
- [x] `setup_opencode_db_maintenance` wired into `schedulers.sh` and invoked
      from the main scheduler loop.
- [x] macOS plist uses `StartCalendarInterval` (Weekday=0 Hour=4 Minute=0).
- [x] Idempotent: re-running `install` when already loaded with identical
      content produces no reload noise (same `_launchd_install_if_changed`
      semantics as the other routines).
- [x] Existing 11 tests still pass.
- [x] Manual end-to-end verification on the author's Mac (launchctl list
      shows the loaded agent).

## PR Conventions

- Title: `t2183: wire r913 opencode DB maintenance into platform scheduler`
- Body closer: `Resolves #<issue-number>` (leaf task, not parent).
- Label: `origin:interactive`.

## Notes

- The helper already no-ops on missing opencode DB, so Sunday-at-04:00 runs
  on a non-opencode machine cost approximately one `sqlite3 -version` +
  one `stat` — effectively free. Installing unconditionally is safer than
  trying to detect opencode presence at setup time (users may install it
  after `aidevops update` ran).
- No ratchet or threshold bumps needed; this adds ~80 lines of shell and
  one plist.
