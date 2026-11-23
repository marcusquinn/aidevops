#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Command reference printed by `full-loop-helper.sh help`. Kept out of the
# orchestrator so its size ratchet tracks behaviour, not help text (GH#39959).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_FULL_LOOP_HELP_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_HELP_LIB_LOADED=1

show_help() {
	cat <<'EOF'
Full Development Loop Orchestrator
Usage: full-loop-helper.sh <command> [options]
Commands:
  start "<prompt>"              Start a new development loop
  resume                        Resume from last phase
  status [--json]               Show observed executor and lifecycle state
  cancel                        Cancel active loop
  logs [N]                      Show last N log lines (default: 50)
  commit-and-pr|create-pr --issue N --message "msg" [--base <parent-branch>]
                                  Stage, commit, rebase, push, create PR, post merge summary
                [--title TEXT]            Set the PR title (default: commit message)
                [--summary TEXT]          Fill the PR Summary section
                [--testing TEXT]          Fill the PR Runtime Testing evidence section
                [--risk-level critical|high|medium|low]
                                          Set the runtime risk classification
                [--testing-level runtime-verified|runtime-pending|self-assessed]
                                          Set the runtime testing evidence level;
                                          runtime-pending (--testing gives the reason)
                                          opens the PR under hold-for-review for a verifier
                [--decisions TEXT]        Record notable decisions in the PR body
                [--regression-evidence TEXT]
                                          Add a ## Regression Evidence rationale (platform
                                          fixes without a test change; checked before push)
                [--label NAME]            Add a PR label (repeatable)
                [--replace-pr N --replacement-reason TEXT]
                                          Audited replacement of an open PR (reason: 20+ characters)
                [--completion-bookkeeping --proof-pr N --task-id tNNN]
                                          Allow audited metadata-only PR for a terminal issue
                [--ready]                 Open the PR non-draft once verification passed
                                          (interactive default is draft; readying later
                                          re-runs every required check, GH#39210)
                [--keep-issue-open]       Link with For #N so merge leaves a long-running
                                          issue open (interactive only, GH#36598)
                [--allow-parent-close]    Permit a closing keyword on a parent-task issue
                                          (verified final phase only, GH#37690)
                [--skip-hooks]             Pass --no-verify to git push (doc-only PRs, GH#20138)
                [--no-rebase]              Explicit recovery mode after a failed/aborted rebase
  pre-merge-gate <PR> [REPO]    Check review bot gate before merge (GH#17541)
  prospective-todo-guard <PR> <REPO> [EXPECTED_HEAD]
                                 Fail closed if merging the PR head into the live base
                                 tip duplicates TODO task IDs or issue refs (GH#38703).
  wait-checks <PR> [options]     Wait with transition-only required-check output
  runtime-pending-notice <PR> [REPO]
                                 Read-only: print JSON for a held runtime-pending PR a verifier
                                 may lift (Pulse routing, GH#39645); exit 1 otherwise.
  verify-runtime <PR> [REPO] --testing "<evidence>" [--dry-run]
                                 Verifier route for a runtime-pending PR (GH#39639), any
                                 author: from a clean checkout of the exact PR head, record
                                 runtime-verified evidence and lift hold-for-review when the
                                 scope recorded for the current hold is runtime-pending only.
                                 A kept hold still records the evidence. Interactive, write+.
  merge <PR> [REPO] [--squash|--merge|--rebase] [--admin] [--auto] [--body-file PATH]
                                 Gate-enforced merge (runs pre-merge-gate first).
                                 --admin / --auto pass through to gh pr merge
                                 for branch-protected personal-account repos (GH#18731).
                                 --body-file passes an exact merge commit body through all
                                 merge transports after validating a readable regular file.
                                 --admin and --auto are mutually exclusive at the
                                 gh CLI level; if both are given, --admin wins and
                                  --auto is dropped (GH#19310).
                [--allow-parent-close]
                                 Refused by default when a closing keyword targets a
                                 parent-task issue (GH#37690); pass only for the
                                 verified final phase.
                [--override-review-bot-gate="REASON"]
                                 Interactive maintainer only (GH#36901): admin-merge
                                 when review-bot-gate is the sole failing required
                                 check and the PR approval verifies. Reason 20+ chars;
                                 audit-logged and recorded on the PR after merge.
  record-no-release <PR> [REPO]  Verify merged evidence and record release:not-requested.
  record-deployment <PR> <RUN_ID> <WORKFLOW.yml> <DEPLOYED_SHA> [REPO]
                                  Verify an existing tagless maintained-app deployment.
  record-included-release <PR> <SOURCE_PR> <TAG> [REPO] [--workflow FILE] [--event EVENT] [--generated-cloudron-catalog]
                                  Verify inclusion in a published non-aidevops release.
                                  --generated-cloudron-catalog re-verifies a catalog-only tag commit.
  record-published-release <PR> <TAG> [REPO] [--workflow FILE] [--event EVENT]
                                   Verify a GitHub release and record release:published.
                                   Defaults to release-event evidence; repository-owned
                                   push/dispatch workflows require an exact workflow identity.
                                   --generated-cloudron-catalog verifies a catalog-only commit,
                                   allowing attested docs-only rebases, with exact-source
                                   image and catalog attestations.
  adopt-merged-receipt <PR> [REPO]
                                 Adopt an externally merged exact-head worktree into cleanup.
  finalize-receipt <PR> [REPO]   Finalize a direct-merge cleanup receipt without local state.
  migrate-repository-receipt <PR> <OLD_REPO> <NEW_REPO>
                                 Migrate cleanup and release identity after a repo rename.
  complete                       Persist CLEANUP_DEFERRED and hand cleanup to a supervisor.
  complete-after-cleanup <PR> <removed-worktree-path> [REPO]
                                 Verify merged, released/deployed, and cleaned evidence.
  help                          Show this help
Options: --max-task-iterations N (50) | --max-preflight-iterations N (5)
  --max-pr-iterations N (20) | --skip-preflight | --skip-postflight
  --skip-runtime-testing | --no-auto-pr | --no-auto-deploy
  --headless | --dry-run | --background
Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
EOF
}
