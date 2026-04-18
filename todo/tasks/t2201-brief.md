<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2201: pulse PATH override puts /bin before /opt/homebrew/bin, bypasses re-exec guard via AIDEVOPS_BASH_REEXECED env leak

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** Diagnosing why workers weren't picking up interactive-origin issues. Root cause was the aidevops repo hitting the 200-worktree cap (fixed by cleaning 80 merged worktrees). While investigating, observed `pre-dispatch-validator-helper.sh: line 55: declare: -A: invalid option` in every pulse cycle's dispatch of aidevops issues (152+ occurrences in current pulse.log). Surface symptom looks like t2176/GH#19632 ("bash re-exec guard not firing"), but the t2176 fix already merged at 06:43Z. Fresh investigation shows the t2176 fix is correct; the failure mode has now moved one level deeper.

## What

Pulse subprocess chain under the running pulse (PID 59131, `/opt/homebrew/bin/bash` 5.3.9) still spawns children that run under `/bin/bash` 3.2, and the re-exec guard fails to fire in those children because `AIDEVOPS_BASH_REEXECED=1` has leaked into their environment from an earlier successful re-exec elsewhere in the chain.

After this task:

1. `pulse-wrapper.sh:74` and the other 9 scripts that prepend `/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin` to PATH re-order the explicit prefixes so modern bash (`/opt/homebrew/bin`, `/usr/local/bin`, `/home/linuxbrew/.linuxbrew/bin`) wins over `/bin`. `env bash` resolves to modern bash directly; bash 3.2 subprocesses are never spawned through the shebang path.
2. `shared-constants.sh` re-exec guard unsets `AIDEVOPS_BASH_REEXECED` after the guard block completes, so grandchild processes don't inherit a stale "already re-exec'd" flag from a successful parent re-exec.
3. A regression test asserts: with `AIDEVOPS_BASH_REEXECED=1` pre-set in the environment and a bash-3.2 subprocess that sources `shared-constants.sh`, the **child** still sets things up so its own children restart the guard cycle. (Cannot demand the inherited child itself re-execs without breaking the anti-infinite-loop property; the unset-on-exit provides the separation for grandchildren.)
4. `pre-dispatch-validator-helper.sh: line 55: declare: -A: invalid option` stops appearing in `~/.aidevops/logs/pulse.log` during normal pulse cycles.

## Why

- **Pulse hygiene.** 152+ `declare: -A: invalid option` errors in the current `pulse.log` is not just log noise: each one is a failed pre-dispatch-validator invocation, which means every auto-generated aidevops issue (ratchet-down generators, etc.) is dispatched without the validator's premise check. The GH#19118 safety net is silently degraded.
- **Blast radius.** The PATH bug is copy-pasted into 10 scripts. Every one of them may spawn bash-3.2 subprocesses whose `#!/usr/bin/env bash` scripts THEN rely on the re-exec guard. The env-var leak makes the guard fail in the subset of those that happen to follow a successful earlier re-exec in the same process tree. We don't actually know how many scripts are silently running on bash 3.2 right now.
- **t2176 was correct, incomplete.** The t2176 fix (walk BASH_SOURCE stack, update plist to `/opt/homebrew/bin/bash`) resolved the original symptom (pulse main process on bash 3.2). Post-fix, the pulse is bash 5, memory-pressure-monitor runs clean. But the bug has moved to the subprocess layer. Two new root causes surface: (a) PATH is overridden to put `/bin` first AFTER the plist sets a good PATH, and (b) `AIDEVOPS_BASH_REEXECED` is exported before `exec` and never cleared, so it leaks across the re-exec'd process's children.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — 10 shell scripts with the same 1-line PATH pattern, plus shared-constants.sh, plus a new test. The edits are mechanically identical across the 10 scripts (the same `oldString`/`newString`).
- [x] **Every target file under 500 lines?** — The guard block in shared-constants.sh is ~30 lines; each of the 10 scripts has the PATH line near the top; new test <200 lines.
- [x] **Exact `oldString`/`newString` for every edit?** — Yes. The 10 scripts all contain the literal `export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"`. shared-constants.sh edit adds one `unset AIDEVOPS_BASH_REEXECED` line in a known location.
- [x] **No judgment or design decisions?** — No. The diagnosis is done, the fix is mechanical.
- [x] **No error handling or fallback logic to design?**
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?**
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:standard`

**Tier rationale:** The diagnosis is complete and documented here; the fix is mechanical (PATH reorder + one-line guard cleanup + regression test). A standard-tier worker can execute this without novel reasoning. Not tier:simple only because 10 files get touched and we want the worker to verify each one actually contains the literal string before editing (not all scripts use the identical pattern — the brief lists them explicitly).

## PR Conventions

Leaf task — use `Resolves #NNN` when the GitHub issue is created.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Confirm the symptom still reproduces
/opt/homebrew/bin/bash -c 'export AIDEVOPS_BASH_REEXECED=1; /bin/bash ~/.aidevops/agents/scripts/pre-dispatch-validator-helper.sh help'
# Expect: line 55: declare: -A: invalid option — the guard-bypass path

# 2. Confirm the PATH ordering is wrong
grep -n 'export PATH="/bin:' ~/.aidevops/agents/scripts/*.sh
# Expect: 10 matches

# 3. Confirm fix logic works
/opt/homebrew/bin/bash -c 'unset AIDEVOPS_BASH_REEXECED; /bin/bash ~/.aidevops/agents/scripts/pre-dispatch-validator-helper.sh help'
# Expect: clean Usage: output (no declare error)
```

### Files to Modify

Ten scripts all have the literal string `export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"`. Replace each with `export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"`:

- `EDIT: .agents/scripts/pulse-wrapper.sh:74`
- `EDIT: .agents/scripts/contribution-watch-helper.sh:36`
- `EDIT: .agents/scripts/routine-log-helper.sh:21`
- `EDIT: .agents/scripts/draft-response-helper.sh:45`
- `EDIT: .agents/scripts/efficiency-analysis-runner.sh:33`
- `EDIT: .agents/scripts/pulse-session-helper.sh:23`
- `EDIT: .agents/scripts/stats-wrapper.sh:19`
- `EDIT: .agents/scripts/foss-handlers/wordpress-plugin.sh:50`
- `EDIT: .agents/scripts/foss-handlers/macos-app.sh:23`
- `EDIT: .agents/scripts/foss-handlers/generic.sh:21`

Plus:

- `EDIT: .agents/scripts/shared-constants.sh` — after the re-exec guard `if` block closes (around line 80), add `unset AIDEVOPS_BASH_REEXECED` guarded by `[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]`. This clears the flag only when we're stably on modern bash (never on the fallthrough branch where no modern bash was found, to avoid a theoretical infinite re-exec loop on a broken install).
- `EDIT: .agents/scripts/tests/test-bash-reexec-guard.sh` — add a test case that pre-sets `AIDEVOPS_BASH_REEXECED=1` in the environment, spawns a `/bin/bash` child that sources shared-constants.sh, then spawns a GRANDCHILD that sources shared-constants.sh; assert the grandchild ends up on bash 4+.

### Implementation Steps

1. **Reorder PATH in all 10 scripts.** Use a single sed or ten Edit calls. The exact `newString` is `export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"`. Preserve the inline comment context. Verify each script still has the line (no duplication, no accidental deletion) with `grep -c 'export PATH=' <file>` = 1.
2. **Clear AIDEVOPS_BASH_REEXECED in shared-constants.sh after guard block.** Add one line after the `fi` that closes the re-exec-guard `if` block at ~line 78: `[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] && unset AIDEVOPS_BASH_REEXECED`. Comment briefly: `# t2201: clear flag on success so grandchildren start fresh`.
3. **Extend the test.** Add a new test case (and bump the PASS count in the final summary) that:
   - Exports `AIDEVOPS_BASH_REEXECED=1`
   - Spawns a bash-3.2 child that sources shared-constants.sh via a `source` line inside a helper script
   - Checks that either (a) the child itself is running under bash 4+ after the source, OR (b) a grandchild that sources shared-constants.sh again ends up on bash 4+
   - The (b) case is the defence-in-depth property introduced by step 2.
4. **Deploy and verify.** Run `setup.sh --non-interactive` in the canonical repo, restart the pulse via `launchctl kickstart -k gui/$(id -u)/com.aidevops.aidevops-supervisor-pulse`, wait one pulse cycle (2-3 minutes), then grep for `declare: -A: invalid option` in `pulse.log` from post-deploy timestamps. Expect zero matches.
5. **Shellcheck the modified scripts** to ensure no regressions.

### Verification

```bash
# 1. All ten PATH lines now start with /opt/homebrew/bin
grep -c 'export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:' .agents/scripts/*.sh .agents/scripts/foss-handlers/*.sh
# Expect: 10

# 2. No script still has the bad ordering
grep -l 'export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:' .agents/scripts/ .agents/scripts/foss-handlers/ 2>/dev/null || echo "none"
# Expect: "none"

# 3. Regression test passes
bash .agents/scripts/tests/test-bash-reexec-guard.sh
# Expect: all tests pass, including the new AIDEVOPS_BASH_REEXECED leak test

# 4. Direct reproduction fails cleanly
/opt/homebrew/bin/bash -c 'export AIDEVOPS_BASH_REEXECED=1; /bin/bash ~/.aidevops/agents/scripts/pre-dispatch-validator-helper.sh help 2>&1 | grep -q "declare: -A"' && echo FAIL || echo PASS
# Expect: PASS (no declare error after deploy)

# 5. No bad substitution or declare errors in a fresh pulse cycle
# (Run post-deploy, after `launchctl kickstart -k gui/$(id -u)/com.aidevops.aidevops-supervisor-pulse` and waiting 3 minutes)
grep -c 'declare: -A: invalid option' ~/.aidevops/logs/pulse.log
# Compare to pre-deploy count; should stop incrementing for the new cycle.

# 6. Shellcheck clean
shellcheck .agents/scripts/shared-constants.sh .agents/scripts/pulse-wrapper.sh .agents/scripts/tests/test-bash-reexec-guard.sh
```

## Acceptance Criteria

- [ ] All 10 scripts with the PATH prefix pattern now put `/opt/homebrew/bin` first.

  ```yaml
  verify:
    method: bash
    run: "test $(grep -l 'export PATH=\"/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:' .agents/scripts/*.sh .agents/scripts/foss-handlers/*.sh 2>/dev/null | wc -l | tr -d ' ') -eq 0"
  ```

- [ ] `shared-constants.sh` unsets `AIDEVOPS_BASH_REEXECED` after the guard block when running on bash 4+.

  ```yaml
  verify:
    method: bash
    run: "/opt/homebrew/bin/bash -c 'source .agents/scripts/shared-constants.sh; [[ -z \"${AIDEVOPS_BASH_REEXECED:-}\" ]]'"
  ```

- [ ] Realistic post-fix reproduction: a bash 4+ parent that sources shared-constants.sh then spawns `/bin/bash` grandchild does NOT produce `declare: -A: invalid option` — because the parent cleared the flag, the grandchild's guard fires cleanly and re-execs under modern bash.

  ```yaml
  verify:
    method: bash
    run: "/opt/homebrew/bin/bash -c 'source .agents/scripts/shared-constants.sh; /bin/bash .agents/scripts/pre-dispatch-validator-helper.sh help 2>&1' | grep -q 'declare: -A' && exit 1 || exit 0"
  ```

  **Not applicable: "manually pre-set flag → /bin/bash <script>" scenario.** Pre-setting `AIDEVOPS_BASH_REEXECED=1` manually and invoking `/bin/bash <script>` directly triggers the guard's anti-infinite-loop short-circuit by design (it protects against the case where a modern-bash candidate path is itself a broken bash-3.2 symlink). The t2201 fix addresses the upstream *env-var leak* from a successful bash-4 ancestor to its `/bin/bash` grandchildren; it does not (and cannot, without reintroducing loop risk) change the guard's behaviour when a caller explicitly sets the flag.

- [ ] Regression test `test-bash-reexec-guard.sh` includes a case for `AIDEVOPS_BASH_REEXECED` env-var leakage and passes it.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-bash-reexec-guard.sh 2>&1 | grep -q 'env-var leak'"
  ```

## Context & Decisions

- **Why not just always unset `AIDEVOPS_BASH_REEXECED` at the top of shared-constants.sh?** Because in the normal successful path (`exec` under modern bash), the re-exec'd process HAS the flag set — and that's correct for its own guard (it's bash 4+, guard doesn't fire). Unsetting at the top would be fine for the modern-bash case but would eliminate the "we successfully re-exec'd once" signal that helps debug infinite-loop scenarios. Unsetting AFTER the guard block, conditional on `BASH_VERSINFO[0] >= 4`, is the minimal fix.
- **Why not just remove the PATH override entirely?** The comment at pulse-wrapper.sh:68-73 says the MCP shell environment may ship a minimal PATH. We keep the normalisation but reorder it. The new order still guarantees `/bin` and `/usr/bin` are present (preserving the original intent) while ensuring modern bash wins for shebang resolution.
- **Why ten scripts copy-pasted the same bug?** Probably drift from an early version of pulse-wrapper.sh. A follow-up would be to extract this PATH normalisation into a shared function (maybe in shared-constants.sh itself, after the guard), but that's out of scope for this hotfix. File a separate task if you want to DRY it up.
- **Non-goals:** this task does NOT try to fix cases where scripts are invoked via explicit `/bin/bash <script>` (like `pulse-wrapper.sh:1558-1560` which hard-codes `/bin/bash issue-sync-helper.sh`). Those bypass both PATH and the shebang. If the re-exec guard still works correctly in those cases (it does, after t2176), no new bug exists. If not, a follow-up task can address them.

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:74` — primary offender (running pulse).
- `.agents/scripts/shared-constants.sh:47-78` — re-exec guard to extend with post-block cleanup.
- `.agents/scripts/tests/test-bash-reexec-guard.sh` — existing test suite to extend.
- `.agents/scripts/contribution-watch-helper.sh:36`
- `.agents/scripts/routine-log-helper.sh:21`
- `.agents/scripts/draft-response-helper.sh:45`
- `.agents/scripts/efficiency-analysis-runner.sh:33`
- `.agents/scripts/pulse-session-helper.sh:23`
- `.agents/scripts/stats-wrapper.sh:19`
- `.agents/scripts/foss-handlers/wordpress-plugin.sh:50`
- `.agents/scripts/foss-handlers/macos-app.sh:23`
- `.agents/scripts/foss-handlers/generic.sh:21`
- `reference/bash-compat.md` — prior art from t2087/t2176; update if the PATH-ordering rule warrants a section.

## Dependencies

- **Blocked by:** none.
- **Blocks:** silent bash-3.2 execution of any `#!/usr/bin/env bash` helper invoked from the pulse chain when a parent has already successfully re-exec'd.
- **Related:** t2087 (installed modern bash), t2094 (upgrade helper), t2176 (walk BASH_SOURCE + plist). This task is the third hole in the same wall.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Diagnosis | done | Completed in the parent session before filing this task. |
| Implementation | 20m | Ten PATH edits (mechanical), one guard-cleanup line, new test case. |
| Testing | 20m | Extend existing test, run it, deploy via setup.sh, restart pulse, verify log. |
| **Total** | **~40m** | tier:standard. |
