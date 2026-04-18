<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2349 Brief — backfill-sub-issues: add umbrella-parent → children detection

**Issue:** GH#TBD (filed alongside this brief).

## Session origin

Discovered 2026-04-18 during board-clearing session after observing parent-tasks #19734 and #19736 had zero GitHub sub-issue links despite both bodies containing explicit `## Children` sections listing 7 and 4 children respectively. Manual `POST /repos/:owner/:repo/issues/:num/sub_issues` with child `id` (integer) linked all children cleanly. Root cause: the existing `backfill-sub-issues` path in `issue-sync-relationships.sh` runs CHILD-side only — `_backfill_one_issue` calls `_detect_parent_from_gh_state` on each candidate child and links upward when it finds one of three patterns (`tNNN.M` dot-notation title, `Parent:` line in body, `Blocked by:` referencing a parent-task-labeled issue). None of those patterns match the umbrella style where the PARENT carries the children list and the children never reference the parent. Result: a whole class of parent-tasks (decomposition umbrellas, retrospective trackers, roadmap epics) ship with a visible children table but no programmatic sub-issue graph, which then breaks `pulse-issue-reconcile.sh::_try_close_parent_tracker` (it falls back to a too-permissive body regex and mis-closes umbrellas on unrelated `#NNN` prose mentions — canonical: t2244/#19762 premature-close of #19734).

## What

Add parent-side detection to `backfill-sub-issues`: when iterating all issues, also check if the issue is a `parent-task` (by label) and, if so, parse its body for a `## Children` section and link every `#NNN` (or `GH#NNN`) reference in that section as a sub-issue.

## Why

- Umbrella-style parents never get their children linked programmatically — the only audit trail is prose in the body.
- `pulse-issue-reconcile.sh::_try_close_parent_tracker` (t2244/#19762 target) needs the authoritative sub-issue graph to avoid false closures. Without umbrella-side detection, it will keep falling back to body regex.
- GitHub UI shows sub-issue progress in the sidebar; unlinked children look like orphans.
- Framework principle: the harness should wire relationships at creation/sync time, not require an agent to remember to POST manually.

## How

### Files to modify

- **EDIT**: `.agents/scripts/issue-sync-relationships.sh:619-665` — extend `_backfill_one_issue` OR add a sibling `_backfill_parent_children($parent_num, $repo)` that runs when the issue carries the `parent-task` label.
- **EDIT**: `.agents/scripts/issue-sync-relationships.sh:676-730` — in `cmd_backfill_sub_issues`, fetch labels alongside title/body and dispatch to child-side or parent-side logic.
- **EXTEND** test: `.agents/scripts/tests/test-backfill-sub-issues.sh` — add cases for umbrella-style parent with `## Children` section listing 4 children. Mirror the existing Class B test harness.
- **EDIT**: `.agents/scripts/issue-sync-helper.sh:1497-1503` — update docstring to document the new parent-side detection pattern.

### Reference pattern

The child-side detection at `issue-sync-relationships.sh:619` shows the exact shape to mirror — fetch title+body, detect pattern, resolve node IDs via `_cached_node_id`, call `_gh_add_sub_issue`. The new function should:
1. Accept parent issue number + repo.
2. Fetch parent body (already fetched in the outer loop — pass it in to avoid double-fetch).
3. Parse the body for a `## Children` heading (case-insensitive, allow `## Child Issues`, `## Sub-issues`, `## Phases` as aliases).
4. In that section, extract every `#NNN` / `GH#NNN` reference (anchored to line start with `-` list marker to avoid prose matches).
5. For each extracted number, resolve its node ID and call `_gh_add_sub_issue($parent_node, $child_node)`.
6. Return count of links made (for summary output).

### Extraction regex candidate

```bash
rg -oE '^[[:space:]]*-[^-]*#([0-9]+)' | sed -E 's/.*#([0-9]+).*/\1/'
```

Validate against both umbrella styles observed today:

- `#19734` body: `| HIGH | t2229 | #19735 | ...` (markdown table)
- `#19736` body: `- t2229 / #19738 — CI workflow cascade-vulnerability linter` (markdown list)

Table-cell regex needs to tolerate both.

### Self-healing hook

Run parent-side backfill from the existing pulse reconcile phase `pulse-issue-reconcile.sh:1236` (already wired to call `backfill-sub-issues`). No new scheduling needed — the addition just widens what the periodic pass detects.

## Acceptance criteria

1. `issue-sync-helper.sh backfill-sub-issues --issue 19734 --dry-run` reports 7 children that would be linked (all of #19735, #19737, #19743, #19744, #19751, #19752, #19753).
2. Without `--dry-run`, the same command produces `sub_issues_summary.total = 7` on #19734.
3. Idempotent — running twice doesn't error or duplicate.
4. Existing child-side detection still works for the three legacy patterns (dot-notation, `Parent:` line, `Blocked by:` with parent-task label). No regression on `test-backfill-sub-issues.sh` Class A + Class B cases.
5. New test case: fixture umbrella issue body with `## Children` section + 3 children issues; assert all 3 get linked.
6. Prose body text like "see #19678" or "resolved by PR #19680" OUTSIDE the `## Children` section does NOT produce a false link.
7. Verification command: `gh api "repos/marcusquinn/aidevops/issues/19734/sub_issues" --jq '[.[] | .number] | sort'` returns the child list.

## Tier

**tier:standard** — single-file change in existing helper, extends well-tested pattern, has clear acceptance criteria and verification command. Not tier:simple because the section-parsing and regex choice are judgment calls that benefit from Sonnet review.

## Related

- GH#19762 / t2244 (parent) — the `_try_close_parent_tracker` bug that misfires when the sub-issue graph is empty; this task addresses the upstream "graph is empty" root cause by populating it.
- GH#19093 / t2114 — original backfill-sub-issues feature (child-side detection); this task is the Phase 2 extension.
- Canonical parents needing this fix: #19734 (v3.8.71 retrospective, 7 children), #19736 (harness self-inflicted CI failure class, 4 children). Already wired manually during the filing session — test by running backfill and confirming idempotence.
