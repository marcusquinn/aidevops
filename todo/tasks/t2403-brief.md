# t2403: Fix Linux auto-update status + docs (systemd branch missing)

## Session origin

- Date: 2026-04-19
- Context: Interactive audit of Linux auto-update paths after shipping t2400 dispatch filter. User flagged "interesting that Linux users might not have auto-update running" — investigated and found three stale-docs / missing-code gaps in `auto-update-helper.sh` around the systemd backend that `platform-detect.sh` can legitimately select.
- Sibling tasks: t2404 (Linux systemd linger gap — separate, higher-impact bug).

## What

Fix the three user-visible gaps that make the systemd scheduler backend a second-class citizen in `auto-update-helper.sh`:

1. `_cmd_status_scheduler` has no `systemd` branch — Linux users with the systemd backend enabled see misleading "cron: disabled" output even when their timer is running.
2. `cmd_help` docstring "SCHEDULER BACKENDS" section claims "Linux: cron" only — hides the systemd path entirely.
3. `.agents/reference/auto-update.md` claims "Linux cron" and uses a stale launchd label (`com.aidevops.auto-update.plist` — actual label has the `aidevops.aidevops` double prefix).

## Why

`_get_scheduler_backend` → `platform-detect.sh` → `_detect_linux_scheduler` at `.agents/scripts/platform-detect.sh:35-43` already prefers systemd user services over cron when `systemctl --user status` succeeds. Code path works; status/help/docs don't. Consequence:

- Linux user runs `aidevops auto-update status`, sees "Scheduler: cron / Status: disabled" despite an enabled systemd timer. They either disable (wrong) or dig through code to figure out reality.
- Anyone reading `aidevops auto-update --help` or the reference doc has no reason to believe systemd is the Linux default, so can't intuit which files to inspect when debugging.
- Stale plist label in the reference doc is a trap for anyone grepping `find ~/Library -name "*aidevops*"`.

Low severity individually, high compounded: the framework advertises cross-platform but its diagnostic surface silently assumes macOS + Linux-cron.

## How

### Files to modify

- **EDIT**: `.agents/scripts/auto-update-helper.sh`
  - `_cmd_status_scheduler` (~line 1890-1938): the current `else` branch at line 1924 only handles cron. Split into three branches: `launchd` (existing, unchanged), `systemd` (new — read `systemctl --user is-enabled ${SYSTEMD_UNIT_NAME}.timer`, `systemctl --user status ${SYSTEMD_UNIT_NAME}.timer --no-pager --lines=0` for next-fire time, display unit + service + timer file paths), `cron` (existing — triggered only when `$backend == "cron"` explicitly). Keep the YELLOW "legacy cron entry found" warning under all three branches so migration-in-flight states remain visible.
  - `cmd_help` heredoc (~line 2115-2119): replace the two-line "SCHEDULER BACKENDS" block with:
    - `macOS:  launchd LaunchAgent (~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist)`
    - `Linux:  systemd user timer preferred (~/.config/systemd/user/aidevops-auto-update.timer); falls back to cron when systemctl --user unavailable`
    - Keep the "auto-migrates cron on macOS" note.

- **EDIT**: `.agents/reference/auto-update.md`
  - Line 10: replace `macOS launchd (~/Library/LaunchAgents/com.aidevops.auto-update.plist); Linux cron.` with accurate three-backend coverage including the correct label `com.aidevops.aidevops-auto-update.plist` and systemd unit name `aidevops-auto-update.timer`.
  - Mention the `_detect_linux_scheduler` preference order (systemd > cron) so reference readers can predict which files `enable` will create.
  - Note that this doc does NOT cover linger — forward-link to t2404 once it lands.

### Reference patterns

- systemd status formatting: model on the existing launchd block (lines 1895-1919 in auto-update-helper.sh) — parallel structure (Scheduler / Status / Unit / PID / Last exit / Interval / Paths).
- `systemctl --user show -p NextElapse,LastTriggerUSec ${SYSTEMD_UNIT_NAME}.timer` gives machine-readable next-fire and last-fire timestamps — use them over parsing `status` output.
- Fallback when `systemctl` is absent (e.g. container w/o systemd): print "Scheduler: systemd (not available on this host)" rather than crashing.

## Acceptance criteria

- [ ] `aidevops auto-update status` on a Linux host with systemd timer enabled shows "Scheduler: systemd (user timer)", "Status: enabled" (or "running"), unit name, and next-fire time.
- [ ] `aidevops auto-update status` on a Linux host with cron entry (systemd unavailable) continues to show the existing cron output unchanged.
- [ ] `aidevops auto-update --help` SCHEDULER BACKENDS section lists all three backends (launchd / systemd / cron) with correct paths.
- [ ] `.agents/reference/auto-update.md` accurately describes all three backends and uses the correct launchd label.
- [ ] `shellcheck .agents/scripts/auto-update-helper.sh` passes.
- [ ] No regression on macOS: status output unchanged (tested by running on the audit host).

## Context

- Audit source: interactive session 2026-04-19, worktree `~/Git/aidevops-docs-t2403-linux-auto-update-audit`.
- Related code: `platform-detect.sh:35-43` (backend selection), `auto-update-helper.sh:130-149` (`_get_scheduler_backend`), `auto-update-helper.sh:1634-1691` (`_cmd_enable_systemd`).
- NOT covered here: linger (t2404), timer drift measurement (out of scope), WSL2-specific testing (best-effort, defer until a user reports).
- Tier: `tier:standard` — single 2187-line file is the primary target which disqualifies `tier:simple` per the hard disqualifier list.
