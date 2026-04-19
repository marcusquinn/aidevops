<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2379: fix(pulse-dispatch): `_task_id_in_recent_commits` false positive on planning PR squash commits

## Origin

- **Created:** 2026-04-19
- **Session:** claude-code:aidevops-interactive (continuation of t2265/t2366 session)
- **Created by:** ai-interactive (marcusquinn)

## What

Fix the commit-subject main-commit dedup gate in `.agents/scripts/pulse-dispatch-core.sh` so it stops blocking dispatch for tasks whose *only* landed main-branch commit is the squash-merge of a **planning** PR.

Two related fixes, both in `_count_impl_commits` / `_task_id_in_recent_commits`:

1. **Root cause — path allowlist**: add `.task-counter` to the planning-only path list. `claim-task-id.sh` bumps `.task-counter` on every ID allocation, so every planning PR touches `TODO.md + brief + .task-counter`. Missing allowlist entry → `is_planning_only_inner=false` → commit counts as implementation → permanent dispatch block.
2. **Defense in depth — subject filter**: extend the grep-exclude regex at `grep -vE '^[0-9a-f]+ (...)'` to include `chore: mark t[0-9]+ complete`. `task-complete-helper.sh` writes these bookkeeping commits after ANY PR merge. They touch `TODO.md` only in the canonical case (already excluded by path filter), but the subject filter makes it robust against future regressions where a bookkeeping commit might accidentally gain extra file touches.

## Why

Reproduced on live system: t2366 (r914 routine) has been blocked from dispatch for 4+ hours because the squash-merge of its **planning** PR #19819 landed commit `10321cb36 t2366: plan r914 ... (#19819)` touching `TODO.md + todo/tasks/t2366-brief.md + .task-counter`. The `.task-counter` touch falls outside the planning-only path allowlist, so `_count_impl_commits` returns 1 → `_task_id_in_recent_commits` returns 0 → `_is_task_committed_to_main` returns 0 → `_check_commit_subject_dedup_gate` blocks dispatch with `task already committed to main (GH#17574)`.

The block is permanent (no time window expires it) until either the maintainer applies `force-dispatch` (which alex-solovyev's cross-runner reconciliation promptly strips — separate bug) or the subject-level dedup happens to miss the match.

This is a latent trap in the framework — every single `#auto-dispatch` task that goes through the plan→implement two-PR workflow (which is a supported pattern) is at risk.

## Evidence

```bash
$ git show --stat 10321cb36
commit 10321cb361f3aabae09a92f232ac775706bed44e
    t2366: plan r914 daily repo-aidevops-health-keeper routine (#19819)
 .task-counter             |   2 +-
 TODO.md                   |   2 +
 todo/tasks/t2366-brief.md | 179 ++++++++++++++++++++++++++++++++++++++++++++++

$ rg "task already committed to main" ~/.aidevops/logs/pulse.log | rg 19817 | wc -l
8  # (and counting — every pulse iteration)
```

## Tier

- **Selected:** `tier:simple` (single-file surgical fix with verbatim test fixture).
  *Note:* tests file is NEW and >100 lines, but the source of truth is the awk-extracted live functions, not a fresh reimplementation.

## How

### Files modified

- `EDIT: .agents/scripts/pulse-dispatch-core.sh` — `_count_impl_commits` path case (line ~300), `_task_id_in_recent_commits` grep filter (line ~366). Two 1-line changes + doc comments.
- `NEW: .agents/scripts/tests/test-pulse-dispatch-core-planning-filter.sh` — 8 regression tests covering both fixes and the positive case (real impl PR still detected).

### Verification

```bash
bash .agents/scripts/tests/test-pulse-dispatch-core-planning-filter.sh  # 8/8 pass
bash .agents/scripts/tests/test-pulse-dispatch-core-force-dispatch.sh   # 6/6 pass (unchanged)
bash .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh      # 8/8 pass (unchanged)
shellcheck .agents/scripts/pulse-dispatch-core.sh .agents/scripts/tests/test-pulse-dispatch-core-planning-filter.sh
```

## PR Conventions

Leaf (non-parent) task. PR body uses `Resolves #19863`.

## Acceptance Criteria

- [ ] `_count_impl_commits` classifies a commit touching `.task-counter + TODO.md + todo/tasks/*.md` as planning (`count == 0`).
- [ ] `_count_impl_commits` classifies a commit touching `.task-counter + real code file` as implementation (`count == 1`) — regression guard.
- [ ] `_task_id_in_recent_commits` returns 1 (not-committed) for the exact commit shape of `10321cb36` (planning PR squash).
- [ ] `_task_id_in_recent_commits` returns 0 (committed) for a real impl PR squash — regression guard.
- [ ] `chore: mark tNNN complete` subjects are excluded by the subject-prefix grep regardless of paths touched.
- [ ] Existing `test-pulse-dispatch-core-force-dispatch.sh` and `test-pulse-wrapper-main-commit-check.sh` still pass.

## Context

- **Pulse log evidence**: `[dispatch_with_dedup] Dispatch blocked for #19817 in marcusquinn/aidevops: task already committed to main (GH#17574)` — appears every pulse iteration.
- **Cross-runner bug (separate)**: alex-solovyev's runner reconciliation strips `force-dispatch` labels. Not fixed here — this PR closes the hole that made `force-dispatch` necessary in the first place.
- **Related**: `t2252` (planning-only PR auto-completion false positive in issue-sync.yml) — different symptom of the same "planning PRs look like implementation" blind spot.
