<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2073: Canonicalise `tier:thinking` as the opus tier label — rename `tier:reasoning` across the framework

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** Both `tier:thinking` and `tier:reasoning` exist as GitHub labels on the aidevops repo, both described as "Route to opus-tier model for dispatch", both with the same colour `#7057FF`. The framework references `tier:reasoning` **92 times across 15+ files** (docs, scripts, tests, templates) and `tier:thinking` in a smaller number of places. User direction 2026-04-14: **`tier:thinking` is the canonical opus label going forward** — rename everywhere and delete the duplicate.

## What

Make `tier:thinking` the single canonical label name for the opus dispatch tier. All references to `tier:reasoning` in framework code, docs, templates, tests, and helper scripts migrate to `tier:thinking`. The `tier:reasoning` GitHub label is deleted (or aliased if deletion would orphan historical issues — see Implementation Steps §4).

After this change:

- `rg "tier:reasoning" .agents/` returns zero hits
- The `tier:thinking` label remains; `tier:reasoning` is deleted from the repo
- `gh label list --repo marcusquinn/aidevops` shows only one opus-tier label
- Dispatch routing, cascade logic, and issue creation all use `tier:thinking`

## Why

- **Two labels for the same thing is a silent footgun.** Workers reading a task that's labelled `tier:reasoning` can't distinguish it from one labelled `tier:thinking`, and the cascade / routing logic has to special-case both. Every place that checks `has_label "tier:reasoning"` is a place that might silently mismatch a `tier:thinking` label.
- **User direction is unambiguous:** `tier:thinking` is the canonical name because it pairs naturally with `tier:standard` / `tier:simple` (all three are present-participle adjectives describing the cognitive work, not the cognitive machinery). `reasoning` is a noun; `thinking` is an adjective. The three-label set is consistent only with `thinking`.
- **The C→A quality campaign will file 10 tasks with `tier:thinking`** (t2064–t2072). Having two labels means these tasks will be visually inconsistent with the 92 existing `tier:reasoning` references. Unifying now avoids the inconsistency.
- **Follow-up saves compound future cost.** Every week the framework accumulates more `tier:reasoning` references; the rename gets harder with each PR that adds one.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? No — **15+ files, 92 matches**
- [ ] Complete code blocks for every edit? Could be mechanical `sed`, BUT tests + dispatch logic need careful handling
- [ ] No judgment or design decisions? No — label deletion strategy, historical issue handling, cascade rules

**Selected tier:** `tier:thinking`

**Tier rationale:** User directive: all new tasks in this batch go at `tier:thinking`. Also justified on merits: the rename touches `pulse-dispatch-core.sh`, `pulse-model-routing.sh`, `worker-lifecycle-common.sh`, `test-label-invariants.sh`, `test-tier-label-dedup.sh` — any silent mismatch between a test's expectation and the new label name breaks dispatch silently, and silent dispatch breakage is the worst kind. Careful worker needed.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Full inventory — every reference
rg "tier:reasoning" .agents/ -c | sort -t: -k2 -rn

# 2. Expected total (time of filing):
#    .agents/scripts/tests/test-tier-label-dedup.sh:12
#    .agents/reference/task-taxonomy.md:12
#    .agents/scripts/worker-lifecycle-common.sh:7
#    .agents/scripts/pulse-dispatch-core.sh:6
#    .agents/templates/brief-template.md:5
#    .agents/scripts/tests/test-label-invariants.sh:4
#    .agents/scripts/tests/test-cost-circuit-breaker.sh:4
#    .agents/scripts/pulse-simplification.sh:3
#    .agents/workflows/triage-review.md:2
#    .agents/workflows/brief.md:2
#    .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh:2
#    .agents/scripts/tests/test-issue-sync-tier-extraction.sh:2
#    .agents/scripts/pulse-wrapper.sh:2
#    .agents/scripts/pulse-model-routing.sh:2
#    (and more — total ~92)

# 3. Current label state on GitHub
gh label list --repo marcusquinn/aidevops --search "tier:"
#    tier:thinking    Route to opus-tier model for dispatch
#    tier:reasoning   Route to opus-tier model for dispatch
#    tier:standard    Auto-created from TODO.md tag
#    tier:simple      Auto-created from TODO.md tag
```

### Files to Modify

- `EDIT: all files in the inventory above (15+ files, 92 occurrences)`
- `EDIT: .agents/AGENTS.md` — the `tier:reasoning` description in the "Briefs, Tiers, and Dispatchability" section
- `EDIT: .agents/reference/task-taxonomy.md` — update tier definitions, cascade diagram
- `EDIT: .agents/templates/brief-template.md` — tier checklist wording
- `EDIT: .agents/workflows/brief/tier-reasoning.md` — rename file to `tier-thinking.md`, update all references to the filename
- **GitHub label changes** (executed as part of the PR validation step):
  - Add alias: migrate all open issues from `tier:reasoning` to `tier:thinking` before deletion
  - Delete `tier:reasoning` label
- `EDIT: any helpers that create the label on setup` (search: `gh label create.*tier:reasoning`)

### Implementation Steps

1. **Inventory.** `rg -l "tier:reasoning" .agents/ > /tmp/reasoning-files.txt`. Review each file to distinguish:
   - Simple string references (safe `sed`)
   - Test assertions that hard-code `tier:reasoning` as the expected value (need careful handling)
   - Historical changelog/memory entries (**leave alone** — those are accurate records of past state)

2. **Define migration rules.**
   - **DO** rename: active code (`pulse-*.sh`, `worker-lifecycle-common.sh`), active tests (`test-*.sh`), templates, docs in `reference/` and `workflows/`, AGENTS.md.
   - **DO NOT** rename: `complexity-thresholds-history.md`, `*CHANGELOG*`, git commit messages, memory-helper entries, archived briefs in `todo/tasks/` that were completed under the old name. These are historical artifacts.

3. **Rename.** `sed -i '' 's/tier:reasoning/tier:thinking/g'` on the active-code set. Manually inspect each test file — tests that dedup tier labels may need both names until migration completes.

4. **Handle the `tier:reasoning` GitHub label:**
   - **Step 4a (before PR merge, may be a pre-merge script step):** list all issues with `tier:reasoning` label: `gh issue list --repo marcusquinn/aidevops --label "tier:reasoning" --state all --limit 1000`
   - **Step 4b:** for each, add `tier:thinking` and remove `tier:reasoning`:

     ```bash
     gh issue list --repo marcusquinn/aidevops --label "tier:reasoning" --state open --json number --jq '.[].number' \
       | while read n; do
           gh issue edit "$n" --repo marcusquinn/aidevops --add-label "tier:thinking" --remove-label "tier:reasoning"
         done
     ```

   - **Step 4c:** closed issues — migrate the label too, so historical label searches remain consistent. Use `--state all` above.
   - **Step 4d:** delete the label: `gh label delete "tier:reasoning" --repo marcusquinn/aidevops --yes`

5. **Update `worker-lifecycle-common.sh` and `pulse-model-routing.sh`** — these are the dispatch routing code paths. A bug here silently breaks dispatch. Model on the existing `tier:thinking` code paths (they already exist — the routing already handles both names, we're just dropping one).

6. **Update tests.**
   - `test-tier-label-dedup.sh` (12 matches) — this test specifically covers the dedup case; rewrite to assert the dedup now has only one label (`tier:thinking`).
   - `test-label-invariants.sh`, `test-cost-circuit-breaker.sh`, `test-pulse-wrapper-worker-detection.sh`, `test-issue-sync-tier-extraction.sh` — rename the expected label.

7. **Rename the `tier-reasoning.md` workflow file** to `tier-thinking.md`. Any references to the filename in other docs also get updated.

8. **Update the changelog entry in the PR description** documenting: files changed, GH labels migrated, any issues needing manual review.

### Verification

```bash
# Zero tier:reasoning in active code
rg -l "tier:reasoning" .agents/ | grep -v -E '(CHANGELOG|history|todo/tasks/|memory)' | wc -l
# Expected: 0

# Label dedup
gh label list --repo marcusquinn/aidevops --search "tier:" | awk '{print $1}' | sort
# Expected: tier:simple, tier:standard, tier:thinking (no tier:reasoning)

# Tests pass
.agents/scripts/tests/test-tier-label-dedup.sh
.agents/scripts/tests/test-label-invariants.sh
.agents/scripts/tests/test-cost-circuit-breaker.sh
.agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
.agents/scripts/tests/test-issue-sync-tier-extraction.sh

# Dispatch dry-run still routes opus
# (manual check — run pulse with a tier:thinking-labelled issue in dry-run mode)
```

## Acceptance Criteria

- [ ] `rg "tier:reasoning" .agents/` returns zero hits in active code (historical files allowed)
  ```yaml
  verify:
    method: bash
    run: "test 0 -eq \"$(rg -l 'tier:reasoning' .agents/ 2>/dev/null | grep -v -E '(CHANGELOG|history|todo/tasks/)' | wc -l | tr -d ' ')\""
  ```
- [ ] `gh label list --repo marcusquinn/aidevops` shows no `tier:reasoning` label
- [ ] All previously `tier:reasoning`-labelled issues (open and closed) now carry `tier:thinking` instead
- [ ] `test-tier-label-dedup.sh` passes
- [ ] `test-label-invariants.sh` passes
- [ ] `pulse-model-routing.sh` routes `tier:thinking` to opus (manual smoke check in PR description)
- [ ] Workflow file `tier-reasoning.md` renamed to `tier-thinking.md` with content updated
- [ ] AGENTS.md and task-taxonomy.md updated to describe only `tier:thinking`

## Context & Decisions

- **Why not keep both as aliases?** Aliases compound maintenance cost forever. The rename is cheap now (one PR) and expensive later (every new PR that could reference either name).
- **Why not just delete the label without the rename?** Because 92 references in active code check for `tier:reasoning`; deleting the label would silently break all of them. Rename first, delete last.
- **Historical files are left alone** because they record accurate past state. Rewriting history is a footgun — `git blame` and `grep` for audit trails expect the old string to appear in files that were committed with it.
- **`tier:thinking` wins on naming consistency** with `tier:simple` / `tier:standard` (adjectives describing the cognitive work) and pairs better with user-facing language ("this task needs thinking" vs "this task needs reasoning").

## Relevant Files

Full list from `rg "tier:reasoning" .agents/ -c`:

- `.agents/scripts/tests/test-tier-label-dedup.sh` (12)
- `.agents/reference/task-taxonomy.md` (12)
- `.agents/scripts/worker-lifecycle-common.sh` (7)
- `.agents/scripts/pulse-dispatch-core.sh` (6)
- `.agents/templates/brief-template.md` (5)
- `.agents/scripts/tests/test-label-invariants.sh` (4)
- `.agents/scripts/tests/test-cost-circuit-breaker.sh` (4)
- `.agents/scripts/pulse-simplification.sh` (3)
- `.agents/workflows/triage-review.md` (2)
- `.agents/workflows/brief.md` (2)
- `.agents/scripts/tests/test-pulse-wrapper-worker-detection.sh` (2)
- `.agents/scripts/tests/test-issue-sync-tier-extraction.sh` (2)
- `.agents/scripts/pulse-wrapper.sh` (2)
- `.agents/scripts/pulse-model-routing.sh` (2)
- `.agents/workflows/review-issue-pr.md` (1)
- … and the rest of the ~92 matches

## Dependencies

- **Blocked by:** none — can ship standalone
- **Blocks:** t2066 (the sweep rewire assumes `tier:thinking` is canonical) — can be completed in parallel, but t2073 should land first
- **External:** `gh` auth with label-delete permission (already standard for repo owner)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Full inventory + distinguishing active vs historical |
| Implementation | 2.5h | Rename sweep + test updates + workflow file rename |
| GH label migration | 30m | Script the open+closed issue relabelling |
| Testing | 1h | Run all tier-related tests, dispatch smoke |
| **Total** | **~4.5h** | |
