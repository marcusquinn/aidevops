<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t19126: fix(sync-workflows): create resync PRs ready with allow-auto-merge so green workflow syncs merge without the maintainer

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `sync-workflows draft PR interactive auto-merge` → 0 hits
- [x] Discovery pass: no open issue/PR on sync-workflows draft state; GH#38487 (closed) fixed duplicate daily resync PRs, not draft state
- [x] File refs verified: `.agents/scripts/sync-workflows-helper.sh` `_sync_open_pr`, `_sync_report_identical_pr`; `.agents/scripts/shared-gh-wrappers-create.sh` `_gh_create_pr_should_default_draft`; `.agents/scripts/pulse-merge-author-checks.sh` `_check_interactive_pr_gates`
- [x] Tier: `tier:standard` — bounded, reversible, existing pattern
- [x] Seeded draft PR decision recorded: skipped — implemented interactively

## Origin

- **Created:** 2026-11-19
- **Session:** opencode:interactive-2026-11-19 (pulse/worker throughput mission)
- **Created by:** ai-interactive (unattended mission authorised by maintainer)
- **Conversation context:** Mining `~/.aidevops/logs/pulse.log` for throughput leaks found ~4,000 merge-pass skip lines per day for 12 green `chore: resync framework workflow to aidevops canonical caller` PRs, all draft since 2026-11-07..12, across 12 managed repos.

## What

`aidevops sync-workflows --apply` publishes resync PRs ready for review and labelled `allow-auto-merge`, and promotes an existing draft sync PR it reuses (ready + label). The pulse merge pass then lands green syncs after required checks and the review-bot gate, with no maintainer action.

## Why

`gh_create_pr` defaults interactive-origin PRs to draft unless `AIDEVOPS_PR_CREATE_READY=1` (`shared-gh-wrappers-create.sh` `_gh_create_pr_should_default_draft`). `_check_interactive_pr_gates` skips drafts before any other gate, and unopted `origin:interactive` PRs need a manual merge. So every sync PR waited on the maintainer indefinitely, which is the reliance on maintainer instigation the framework exists to remove.

## How (Approach)

Follow the planning PR fallback in `.agents/scripts/shared-todo-commit.sh` `_todo_open_planning_pr`: `AIDEVOPS_PR_CREATE_READY=1 gh_create_pr ... --label allow-auto-merge`, with the label provisioned through `managed_labels_ensure_planning_pr_set`.

### Files to Modify

- `EDIT: .agents/scripts/sync-workflows-helper.sh` — `_sync_open_pr`: create ready with the label (label omitted when provisioning fails); promote reused exact-branch PRs. `_sync_report_identical_pr`: promote reused identical PRs. New `_sync_ensure_auto_merge_label`, `_sync_promote_pr` (best effort; a `hold-for-review` label is a maintainer opt-out and is left untouched).

### Hazards

- Workflow-file PRs need a token with `workflow` scope to merge; the same token already pushed the branch.
- Promotion failures only warn; the sync result is unchanged.

## Acceptance Criteria

- [ ] New sync PRs are created non-draft with `allow-auto-merge`.
- [ ] Re-running `sync-workflows --apply` against an existing draft sync PR marks it ready and adds the label, unless it carries `hold-for-review`.
- [ ] Existing sync suites pass: `test-sync-workflows-helper.sh`, `test-sync-workflows-install-missing.sh`, `test-sync-workflows-mirror-provenance.sh`; ShellCheck clean.
- [ ] The 12 existing draft sync PRs are promoted and the pulse merge pass evaluates them instead of skipping as draft.

## Relevant Files

- `.agents/scripts/sync-workflows-helper.sh` — `_sync_open_pr`, `_sync_report_identical_pr`
- `.agents/scripts/shared-todo-commit.sh` — `_todo_open_planning_pr` (reference pattern)
- `.agents/scripts/pulse-merge-author-checks.sh` — `_check_interactive_pr_gates`, `_interactive_pr_auto_merge_allowed`
