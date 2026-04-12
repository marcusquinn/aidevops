---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1994: post-checkout hook — auto-restore main in canonical worktree

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:t1988-interactive
- **Created by:** ai-interactive (user-directed)
- **Parent task:** none (follow-up to t1990)
- **Conversation context:** During the t1988 session the canonical repo `~/Git/aidevops` drifted off main onto `bugfix/t1980-claim-task-id-dedup` (the reflog shows a session committed to main at 19:46:48, reset at 19:46:56, checked out the bugfix branch at 19:47:00, recommitted there — the classic "oops, committed to main, move it" dance, which left the canonical on a feature branch afterward). When the user asked "how do we get back onto main and prevent creating branches?" we confirmed that t1990 (merged 20:54Z today) already guards the **edit** side — interactive sessions now require a worktree for every edit, no TODO/brief allowlist exception — but t1990's PR body explicitly listed as out-of-scope: "A git `post-checkout` hook to enforce 'canonical stays on main' at the git-operation level." This task is that follow-up. A working hook was already hand-installed into `/Users/marcusquinn/Git/aidevops/.git/hooks/post-checkout` during the t1988 session and proven against four test cases — this task ships it as framework infrastructure so every initialized aidevops repo gets it, not just the one machine.

## What

Framework-level install of a `post-checkout` git hook that enforces "canonical worktree stays on main" at the git-operation level, complementing t1990's edit-time check. Four pieces ship together:

1. **New hook source file** at `.agents/hooks/main-branch-guard-post-checkout.sh` — the shell script that git executes on every `post-checkout` event. Detects branch-level checkouts in the canonical worktree (via `git-dir == git-common-dir`), refuses any target other than `main`/`master`, auto-restores main, and prints a loud guided error pointing at `wt add <branch>`. Linked worktrees are unaffected — the git-dir discrimination skips them cleanly.
2. **Installer wiring** in `.agents/scripts/install-hooks-helper.sh` — add a new case that installs `main-branch-guard-post-checkout.sh` as `.git/hooks/post-checkout` in each target repo, idempotent and conflict-aware (if an existing `post-checkout` hook already exists, append-vs-replace logic matching the existing pre-push privacy-guard install pattern). Include `install`, `uninstall`, and `status` subcommands consistent with privacy-guard.
3. **Auto-install on setup** — `setup.sh` (or the `aidevops init` flow) calls `install-hooks-helper.sh install` on every `initialized_repos[]` entry with a present `.git/` directory, same way privacy-guard is now installed per t1968. Opt-out via `AIDEVOPS_MAIN_BRANCH_GUARD=false` env var.
4. **Test harness** — new `.agents/scripts/test-main-branch-guard.sh` that creates a temp repo, installs the hook, and runs the same four test cases that the local install was already proven against (canonical `checkout other`, canonical `checkout -b new`, linked-worktree `checkout -b`, canonical `checkout main` no-op).

Explicitly out of scope (non-goals):

- **No changes to t1990's edit-time rules.** The pre-edit-check logic stays exactly as t1990 shipped it — this task is purely additive.
- **No `pre-commit` hook.** Tempting as a belt-and-braces measure, but `post-checkout` is the earlier gate — by the time a commit is attempted, the branch switch has already happened. One gate is enough if it's in the right place.
- **No changes to existing hooks** (git_safety_guard.py, privacy-guard-pre-push.sh, mcp_task_post_hook.py). They coexist.
- **No "auto-create worktree" behaviour.** The hook restores main and tells the user the command to run — it does not silently call `wt add` on their behalf, because that would hide the intent drift from the session log.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — 4 files (new hook + install-hooks-helper.sh edit + setup.sh edit + new test script).
- [x] **Complete code blocks for every edit?** Yes — the hook body is already proven working in `~/Git/aidevops/.git/hooks/post-checkout` (ready to copy verbatim into `.agents/hooks/`).
- [x] **No judgment or design decisions?** The design is already made and validated — this is mechanical translation of a proven local hook into framework plumbing.
- [x] **No error handling or fallback logic to design?** The hook's error handling is already designed and tested; installer just needs to mirror privacy-guard's idempotent install pattern.
- [ ] **Estimate 1h or less?** No — ~2h including the test harness and setup.sh wiring.
- [x] **4 or fewer acceptance criteria?** Yes — 4.

**Selected tier:** `tier:standard`

**Tier rationale:** Multi-file but mechanical. The hard work (design + validation) was done in the t1988 session where the hook was installed locally and tested against four cases. Standard tier (Sonnet) can execute the install-hooks wiring from the privacy-guard pattern at `.agents/scripts/install-privacy-guard.sh` as its reference. Not `tier:simple` because 4 files and a test harness exceed the `tier:simple` ceiling.

## How (Approach)

### Files to Modify

- `NEW: .agents/hooks/main-branch-guard-post-checkout.sh` — the hook body. Copy verbatim from the proven local install at `~/Git/aidevops/.git/hooks/post-checkout` (available for reference during implementation — do not touch it during this task, it is the production local install).
- `EDIT: .agents/scripts/install-hooks-helper.sh` — add a new case/function for post-checkout hook install, following the privacy-guard pattern. May be simpler to add a dedicated `install-main-branch-guard.sh` sibling to `install-privacy-guard.sh` and have `install-hooks-helper.sh install` call both.
- `NEW: .agents/scripts/install-main-branch-guard.sh` (optional, if the one-sibling-per-hook pattern is preferred) — dedicated installer mirroring `install-privacy-guard.sh` structure: `install`, `uninstall`, `status` subcommands, idempotent, opt-out via `AIDEVOPS_MAIN_BRANCH_GUARD=false`.
- `EDIT: setup.sh` — add a call to install the main-branch-guard in every `initialized_repos[]` entry with a present `.git/` directory, mirroring how privacy-guard is installed per t1968.
- `NEW: .agents/scripts/test-main-branch-guard.sh` — 4 test cases in a stubbed temp repo.

### Implementation Steps

1. **Capture the hook body** — copy `~/Git/aidevops/.git/hooks/post-checkout` to `.agents/hooks/main-branch-guard-post-checkout.sh`. Keep the content exactly as-is; it has been shellcheck-clean and behaviourally tested.

2. **Create installer** — model on `.agents/scripts/install-privacy-guard.sh`. Three subcommands (`install`, `uninstall`, `status`), idempotent install (detect existing `post-checkout` hook and handle: replace if it matches a prior aidevops install via header comment, skip with warning if user has their own, backup-and-replace on `--force`), uninstall restores any backup, status reports install presence and version.

3. **Wire into install-hooks-helper.sh** — add the new installer to the `install` flow alongside privacy-guard.

4. **Wire into setup.sh** — iterate `initialized_repos[]`, call the installer with `--repo-path` for each. Opt-out via `AIDEVOPS_MAIN_BRANCH_GUARD=false`.

5. **Test harness** — model on `.agents/scripts/test-privacy-guard.sh`. Create a temp repo, install the hook, run:
   - `checkout other-branch` → expect hook output + branch == main
   - `checkout -b new-branch` → expect hook output + branch == main + new-branch deleted cleanly
   - linked worktree `checkout -b branch-in-worktree` → expect no hook output + branch stays
   - `checkout main` when already main → expect no hook output + no error
   Assert exit codes and final branch state.

6. **Docs** — one paragraph in `.agents/AGENTS.md` under "Git Workflow" noting the new hook. One paragraph in `.agents/prompts/build.txt` under "Pre-edit rules" or a new "Git hook protection" subsection. Both reference `install-main-branch-guard.sh status` for diagnostics.

### Verification

```bash
# Unit: test harness passes all 4 cases
.agents/scripts/test-main-branch-guard.sh

# Integration: hook fires on canonical drift, not on linked worktree churn
bash -x .agents/hooks/main-branch-guard-post-checkout.sh <prev> <new> 1   # smoke

# Installer idempotency
.agents/scripts/install-main-branch-guard.sh install --repo-path /tmp/testrepo
.agents/scripts/install-main-branch-guard.sh install --repo-path /tmp/testrepo   # second run, no change
.agents/scripts/install-main-branch-guard.sh status --repo-path /tmp/testrepo    # reports installed

# Shellcheck clean
shellcheck .agents/hooks/main-branch-guard-post-checkout.sh .agents/scripts/install-main-branch-guard.sh .agents/scripts/test-main-branch-guard.sh
```

## Acceptance Criteria

- [ ] `.agents/hooks/main-branch-guard-post-checkout.sh` exists, shellcheck-clean, and byte-identical to the t1988-session local install (modulo the SPDX header and a file-level comment naming the install path and opt-out env var).

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/hooks/main-branch-guard-post-checkout.sh"
  ```

- [ ] `install-hooks-helper.sh install` installs the main-branch-guard into every `initialized_repos[]` entry with a present `.git/` directory, idempotently, with an opt-out via `AIDEVOPS_MAIN_BRANCH_GUARD=false`.

  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_MAIN_BRANCH_GUARD"
    path: ".agents/scripts"
  ```

- [ ] `.agents/scripts/test-main-branch-guard.sh` runs all 4 test cases and exits 0.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/test-main-branch-guard.sh"
  ```

- [ ] `.agents/AGENTS.md` and `.agents/prompts/build.txt` reference the hook in the git-workflow / pre-edit-rules sections.
- [ ] Tests pass, lint clean.

## Context & Decisions

- **Why not make it a pre-commit hook instead:** a pre-commit hook only fires when the user tries to commit, which is later than the branch switch. The `post-checkout` hook catches the drift at the earliest possible moment (immediately after `git checkout` or `git switch` completes), so the canonical worktree never stays in a bad state long enough for follow-on commands to build on it.
- **Why auto-restore instead of just warning:** warnings without restoration still leave the canonical in a bad state. If the user acknowledged the warning but did nothing, the next script (pulse, auto-dispatch, setup.sh) would still see a non-main canonical. Auto-restore makes the bad state impossible to persist, which is the point.
- **Why the `git-dir == git-common-dir` check for canonical discrimination:** in a shared git database (main repo + linked worktrees), the hooks directory lives in the common git dir and is shared. Without the discrimination check, the hook would fire inside linked worktrees and forcibly revert their legitimate feature-branch work. The `git-dir` vs `git-common-dir` comparison is the standard way to answer "am I in the canonical worktree or a linked one?" — in the canonical, both point to the same `.git`; in a linked worktree, `git-dir` points to `.git/worktrees/<name>/` while `git-common-dir` points to the main `.git`.
- **Why a new sibling installer (`install-main-branch-guard.sh`) rather than folding into privacy-guard:** the privacy-guard has its own well-tested lifecycle (install, uninstall, status, bypass). Mixing two unrelated hooks into one installer couples them artificially — a user opting out of privacy-guard shouldn't lose main-branch protection, and vice versa. The one-hook-per-installer pattern also matches what privacy-guard already does.
- **Why interactive-only (no headless exclusion):** unlike t1990 which correctly exempts headless sessions from the edit-time rule (pulse workers need to write routine state directly on main), the git-operation rule is symmetric: no session, headless or interactive, should leave the canonical on a non-main branch. Pulse workers work in their own worktrees anyway; if a pulse worker switched the canonical off main, that IS a bug regardless of session origin. So the hook has no session-origin check.
- **Prior art consulted:**
  - The hook body was proven during the t1988 session with 4 test cases against the real `~/Git/aidevops` canonical repo. This task is translating that proven local install into framework plumbing.
  - `.agents/scripts/install-privacy-guard.sh` (t1965) — structural template for installer subcommands, idempotency, backup/restore, opt-out env var.
  - `.agents/scripts/test-privacy-guard.sh` (t1969) — structural template for stub-based hook testing.
  - `.agents/hooks/privacy-guard-pre-push.sh` — structural template for a shell git hook with graceful fallback.

## Relevant Files

- `~/Git/aidevops/.git/hooks/post-checkout` — the proven local install from the t1988 session; reference implementation
- `.agents/scripts/install-privacy-guard.sh` — installer pattern to mirror
- `.agents/scripts/test-privacy-guard.sh` — test harness pattern to mirror
- `.agents/hooks/privacy-guard-pre-push.sh` — git hook file pattern to mirror
- `.agents/scripts/install-hooks-helper.sh` — where the new install call is wired
- `setup.sh` — where the per-repo install loop runs during `aidevops init`
- `todo/tasks/t1990-brief.md` — the edit-time counterpart; this task is explicitly listed as a follow-up in t1990's PR body

## Dependencies

- **Blocked by:** none. t1990 is already merged; this task is an additive follow-up.
- **Blocks:** nothing explicit. Every session that touches the canonical repo benefits.
- **External:** none.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read privacy-guard install + test patterns | 15m | Structural reference |
| Hook file + installer | 45m | Mechanical translation + idempotency logic |
| setup.sh wiring | 15m | Mirror t1968 privacy-guard install loop |
| Test harness | 30m | 4 cases against stubbed temp repo |
| Docs (AGENTS.md + build.txt) | 15m | Two short paragraphs |
| PR + verify | 10m | |
| **Total** | **~2h 10m** | |
