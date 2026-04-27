<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2898: aidevops update + setup.sh — verify auto-update daemon is enabled and warn if not

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `launchd auto-update enable health check` → 0 hits. `pulse version check auto-update` → 0 hits. No prior art on daemon-health verification at update or setup time.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch the daemon-enable verification path in last 60 days. `auto-update-helper.sh` last meaningfully changed in `t2398: post-release hot-deploy trigger` and `t2706: deployed-SHA drift detection`.
- [x] File refs verified: `aidevops.sh`, `setup.sh`, `auto-update-helper.sh`, the launchd plist template (search `setup-modules/` for the install path) all present at HEAD.
- [x] Tier: `tier:standard` — narrative brief with file references, well-defined surface (idempotent install + a status check), no novel state machine.

## Origin

- **Created:** 2026-04-26
- **Session:** OpenCode (interactive)
- **Created by:** marcusquinn (human, AI-assisted refinement)
- **Parent task:** none (peer of t2897)
- **Conversation context:** Maintainer noted that the existing session-greeting advisory only catches users in interactive sessions — but the user with a broken auto-update daemon is exactly the user who isn't running interactively. The verification has to fire on paths that run regardless of interactive presence: `setup.sh` (run on every release deploy via the daemon itself, when it works) and `aidevops update` (called by the daemon and by interactive users). Making `setup.sh` idempotently re-install the daemon means every release that lands self-heals the daemon if broken.

## What

Three small, composable additions:

1. **A new `auto-update-helper.sh health-check` subcommand** that returns 0 (healthy), 1 (loaded but stalled — last successful run > 2× expected interval), or 2 (not installed / not loaded). Outputs a human-readable status line and a remediation command.

2. **`setup.sh` end-of-run idempotent re-install of the auto-update daemon.** After agents are deployed, call `auto-update-helper.sh enable --idempotent` (new flag — currently `enable` errors if already enabled) so every release that lands fixes its own daemon if the launchd unit was unloaded, the cron entry was scrubbed, or the systemd unit drifted. Also surface the health-check result; if `health-check` returns 1 or 2 after the install attempt, log a clear warning with the fix command.

3. **`aidevops update` warns if the daemon is unhealthy after the update completes.** When invoked interactively (not from the daemon itself — detect via `AIDEVOPS_AUTO_UPDATE=1` or similar process-env signal), call `health-check` and print a yellow warning if non-zero, with the remediation command. Also write a `daemon-disabled` advisory to `~/.aidevops/advisories/` so the session greeting picks it up if/when the user is interactive.

The combined effect: every release self-heals the daemon. Even a runner that was installed without the daemon (or had it removed) gets it re-installed automatically the next time `setup.sh` runs — which is every release when the daemon IS working. For a runner where the daemon was never enabled, the user just has to run `aidevops update` once to bootstrap the loop.

## Why

The existing session-greeting advisory has an asymmetry: the user with the broken daemon is by definition the user who isn't seeing greetings. They run `pulse-wrapper.sh` from launchd; their interactive sessions are on a different machine or they're a headless contributor. The advisory machinery doesn't reach them.

The fix is to put the verification on paths that run in both modes: `setup.sh` (runs during every release deploy) and `aidevops update` (runs every 10 minutes from the daemon, when it works). When the daemon is healthy, every release re-verifies it. When it's broken, the next manual `aidevops update` re-enables it. The path that doesn't break naturally heals the path that did.

This is the cheap, high-leverage fix that catches the most common case (daemon was never installed / was unloaded by an OS update / was scrubbed by a cron cleanup) without requiring per-runner failure tracking.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? — borderline (4 files: aidevops.sh, setup.sh, auto-update-helper.sh, tests). Treating as more than 2.
- [ ] Every target file under 500 lines? — `auto-update-helper.sh` is 1418 lines.
- [ ] Exact `oldString`/`newString` for every edit? — no, edits are described.
- [x] No judgment or design decisions? — yes; subcommand surface and integration points are specified.
- [x] No error handling or fallback logic to design? — yes; `health-check` exit codes are specified.
- [x] No cross-package or cross-module changes? — yes.
- [x] Estimate 1h or less? — borderline (~1.5h with tests).
- [x] 4 or fewer acceptance criteria? — yes (4 below).
- [ ] Dispatch-path classification (t2821): `auto-update-helper.sh`, `setup.sh`, `aidevops.sh` are NOT in `.agents/configs/self-hosting-files.conf`. Auto-dispatch is appropriate.

**Selected tier:** `tier:standard`

**Tier rationale:** Two unchecked items (file size, oldString/newString) push it above tier:simple. The work is well-scoped — new subcommand, idempotent flag on existing subcommand, integration points specified — but `auto-update-helper.sh` is a 1418-line file that requires Sonnet-level navigation. No design judgment beyond the spec.

## PR Conventions

Leaf task. PR body uses `Resolves #NNN` linking to the GitHub issue created from this brief.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/auto-update-helper.sh` — add `health-check` subcommand and `--idempotent` flag on `enable`. The script is 1418 lines; the additions go in the subcommand dispatch block (search for the existing `case` handling `enable|disable|status|check|logs|help`) and a new function `_cmd_health_check` near the existing `_cmd_check_stale_agent_redeploy`.
- `EDIT: setup.sh` (or relevant `setup-modules/*.sh`) — at end of run, call `auto-update-helper.sh enable --idempotent` then `auto-update-helper.sh health-check`. Log the outcome. Find the integration point by searching for the existing agent-deploy completion path (likely `setup-modules/agent-deploy.sh` based on the t2706 commit message referencing `setup-modules/agent-deploy.sh on every successful deploy`).
- `EDIT: aidevops.sh` — find the `update` subcommand handler. After the update completes, if invoked interactively (heuristic: `[[ -t 0 ]] && [[ -z "${AIDEVOPS_AUTO_UPDATE:-}" ]]`), call `auto-update-helper.sh health-check` and print a yellow warning + remediation command on non-zero exit.
- `NEW: .agents/scripts/tests/test-auto-update-health-check.sh` — unit tests for the new subcommand: not-installed case, installed-but-stalled case, healthy case, idempotent enable.

### Implementation Steps

**1. Add `health-check` subcommand to `auto-update-helper.sh`.** Detection logic varies by platform:

```bash
_cmd_health_check() {
    local platform unit_loaded last_run_ts now_ts age_sec interval_sec interval_minutes

    platform=$(uname -s)
    unit_loaded=0
    last_run_ts=""

    case "$platform" in
        Darwin)
            # launchctl list returns the unit if loaded; non-zero exit if not.
            if launchctl list 2>/dev/null | grep -q "com.aidevops.aidevops-auto-update"; then
                unit_loaded=1
            fi
            ;;
        Linux)
            # Try systemd user unit first, then cron.
            if systemctl --user is-active --quiet aidevops-auto-update.timer 2>/dev/null; then
                unit_loaded=1
            elif crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
                unit_loaded=1
            fi
            ;;
    esac

    if [[ $unit_loaded -eq 0 ]]; then
        printf "auto-update daemon: NOT INSTALLED\n" >&2
        printf "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh enable\n" >&2
        return 2
    fi

    # Loaded — check freshness via state file.
    if [[ -f "$STATE_FILE" ]]; then
        last_run_ts=$(jq -r '.last_run // empty' "$STATE_FILE" 2>/dev/null || echo "")
    fi

    if [[ -z "$last_run_ts" ]]; then
        # Loaded but never ran — could be a fresh install. Treat as healthy with a soft warning.
        printf "auto-update daemon: LOADED (never run yet)\n" >&2
        return 0
    fi

    # Convert ISO-8601 to epoch (handles both GNU and BSD date).
    now_ts=$(date -u '+%s')
    if last_run_epoch=$(date -u -d "$last_run_ts" '+%s' 2>/dev/null) ||
       last_run_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_run_ts" '+%s' 2>/dev/null); then
        age_sec=$((now_ts - last_run_epoch))
    else
        printf "auto-update daemon: LOADED (state file unparseable)\n" >&2
        return 1
    fi

    # Use local with default so the function is self-contained regardless of caller scope.
    interval_minutes=${INTERVAL_MINUTES:-10}
    interval_sec=$((interval_minutes * 60))
    if (( age_sec > 2 * interval_sec )); then
        printf "auto-update daemon: STALLED (last run %ds ago, expected every %ds)\n" "$age_sec" "$interval_sec" >&2
        printf "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh check\n" >&2
        return 1
    fi

    printf "auto-update daemon: HEALTHY (last run %ds ago)\n" "$age_sec" >&2
    return 0
}
```

The `STATE_FILE` is already populated by the daemon's per-run logic — verify by reading the existing state-file write path in `auto-update-helper.sh` and confirm the `last_run` key exists or add it if not.

**2. Add `--idempotent` flag to existing `enable` subcommand.** The existing `enable` should error if already enabled (current behaviour should be confirmed during implementation by reading `_cmd_enable`). Add a flag that suppresses the error and exits 0 if already loaded:

```bash
_cmd_enable() {
    local idempotent=0
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --idempotent) idempotent=1; shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]}"

    if [[ $idempotent -eq 1 ]]; then
        local health_status
        _cmd_health_check >/dev/null 2>&1
        health_status=$?
        # Exit 0 = healthy; exit 1 = stalled but still loaded.
        # Both mean the unit is already loaded — skip re-enable to avoid
        # launchctl/systemctl errors from double-loading.
        if [[ $health_status -eq 0 || $health_status -eq 1 ]]; then
            log_info "auto-update daemon already enabled (idempotent — no-op)"
            return 0
        fi
    fi

    # ... existing enable logic ...
}
```

**3. Hook into `setup.sh` end-of-run.** Find the post-deploy completion path (likely `setup-modules/agent-deploy.sh` based on t2706 history). After the deployed-SHA stamp is written, call:

```bash
log_info "Verifying auto-update daemon..."
if "$HOME/.aidevops/agents/scripts/auto-update-helper.sh" enable --idempotent; then
    if "$HOME/.aidevops/agents/scripts/auto-update-helper.sh" health-check; then
        log_ok "auto-update daemon is healthy"
    else
        log_warn "auto-update daemon installed but unhealthy — run: auto-update-helper.sh check"
    fi
else
    log_warn "Failed to enable auto-update daemon — manual fix: auto-update-helper.sh enable"
fi
```

**4. Hook into `aidevops.sh update` subcommand.** After update completes, if interactive:

```bash
if [[ -t 0 ]] && [[ -z "${AIDEVOPS_AUTO_UPDATE:-}" ]]; then
    if ! "$HOME/.aidevops/agents/scripts/auto-update-helper.sh" health-check; then
        printf "\n\033[33mwarning:\033[0m auto-update daemon is not running. Run: auto-update-helper.sh enable\n" >&2
        # Drop a session-greeting advisory.
        mkdir -p "$HOME/.aidevops/advisories"
        cat >"$HOME/.aidevops/advisories/daemon-disabled.advisory" <<EOF
auto-update daemon is not running. Without it, this runner falls behind the
fleet and may dispatch workers that fail because of bugs already fixed
upstream. Fix: ~/.aidevops/agents/scripts/auto-update-helper.sh enable
EOF
    fi
fi
```

**5. Tests.** `tests/test-auto-update-health-check.sh` mocks `launchctl` and `STATE_FILE` to simulate the four cases (not installed, installed never run, installed stalled, installed healthy) and asserts exit code + stderr message. Idempotent enable test asserts second call exits 0 with no error.

### Complexity Impact

- **Target function:** `_cmd_enable` (new branch via `--idempotent`), new `_cmd_health_check` function, and dispatch-block extension.
- **Estimated growth:** +60-80 lines in `auto-update-helper.sh` (currently 1418 lines, file-size threshold is 1500). Pushes the file uncomfortably close to the file-size gate.
- **Action required:** **Watch.** If post-change line count is between 1450-1500, ship as-is and file a follow-up split. If projected over 1500, extract the platform-specific health-check logic into a sub-library (`auto-update-health-lib.sh`) following the t2706 freshness-lib pattern (`auto-update-freshness-lib.sh` already exists at `.agents/scripts/auto-update-freshness-lib.sh:439`).

### Verification

```bash
# Unit tests
.agents/scripts/tests/test-auto-update-health-check.sh

# Manual smoke test
~/.aidevops/agents/scripts/auto-update-helper.sh health-check && echo "healthy"
~/.aidevops/agents/scripts/auto-update-helper.sh enable --idempotent
~/.aidevops/agents/scripts/auto-update-helper.sh enable --idempotent  # second call should no-op cleanly

# Verify aidevops update warns when daemon disabled (manual):
launchctl unload ~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist
aidevops update                                # should print yellow warning + advisory file
ls ~/.aidevops/advisories/daemon-disabled.advisory  # should exist
launchctl load ~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist
aidevops update                                # advisory should be cleared

# Lint
shellcheck .agents/scripts/auto-update-helper.sh
shellcheck .agents/scripts/tests/test-auto-update-health-check.sh
```

### Files Scope

- `.agents/scripts/auto-update-helper.sh`
- `.agents/scripts/tests/test-auto-update-health-check.sh`
- `setup.sh`
- `setup-modules/agent-deploy.sh`
- `aidevops.sh`
- `todo/tasks/t2898-brief.md`
- `TODO.md`

## Acceptance Criteria

- [ ] `auto-update-helper.sh health-check` exists and returns 0 / 1 / 2 per the spec, with human-readable stderr output on each path.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/auto-update-helper.sh health-check; rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 2 ]]"
  ```

- [ ] `auto-update-helper.sh enable --idempotent` is a no-op when daemon is already loaded; first call enables when not loaded.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/tests/test-auto-update-health-check.sh"
  ```

- [ ] Running `setup.sh --non-interactive` on a host with the daemon unloaded re-loads it. Verified by `launchctl list` (macOS) or `systemctl --user is-active` (Linux) before vs after.
- [ ] Running `aidevops update` interactively when the daemon is unhealthy prints a yellow warning AND writes `~/.aidevops/advisories/daemon-disabled.advisory`. The advisory is removed (or rewritten as cleared) on the next update where the daemon is healthy.

## Context & Decisions

- **Verification on `setup.sh` is the leverage point.** Every release-driven deploy passes through it. If we re-verify there, every release self-heals the daemon. Verifying only at session-greeting-time misses the asymmetry where the broken-daemon user isn't interactive.
- **Idempotent enable, not "force re-install".** Force re-install would scrub user customisations (custom intervals, custom env vars). Idempotent means "ensure loaded, no-op if already loaded" — preserves user state.
- **Detection is platform-specific by necessity.** macOS uses `launchctl list`; Linux can be either systemd-user or cron. The current `auto-update-helper.sh` already handles both install paths, so the health check just mirrors them.
- **State-file freshness as the "stalled" signal.** A loaded launchd unit can fail silently (e.g., the script's first line errors out before logging). The state file's `last_run` timestamp is the ground truth — if it's stale, the daemon is not actually running even if loaded.
- **Advisory dedup.** Writing `~/.aidevops/advisories/daemon-disabled.advisory` is idempotent (overwrite). The session greeting reads it once per session start. No need for explicit dedup.
- **Why two flags and not just `enable` always idempotent.** Existing callers may rely on the error behaviour for diagnostics. Adding `--idempotent` is non-breaking; making `enable` always idempotent could mask install bugs.

## Relevant Files

- `.agents/scripts/auto-update-helper.sh:430-509` — `_cmd_check_stale_agent_redeploy` for the stale-detection conventions and platform-aware patterns.
- `.agents/scripts/auto-update-freshness-lib.sh` — sub-library extraction pattern (already in place since the file approached 1418 lines).
- `setup-modules/agent-deploy.sh` — where the deployed-SHA stamp is written (per t2706 commit message); likely the right hook point for the post-deploy verification.
- `.agents/reference/cross-runner-coordination.md:268-292` — §4.4 "Token Cost Runaway" documents version-skew as the cause of repeat alex-solovyev failures. Reference for the rationale.
- Companion task: `todo/tasks/t2897-brief.md` — the runner-side circuit breaker. Together they close the gap.

## Dependencies

- **Blocked by:** none.
- **Blocks:** none directly; t2897 benefits from this landing first because the breaker's `aidevops update` call is more useful when the daemon-install path is self-healing. But neither blocks the other strictly.
- **External:** none.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | auto-update-helper.sh dispatch block, setup-modules/agent-deploy.sh end-of-run, aidevops.sh update subcommand. |
| Implementation | 1h | New subcommand (~70 lines), idempotent flag (~15 lines), two integration points (~10 lines each). |
| Testing | 30m | Mock launchctl + state file; four exit-code paths. |
| **Total** | **~2h** | Tier:standard. |
