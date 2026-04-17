---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2156: Detect deployed-script drift vs canonical repo, hot-redeploy on local-merged-but-unreleased commits

## Origin

- **Created:** 2026-04-17
- **Session:** Claude Code:t2153-followup
- **Created by:** ai-interactive (marcusquinn directing)
- **Parent task:** none
- **Conversation context:** While diagnosing t2153 (stale-recovery age-floor guard), discovered that the fix was merged to `main` at 3bbe31f36 but the production pulse kept stale-recovering fresh issues for 90+ minutes. Root cause: `aidevops update` deploys scripts only when the local `VERSION` differs from the released `VERSION` on `main` — local commits merged AFTER the latest release (v3.8.63) stay invisible to the runtime until the next release/version bump. Workaround was a manual `cp` + pulse restart at 01:32 BST. This is a systemic gap that affects every script-only fix between releases.

## What

`aidevops-update-check.sh` (or a new sibling) MUST detect when the canonical repo at `~/Git/aidevops/.agents/scripts/` contains commits that have not been deployed to `~/.aidevops/agents/scripts/`, and trigger a redeploy automatically — independent of whether `VERSION` has been bumped.

Detection signal: the git SHA of the canonical repo's `HEAD` (`git -C ~/Git/aidevops rev-parse HEAD`) MUST match a recorded "deployed SHA" stamp file at `~/.aidevops/.deployed-sha`. On drift (canonical SHA ahead of deployed SHA AND any of `.agents/scripts/**`, `.agents/agents/**`, `.agents/workflows/**`, `.agents/prompts/**`, `.agents/hooks/**` differs since the deployed SHA), trigger `setup.sh --non-interactive --silent` and update the stamp.

Drift check should run on the same ~10min cadence as `aidevops-update-check.sh` (already wired via launchd). On drift detected, it MUST NOT prompt the user — silent redeploy + pulse restart, identical to how a normal `aidevops update` flow handles a remote VERSION bump.

## Why

Every framework script fix between releases is invisible to the runtime until a new release. This caused t2153 to leak stale-recovery dispatches on 5 issues (#19432, #19433, #19440, #19441, #19443) for 90+ minutes after the fix had merged — exactly the bug the fix was designed to prevent. The asymmetry: the canonical repo holds the corrected code, the runtime keeps using the broken code, the only signal to the user is "why is this still happening?". For a framework whose own pulse depends on its scripts being current, this is a self-inflicted footgun on every merge.

The release cadence cannot rescue this — releases lag merges by hours-to-days, and many merges are minor enough to not justify a release on their own. The deployment must follow the merge, not the release.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** (likely 2: `aidevops-update-check.sh` + `setup.sh` plus a regression test)
- [ ] **Every target file under 500 lines?** `aidevops-update-check.sh` is ~200 lines, `setup.sh` is ~1500
- [ ] **Exact `oldString`/`newString` for every edit?** No — needs a new function added
- [ ] **No judgment or design decisions?** No — must decide stamp file location, drift trigger threshold, restart policy
- [x] **No error handling or fallback logic to design?** Has fallback: missing stamp = treat as cold install
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** Possibly
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** New function with stamp-file management, restart policy, integration with launchd-driven update loop. `setup.sh` >500 lines disqualifies `tier:simple`. Worker needs to design the stamp file format and decide drift-trigger conditions; this is judgment work.

## PR Conventions

Leaf task, use `Resolves #NNN`.

## How (Approach)

### Files to Modify

- **EDIT:** `.agents/scripts/aidevops-update-check.sh` — add `_check_script_drift()` called from the top-level update loop after the existing VERSION check. If drift detected and no remote VERSION bump pending, trigger silent redeploy.
- **EDIT:** `setup.sh` — at the end of the deploy section (after scripts/agents/workflows/prompts copied), write the canonical-repo HEAD SHA to `~/.aidevops/.deployed-sha`. Pattern: append after the existing "Deployment complete" message (search the file for the canonical end-of-deploy marker).
- **NEW:** `.agents/scripts/tests/test-script-drift-detection.sh` — regression test using a sandbox repo + stub `~/.aidevops/.deployed-sha` to verify drift triggers redeploy and in-sync skips it. Model on `tests/test-stale-recovery-age-floor.sh` for sandbox setup pattern.
- **REFERENCE:** `~/.aidevops/agents/scripts/aidevops-update-check.sh:110-117` for the curl-based VERSION fetch pattern (similar HTTP/git-based drift check).

### Implementation Steps

1. **Stamp file format.** Single line at `~/.aidevops/.deployed-sha`: `<sha> <timestamp_iso8601>`. Read with `awk '{print $1}'`. Missing file = cold install (treat all canonical-repo files as needing deploy).

2. **Drift detection function.** In `aidevops-update-check.sh`:

   ```bash
   _check_script_drift() {
     local canonical_repo="$HOME/Git/aidevops"
     [[ ! -d "$canonical_repo/.git" ]] && return 0
     local current_sha deployed_sha
     current_sha=$(git -C "$canonical_repo" rev-parse HEAD 2>/dev/null) || return 0
     deployed_sha=$(awk '{print $1}' "$HOME/.aidevops/.deployed-sha" 2>/dev/null || echo "")
     [[ "$current_sha" == "$deployed_sha" ]] && return 0
     # Verify drift is in framework files (not just docs/tests)
     local diff_paths
     if [[ -n "$deployed_sha" ]]; then
       diff_paths=$(git -C "$canonical_repo" diff --name-only "$deployed_sha" HEAD 2>/dev/null | \
         grep -E '^\.agents/(scripts|agents|workflows|prompts|hooks)/' || true)
       [[ -z "$diff_paths" ]] && return 0
     fi
     echo "[update-check] Script drift detected: $current_sha != $deployed_sha"
     "$canonical_repo/setup.sh" --non-interactive --silent >> "$HOME/.aidevops/logs/auto-update.log" 2>&1
   }
   ```

3. **Stamp write in setup.sh.** At the end of the deploy section, after the canonical-repo files are copied:

   ```bash
   if [[ -d "$AGENTS_REPO/.git" ]]; then
     local _sha
     _sha=$(git -C "$AGENTS_REPO" rev-parse HEAD 2>/dev/null || echo "unknown")
     printf '%s %s\n' "$_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$HOME/.aidevops/.deployed-sha"
   fi
   ```

4. **Wire drift check into update loop.** In `aidevops-update-check.sh`, after the existing VERSION check returns "no update needed", call `_check_script_drift` (so released-VERSION updates take precedence).

5. **Pulse restart on redeploy.** `setup.sh` already restarts the pulse via `_restart_pulse_if_running` per `prompts/build.txt` "Pulse restart after deploying pulse script fixes". Verify this fires on `--non-interactive --silent` invocation; if it does not, add it.

### Verification

```bash
# 1. Cold install path (no stamp)
rm -f ~/.aidevops/.deployed-sha
~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive
# Expect: drift detected, setup.sh runs, stamp written, pulse restarts

# 2. In-sync path (stamp matches HEAD)
~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive
# Expect: no drift, no redeploy

# 3. Drift path (manually back-date stamp)
echo "$(git -C ~/Git/aidevops rev-parse HEAD~5) 2026-01-01T00:00:00Z" > ~/.aidevops/.deployed-sha
~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive
# Expect: drift detected, setup.sh runs, stamp updated to HEAD

# 4. Docs-only drift (should skip)
echo "$(git -C ~/Git/aidevops log -n2 --pretty=%H -- TODO.md | tail -1) 2026-01-01T00:00:00Z" > ~/.aidevops/.deployed-sha
~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive
# Expect: skip, no redeploy

# 5. ShellCheck clean
shellcheck .agents/scripts/aidevops-update-check.sh

# 6. Regression test passes
bash .agents/scripts/tests/test-script-drift-detection.sh
```

## Acceptance Criteria

- [ ] `~/.aidevops/.deployed-sha` is written by `setup.sh` after every successful deploy
- [ ] `aidevops-update-check.sh` detects SHA drift between canonical-repo HEAD and the stamp
- [ ] On drift in `.agents/scripts/**`, `.agents/agents/**`, `.agents/workflows/**`, `.agents/prompts/**`, or `.agents/hooks/**`, redeploy fires silently via `setup.sh --non-interactive --silent`
- [ ] Drift in docs-only paths (`*.md`, `todo/**`, `.github/*.md`) does NOT trigger redeploy
- [ ] Pulse restarts after silent redeploy (verify via PID change)
- [ ] ShellCheck clean for all modified scripts
- [ ] Regression test in `tests/test-script-drift-detection.sh` covers cold-install, in-sync, drift-framework, drift-docs-only branches

## Context

- **Stored memory:** `mem_20260417013733_b01f4440` — full diagnosis of the deployment gap
- **Triggering incident:** PR #19429 (3bbe31f36, t2153) merged at 00:09Z, ran undeployed for 83 minutes, manual `cp` workaround at 01:32 BST.
- **Affected issues during gap:** #19432, #19433, #19440, #19441, #19443 — all hit by buggy stale-recovery the fix was designed to prevent.
- **Related fix t2148** (interactive-session-helper.sh scan-stale) — addresses the symptom (zombie claims) but not the deployment root cause.
- **AGENTS.md** ("Pulse restart after deploying pulse script fixes (MANDATORY)") already documents the manual `pkill + nohup` workaround for ad-hoc fixes; this task makes the automation match the documented manual procedure.
