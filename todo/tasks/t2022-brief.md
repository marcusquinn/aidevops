<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2022: `init-routines-helper.sh` readonly color collision terminates `setup.sh` early

## Origin

- **Created:** 2026-04-13
- **Session:** opencode:chore/t-new-setup-sh-readonly-green
- **Created by:** marcusquinn (ai-interactive) — observed while running `setup.sh --non-interactive` during the GH#18439 post-merge deploy
- **Parent task:** none (standalone bug)
- **Conversation context:** While deploying the Linux pulse fix (GH#18439 → PR #18477 → v3.7.3) the post-merge `setup.sh --non-interactive` call emitted `init-routines-helper.sh: line 22: GREEN: readonly variable` and then exited silently. Investigation showed this terminates setup.sh before `setup_privacy_guard` and `setup_canonical_guard` run, so every setup.sh invocation has been silently failing to install/refresh two security-critical git hooks.

## What

Make `init-routines-helper.sh` safe to source from `setup.sh` without colliding on color constants that `shared-constants.sh` has already declared `readonly`.

After this fix, a `setup.sh --non-interactive` invocation must run to completion — emitting the "privacy-guard pre-push hook installed" and "canonical-guard post-checkout hook installed" lines that currently never appear in the log.

## Why

**This is not a cosmetic warning. It is a fatal termination of setup.sh.**

Chain of events on every `setup.sh --non-interactive`:

1. `setup.sh:103-109` sources `.agents/scripts/shared-constants.sh`, which declares `readonly GREEN='\033[0;32m'` (and `RED`, `BLUE`, `YELLOW`, `NC`, etc.) at lines 313-333.
2. `setup.sh:919` calls `setup_routines`, defined in `.agents/scripts/setup/_routines.sh:25`.
3. `_routines.sh:13` sources `.agents/scripts/init-routines-helper.sh` into the current shell.
4. `init-routines-helper.sh:18` sets `set -Eeuo pipefail`, inheriting errexit into the parent.
5. `init-routines-helper.sh:22` attempts plain `GREEN='\033[0;32m'`. Because `GREEN` is already `readonly` from step 1, bash writes `line 22: GREEN: readonly variable` to stderr and treats the assignment as a failure. Under the inherited `errexit`, bash then terminates the parent `setup.sh` with exit 1.
6. Steps that run after `setup_routines` in `setup.sh` are silently skipped:
   - `setup.sh:923` — `setup_privacy_guard` (installs `.git/hooks/pre-push` scanning `TODO.md`/`todo/**`/`README.md` for private slug leaks, t1965)
   - `setup.sh:928` — `setup_canonical_guard` (installs `.git/hooks/post-checkout` warning on branch switches from canonical main, t1995)
   - Any post-routines status reporting

### Observed impact — confirmed by log inspection

From the setup.sh run log during the GH#18439 deploy (`/tmp/setup-18439.log`, 244 lines total):

```
[INFO] Setting up routines repo...
/Users/marcusquinn/Git/aidevops/.agents/scripts/setup/../init-routines-helper.sh: line 22: GREEN: readonly variable
```

These are the **final two lines** of the log. No `setup_privacy_guard` or `setup_canonical_guard` success messages exist. The process exited here.

### Reproduction (bash, outside setup.sh)

```bash
cat > /tmp/repro.sh <<'SH'
#!/usr/bin/env bash
source ~/Git/aidevops/.agents/scripts/shared-constants.sh
echo "BEFORE source"
source ~/Git/aidevops/.agents/scripts/init-routines-helper.sh
echo "AFTER source (should print if bug is fixed)"
SH
bash /tmp/repro.sh; echo "exit=$?"
```

Current output (bug present):

```
BEFORE source
/Users/marcusquinn/Git/aidevops/.agents/scripts/init-routines-helper.sh: line 22: GREEN: readonly variable
exit=1
```

`AFTER source` never prints. The parent script exits 1.

### Why it matters

- **Security control gap**: privacy-guard pre-push hook never gets refreshed by `aidevops update`. On a fresh machine, it never gets installed at all. A user who edits `TODO.md` with a private repo slug will push it to a public repo because the client-side hook isn't there.
- **Worktree safety gap**: canonical-guard post-checkout hook not installed/refreshed. Accidental branch switches on the canonical main directory go unwarned.
- **Silent failure**: the error is one line among hundreds of setup.sh status messages and looks cosmetic. Users (including me) have been ignoring it. It was only caught because the previous task ran setup.sh to deploy a release and I happened to read the tail of the log.

### Regression window

The bug exists when **both** of these are true:

1. `shared-constants.sh` declares color names as readonly (commit history shows this has been stable for a long time).
2. `init-routines-helper.sh` declares the same names with plain `VAR=...` (first introduced in t1924 — GH#17381 lineage — when this helper was created).

The collision surfaces only when the helper is SOURCED into a shell that already sourced `shared-constants.sh`. Direct execution (`./init-routines-helper.sh` or `aidevops init-routines`) works because the child bash process starts fresh and `shared-constants.sh` is sourced inside the helper's own scope without preexisting readonly bindings. **This is why the bug went undetected: the helper's own tests all execute it as a child process, not as a source.**

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** — only `.agents/scripts/init-routines-helper.sh`
- [x] **Complete code blocks for every edit?** — exact oldString/newString in Implementation Steps below
- [x] **No judgment or design decisions?** — the guard-pattern fix is prescribed; no alternatives to weigh in the worker step
- [x] **No error handling or fallback logic to design?** — the existing pattern at `pulse-session-helper.sh:42` is the template
- [x] **Estimate 1h or less?** — 15 min including test
- [x] **4 or fewer acceptance criteria?** — 4 below

**Selected tier:** `tier:simple`

**Tier rationale:** Single-file edit, exact diff provided, prior art in the same codebase (`pulse-session-helper.sh:42`) to copy verbatim. Haiku should handle this without escalation.

## How (Approach)

### Root cause

`init-routines-helper.sh` defines color constants with plain assignment, assuming they are not already set. When sourced after `shared-constants.sh`, those names are already `readonly`, so the assignment fails. Under `set -Eeuo pipefail`, this is fatal.

### Fix strategy

Guard each color assignment with a "set it only if unset" pattern. Do not remove the definitions entirely — the helper can also be executed directly (as `aidevops init-routines` does), in which case `shared-constants.sh` has not been sourced and the colors must be defined.

The canonical pattern is already in use at `.agents/scripts/pulse-session-helper.sh:42`:

```bash
[[ -z "${GREEN+x}" ]] && readonly GREEN='\033[0;32m'
```

This reads: "if `GREEN` is unset (`${GREEN+x}` substitutes the literal `x` only when `GREEN` is set, so the parameter expansion is empty when unset), declare it readonly." When the helper is sourced after `shared-constants.sh`, the `[[ ]]` short-circuits and the assignment never runs. When the helper is executed directly, the assignment runs normally.

`&&` with a failing left-hand side returns 0 at the command level (bash treats `[[ ]] && cmd` as a compound command whose exit is 0 when the test is false), so `set -e` does not trip.

### Files to Modify

- `EDIT: .agents/scripts/init-routines-helper.sh:21-26` — replace the unconditional color assignments with the guard pattern

### Implementation Steps

1. Replace lines 21-26 of `.agents/scripts/init-routines-helper.sh`:

   **Before** (lines 21-26):

   ```bash
   # Colors
   GREEN='\033[0;32m'
   BLUE='\033[0;34m'
   YELLOW='\033[1;33m'
   RED='\033[0;31m'
   NC='\033[0m'
   ```

   **After**:

   ```bash
   # Colors (guarded: may already be readonly when sourced from setup.sh after
   # shared-constants.sh — see GH#18485 / t2022. Pattern mirrors
   # pulse-session-helper.sh:42.)
   [[ -z "${GREEN+x}" ]] && readonly GREEN='\033[0;32m'
   [[ -z "${BLUE+x}" ]] && readonly BLUE='\033[0;34m'
   [[ -z "${YELLOW+x}" ]] && readonly YELLOW='\033[1;33m'
   [[ -z "${RED+x}" ]] && readonly RED='\033[0;31m'
   [[ -z "${NC+x}" ]] && readonly NC='\033[0m'
   ```

2. Run `shellcheck .agents/scripts/init-routines-helper.sh` — must exit clean.

3. Reproduce with the source-after-shared-constants test above and confirm `AFTER source` now prints and exit code is 0.

4. Run `bash ~/Git/aidevops/setup.sh --non-interactive 2>&1 | tail -15` and confirm the final lines include a privacy-guard success message (the exact wording lives in `setup.sh:923` / the `setup_privacy_guard` function — it should print something containing "privacy" or "privacy-guard"). Also confirm there is no `GREEN: readonly variable` line anywhere in the output.

### Verification

```bash
# 1. shellcheck
shellcheck .agents/scripts/init-routines-helper.sh

# 2. Source-after-shared-constants regression check
cat > /tmp/t2022-repro.sh <<'SH'
#!/usr/bin/env bash
source ~/Git/aidevops/.agents/scripts/shared-constants.sh
source ~/Git/aidevops/.agents/scripts/init-routines-helper.sh
echo "OK"
SH
bash /tmp/t2022-repro.sh
# Must print "OK" and exit 0.
rm -f /tmp/t2022-repro.sh

# 3. End-to-end: setup.sh runs to completion (background + capture)
nohup bash ~/Git/aidevops/setup.sh --non-interactive >/tmp/t2022-setup.log 2>&1 &
SETUP_PID=$!
wait "$SETUP_PID"
echo "setup.sh exit=$?"
# Must exit 0. Log must NOT contain "GREEN: readonly variable".
! grep -q 'GREEN: readonly variable' /tmp/t2022-setup.log
# Log MUST contain a privacy-guard success line (search for "privacy" case-insensitive).
grep -qi 'privacy' /tmp/t2022-setup.log
```

## Acceptance Criteria

- [ ] `shellcheck .agents/scripts/init-routines-helper.sh` exits 0.
  ```yaml
  verify:
    method: bash
    run: "shellcheck ~/Git/aidevops/.agents/scripts/init-routines-helper.sh"
  ```
- [ ] Sourcing `init-routines-helper.sh` after `shared-constants.sh` does not emit a `readonly variable` error and the sourcing shell continues executing subsequent commands.
  ```yaml
  verify:
    method: bash
    run: "bash -c 'source ~/Git/aidevops/.agents/scripts/shared-constants.sh; source ~/Git/aidevops/.agents/scripts/init-routines-helper.sh; echo OK' | grep -q '^OK$'"
  ```
- [ ] A full `setup.sh --non-interactive` run completes without printing `GREEN: readonly variable` anywhere in its output.
  ```yaml
  verify:
    method: bash
    run: "bash ~/Git/aidevops/setup.sh --non-interactive 2>&1 | tee /tmp/t2022-verify.log; ! grep -q 'GREEN: readonly variable' /tmp/t2022-verify.log"
  ```
- [ ] The same run reaches and executes `setup_privacy_guard` — the log contains a line matching `privacy` (case-insensitive) indicating the privacy-guard hook setup step ran.
  ```yaml
  verify:
    method: bash
    run: "grep -qi 'privacy' /tmp/t2022-verify.log"
  ```

## Context & Decisions

- **Why guard-pattern over sourcing `shared-constants.sh` from the helper**: sourcing is more "DRY" but introduces a new dependency chain and loading-order concerns (the helper might be executed before `shared-constants.sh` exists on a fresh checkout, before `setup.sh --non-interactive` finishes its deploy). The guard pattern is 5 lines, self-contained, and matches an existing idiom in the repo (`pulse-session-helper.sh:42`).
- **Why not use `|| true` or `2>/dev/null`**: both would hide the problem rather than fix it. The readonly assignment would still be a silent no-op, and if future code tries to RE-assign GREEN (e.g., to a different color scheme), the failure would surface later in confusing ways.
- **Why not remove `set -Eeuo pipefail` from the helper**: the strict mode is correct — it catches real bugs. Removing it would mask legitimate failures.
- **Explicit non-goals** (keep this task tight):
  - Do NOT audit every script in `.agents/scripts/` for the same pattern. There are many scripts that declare `readonly COLOR=` and could theoretically collide if sourced. The observed failure is specifically in `init-routines-helper.sh` because it's the one `setup.sh` sources. A broader audit is a separate follow-up task once this one ships — file as `t2023` if you find more sites during this work, do not expand this PR.
  - Do NOT touch `shared-constants.sh`. It is the source-of-truth and its `readonly` declarations are correct.
  - Do NOT touch `pulse-session-helper.sh:42`. It already uses the correct pattern.

## Relevant Files

- `.agents/scripts/init-routines-helper.sh:21-26` — the lines to replace
- `.agents/scripts/shared-constants.sh:313-333` — where `GREEN`/`BLUE`/`YELLOW`/`RED`/`NC` are declared readonly (do not modify)
- `.agents/scripts/pulse-session-helper.sh:42` — reference pattern to copy
- `.agents/scripts/setup/_routines.sh:13` — the `source` call that triggers the collision
- `setup.sh:103-111` — where `shared-constants.sh` is sourced (establishes the readonly state)
- `setup.sh:919-929` — where `setup_routines`, `setup_privacy_guard`, and `setup_canonical_guard` are called in sequence

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing directly, but unblocks `setup_privacy_guard` and `setup_canonical_guard` refresh paths across all aidevops installs. Worth flagging in the PR body so users know to re-run `setup.sh` after the release lands.
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 3m | Read lines 21-26 of init-routines-helper.sh + pattern at pulse-session-helper.sh:42 |
| Implementation | 5m | 5-line diff |
| Testing | 7m | shellcheck, source-after reproduction, full setup.sh run |
| **Total** | **15m** | |

## Follow-up (post-merge, separate task)

Once this ships, file `t2023` (or whatever the next ID is) to **audit all scripts in `.agents/scripts/` that declare `readonly <color>=` without a guard** and apply the same pattern where they might be sourced. Candidates from an initial `rg` pass include:

- `coderabbit-cli.sh:36` — likely safe (always executed as a child process, not sourced)
- Various `tests/test-*.sh` — safe by convention (tests run as child processes)

The follow-up should focus on any helper that might end up on a source path. Not scope for this task.
