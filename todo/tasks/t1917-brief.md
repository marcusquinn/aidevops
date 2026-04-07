---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1917: Linux scheduler dual-execution fix and systemd migration completion

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human, interactive session reviewing GH#17695)
- **Parent task:** none (upstream: GH#17695 by @robstiles)
- **Conversation context:** External contributor filed detailed issue about cron/systemd scheduler gaps on Linux. Review confirmed findings A (dual-execution bug), B (non-interactive update gap), C (helper bypass), D (missing migration) are real. macOS (launchd) is unaffected. Accepting the fix as valid cross-platform work.

## What

Fix four gaps in the Linux scheduler path:

**A. Dual-execution bug (critical):** After systemd timer install succeeds, clean up any pre-existing cron entries. Fix uninstall to check ALL backends sequentially, not `elif`.

**B. Non-interactive update gap:** Extend `_should_setup_noninteractive_*` pattern to cover all 10+ schedulers, not just pulse.

**C. Helper script bypass (3 files):** Replace hardcoded Linux→cron with `platform-detect.sh` sourcing in `auto-update-helper.sh`, `repo-sync-helper.sh`, `attribution-detection-helper.sh`.

**D. Migration function:** Add `_migrate_cron_to_systemd()` to `migrations.sh` for existing installations switching from cron to systemd.

## Why

On Linux systems with systemd, installing a systemd timer without removing the existing cron entry causes dual execution — the scheduled task fires twice. The uninstall only checks one backend, leaving orphan entries. This is a real bug affecting Linux deployments.

## Tier

`tier:standard`

**Tier rationale:** Multiple files but each change is straightforward. Clear dependency graph A→C→B→D. No architectural decisions needed — follows existing patterns.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/schedulers.sh:616-627` — add cron cleanup after systemd success
- `EDIT: .agents/scripts/schedulers.sh:663-683` — change `elif` to sequential checks in `_uninstall_scheduler()`
- `EDIT: .agents/scripts/auto-update-helper.sh:127-133` — source platform-detect.sh, use scheduler backend
- `EDIT: .agents/scripts/repo-sync-helper.sh:100-106` — source platform-detect.sh, use scheduler backend
- `EDIT: .agents/scripts/attribution-detection-helper.sh:551-555` — source platform-detect.sh, use scheduler backend
- `EDIT: .agents/scripts/setup.sh:963-974` — extend non-interactive scheduler coverage
- `EDIT: .agents/scripts/migrations.sh` — add `_migrate_cron_to_systemd()`

### Implementation Steps

1. **Finding A — schedulers.sh dual-execution fix:**

   After `_install_scheduler_systemd()` succeeds (line ~627), add cron cleanup:

   ```bash
   # After systemd install succeeds, remove any pre-existing cron entry
   if command -v crontab >/dev/null 2>&1; then
       local marker="$1"
       local current_cron
       current_cron=$(crontab -l 2>/dev/null) || current_cron=""
       if [[ -n "$current_cron" ]] && echo "$current_cron" | grep -qF "$marker"; then
           echo "$current_cron" | grep -vF "$marker" | crontab -
           echo "[schedulers] Removed pre-existing cron entry for $marker (migrated to systemd)"
       fi
   fi
   ```

   Fix `_uninstall_scheduler()` — replace `elif` with sequential checks:

   ```bash
   # Check and remove from ALL backends, not just the first match
   if systemctl --user is-enabled "$timer_name" 2>/dev/null; then
       systemctl --user stop "$timer_name" 2>/dev/null || true
       systemctl --user disable "$timer_name" 2>/dev/null || true
       rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${timer_name}"* 2>/dev/null
       systemctl --user daemon-reload 2>/dev/null || true
   fi
   if command -v crontab >/dev/null 2>&1; then
       local current_cron
       current_cron=$(crontab -l 2>/dev/null) || current_cron=""
       if echo "$current_cron" | grep -qF "$marker"; then
           echo "$current_cron" | grep -vF "$marker" | crontab -
       fi
   fi
   ```

2. **Finding C — helper scripts:** Source `platform-detect.sh` and use its scheduler backend detection instead of hardcoded `uname` checks.

3. **Finding B — setup.sh:** Follow the `_should_setup_noninteractive_supervisor_pulse()` pattern for remaining schedulers.

4. **Finding D — migrations.sh:** Add migration function that scans cron for aidevops markers and converts to systemd timers.

### Verification

```bash
shellcheck .agents/scripts/schedulers.sh .agents/scripts/auto-update-helper.sh \
  .agents/scripts/repo-sync-helper.sh .agents/scripts/attribution-detection-helper.sh \
  .agents/scripts/setup.sh .agents/scripts/migrations.sh
```

## Acceptance Criteria

- [ ] `_install_scheduler_systemd()` removes pre-existing cron entries on success
  ```yaml
  verify:
    method: codebase
    pattern: "grep -vF.*cron"
    path: ".agents/scripts/schedulers.sh"
  ```
- [ ] `_uninstall_scheduler()` checks systemd AND cron sequentially (no elif)
  ```yaml
  verify:
    method: bash
    run: "! rg 'elif.*crontab' .agents/scripts/schedulers.sh | grep -q 'uninstall'"
  ```
- [ ] Helper scripts source `platform-detect.sh` instead of hardcoding cron
  ```yaml
  verify:
    method: codebase
    pattern: "platform-detect"
    path: ".agents/scripts/auto-update-helper.sh"
  ```
- [ ] ShellCheck clean on all modified files
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/schedulers.sh .agents/scripts/auto-update-helper.sh .agents/scripts/repo-sync-helper.sh .agents/scripts/attribution-detection-helper.sh"
  ```
- [ ] macOS launchd path unchanged (no regression)
  ```yaml
  verify:
    method: bash
    run: "rg 'launchctl\\|plist' .agents/scripts/schedulers.sh | wc -l | xargs test 0 -lt"
  ```

## Context & Decisions

- macOS (launchd) is unaffected — this is Linux-only work
- Implementation order: A→C→B→D (dependency graph from GH#17695)
- `worker-watchdog.sh` already fixed (GH#17691) — excluded from scope
- `routine-helper.sh` tracked separately (GH#17692/t1909)
- Decomposition into separate PRs (A standalone, C+B+D follow-up) is recommended but not required

## Relevant Files

- `.agents/scripts/schedulers.sh` — core scheduler install/uninstall
- `.agents/scripts/setup.sh:963-974` — non-interactive scheduler setup
- `.agents/scripts/auto-update-helper.sh:127-133` — hardcoded cron
- `.agents/scripts/repo-sync-helper.sh:100-106` — hardcoded cron
- `.agents/scripts/attribution-detection-helper.sh:551-555` — inline platform check
- `.agents/scripts/migrations.sh` — migration functions
- `.agents/scripts/platform-detect.sh` — scheduler backend detection

## Dependencies

- **Blocked by:** none
- **Blocks:** Closing GH#17695
- **External:** Linux test environment for full verification (macOS can only verify shellcheck + code review)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review schedulers.sh patterns |
| Implementation (A) | 45m | Dual-execution fix + uninstall fix |
| Implementation (C) | 30m | 3 helper scripts |
| Implementation (B) | 30m | setup.sh non-interactive |
| Implementation (D) | 45m | Migration function |
| Testing | 30m | shellcheck + code review |
| **Total** | **~3h** | |
