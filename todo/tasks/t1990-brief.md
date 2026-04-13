<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1990: pre-edit-check — tighten interactive-session rule (canonical stays on main, no planning exception)

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (at user's explicit direction)
- **Parent task:** none
- **Conversation context:** User statement at end of the t1979–t1985 filing session:
  > "we should always work on main with worktrees in interactive sessions — no exceptions"
  Current behaviour: `pre-edit-check.sh` allows edits on `main` for an allowlist of paths (`README.md`, `TODO.md`, `todo/**`). This is the "main-branch planning exception" documented in AGENTS.md. The user is removing that exception for interactive sessions. Headless sessions (pulse, CI workers, routines) still need direct-main writes for routine state and TODO dispatch bookkeeping, so the exception stays for those.

## What

In `pre-edit-check.sh`, make the main-branch allowlist **session-origin-aware**:

- **Interactive session** (`detect_session_origin` returns `interactive`): allowlist is **empty**. Every edit in the canonical repo directory on main requires a linked worktree, regardless of file path. Even `TODO.md` / `todo/**` changes.
- **Headless session** (`worker` origin): current allowlist (`README.md`, `TODO.md`, `todo/*`) stays. Routines, pulse, and CI workers continue to write these directly on main.

Also update `.agents/AGENTS.md` and `.agents/prompts/build.txt` to state the tightened rule for interactive sessions and remove the "planning exception" carve-out from the interactive path.

## Why

**Concrete failure in the session that prompted this:**

During the filing of t1979–t1985 I committed a planning-only change directly on main from the canonical `~/Git/aidevops` directory because `pre-edit-check.sh --loop-mode --file todo/tasks/t1983-brief.md` returned `LOOP_DECISION=stay`. That commit landed on a feature branch (`bugfix/t1980-claim-task-id-dedup`) because the canonical directory had been silently moved off main by a parallel operator — the pre-edit-check's allowlist decision was "stay on main", but the canonical wasn't actually on main anymore. The planning commit ended up on a stale feature branch that was already merged via PR #18396, and I had to recover with a temporary worktree + cherry-pick.

**Root cause class:** the allowlist lets agents commit directly in a shared canonical directory whose state is not guaranteed to match what the agent believes. In a multi-operator / multi-session environment, the canonical directory is effectively shared mutable state — any agent editing it can stomp on another's work. Worktrees give each session its own isolated state.

**Why headless stays untouched:** headless workers are deterministic, run one task at a time, and the routines they maintain (`TODO.md` cleanup, routine state, etc.) legitimately need direct-main writes with no PR ceremony. They don't share canonical directories across sessions in the same way.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** — 3 (`pre-edit-check.sh`, `.agents/AGENTS.md`, `.agents/prompts/build.txt`). 1 over the limit.
- [x] **Complete code blocks for every edit?** — yes, diff provided below
- [x] **No judgment or design decisions?** — the user has set the rule explicitly; implementation is mechanical
- [x] **No error handling or fallback logic to design?** — the change is a guarded short-circuit
- [x] **Estimate 1h or less?** — yes, ~45m including verification
- [x] **4 or fewer acceptance criteria?** — 4

**Selected tier:** `tier:standard` (3 files > 2 disqualifier)

**Tier rationale:** Close to tier:simple but three files slightly over the strict limit. The implementation is fully specified below; the third file is a one-paragraph docs addition. Standard tier gives the worker enough context budget to audit the change across all three files.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pre-edit-check.sh:172-222` — `is_main_allowlisted_path` function
- `EDIT: .agents/AGENTS.md` — "Main-branch planning exception" paragraph (around line 165–175)
- `EDIT: .agents/prompts/build.txt` — mirror the AGENTS.md update in the system prompt's Git Workflow section

### Implementation Steps

1. Source `shared-constants.sh` for `detect_session_origin` if not already sourced. Check the current source chain at the top of `pre-edit-check.sh`. If not sourced, add:

    ```bash
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/shared-constants.sh"
    ```

2. Modify `is_main_allowlisted_path` to short-circuit FALSE in interactive sessions:

    ```bash
    is_main_allowlisted_path() {
        local file_path="$1"

        # t1990: Interactive sessions have NO main-branch planning exception.
        # Every edit in the canonical repo directory on main requires a linked
        # worktree, regardless of file path. Headless sessions (pulse, CI,
        # routines) still use the allowlist — they need direct-main writes
        # for routine state and dispatch bookkeeping.
        local origin
        origin=$(detect_session_origin 2>/dev/null || echo "interactive")
        if [[ "$origin" == "interactive" ]]; then
            return 1
        fi

        # ... existing logic below (canonicalize + allowlist check) ...
    }
    ```

3. Update `.agents/AGENTS.md`. Find the paragraph:

    ```markdown
    **Main-branch planning exception:** `TODO.md` and `todo/*` are the explicit exception to the PR-only flow — planning-only edits may be committed and pushed directly to `main`.
    ```

    Replace with:

    ```markdown
    **Main-branch planning exception (headless sessions only):** `TODO.md` and `todo/*` are an explicit exception to the PR-only flow for **headless sessions** (pulse, CI workers, routines) — they may be committed and pushed directly to `main`. **Interactive sessions must always use a linked worktree**, regardless of file path. No exceptions. The canonical repo directory always stays on `main`; every interactive edit goes through a worktree at `~/Git/<repo>-<branch>`. Enforced by `pre-edit-check.sh` (t1990).
    ```

4. Update `.agents/prompts/build.txt` to mirror the AGENTS.md change. Find the equivalent "Main-branch planning exception" line in the Git Workflow section and apply the same update.

5. Add a regression test. Create or extend a test harness that:
   - Runs `pre-edit-check.sh --loop-mode --file todo/tasks/test-brief.md` with `AIDEVOPS_HEADLESS=true` → expects `LOOP_DECISION=stay` (exit 0)
   - Runs the same without any headless env var → expects worktree creation (exit 2 in non-auto mode, or worktree created in auto mode)

6. Run shellcheck on `pre-edit-check.sh`.

### Verification

```bash
# Verify interactive session on main rejects TODO.md edit
cd ~/Git/aidevops
unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS
bash .agents/scripts/pre-edit-check.sh --loop-mode --file TODO.md 2>&1
# Expected: worktree required / created (NOT "stay on main")

# Verify headless session on main still allows TODO.md edit
FULL_LOOP_HEADLESS=true bash .agents/scripts/pre-edit-check.sh --loop-mode --file TODO.md 2>&1
# Expected: LOOP_DECISION=stay, exit 0

# Verify code path unchanged for interactive
bash .agents/scripts/pre-edit-check.sh --loop-mode --file .agents/scripts/pre-edit-check.sh 2>&1
# Expected: worktree required / created (same as before this change)

# Shellcheck
shellcheck .agents/scripts/pre-edit-check.sh
```

## Acceptance Criteria

- [ ] `pre-edit-check.sh --loop-mode --file TODO.md` run in an interactive session (no `*_HEADLESS` env vars set) returns a worktree-required decision (exit 2 or auto-creates a worktree), NOT `LOOP_DECISION=stay`.
- [ ] The same command run with `FULL_LOOP_HEADLESS=true` still returns `LOOP_DECISION=stay` (headless path unchanged).
- [ ] `.agents/AGENTS.md` and `.agents/prompts/build.txt` both document the tightened rule and the interactive/headless split.
- [ ] Shellcheck clean on `pre-edit-check.sh`.

## Context & Decisions

- **Why not remove the allowlist entirely:** headless workers (pulse, routines, CI) legitimately need direct-main writes. Removing the allowlist would break auto-update, routine logging, and TODO.md reconciliation. The split preserves headless functionality.
- **Why use `detect_session_origin` instead of `[[ -t 0 ]]`:** TTY detection is unreliable for AI coding tools (per the docstring in `shared-constants.sh:736-738`). The explicit env-var-based detection is the framework's canonical signal.
- **Why not enforce this via a git hook:** `pre-edit-check.sh` is the existing choke point for edits, and it's already called by agents before every tool invocation. Adding a git `post-checkout` hook would catch branch switches but not direct edits. The edit-time check is more fundamental.
- **Why not also block `git checkout <non-main-branch>` in the canonical dir:** out of scope for this task. `pre-edit-check.sh` fires on edits, not on git operations. A separate task could add a `post-checkout` hook to enforce "canonical stays on main" at the git-operation level. File as a follow-up if the edit-time check alone isn't sufficient.

## Relevant Files

- `.agents/scripts/pre-edit-check.sh:172-222` — `is_main_allowlisted_path` (the site to gate)
- `.agents/scripts/shared-constants.sh:756-782` — `detect_session_origin` (the helper to call)
- `.agents/AGENTS.md` — "Main-branch planning exception" paragraph
- `.agents/prompts/build.txt` — mirror text in Git Workflow section
- Evidence: this session's transcript showing the accidental feature-branch commit and recovery

## Dependencies

- **Blocked by:** none
- **Blocks:** cleaner multi-operator behaviour; reduces the blast radius of t1981 (assignee churn investigation)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | done | (this session) |
| Implementation | 20m | 3 files, small surgical edits |
| Testing | 15m | 3 scenarios (interactive, headless, code-path) |
| PR | 10m | |

**Total estimate:** ~45m
