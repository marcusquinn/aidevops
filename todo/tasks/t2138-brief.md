<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2138 — fix(pulse): `reconcile_completed_parent_tasks` consults sub-issue graph before body regex

## Session Origin

Interactive session, 2026-04-16. Surfaced while inspecting parent issue
#19222 (t2126). Parent body is narrative prose with no `#NNN` references;
its 5 children (#19223-#19227) are all CLOSED and are wired via GitHub's
GraphQL `subIssues` relationship (per PR #19228's own body: "All 5 children
are wired as sub-issues of the parent via the GitHub GraphQL API"). The
reconciler (`pulse-issue-reconcile.sh:reconcile_completed_parent_tasks`,
shipped in PR #19211) relies on body regex `grep -oE '#[0-9]+'` — which
finds nothing — so the parent stays open forever.

## What

Upgrade `reconcile_completed_parent_tasks` to prefer GitHub's native
sub-issue graph. When the graph has children, use that as the authoritative
source. Fall back to body-regex only when the graph returns empty (legacy
parents that pre-date sub-issue wiring).

## Why

- **Correctness**: sub-issue graph is the canonical parent-child
  relationship on GitHub; body regex is a heuristic. When they disagree,
  the graph wins.
- **Adoption alignment**: since PR #19098 (t2114), the framework actively
  backfills sub-issue graph edges via `issue-sync-helper.sh
  backfill-sub-issues`. Most new parent-tasks use the graph. The reconciler
  must catch up.
- **Zero regression for legacy**: body-regex path is preserved as a
  fallback, so any parent that lists children only inline still closes on
  cycle.
- **Closes #19222 and any future parent in the same shape** — no
  per-parent manual body edits required.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-issue-reconcile.sh`
  - Function `reconcile_completed_parent_tasks` (~line 964-1057).
  - Add a helper `_fetch_subissue_numbers "$slug" "$issue_num"` that runs
    one `gh api graphql` query against the `subIssues` field and emits
    newline-separated issue numbers. Returns empty string on failure, on
    missing feature, or on an empty graph.
  - In the main loop, try the graph first; if non-empty, use those numbers
    as `child_nums`. Otherwise use the existing body-regex path.
  - Preserve all existing safeguards: min 2 children, max 5 closes per
    cycle, skip unknown states, skip parents labelled with rejection
    labels.

- **EDIT:** `.agents/scripts/tests/test-pulse-reconcile-parent-task-close.sh`
  (create if absent; if present extend).
  - Mock `gh api graphql` responses for the `subIssues` query; assert
    graph-path close.
  - Mock an empty-graph response + body with `#NNN`; assert fallback-path
    close.
  - Mock a graph with one open child; assert no-close.
  - Mock a graph with <2 children; assert no-close (single-ref guard).

### Reference patterns

- **Existing GraphQL in the file**: `shared-constants.sh:1092` uses
  `gh api graphql -f query='mutation...addSubIssue...'` — the same
  invocation style applies for the `query` direction.
- **Existing reconciler structure**: `pulse-issue-reconcile.sh:964-1057`
  — body-regex path stays intact as the fallback; only the "collect child
  numbers" stage gets an earlier attempt.
- **Existing test idiom**: `tests/test-label-invariants.sh` Part 3 mocks
  `gh` via `STUB_DIR/gh` and asserts on call log — same pattern applies.

### GraphQL query shape

```graphql
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      subIssues(first: 50) {
        nodes { number state }
      }
    }
  }
}
```

Note the `subIssues` field is GA on all GitHub tiers where AI DevOps repos
live; it returns an empty list (not an error) when the feature is unused on
an issue. Error handling:
- Non-zero exit → empty list → fall back to body regex.
- Rate limit / network → empty list → fall back (safe degrade).
- Feature-not-enabled (enterprise quirk) → empty list → fall back.

### Verification

- **Unit tests**: new `tests/test-pulse-reconcile-parent-task-close.sh` run
  under `bash` with a stubbed `gh`. Cover: graph-path close, fallback-path
  close, graph-partial-open no-close, graph-single-child no-close.
- **Static checks**: `shellcheck` on the modified helper and new test.
- **Manual integration**: on the actual #19222 after merge, watch the
  pulse log for `Reconcile parent-task: closed #19222`. If not auto-closed
  by next cycle, fall back to manual close citing the new logic (smoke
  test still validates).

## Acceptance criteria

- [ ] `reconcile_completed_parent_tasks` queries the sub-issue graph
  before body regex.
- [ ] When graph returns ≥2 children and all are closed, the parent is
  closed with the existing summary-comment format.
- [ ] When graph returns empty, legacy body-regex path runs unchanged.
- [ ] No regression on existing safeguards (min 2 children, max 5/cycle,
  rejection-label skip, unknown-state skip).
- [ ] New test file asserts all four scenarios and passes.
- [ ] `shellcheck` clean on modified files.
- [ ] #19222 closes on the next pulse cycle post-merge (primary
  integration signal).

## Context

- **Reconciler shipped**: PR #19211 (`ff80f9523`).
- **Sub-issue infra**: PR #19098 (t2112+t2113+t2114) — `addSubIssue`
  mutation + backfill helper + CI wrapper guard.
- **Primary motivating case**: #19222 — 5 closed children via sub-issue
  graph, 0 `#NNN` references in body, reconciler can't close it.
- **GraphQL surface**: used elsewhere in `shared-constants.sh` and
  `issue-sync-helper.sh` — no new dependency.

## CI/CD consequence audit

| Aim | Current | After fix | Risk |
|---|---|---|---|
| Close parent-tasks with all children closed | Only if body has `#NNN` | Any parent with ≥2 closed sub-issues OR ≥2 closed `#NNN` body refs | None — strictly more permissive, both signals still require ALL-closed |
| Min 2 children safeguard | Enforced | Enforced on whichever source wins | None |
| Max 5 closes per cycle | Enforced | Enforced | None |
| Rejection-label skip | Enforced (implicit via body-regex `continue`) | Explicit parity in the graph path | None |
| GraphQL rate-limits | N/A | Adds 1 query per open parent-task per cycle | Low — parent-task count is bounded (<20 typical); fall-back is safe |
| Errors on GraphQL failure | N/A | Silent fallback to body regex | None — matches existing error-tolerance pattern |
| Test coverage | None for this function | New unit test covers 4 scenarios | Improvement |

## Tier checklist

- [x] `tier:standard` — bug-fix with non-trivial logic branch, ~50 LOC
  in helper + ~80 LOC test + 2 files
- [x] Estimate ~45min including tests and verification
