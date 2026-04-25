---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2838: Periodic parent-task sub-issue backfill in pulse + `--parent-issue` flag on claim-task-id

## Pre-flight

- [x] Memory recall: `parent task sub-issue relationship GitHub` / `pulse cycle backfill rate limit sub-issue` → 0 / 0 hits — no relevant prior lessons; t2114, t2404, t2738 are the relevant prior PRs (already merged, infrastructure exists)
- [x] Discovery pass: 0 in-flight PRs touching pulse-issue-reconcile.sh / claim-task-id.sh / claim-task-id-issue.sh on this scope; recent commits (GH#20872, GH#20871) on adjacent parent-tracking but non-conflicting
- [x] File refs verified: `pulse-issue-reconcile.sh:2199`, `claim-task-id.sh:218`, `claim-task-id-issue.sh:331`, `issue-sync-relationships.sh:937` all present at HEAD
- [x] Tier: `tier:standard` — multi-file change with new flag plumbing, new pulse stage, and tests; not a 2-file mechanical replacement

## Origin

- **Created:** 2026-04-25
- **Session:** opencode:feature/t2838-parent-backfill
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** User observed that GitHub parent issues are not consistently using the sub-issue relationship field. Investigation showed infrastructure (`_gh_auto_link_sub_issue` wrapper, `cmd_backfill_sub_issues`, `cmd_relationships`) exists but two gaps remain: (1) the repo-wide backfill is on-demand only, not scheduled in pulse cycles, and (2) `claim-task-id.sh` has no first-class flag to declare a parent issue at creation time, so workers manually filing phase children outside `shared-phase-filing.sh` produce orphaned children.

## What

Two cooperating fixes that make GitHub parent-task issues consistently use the sub-issue relationship field:

**A. Periodic parent-task sub-issue backfill in pulse cycles.** A new code path in the pulse's reconcile pass that, for every open `parent-task` issue per pulse cycle (gated by interval), calls the existing `cmd_backfill_sub_issues --issue N` command. The parent-side detection branch already extracts children from `## Children`, `## Sub-issues`, `## Phases` body sections and links them via the `addSubIssue` GraphQL mutation. Idempotent — `_gh_add_sub_issue` suppresses duplicate-relationship errors.

**B. `--parent-issue N` flag on `claim-task-id.sh`.** Declares the parent issue at child creation time. Two effects: (1) the composed body gets a `Parent: #N` line at the end (visible to humans, picked up by the `_gh_auto_link_sub_issue` wrapper for the rare path that uses it), and (2) an explicit `addSubIssue` mutation runs after the bare-fallback issue creation path, since that path uses raw `gh "${gh_args[@]}"` and bypasses the wrapper.

Empirical confirmation of the gap before this fix: parent #20518 (the only org-wide open `parent-task`) has 0 sub-issues despite being a held decomposition tracker.

## Why

User-visible symptom: opening a parent-task issue in GitHub's UI shows no children in the "Tracked by" / "Sub-issues" panel even when the body contains a fully-populated `## Children` section. The relationship field is the canonical GitHub mechanism for parent-child issue linkage; without it, GitHub Projects, the issue sidebar, and external tooling (notification rules, GraphQL queries) cannot traverse the hierarchy.

The infrastructure is 95% there — three linking paths (wrapper at create, TODO-driven, GH-state backfill) — but the only path that handles the umbrella case ("parent body lists children, but children were filed without `Parent:` in their body") is on-demand. Wired into the pulse, it self-heals continuously.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** 4 files modified across two helper paths + new pulse stage + 2 new test files. Disqualifiers: cross-module (claim-task-id flow + pulse cycle), error/fallback logic (rate-limit gating, idempotency), >4 acceptance criteria. Not `tier:thinking` because the pattern is well-established (mirrors t2404 parent-side detection and t2114 backfill).

## How

### Files Scope

- `.agents/scripts/claim-task-id.sh`
- `.agents/scripts/claim-task-id-issue.sh`
- `.agents/scripts/pulse-issue-reconcile.sh`
- `.agents/scripts/tests/test-claim-parent-issue.sh`
- `.agents/scripts/tests/test-pulse-parent-backfill.sh`
- `.agents/templates/brief-template.md`
- `todo/tasks/t2838-brief.md`
- `TODO.md`

### Complexity Impact

`parse_args` in `claim-task-id.sh` currently 100 lines (at threshold). Adding `--parent-issue` case adds 4 lines → 104. `create_github_issue` currently 143 lines (already over); adding parent-link call adds ~5 lines → 148. Both bumps are justified additive flag wiring; PR will carry `complexity-bump-ok` label with `## Complexity Bump Justification` section. Refactoring `parse_args` (one large case statement) is out of scope for a 3-line bump.

`reconcile_issues_single_pass` in `pulse-issue-reconcile.sh` currently ~140 lines; adding the backfill stage adds ~12 lines → ~152. Same bump pattern.

### Implementation pattern

**Plan B — `--parent-issue N` flag:** Model on the `--no-blocked-by` flag pattern at `claim-task-id.sh:252` (option parser) and `_link_parent_issue_post_create` modeled on `_gh_add_sub_issue` from `issue-sync-relationships.sh:153`. Inject `Parent: #N` at the end of the composed body in `_compose_issue_body` (claim-task-id-issue.sh:331) so the bare path produces a wrapper-detectable body. After successful issue creation in `create_github_issue`, call the new `_link_parent_issue_post_create` helper which resolves both node IDs and runs the `addSubIssue` mutation directly — independent of body parsing.

**Plan A — periodic pulse backfill:** Model on the `_action_lia_single` stage 5 backfill call at `pulse-issue-reconcile.sh:2161` which already invokes `issue-sync-helper.sh backfill-sub-issues --issue N`. Add a stage in the single-pass iterator's parent-task block (after `_action_cpt_single`) gated by a global cycle-level flag `_parent_backfill_this_cycle` set once per orchestrator entry based on a state file timestamp comparison.

### Verification

```bash
# Unit tests
bash .agents/scripts/tests/test-claim-parent-issue.sh
bash .agents/scripts/tests/test-pulse-parent-backfill.sh

# Existing tests still pass
bash .agents/scripts/tests/test-backfill-sub-issues.sh
bash .agents/scripts/tests/test-gh-auto-link-parent-line.sh
bash .agents/scripts/tests/test-issue-reconcile.sh

# Lint
shellcheck .agents/scripts/claim-task-id.sh .agents/scripts/claim-task-id-issue.sh .agents/scripts/pulse-issue-reconcile.sh

# Manual smoke (after merge): file a child via claim-task-id with --parent-issue,
# verify GitHub sub-issue panel shows the link
```

## Acceptance

- `--parent-issue N` accepted by `claim-task-id.sh`, validated as positive integer, surfaced in `--help` output
- Composed issue body contains a `Parent: #N` line at the end when `--parent-issue` is set
- After bare-fallback issue creation, the child is linked as a sub-issue of the declared parent (verifiable via `gh api graphql` query on `subIssues`)
- Pulse cycle gates the parent-task backfill on `AIDEVOPS_PARENT_BACKFILL_INTERVAL_SECS` (default 3600 = 1h); first cycle after interval calls `backfill-sub-issues --issue N` for every open parent-task issue, subsequent cycles skip until interval lapses again
- Both new test files pass; no regression in existing tests for `_gh_auto_link_sub_issue`, `cmd_backfill_sub_issues`, or pulse reconcile

## PR Conventions

Leaf task — PR uses `Resolves #20888` as normal.

## Session Origin

Filed during interactive session diagnosing why parent-task issues weren't using GitHub's sub-issue relationship field. Empirical confirmation: `gh api graphql` on parent #20518 returned `subIssues: { nodes: [] }`.
Parent: none (leaf task).
