# t2398: feat(deploy): post-release hot-deploy trigger for framework-critical script fixes

## Session origin

- Date: 2026-04-19
- Context: Diagnostic session. t2392 (OAuth model-availability fix) merged at 18:13 UTC today, bumped to v3.8.78, but remote runner (`alex-solovyev`) is still running pre-t2392 code because `aidevops update` is rate-limited to ~24h auto-check cycles and only pulls released versions. Between merge and next update-check, remote runner continues fast-failing every dispatch cycle.
- Sibling tasks: t2394 (CLAIM_VOID), t2395 (maintainer-gate exemption), t2396 (reassign normalization), t2397 (HARD STOP age-out).

## What

Add a `--hotfix` flag to `version-manager.sh release` that signals "this release should propagate to remote runners immediately, not on their next scheduled update-check". Remote runners poll a well-known endpoint (or issue comment / repo tag) for hotfix signals and pull + restart when one is published. Gated by a user-land opt-in per machine (`~/.config/aidevops/auto-hotfix.conf` with default off) for safety.

## Why

**Root cause confirmed in production 2026-04-19.** `model-availability-helper.sh` pre-t2392 was treating OAuth access tokens as `x-api-key`, causing every dispatch to HTTP 401 → "No available model for tier" → worker exits in <1 min. t2392 merged at 18:13 UTC and bumped release to v3.8.78. The local runner (`marcusquinn`) picked up the fix immediately (via manual `setup.sh --non-interactive`). The remote runner (`alex-solovyev`) is still on pre-t2392 code hours later and continues to fast-fail every dispatch — poisoning cross-runner coordination (see t2394 for the amplifier fix).

**Memory lesson (2026-04-17T03:57:35Z):** "aidevops update only pulls from RELEASED versions. When a fix merges to main but version-manager.sh release isn't run, remote pulse runners continue running OLD code indefinitely. ... Deployment gap from setup.sh --non-interactive is faster than aidevops update for the local runner since it doesn't require a release tag."

**Structural gap:** the framework has:
- Rate-limited auto-update (good default for most changes, but slow for hotfixes)
- Manual `aidevops update` (good for explicit operator control, but requires the operator to notice the need)

It lacks:
- A maintainer-signalled fast path for "pull this specific release immediately, bypass rate limit"

## How

### Files to modify

- **EDIT**: `.agents/scripts/version-manager.sh` — add `--hotfix` flag to the `release` subcommand.
  - When set, the release also writes a `HOTFIX` marker file (e.g., `~/.aidevops/HOTFIX_AVAILABLE`) and emits a `hotfix-v{version}` tag to the origin repo.
  - Release commit message body includes `hotfix:critical` marker.

- **EDIT**: `.agents/scripts/aidevops-update-check.sh` — add a hotfix-check path that runs on a shorter interval (e.g., 5 minutes instead of 24 hours) regardless of the regular rate-limit timer.
  - Poll the origin `hotfix-v*` tags via `gh api repos/{slug}/tags`; if the newest tag is newer than the deployed version AND the user has `auto_hotfix_accept=true` in their config, run `aidevops update` immediately.
  - If `auto_hotfix_accept` is unset/false, emit a session greeting banner: `⚠ Hotfix available: v{version} ({release_notes}). Run 'aidevops update' to apply.`

- **NEW**: `~/.aidevops/configs/auto-hotfix.conf` template with documented defaults:
  ```
  # Accept critical hotfixes automatically? (default: false — manual confirm required)
  auto_hotfix_accept=false
  # Restart pulse automatically after hotfix? (default: true when auto_hotfix_accept=true)
  auto_hotfix_restart_pulse=true
  ```

- **EDIT**: `setup.sh` — when running as part of a hotfix-triggered update, also restart the pulse via `pkill -f 'pulse-wrapper.sh' && nohup pulse-wrapper.sh >>$LOG 2>&1 &`. Otherwise the deployed scripts don't take effect until the next pulse restart (existing rule in the framework build prompt).

- **NEW**: `.agents/reference/hot-deploy.md` — documents the mechanism, when to use it, the opt-in/opt-out flow, and what constitutes "hotfix-worthy" (OAuth auth regressions, security fixes, core-loop regressions).

### Reference pattern

- Existing auto-update flow in `aidevops-update-check.sh` — keep the polling and update-orchestration shape, add a higher-priority channel.
- Pulse restart pattern: `prompts/build.txt` → "Pulse restart after deploying pulse script fixes" already documents the `pkill` + `nohup` invocation. Reuse it.
- Tag-based signal: use `hotfix-v{version}` alongside the normal `v{version}` release tag so the two channels are independent.

### Safety constraints

- Hotfix flag can only be applied by maintainers (enforce in `version-manager.sh` — check `git config user.email` matches the repo's declared maintainer list, OR check that the current user is the repo OWNER via `gh api user`).
- Runners MUST default to "warn, don't auto-apply" — auto-apply requires explicit opt-in per-machine.
- Hotfix releases bump patch version (never major/minor), so SemVer rules remain intact.

## Acceptance criteria

1. `version-manager.sh release patch --hotfix` creates v{X+1}, pushes `hotfix-v{X+1}` tag alongside `v{X+1}`.
2. Runners with `auto_hotfix_accept=true` poll for the hotfix tag every 5 minutes and apply it automatically within 10 minutes of publication.
3. Runners with `auto_hotfix_accept=false` (default) see a session-greeting banner noting the hotfix is available.
4. Non-maintainer users attempting `release patch --hotfix` are rejected with `ERROR: hotfix release requires maintainer identity`.
5. After a hotfix applies, the pulse is automatically restarted (when `auto_hotfix_restart_pulse=true`).
6. Full regression: a normal `release patch` (no `--hotfix`) behaves exactly as before — no hotfix tag, no accelerated polling.
7. `shellcheck` passes on all modified scripts.

## Verification

```bash
# Regression test (local, dry-run)
.agents/scripts/tests/test-hot-deploy-flow.sh  # new test

# Manual
.agents/scripts/version-manager.sh release patch --hotfix --dry-run  # should show plan, not execute
# After real hotfix push, verify remote runner picks up within 10 min
ssh <remote-runner> 'cat ~/.aidevops/agents/VERSION'

# Banner test
AIDEVOPS_FORCE_HOTFIX_BANNER=1 .agents/scripts/aidevops-update-check.sh --interactive
```

## Context

- Workaround today: `version-manager.sh release patch` (triggers normal release; all runners pick up on next rate-limited auto-update, ~10 min to 24h lag depending on timing).
- This task complements t2394 (CLAIM_VOID) — together they cover both "cross-runner runner-level poisoning" (t2394) and "cross-runner version-skew" (this task).
- Priority: LOW — t2394 handles the immediate symptom (degraded runner doesn't block the healthy fleet). This task fixes the upstream "degraded runner persistence" problem. Ship t2394 first.
