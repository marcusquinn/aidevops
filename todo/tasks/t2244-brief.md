<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2244: reconcile_completed_parent_tasks — prevent premature close from prose #NNN refs

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19762
**Tier:** thinking (NOT auto-dispatch — maintainer picks approach first)
**Severity:** CRITICAL (silent data-integrity issue in cross-runner coordination)

## What

`pulse-issue-reconcile.sh::reconcile_completed_parent_tasks` (line 1166) uses `_try_close_parent_tracker` (line 1122) which applies a too-permissive body-regex fallback: any `#NNN` mention anywhere in the parent body is treated as a potential child reference. When ≥2 such refs exist and ALL are closed, the parent is auto-closed — even if those refs are narrative context, not children.

## Why

Concrete incident: umbrella #19734 (t2228 v3.8.71 retrospective) was **prematurely closed 28 minutes before its own tracking PR existed**. A cross-runner pulse (`alex-solovyev` account) ran `reconcile_completed_parent_tasks` at 2026-04-18T18:23:17Z while the author was still claiming task IDs and writing briefs. The umbrella body at that moment mentioned #19708 (t2213 cloudron skill sync) and #19715 (t2214 gemini nits) — the release PRs that *triggered* the retrospective. Both were already closed → reconcile saw 2 closed refs → all-closed → auto-close with "All child tasks completed" comment.

This is a **race condition on incrementally-authored umbrellas**: any parent that cites historical closed issues in its body is vulnerable during the window between "issue created" and "all real children linked". The window can be minutes to hours depending on authoring speed.

## How

### Design intent being corrected

The body-regex fallback exists because GitHub sub-issues are a recent GraphQL feature (t2138) and legacy parents may only list children inline. But the fallback should require SYNTACTIC evidence that a reference IS a child — not just the presence of `#NNN` anywhere in the body.

### Files to modify

- **EDIT:** `.agents/scripts/pulse-issue-reconcile.sh:1122-1165` (`_try_close_parent_tracker`) and the caller at `:1166` (`reconcile_completed_parent_tasks`)
- **NEW:** `.agents/scripts/tests/test-reconcile-parent-body-parse.sh` — fixture-based regression tests

### Options (pick ONE — architectural decision, maintainer call)

**Option A — strict (recommended):** require an explicit `## Children` / `## Sub-tasks` / `## Child issues` heading in the parent body. Parse `#NNN` only from within that section (until the next `##` heading). Drop the blanket body regex. Parents without such a heading rely on GraphQL sub-issues only; legacy parents migrate to `## Children` format.

**Option B — structural:** require the parent body to contain a recognisable list/table structure of children (markdown table with `#NNN` refs in cells, or bulleted list where every bullet starts with `- #NNN`). Skip reconcile if no structured list.

**Option C — age gate:** only run reconcile on parents older than N hours (e.g., 2h) AND unmodified in the last M minutes (e.g., 30m). Buys authoring windows but doesn't fix the root cause.

**Option D — A + B fallback:** A as primary path, B as fallback for parents without `## Children` heading but with a structured bulleted list. No indiscriminate body regex ever.

### Recommendation

Option A. It's the clearest contract: "a parent-task tracks children declared under `## Children`". Low migration cost (retrospective umbrellas already use this convention). Easiest to explain, easiest to test, hardest to regress.

### Verification

- Fixture: parent body with `## Children` heading + 2 closed refs → `_try_close_parent_tracker` closes
- Fixture: parent body with 2 closed prose refs + no `## Children` heading → skip
- Fixture: parent body with `## Children` (3 refs, 1 open) + 2 unrelated closed prose refs elsewhere → skip (one child open)
- Fixture: replay #19734 body as a fixture file, confirm new logic does NOT close
- GraphQL sub-issue path unchanged (primary detection, only fallback semantics change)
- `shellcheck .agents/scripts/pulse-issue-reconcile.sh` clean

### Why NOT auto-dispatch

Architectural decision with blast radius: applies to every parent-task issue on every pulse cycle across every registered repo. Options A/B/C/D differ in operational cost and migration pain. Maintainer picks approach first; then a worker can implement.

## Acceptance Criteria

- [ ] Prose `#NNN` mentions in parent body no longer trigger premature close
- [ ] Chosen pattern (Children heading / structured list / age gate / combo) documented in function docstring
- [ ] GraphQL sub-issue path unchanged (primary detection)
- [ ] #19734 body fixture regression test passes (proves the specific incident can't recur)
- [ ] ShellCheck clean

## Context

Discovered during PR #19758 (t2228 v3.8.71 lifecycle retrospective) — bonus find #3 of 4. Highest-severity of the four: silent data-integrity issue affecting every parent-task on every pulse.

## Related

- t2138 — GraphQL sub-issue detection with fail-closed pagination guard (the primary path being preserved)
- `reference/cross-runner-coordination.md` — cross-runner pulse model
- t1986 — parent-task label semantics (originating design)
