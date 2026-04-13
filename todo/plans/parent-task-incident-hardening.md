<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Plan: Parent-task lifecycle hardening — root-cause fixes from the t2010 incident

**Incident:** GH#18458 (t2010) — three workers dispatched between 23:08-00:19 UTC on 2026-04-12, then PR #18581 auto-closed the parent issue with `Resolves #18458`.
**Status:** plan + recommendations. Implementation is t2046 (sibling brief).
**Precedent for this hardening style:** the t1986 + GH#18537 chain that produced the parent-task guard itself.

---

## 1. Incident timeline

| Time (UTC) | Event |
|---|---|
| 2026-04-12 21:02 | t1986 parent-task dispatch guard merged (PR #18419). The guard reads `.labels[].name` from the gh API response and short-circuits with `PARENT_TASK_BLOCKED` when `parent-task` is present. |
| 2026-04-12 22:54 | GH#18458 (t2010) filed with `parent-task` label. The brief simultaneously tagged `#parent` (block dispatch) AND specified four substantive worker deliverables (read 48 functions, derive cluster map, write plan, file Phase 0 child) — internally contradictory, but the guard should still have blocked dispatch. |
| 2026-04-12 23:08 | First worker dispatched to GH#18458 by `alex-solovyev` runner. PID 2875870, model opus-4-6, tier reasoning. Worker silently exited; no PR. |
| 2026-04-12 23:39 | Second worker dispatched. PID 3657722. Same outcome. |
| 2026-04-13 00:19 | Third worker dispatched. PID 413412. Same outcome. |
| 2026-04-13 03:40 | GH#18537 merged (`fix(dispatch-dedup): use (.labels // []) null-fallback for all label jq filters`). Root cause was identified: five jq filters used `.labels[].name` which threw when `.labels` was null/absent from the gh API response. The throw bubbled up and `is_assigned()` returned the implicit failure code, which the dispatcher treated as "no block, dispatch allowed". Three workers had already been dispatched in the intervening ~6 hours. |
| 2026-04-13 03:46 | User flagged the issue: "needs our help, as the worker seems to be flogging". |
| 2026-04-13 04:12 | PR #18581 merged (the t2010 plan + Phase 0 child filing). The PR body used `Resolves #18458`, GitHub auto-closed the parent issue. |
| 2026-04-13 04:18 | Manual reopen of #18458 because the parent is meant to stay open until Phases 1-3 (children) merge. |

The incident exposes **two distinct systemic gaps**:

1. **A guard that was supposed to block dispatch failed silently, allowing through three workers.** The immediate jq null-handling bug was fixed, but the deeper question is unaddressed: *why did the guard fail open instead of fail closed?*
2. **A PR that delivered work for a parent-tracker issue used `Resolves #NNN` and auto-closed the parent.** This is a category error baked into GitHub's keyword convention — `Resolves`/`Closes`/`Fixes` always close on merge, regardless of issue role. There is no friction to catch it at PR-creation time.

This plan documents both root causes and proposes hardening for each. Both fixes ship as the same task (t2046) so the case study stays attached to the fixes.

---

## 2. Root cause #1 — guard fail-open default

### 2.1 What happened

`is_assigned()` at `dispatch-dedup-helper.sh:1035` is the canonical block-or-allow guard for every dispatch decision. Lines 1058-1075 are the parent-task short-circuit:

```bash
local parent_task_hit
parent_task_hit=$(printf '%s' "$issue_meta_json" |
    jq -r '[.labels[].name] | map(select(. == "parent-task" or . == "meta")) | .[0] // empty' 2>/dev/null)
if [[ -n "$parent_task_hit" ]]; then
    printf 'PARENT_TASK_BLOCKED (label=%s)\n' "$parent_task_hit"
    return 0
fi
```

When `$issue_meta_json.labels` is `null` or absent, the jq expression `[.labels[].name]` errors with `Cannot iterate over null (null)`. With `2>/dev/null` swallowing stderr, the failure is invisible. With `set -e` somewhere upstream the failure aborts the chain, leaving `parent_task_hit` empty and the if-branch un-taken. The function falls through to the assignee scan, finds no blocking assignees on a fresh `status:available` issue, and returns 1 (= dispatch allowed).

**The fix shipped in GH#18537 was correct** (replace `.labels[].name` with `(.labels // [])[].name`), but it only patches the symptom. The same shape of bug can recur in any of the **five other jq label filters in the same file** if any are missed in future audits, or in any new guard code added to the dispatch path.

### 2.2 The deeper question

`is_assigned()` returns:

- **0** = block dispatch (parent-task hit, cost-budget exceeded, blocking assignee, etc.)
- **1** = allow dispatch (no block reason found)

When jq throws, the function reaches an implicit `return 1` (or whatever the next return statement is). **The default behavior on uncertainty is to allow dispatch.** This is fail-open.

For a guard whose entire purpose is to *prevent harmful dispatches*, fail-open is the wrong default. Fail-closed (= "if I cannot determine the answer, refuse to dispatch") would have:

- Caught the GH#18458 incident at the first failed jq call instead of after three wasted workers
- Caught the same shape of bug for any of the other four jq filters that GH#18537 fixed
- Caught any future jq filter introduced into the guard chain

The cost of fail-closed is that a transient gh API failure (rate limit, network blip) would temporarily block dispatch on the affected issue. This is **strictly preferable** to dispatching workers that produce nothing — a transient block clears in the next pulse cycle without cost; a wasted worker burns ~20K tokens.

### 2.3 Other guard functions in the same file

```text
_check_db_entry()           — checks dedup DB for prior dispatch claim
is_duplicate()              — Layers 1-7 dedup chain
_is_stale_assignment()      — stale-recovery escalation
_check_cost_budget()        — t2007 cost-per-issue circuit breaker
is_assigned()               — the canonical guard (this file's main entry point)
_is_dispatch_comment_active()  — active dispatch claim freshness
```

All of these need the same audit. Some already fail-closed by design (e.g. `_check_cost_budget` blocks if the cost ledger is unreadable). Others (the layered `is_duplicate`, the comment-freshness checks) need explicit review to confirm their default on uncertainty.

### 2.4 Recommendation

**Switch `is_assigned()` and its peers to fail-closed on internal errors.** Specifically:

1. **Detect uncertainty explicitly.** When an internal subroutine (jq, gh API, gopass, file read) fails, capture the failure with a non-zero local rc rather than silently swallowing it. Treat any "I tried to check X and could not" as a third state distinct from "blocked" and "allowed".
2. **On uncertainty, emit a `GUARD_UNCERTAIN` signal and return 0 (block).** Mirror the existing `PARENT_TASK_BLOCKED` and cost-budget signal patterns. The pulse logs the signal and skips dispatch for this cycle.
3. **Add a watchdog metric.** If `GUARD_UNCERTAIN` fires more than N times per hour for the same issue, escalate via the same `needs-maintainer-review` label that t2007 cost-budget uses. This prevents an issue from silently sitting in uncertain limbo forever.
4. **Add a regression test.** `tests/test-dispatch-dedup-fail-closed.sh` that:
    - Stubs `gh issue view` to return `{}` (missing labels key) — must produce `GUARD_UNCERTAIN` and exit 0 (block)
    - Stubs `gh issue view` to return `{"labels": null, "assignees": []}` — must produce `GUARD_UNCERTAIN` and exit 0 (block)
    - Stubs `gh issue view` to return well-formed parent-task labels — must produce `PARENT_TASK_BLOCKED` and exit 0 (block)
    - Stubs `gh issue view` to return a clean dispatchable issue — must exit 1 (allow)

The implementation is local to `dispatch-dedup-helper.sh` and adds no new dependencies. Estimated effort: ~2-3h.

### 2.5 What the existing GH#18537 fix already covers

GH#18537 already replaced `.labels[].name` with `(.labels // [])[].name` in **all five** label-filter sites and added two regression tests (Cases F and G in `test-parent-task-guard.sh`) for null and absent-labels inputs. That fix is sufficient for the specific jq null bug. **What it does not cover** is the broader principle: any *other* failure mode in the guard chain (a future API schema change, a new jq filter, a network error) will still default to allowing dispatch. This plan recommends the architectural switch to fail-closed as belt-and-braces beyond the specific patch.

---

## 3. Root cause #2 — parent-task PR keyword trap

### 3.1 What happened

PR #18581 used:

```text
Resolves #18458
For #18579
```

The PR body distinguished the two issues correctly in plain English ("filed Phase 0 child as #18579, parent #18458 stays open as tracker"), but the closing keyword `Resolves` triggered GitHub's auto-close on merge. #18458 was closed at 2026-04-13T04:12:58Z, immediately after the merge at T04:12:57Z. Manual reopen was required.

### 3.2 Why the convention bites parent tasks

The framework already has the right mental model for distinguishing *what should close on merge* from *what should not*:

> **`prompts/build.txt` "Traceability"** — Code fix commit messages may use `Fixes #NNN` (auto-closes when merged to the default branch). Planning-only commits (TODO entries, briefs, docs) must use `For #NNN` or `Ref #NNN` — these reference the issue without triggering GitHub's auto-close.

The rule covers the *commit-vs-planning* axis. It does not cover the *parent-vs-leaf* axis.

For a parent task the right keyword depends on **what the PR delivers**:

| PR delivers… | Issue role | Closing keyword | Effect on merge |
|---|---|---|---|
| The full implementation of issue #N | normal leaf | `Closes #N` / `Resolves #N` / `Fixes #N` | Issue closes |
| Planning files only (brief, TODO, plan doc) | normal leaf | `For #N` / `Ref #N` | Issue stays open until code lands |
| **Plan doc + brief filing for a tracker** | **parent-task** | **`For #N` / `Ref #N`** | **Parent stays open** |
| The last child phase that completes the tracker | parent-task | `Closes #N` (parent) | Parent closes when all phases done |

Today nothing enforces or even hints at the third row. Workers and humans both get it wrong because the existing `prompts/build.txt` rule only contemplates the commit-vs-planning split.

### 3.3 Recommendation

Three layered defenses, ordered cheap-to-expensive:

#### 3.3.1 Brief template + AGENTS.md note (cheapest, immediate value)

Add a short section to `templates/brief-template.md` covering parent-task PR keyword conventions. Add a corresponding paragraph to `AGENTS.md` "Traceability" so workers and interactive sessions both see it before drafting a PR body.

Concrete text to paste into both:

> **Parent-task PRs (MANDATORY).** When a PR delivers ANY work for an issue tagged `parent-task` — including the initial plan-filing PR — the PR body MUST use `For #NNN` or `Ref #NNN`, never `Closes`/`Resolves`/`Fixes`. The parent issue must stay open until ALL phase children merge. The final phase PR uses `Closes #NNN` to close the parent. If you wrote `Resolves` and the parent auto-closed, reopen it manually with a comment explaining the convention.

This costs nothing to add but only catches careful authors. Helpful but insufficient on its own.

#### 3.3.2 PR creation linter (medium cost, high value)

A pre-PR check that scans the proposed PR body for any closing keyword, looks up each referenced issue's labels, and warns/blocks if the keyword would close a parent-task issue. Two implementation paths:

**Path A: client-side helper**, invoked by `full-loop-helper.sh commit-and-pr` and by interactive `gh pr create` wrappers. New script `.agents/scripts/parent-task-keyword-guard.sh`:

```bash
parent-task-keyword-guard.sh check-body --body-file body.md --repo OWNER/REPO
```

Returns exit 0 + warnings on findings. Optional `--strict` flag returns exit 1 instead. `commit-and-pr` always calls in `--strict` mode and refuses to create the PR until the keyword is downgraded.

**Path B: GitHub Actions check**, runs on `pull_request` events. Reads the PR body via `gh pr view`, runs the same logic, posts a check-status. Belt-and-braces for the path-A miss case (e.g. PRs created via the GitHub web UI or by external contributors).

Both paths together. Path A catches at the source (cheap, fast feedback). Path B catches anything Path A missed.

#### 3.3.3 Auto-reopen sweeper (most expensive, narrowest fix)

A pulse-side sweep that periodically checks closed `parent-task` issues against their open child phases. If the parent has open children and was closed by a `merged_pr` reference (not by a maintainer), reopen with an explanatory comment.

Optional. Useful as a backstop but addresses the symptom rather than the cause. Not in scope for the t2046 implementation unless 3.3.1 and 3.3.2 prove insufficient.

---

## 4. What goes into t2046 (the implementation task)

The sibling brief `todo/tasks/t2046-brief.md` scopes the implementation. Two deliverables:

### Deliverable A — `is_assigned()` fail-closed default

- Add a `GUARD_UNCERTAIN` signal pattern mirroring `PARENT_TASK_BLOCKED`.
- Switch `is_assigned()` to detect jq, gh, and helper-script failures explicitly via local rc capture instead of `2>/dev/null || true` swallowing.
- Block dispatch on uncertainty. Emit `GUARD_UNCERTAIN` to stdout for caller pattern matching.
- Add `tests/test-dispatch-dedup-fail-closed.sh` with the four cases enumerated in §2.4.
- Document the fail-closed contract in the function docstring at line 1035.
- Audit (read-only, log findings) the other guard functions in §2.3 and file follow-up tasks for any additional fixes.

### Deliverable B — parent-task PR keyword guard

- Add the §3.3.1 text to `templates/brief-template.md` and `AGENTS.md` "Traceability".
- Add `.agents/scripts/parent-task-keyword-guard.sh` per §3.3.2 Path A.
- Wire it into `full-loop-helper.sh commit-and-pr` (`--strict` mode by default; opt-out via `--allow-parent-close` for the final-phase PR case).
- Add `.github/workflows/parent-task-keyword-check.yml` per §3.3.2 Path B.
- Add `tests/test-parent-task-keyword-guard.sh` covering: parent issue with `Resolves` (block), parent issue with `For` (allow), leaf issue with `Resolves` (allow), parent issue with no closing keyword (allow), parent issue with `Closes` AND `--allow-parent-close` (allow).
- Update `templates/brief-template.md` with the new rule.

Estimated total effort: **~5-6h**, `tier:standard`. Splittable into two children if a worker prefers (A is shell + tests, B is shell + workflow + tests + docs).

---

## 5. Why one task, not two

Both fixes share the same root-cause story (the t2010 incident) and the same architectural principle (guards meant to prevent bad outcomes should fail closed, by code or by convention). Filing them as one task keeps the case study attached. If the implementing worker decides the scope is too large, decomposition is encouraged — file Deliverable A as `t2046` and Deliverable B as a sibling, both pointing back to this plan doc.

If decomposed, neither child should be tagged `#parent`. Both are real implementation tasks.

---

## 6. Out of scope

- Auditing every guard function in *every* helper script (the §2.3 audit is scoped to `dispatch-dedup-helper.sh` only)
- Adding the §3.3.3 auto-reopen sweeper (filed as a follow-up if §3.3.1 + §3.3.2 prove insufficient over the next 30 days)
- Changing the existing `prompts/build.txt` "Traceability" rule (the new parent-task rule is an *addition*, not a replacement)
- Revisiting the GH#18537 patch itself — that fix is correct, this plan adds belt-and-braces beyond it

---

## 7. References

- **GH#18458** — the t2010 incident issue
- **PR #18581** — the t2010 plan-filing PR that mis-closed #18458 with `Resolves`
- **GH#18537** — the immediate jq null-fallback fix (architectural fail-open hole still open)
- **PR #18419 (t1986)** — the original parent-task dispatch guard
- **`prompts/build.txt` "Traceability" section** — existing planning-vs-code rule that does not cover parent-vs-leaf
- **`templates/brief-template.md`** — gets the new convention text
- **`.agents/scripts/dispatch-dedup-helper.sh:1035`** — `is_assigned()` source
