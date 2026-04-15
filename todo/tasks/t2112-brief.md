<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2112: feat(pulse): reconcile pass for labelless aidevops-shaped issues

## Origin

- **Created:** 2026-04-15
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (operator investigated `awardsapp/awardsapp#2395..#2400`)
- **Parent task:** none
- **Conversation context:** Six child issues on awardsapp (`t325.2` through `t325.7`) were created with aidevops-shaped bodies (`Brief:` + `## Files` + `## Verification`) but zero labels — no `origin:*`, no `tier:*`, no tag labels, no parent-child link to `#2385`. Investigation confirmed they bypassed `issue-sync-helper.sh` entirely (no "Synced from TODO.md" footer, no signature footer, no matching `TODO.md` entry). Almost certainly a hand-crafted `gh issue create` call by alex's AI session. Alex's parent `#2385` went through the proper sync path and is correctly labelled — only the children are unblessed. Under the current framework, the pulse's reconcile passes (`normalize_active_issue_assignments`, `close_issues_with_merged_prs`, `reconcile_stale_done_issues`) never look at labelless issues and never apply backfill; label application happens only during `cmd_push` (new issue creation) and `cmd_enrich` (keyed on `TODO.md` entries with `ref:GH#NNN`). Anything that bypasses both is permanently invisible to the enrichment pipeline.

## What

Add a new reconcile pass `reconcile_labelless_aidevops_issues` to `.agents/scripts/pulse-issue-reconcile.sh` that:

1. Scans each `pulse:true` repo for open issues with title matching `^t[0-9]+(\.[0-9]+)*: ` OR `^GH#[0-9]+: ` (the aidevops title shape).
2. Filters to issues that have ZERO labels in the aidevops namespaces — no `origin:*`, no `tier:*`, no `status:*`. (Having *some* tag-derived labels but missing tier/origin is also caught.)
3. For each candidate, attempts deterministic backfill in this order:
   a. **`origin:worker` / `origin:interactive`** — pick `origin:worker` for labelless issues (conservative default: if the creator was interactive they would have used the wrapper; labelless almost always = automation bypass). This choice is logged.
   b. **`tier:standard`** — the safe default tier per `reference/task-taxonomy.md` "Default to `tier:standard` when uncertain".
   c. **Tag-derived labels from body** — grep the issue body for `#([a-z][a-z0-9-]{2,})` hashtags and apply them via `ensure_labels_exist` + `gh issue edit --add-label`.
   d. **Sub-issue link from body `Parent: tNNN`** — delegate to the new `issue-sync-helper.sh backfill-sub-issues` command from t2114.
4. Posts a one-time mentorship comment (idempotent, guarded by an HTML sentinel marker `<!-- aidevops:labelless-backfill -->`) linking the operator to the `gh_create_issue` wrapper rule in `prompts/build.txt` "Origin labelling (MANDATORY)".

Hard cap: 10 issues per repo per pulse cycle.

## Why

The framework currently has three ways to create a GitHub issue:

- `issue-sync-helper.sh cmd_push` — labels applied, sync footer written, sub-issues wired. Good.
- `claim-task-id.sh --with-issue` → `gh_create_issue` wrapper — labels applied via `session_origin_label` + `_gh_auto_link_sub_issue`. Good.
- Bare `gh issue create` — zero labels, zero wiring. Invisible to reconcile. Bad.

The bare path exists in several places in the framework itself (14+ scripts per t2113's discovery) and in ad-hoc AI sessions. t2113 prevents new instances; t2112 heals existing ones so the pulse is self-repairing instead of requiring a human to notice six unlabelled issues on a third-party repo.

The comment-and-label approach is better than "auto-fix silently" because: (1) a labelless issue may be a test or genuine manual experiment, (2) the operator needs to know their workflow bypassed the wrapper, (3) applying labels without posting the comment means the bypass keeps happening.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify — **false**, this touches 3 files (`pulse-issue-reconcile.sh`, `pulse-wrapper.sh` to wire the call, new test file)
- [x] Every target file under 500 lines — **false**, `pulse-issue-reconcile.sh` is 850 lines
- [x] No judgment calls — the ordering of backfill steps is specified
- [x] Estimate 1h or less — **false**, new function of ~100 lines + wire + test
- [x] 4 or fewer acceptance criteria — **false**, 6 below

**Selected tier:** `tier:standard` — implementation, following the existing `reconcile_stale_done_issues` pattern in the same file. Not thinking-tier (no novel design, pattern exists to model on).

## PR Conventions

Leaf task. PR body will use `Resolves #NNN`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-issue-reconcile.sh` — add `reconcile_labelless_aidevops_issues` function after `reconcile_stale_done_issues`, model on the existing function's structure (per-repo loop, 20-issue cap, log to `$LOGFILE`).
- EDIT: `.agents/scripts/pulse-wrapper.sh` — add call to the new function inside the same block that already calls `reconcile_stale_done_issues` (find via `rg "reconcile_stale_done_issues" .agents/scripts/pulse-wrapper.sh`).
- NEW: `.agents/scripts/tests/test-pulse-labelless-reconcile.sh` — unit tests with `gh` stub, exercise the detection query and the backfill actions.

### Implementation Steps

**Step 1 — add `reconcile_labelless_aidevops_issues` function.** Follows the same scaffolding as `reconcile_stale_done_issues`:

- Header doc explaining the scan/backfill/comment flow and the 10-per-repo cap.
- Per-repo loop via `jq -r '.initialized_repos[] | select(.pulse == true ...) | .slug'`.
- `gh issue list --repo "$slug" --state open --json number,title,body,labels --limit 100` then `jq` filter for title-matches-shape AND labels-array-is-empty-or-missing-aidevops-namespaces.
- For each hit:
  - Check for the sentinel marker via `gh issue view --json body,comments` (don't double-comment).
  - Apply `origin:worker` + `tier:standard` via `set_issue_status`-style atomic `gh issue edit --add-label A --add-label B`.
  - Parse `#tag` hashtags from body (regex `#([a-z][a-z0-9-]{2,})` excluding obvious false positives like `#1234` issue refs — already excluded by the anchored regex).
  - Ensure any new tag labels exist via sourcing and calling `ensure_labels_exist` from `issue-sync-helper.sh` (or reuse `gh label create --force`).
  - Call `issue-sync-helper.sh backfill-sub-issues --repo "$slug" --issue "$num"` (the t2114 command; a no-op if no parent-ref in body).
  - Post one-time comment with the sentinel marker; text mentors the operator on the `gh_create_issue` wrapper rule.
- Log per-repo summary to `$LOGFILE` with the reconcile-pass prefix.

**Step 2 — wire into pulse cycle.** Find the block in `pulse-wrapper.sh` that calls `reconcile_stale_done_issues` and add a call to `reconcile_labelless_aidevops_issues` immediately after it, guarded on the same conditions.

**Step 3 — test harness.** Stub `gh` on `PATH` with a shim that:

- Responds to `gh issue list` with canned JSON containing: one labelless aidevops-shaped issue, one labelless non-aidevops issue (ignored), one already-labelled aidevops issue (ignored).
- Records `gh issue edit` / `gh issue comment` calls to a trace file.
- Assert: the labelless aidevops issue triggered `--add-label origin:worker`, `--add-label tier:standard`, and exactly one comment with the sentinel marker.

### Verification

```bash
cd /Users/marcusquinn/Git/aidevops-feature-t2112-pulse-labelless-reconcile-gh-wrapper-sub-issue-body
shellcheck .agents/scripts/pulse-issue-reconcile.sh
bash .agents/scripts/tests/test-pulse-labelless-reconcile.sh
```

## Acceptance Criteria

1. `reconcile_labelless_aidevops_issues` is defined in `pulse-issue-reconcile.sh` and exported through the include-guard block comment.
2. `pulse-wrapper.sh` calls the new function once per cycle in the same block as `reconcile_stale_done_issues`.
3. Labelless issues with aidevops-shaped titles receive `origin:worker` + `tier:standard` labels on the first pass.
4. Tag hashtags from issue body are extracted and applied as labels (via `ensure_labels_exist`).
5. Exactly one mentorship comment is posted per labelless issue; the sentinel marker prevents duplicates on subsequent cycles.
6. Test harness exercises the detect/label/comment flow with a stubbed `gh` and passes.
7. Shellcheck clean on both modified files.
