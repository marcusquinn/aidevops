#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full Development Loop Orchestrator -- state management for AI-driven dev workflow.
# =============================================================================
# Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
# Decision logic lives in full-loop.md; this script handles state + background exec.
#
# Sub-libraries (sourced below):
#   full-loop-helper-state.sh   -- state persistence, phase emitters, lifecycle commands
#   full-loop-helper-risk.sh    -- PR runtime-risk and testing-evidence classification
#   full-loop-helper-commit.sh  -- staging, validators, PR creation, merge summary
#   full-loop-helper-merge.sh   -- merge execution, admin fallback, resource unlocking
#   full-loop-helper-help.sh    -- `help` command reference (show_help)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# Keep nested gh calls on the same helper generation as this orchestrator.
# In a linked worktree, an inherited runtime-bundle shim can otherwise win
# before the worktree's sibling shim and mutate merge metadata differently.
if [[ -x "${SCRIPT_DIR}/gh" ]]; then
	case "${PATH:-}" in
	"${SCRIPT_DIR}" | "${SCRIPT_DIR}:"*) ;;
	*) PATH="${SCRIPT_DIR}${PATH:+:${PATH}}" ;;
	esac
	export PATH
else
	printf '[aidevops] full-loop helper: sibling gh shim missing; retaining inherited PATH\n' >&2
fi
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"
# shellcheck source=./dependency-event-reconciler.sh
source "${SCRIPT_DIR}/dependency-event-reconciler.sh"

readonly SCRIPT_DIR
readonly STATE_DIR=".agents/loop-state"
readonly STATE_FILE="${STATE_DIR}/full-loop.local.state"
readonly DEFAULT_MAX_TASK_ITERATIONS=50 DEFAULT_MAX_PREFLIGHT_ITERATIONS=5 DEFAULT_MAX_PR_ITERATIONS=20
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

HEADLESS="${FULL_LOOP_HEADLESS:-false}"
_FG_PID_FILE=""

is_headless() { [[ "$HEADLESS" == "true" ]]; }

print_phase() {
	printf "\n${BOLD}${CYAN}=== Phase: %s ===${NC}\n${CYAN}%s${NC}\n\n" "$1" "$2"
}

# --- Source sub-libraries ---

# shellcheck source=./full-loop-helper-state.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state.sh"

# shellcheck source=./full-loop-helper-risk.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-risk.sh"

# shellcheck source=./full-loop-helper-commit.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-commit.sh"
# shellcheck source=./issue-open-pr-guard.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/issue-open-pr-guard.sh"

# shellcheck source=./full-loop-helper-merge.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-merge.sh"

# shellcheck source=./full-loop-helper-verify-runtime.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-verify-runtime.sh"

# shellcheck source=./macos-local-checks.sh
source "${SCRIPT_DIR}/macos-local-checks.sh"

# shellcheck source=./full-loop-helper-help.sh
source "${SCRIPT_DIR}/full-loop-helper-help.sh"

# --- cmd_commit_and_pr ---
# The phase helpers below use Bash's dynamic scope to share the orchestrator's
# local metadata. Keep them in this file so the workflow has a single owner.
#
# Commit-and-PR: stage, commit, rebase, push, create PR, post merge summary.
# Collapses full-loop steps 4.1-4.2.1 into a single deterministic call.
# Workers and interactive sessions both use this — no parallel logic.
#
# Usage: full-loop-helper.sh commit-and-pr|create-pr --issue <N> --message <msg> [--title <title>] [--summary <what>] [--testing <how>] [--risk-level <level>] [--testing-level <level>] [--decisions <notes>] [--regression-evidence <why>] [--label <label>...] [--completion-bookkeeping --proof-pr <N> --task-id <tNNN>] [--allow-parent-close] [--keep-issue-open] [--ready] [--skip-hooks] [--no-rebase] [--base <branch>]
# --ready: create the PR non-draft (verified implementation intent); default interactive PRs are draft.
# --base <branch>: stacked PR. Rebase onto origin/<branch> and open the PR against it
#   (branch must exist on origin, differ from the current branch, and be an open PR head;
#   workers fail closed otherwise). Default: pr_base_branch config, else the remote default (GH#39167).
# Exit codes: 0 = PR created (prints PR number to stdout), 1 = failure
# --allow-parent-close: skip the parent-task keyword guard (final-phase PR only)
# --keep-issue-open: interactive only; link with `For #N` (no closing keyword) and skip the
#   issue status:in-review handoff so a long-running issue stays open after merge (GH#36598).
# --skip-hooks: pass --no-verify to git push (bypasses pre-push hooks). Use for doc-only PRs
#   after manually verifying no secrets/private-slugs in the diff. See GH#20138.
# --no-rebase: explicit recovery mode after a failed rebase; requires clean git state and commits ahead of the detected base branch.
# --replace-pr <N> --replacement-reason <text>: explicit audited replacement of open PR <N>.
#   Ancestry (PR <N>'s head reachable from HEAD) is proven before WIP finalization/rebase
#   rewrite history, since both discard that ancestry (GH#33253). Works with or without --no-rebase.
#
# On rebase conflict: returns 1 with instructions. Caller must resolve and retry.
# On push failure: returns 1. Caller should check remote state.
# On PR creation failure: returns 1. Changes are committed and pushed — caller
# can create the PR manually.
cmd_commit_and_pr() {
	local issue_number="" commit_message="" pr_title="" summary_what="" summary_testing="" summary_decisions=""
	local runtime_risk="" testing_level="" pr_metadata_overrides="" summary_regression=""
	local completion_bookkeeping=0 bookkeeping_proof_pr="" bookkeeping_task_id=""
	local replacement_pr="" replacement_reason=""
	local -a extra_labels=()
	local allow_parent_close=0 keep_issue_open=0 create_ready=0 skip_hooks=0 skip_rebase=0 stack_base_arg=""

	_parse_commit_and_pr_args "$@" || return 1
	_validate_keep_issue_open_request || return 1

	# Missing inputs report usage (GH#39377); the title is then rejected before any
	# repo read, staging, rebase or publication (GH#33949).
	_require_commit_and_pr_inputs "$issue_number" "$commit_message" || return 1
	_commit_and_pr_validate_title || return 1
	local repo="" branch="" base_branch="" base_ref=""
	_validate_commit_and_pr_inputs "$issue_number" "$commit_message" || return 1
	if [[ -n "$replacement_pr" || -n "$replacement_reason" ]]; then
		if [[ ! "$replacement_pr" =~ ^[1-9][0-9]*$ || ${#replacement_reason} -lt 20 ]]; then
			print_error "Explicit replacement requires --replace-pr N and --replacement-reason with at least 20 characters"
			return 1
		fi
	fi
	_validate_explicit_pr_metadata "$runtime_risk" "$testing_level" || return 1
	_validate_stack_base "$stack_base_arg" "$branch" "$repo" || return 1
	_validate_completion_bookkeeping_request "$completion_bookkeeping" "$bookkeeping_proof_pr" \
		"$bookkeeping_task_id" "$allow_parent_close" "$repo" \
		"${extra_labels[@]+"${extra_labels[@]}"}" || return 1
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	base_ref="origin/${base_branch}"
	local parent_issue=0
	_issue_has_parent_task_label "$issue_number" "$repo" && parent_issue=1
	if [[ "$parent_issue" -eq 0 ]]; then
		local initial_open_pr_guard_rc=0
		issue_open_pr_guard_check "$issue_number" "$repo" "$branch" \
			"$replacement_pr" "$replacement_reason" 0 || initial_open_pr_guard_rc=$?
		case "$initial_open_pr_guard_rc" in
		0) ;;
		3) _inherit_pr_runtime_metadata "$ISSUE_OPEN_PR_NUMBER" "$repo" || return 1 ;;
		1)
			print_error "Issue #${issue_number} already has open PR #${ISSUE_OPEN_PR_NUMBER}; continue branch '${ISSUE_OPEN_PR_HEAD_REF}' or use an explicit audited replacement"
			return 1
			;;
		*)
			print_error "Open-PR linkage evidence is unavailable or ambiguous for issue #${issue_number}; refusing PR workflow"
			return 1
			;;
		esac
	fi
	_validate_pending_runtime_metadata "$runtime_risk" "$testing_level" \
		"$summary_testing" "$summary_what" "$base_ref" || return 1

	_stage_and_commit "$commit_message" || return 1
	# GH#33253: prove an explicit --replace-pr's ancestry now, before WIP
	# finalization or rebase rewrite HEAD and defeat the final guard's ancestry
	# check below. REPLACEMENT_PR_ANCESTRY_VALIDATED is consulted at that call.
	_validate_replacement_pr_ancestry "$issue_number" "$repo" "$branch" \
		"$replacement_pr" "$replacement_reason" || return 1
	local replacement_pr_head_sha="${ISSUE_OPEN_PR_HEAD_SHA:-}"
	# GH#34233: prove a seed draft's head is in this branch before WIP
	# finalization squashes it; the proven SHA authorizes closing the seed.
	local seed_proof=""
	seed_proof=$("${SCRIPT_DIR}/seed-pr-helper.sh" proof "$issue_number" --repo "$repo" 2>/dev/null) || seed_proof=""
	# GH#27902: WIP commits are durable checkpoints, not publishable history.
	# If any exist on the branch, replace the branch range with one final commit
	# before validators inspect HEAD and before rebase/push can publish it.
	_finalize_wip_history "$commit_message" || return 1
	_commit_and_pr_privacy_scan || return 1
	# t2842: project-aware validators (auto-fix format/lint, fail-closed typecheck).
	# Inserted between commit and push so amends apply to the same commit
	# the worker just made, and so failures abort BEFORE we push broken code.
	_run_project_validators "$skip_hooks" || return 1
	_rebase_for_push "$branch" "$skip_rebase" || return 1
	local files_changed=""
	local closing_keyword="Resolves"
	local planning_only=0
	local pr_body=""
	local origin_label=""
	local pr_only_scope=0
	_commit_and_pr_prepare_metadata || return 1
	_commit_and_pr_check_readiness || return 1
	local pr_number=""
	_commit_and_pr_publish || return 1
	if [[ -n "$seed_proof" && -n "$pr_number" ]]; then
		"${SCRIPT_DIR}/seed-pr-helper.sh" supersede "$issue_number" "$pr_number" --repo "$repo" \
			--seed-oid "${seed_proof##*$'\t'}" >&2 ||
			print_warning "Seed PR for #${issue_number} was not closed; close it after verifying PR #${pr_number} contains it"
	fi

	# Output PR number for caller to pass to `merge`
	printf '%s\n' "$pr_number"
	return 0
}

# Compose (when absent) and reject an invalid final title before staging,
# rebasing or publishing anything (GH#33949). Uses caller-scoped $pr_title,
# $issue_number and $commit_message from cmd_commit_and_pr.
_commit_and_pr_validate_title() {
	if [[ -z "$pr_title" ]]; then
		pr_title="$(_compose_pr_title "$issue_number" "$commit_message")" || return 1
	fi
	if ! _full_loop_valid_squash_subject "$pr_title"; then
		print_error "PR title is not a valid squash subject; refusing commit-and-pr"
		print_error "Use GH#N: ..., tNNN: ..., or conventional type(scope): ...; extra issues belong in the body as Resolves #N."
		return 1
	fi
	return 0
}

# Only non-empty diffs confined to planning paths qualify.
# GH#36002: planning artifacts are TODO.md and markdown under todo/. Other
# files a repository keeps under todo/ (JSON/JSONL worklogs, specs, scripts)
# are deliverables, so their PRs keep the default closing keyword.
_diff_is_planning_only() {
	local base_ref="$1"
	local paths="" path="" comparison_base=""
	comparison_base=$(_pending_runtime_comparison_base "$base_ref") || return 1
	# Classify both sides of renames so a data source cannot disappear behind
	# a planning-only destination.
	paths=$(git diff --no-renames --name-only "$comparison_base" HEAD) || return 1
	[[ -n "$paths" ]] || return 1
	while IFS= read -r path; do
		case "$path" in
		TODO.md | todo/*.md) ;;
		*) return 1 ;;
		esac
	done <<<"$paths"
	return 0
}

# Validate an explicit task prefix before publishing (GH#36016). TODO proof
# must match both the task and issue; an issue title is an alternative proof.
_validate_explicit_pr_title() {
	local issue_number="$1" title="$2" repo="$3" todo_file="${4:-}"
	if [[ ! "$title" =~ ^t([0-9]+): ]]; then
		printf '%s\n' "$title"
		return 0
	fi
	local task_number="${BASH_REMATCH[1]}" repo_root="" issue_title=""
	if [[ -z "$todo_file" ]]; then
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
		[[ -z "$repo_root" ]] || todo_file="${repo_root}/TODO.md"
	fi
	if [[ -n "$issue_number" && -f "$todo_file" ]] &&
		grep -qE "^- \[[ x]\] t${task_number} .*ref:GH#${issue_number}([^0-9]|\$)" "$todo_file"; then
		printf '%s\n' "$title"
		return 0
	fi
	if [[ -n "$issue_number" ]]; then
		if ! issue_title=$(gh issue view "$issue_number" --repo "$repo" --json title --jq '.title' 2>/dev/null); then
			print_error "Unable to verify issue #${issue_number} title; refusing explicit task title validation." >&2
			return 1
		fi
	fi
	if [[ "$issue_title" =~ (^|[^a-zA-Z0-9_])t${task_number}([^a-zA-Z0-9_]|$) ]]; then
		printf '%s\n' "$title"
		return 0
	fi
	local derived_prefix=""
	derived_prefix=$(_derive_pr_title_prefix "$issue_number" "$todo_file")
	if [[ "$task_number" == "$issue_number" ]]; then
		print_warning "Explicit PR title uses issue #${issue_number} as an unclaimed task ID; using '${derived_prefix}:' instead." >&2
		printf '%s:%s\n' "$derived_prefix" "${title#*:}"
		return 0
	fi
	print_error "Explicit PR title task t${task_number} is not linked to issue #${issue_number}. Use '--title ${derived_prefix}: ...' or establish the task's TODO/issue-title linkage before pushing." >&2
	return 1
}

# Derive final-diff metadata after rebase but before any remote mutation.
# Invalid risk/testing evidence must not leave a pushed orphan branch.
_commit_and_pr_prepare_metadata() {
	local comparison_base=""
	if [[ "$completion_bookkeeping" -eq 1 ]]; then
		closing_keyword="For"
	fi
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	base_ref="origin/${base_branch}"
	# Freeze the comparison once: upstream movement is not part of this PR.
	comparison_base=$(_pending_runtime_comparison_base "$base_ref") || return 1
	local macos_evidence=""
	macos_evidence=$(macos_checks_evidence "$comparison_base") || return 1
	if [[ -n "$macos_evidence" ]]; then
		summary_testing="${summary_testing}${summary_testing:+; }${macos_evidence}"
	fi
	# GH#40064: a local validator timeout deferred to a required CI check is
	# disclosed with the evidence it replaced; that check still gates merge.
	if [[ -n "${FULL_LOOP_VALIDATOR_DEFERRALS:-}" ]]; then
		summary_testing="${summary_testing}${summary_testing:+; }local validators deferred to required CI after a host-load timeout: ${FULL_LOOP_VALIDATOR_DEFERRALS}"
	fi
	files_changed=$(git diff --name-only "$comparison_base" HEAD) || return 1
	files_changed=$(printf '%s' "$files_changed" | tr '\n' ',' | sed 's/,/, /g')
	pr_body=$(_build_pr_body "$issue_number" "$summary_what" "$summary_testing" "$files_changed" "" "$closing_keyword" "$runtime_risk" "$testing_level" "$comparison_base") || return 1

	# Validate explicit titles before push; avoid double-prefixing derived titles.
	if [[ -z "$pr_title" ]]; then
		pr_title="$(_compose_pr_title "$issue_number" "$commit_message")"
	elif [[ "$pr_title" =~ ^t[0-9]+: ]]; then
		pr_title=$(_validate_explicit_pr_title "$issue_number" "$pr_title" "$repo") || return 1
	fi
	# Use the same origin detection as gh_create_pr (GH#21825).
	origin_label=$(session_origin_label)
	local sig_footer="" sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		sig_footer=$("$sig_helper" footer 2>/dev/null || echo "")
	fi
	local worker_closing_check=0
	if [[ "$allow_parent_close" -eq 1 ]]; then
		closing_keyword="Resolves"
	elif [[ "$origin_label" == "origin:worker" && "$completion_bookkeeping" -eq 0 ]]; then
		closing_keyword=$(_review_repair_closing_keyword "$issue_number" "$repo") || return 1
		worker_closing_check=1
	fi
	local parent_for_link=0
	if [[ "$allow_parent_close" -eq 0 ]] && _issue_has_parent_task_label "$issue_number" "$repo"; then
		closing_keyword="For"
		parent_for_link=1
		print_info "Issue #${issue_number} has parent-task label — using 'For' keyword (t2242)"
	fi
	if [[ "$allow_parent_close" -eq 0 ]] && _diff_is_planning_only "$comparison_base"; then
		closing_keyword="For"
		planning_only=1
		print_info "Planning-only diff — using 'For' keyword; issue stays dispatchable"
	fi
	# GH#36922: guarded worker merges accept `For #parent` only for planning
	# checkpoints (TODO.md/todo markdown). Surface the contract at PR creation
	# instead of leaving a later opaque merge refusal.
	if [[ "$parent_for_link" -eq 1 && "$planning_only" -eq 0 ]]; then
		print_warning "Parent-task #${issue_number} link with non-planning changes: guarded worker merge accepts 'For #${issue_number}' only for TODO.md/todo markdown checkpoints; link a child phase issue or use --allow-parent-close for the final phase"
	fi
	if [[ "$keep_issue_open" -eq 1 ]]; then
		closing_keyword="For"
		print_info "--keep-issue-open — using 'For' keyword; issue #${issue_number} stays open after merge"
	fi
	# GH#38823: evaluate the FINAL keyword (after planning/parent/keep-open
	# overrides). A worker summary declaring `For/Ref #<this issue>` contradicts
	# a closing PR; refuse instead of silently closing the issue.
	if [[ "$worker_closing_check" -eq 1 && "$closing_keyword" != "For" && "$allow_parent_close" -eq 0 ]] &&
		! _summary_declares_partial_self "$issue_number" "$summary_what" "$summary_testing" "${summary_decisions:-}"; then
		print_error "Summary references 'For/Ref #${issue_number}' (partial PR) but commit-and-pr would emit a closing keyword and close the issue. Remove the self-reference if the work is complete (closure is intended), or finish the remaining criteria; unmet verification must not be lost on merge." >&2
		return 1
	fi
	local replacement_note=""
	if [[ -n "$replacement_pr" ]]; then
		replacement_note="This explicitly justified replacement preserves open PR #${replacement_pr}. Rationale: ${replacement_reason}"
		[[ -n "$replacement_pr_head_sha" ]] && replacement_note="${replacement_note} Verified ancestor before WIP finalization: ${replacement_pr_head_sha}."
	fi
	pr_body=$(_build_pr_body "$issue_number" "$summary_what" "$summary_testing" "$files_changed" "$sig_footer" "$closing_keyword" "$runtime_risk" "$testing_level" "$comparison_base" "$replacement_note" "$summary_decisions" "${summary_regression:-}") || return 1
	_commit_and_pr_platform_evidence_gate "$pr_title" "$pr_body" "$comparison_base" || return 1

	# Parent-task closing keywords are forbidden except for an explicit final phase.
	local keyword_guard="${SCRIPT_DIR}/parent-task-keyword-guard.sh"
	if [[ -x "$keyword_guard" ]]; then
		local tmp_pr_body guard_rc=0
		tmp_pr_body=$(mktemp)
		printf '%s\n' "$pr_body" >"$tmp_pr_body"
		local guard_args=("check-body" "--body-file" "$tmp_pr_body" "--repo" "$repo" "--strict")
		[[ "$allow_parent_close" -eq 1 ]] && guard_args+=("--allow-parent-close")
		"$keyword_guard" "${guard_args[@]}" 2>&1 >&2 || guard_rc=$?
		rm -f "$tmp_pr_body"
		if [[ "$guard_rc" -eq 2 ]]; then
			print_error "Aborting PR creation: parent-task keyword violation (t2046). See error above."
			return 1
		fi
	fi
	return 0
}

_commit_and_pr_check_readiness() {
	# A stale-recovered worker must not create a PR after losing its claim.
	_validate_worker_claim "$issue_number" "$repo" || {
		print_error "Aborting: dispatch claim no longer valid for #${issue_number} (t1955)"
		return 1
	}
	# A closed issue needs explicit, verified completion bookkeeping.
	local _pre_pr_issue_state="" _pre_pr_issue_reason="" _pre_pr_issue_meta=""
	_pre_pr_issue_meta=$(gh issue view "$issue_number" --repo "$repo" \
		--json state,stateReason --jq '[.state, (.stateReason // "")] | @tsv' 2>/dev/null || echo "")
	IFS=$'\t' read -r _pre_pr_issue_state _pre_pr_issue_reason <<<"$_pre_pr_issue_meta"
	if [[ "$_pre_pr_issue_state" == "CLOSED" ]]; then
		if [[ "$completion_bookkeeping" -eq 1 ]]; then
			_validate_closed_issue_completion_bookkeeping "$issue_number" "$repo" \
				"$_pre_pr_issue_reason" "$bookkeeping_proof_pr" "$bookkeeping_task_id" \
				"$base_ref" "$pr_body" || return 1
			if [[ -n "$summary_decisions" ]]; then
				summary_decisions="${summary_decisions}; ${FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT}"
			else
				summary_decisions="$FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT"
			fi
		else
			print_error "Aborting: issue #${issue_number} is already closed — not opening a duplicate PR (t2091)"
			gh_issue_comment "$issue_number" --repo "$repo" \
				--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Worker aborted PR creation: issue #${issue_number} was already closed by the time this session completed implementation. No PR was opened.
<!-- ops:end -->" \
				2>/dev/null || true
			return 1
		fi
	elif [[ "$completion_bookkeeping" -eq 1 ]]; then
		print_error "Completion bookkeeping requires issue #${issue_number} to be verified closed with a terminal reason"
		return 1
	fi
	# GH#34052: resolve trusted PR-only scope before any remote mutation so an
	# unknown scope never publishes a PR that lacks its merge hold.
	local pr_only_rc=0
	_issue_pr_only_contract_state "$issue_number" "$repo" || pr_only_rc=$?
	case "$pr_only_rc" in
	0)
		pr_only_scope=1
		print_info "Issue #${issue_number} has a trusted PR-only completion contract; the PR will carry hold-for-review"
		;;
	1) ;;
	*)
		print_error "Aborting: unable to verify PR-only completion scope for issue #${issue_number}; retry when GitHub reads recover"
		return 1
		;;
	esac
	return 0
}

# GH#34052: a trusted PR-only task ends at a verified ready PR. The live
# hold-for-review label refuses every full-loop, pulse, auto-merge and stuck-PR
# merge transport until a maintainer removes it. Verify the postcondition so a
# partial label write cannot leave the PR mergeable; rerunning commit-and-pr
# continues the same PR and reapplies the hold.
_apply_pr_only_hold() {
	local pr_number="$1"
	local repo="$2"
	local hold_scope="${3:-trusted PR-only scope}"
	local hold_tokens="${4:-}"
	local labels=""
	if ! gh_pr_edit_safe "$pr_number" --repo "$repo" --add-label "hold-for-review" >/dev/null; then
		print_error "Could not apply hold-for-review to PR #${pr_number} (${hold_scope}); rerun commit-and-pr before any merge"
		return 1
	fi
	labels=$(_flm_gh_read gh pr view "$pr_number" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")') || labels=""
	if [[ ",${labels}," != *",hold-for-review,"* ]]; then
		print_error "PR #${pr_number} (${hold_scope}) did not reach the hold-for-review postcondition; rerun commit-and-pr before any merge"
		return 1
	fi
	# GH#39639: record the scope so verify-runtime lifts only runtime-only holds.
	# The label stays the gate: a missing marker keeps the hold, never lifts it.
	if [[ -n "$hold_tokens" ]] && ! _record_hold_scope_marker "$pr_number" "$repo" "$hold_tokens"; then
		print_warning "PR #${pr_number} hold scope (${hold_tokens}) was not recorded; verify-runtime will keep the hold for a maintainer"
	fi
	print_info "PR #${pr_number} held for maintainer review (${hold_scope}); emit POST_PR_HANDOFF instead of merging"
	return 0
}

_commit_and_pr_publish() {
	_push_branch "$branch" "$skip_hooks" "$repo" "$replacement_pr" || return 1
	# GH#33381: a diverged foreign remote branch is preserved and this work is
	# published under a replacement name; every later step uses that exact head.
	branch="${FULL_LOOP_PUSHED_BRANCH:-$branch}"
	local continuation_pr=""
	if [[ "$parent_issue" -eq 0 ]]; then
		local final_open_pr_guard_rc=0
		# WIP finalization/rebase rewrite HEAD; do not repeat a proven ancestry check.
		local final_require_ancestry=1
		[[ "$REPLACEMENT_PR_ANCESTRY_VALIDATED" -eq 1 ]] && final_require_ancestry=0
		issue_open_pr_guard_check "$issue_number" "$repo" "$branch" \
			"$replacement_pr" "$replacement_reason" "$final_require_ancestry" || final_open_pr_guard_rc=$?
		case "$final_open_pr_guard_rc" in
		0) ;;
		3) continuation_pr="$ISSUE_OPEN_PR_NUMBER" ;;
		1)
			print_error "Aborting duplicate PR creation: open PR #${ISSUE_OPEN_PR_NUMBER} remains durable work, or its head is not preserved by this replacement"
			return 1
			;;
		*)
			print_error "Aborting PR creation: final open-PR linkage evidence is unavailable or ambiguous"
			return 1
			;;
		esac
	fi
	# GH#39558: a runtime-pending PR takes the same verified hold as PR-only
	# scope, applied after creation because continued PRs ignore create labels.
	local hold_scope="" hold_tokens=""
	if [[ "$pr_only_scope" -eq 1 ]]; then
		hold_scope="trusted PR-only scope"
		hold_tokens="pr-only"
	fi
	if _pr_body_declares_runtime_pending "$pr_body"; then
		hold_scope="${hold_scope:+${hold_scope}; }runtime verification pending"
		hold_tokens="${hold_tokens:+${hold_tokens},}runtime-pending"
	fi
	pr_number=$(_create_or_continue_pr "$continuation_pr" "$repo" "$pr_title" "$pr_body" \
		"$origin_label" "${extra_labels[@]+"${extra_labels[@]}"}") || {
		# GH#33381: the push already succeeded; the pushed branch is the durable
		# retry state. Rerunning commit-and-pr recommits nothing, re-pushes the
		# same head under a lease, and resumes at PR creation with --head.
		print_warning "LIFECYCLE_STATE=PUSHED_PR_PENDING branch=${branch}"
		printf 'PR_CREATE_NEXT=git checkout %q && full-loop-helper.sh commit-and-pr --issue %q --message %q\n' \
			"$branch" "$issue_number" "$commit_message" >&2
		return 1
	}
	if [[ -n "$hold_scope" ]]; then
		_apply_pr_only_hold "$pr_number" "$repo" "$hold_scope" "$hold_tokens" || return 1
	fi
	local macos_base=""
	macos_base=$(_pending_runtime_comparison_base "$base_ref") || return 1
	macos_checks_route "$macos_base" "$pr_number" "$repo" || return 1
	# Recover from partial GraphQL writes before marking either side in review.
	if [[ "$origin_label" == "origin:worker" ]]; then
		_ensure_worker_pr_linkage "$pr_number" "$repo" "$issue_number" "$pr_body" || return 1
	fi
	_post_merge_summary "$pr_number" "$repo" "$issue_number" "$summary_what" "$files_changed" "$summary_testing" "$summary_decisions" || return 1
	if [[ "$planning_only" -eq 0 && "$keep_issue_open" -eq 0 ]]; then
		_label_issue_in_review "$issue_number" "$repo"
	fi
	_label_pr_in_review "$pr_number" "$repo"
	if is_loop_active; then
		_full_loop_record_phase "pr-review" "$pr_number" || return 1
	fi
	return 0
}

# --- Help & Main ---

cmd_wait_checks() {
	local helper="${SCRIPT_DIR}/gh-checks-wait-helper.sh"
	if [[ ! -x "$helper" ]]; then
		print_error "Required-check wait helper unavailable: $helper"
		return 1
	fi
	"$helper" wait "$@"
	return $?
}

_run_foreground() {
	local prompt="$1"
	# Use a global for the trap — local variables are out of scope when the
	# EXIT trap fires after the function returns (causes unbound variable
	# crash under set -u).
	_FG_PID_FILE="${STATE_DIR}/full-loop.pid"
	trap 'rm -f "$_FG_PID_FILE"' EXIT
	emit_task_phase "$prompt"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	#aidevops:trust-boundary GH#36901 -- the review-bot-gate override is set only
	# by cmd_merge from its explicit flag, never inherited from the environment.
	_FULL_LOOP_RBG_OVERRIDE_REASON=""
	# Command help is an introspection request, not an operation. Handle it
	# before dispatch so probes such as `start --help` cannot create loop state.
	case "${1:-}" in
	help | --help | -h)
		show_help
		return 0
		;;
	esac
	case "$command" in
	start) cmd_start "$@" ;; resume) cmd_resume ;; status) cmd_status "$@" ;;
	cancel) cmd_cancel ;; logs) cmd_logs "$@" ;; _run_foreground) _run_foreground "$@" ;;
	commit-and-pr | create-pr) cmd_commit_and_pr "$@" ;;
	pre-merge-gate) cmd_pre_merge_gate "$@" ;;
	prospective-todo-guard) cmd_prospective_todo_guard "$@" ;;
	wait-checks) cmd_wait_checks "$@" ;;
	verify-runtime) cmd_verify_runtime "$@" ;;
	runtime-pending-notice) cmd_runtime_pending_notice "$@" ;;
	merge) cmd_merge "$@" ;;
	record-no-release) cmd_record_no_release "$@" ;;
	record-deployment) cmd_record_deployment "$@" ;;
	record-published-release) cmd_record_published_release "$@" ;;
	record-included-release) cmd_record_included_release "$@" ;;
	adopt-merged-receipt) cmd_adopt_merged_receipt "$@" ;;
	finalize-receipt) cmd_finalize_receipt "$@" ;;
	migrate-repository-receipt) cmd_migrate_repository_receipt "$@" ;;
	complete) cmd_complete "$@" ;;
	complete-after-cleanup) cmd_complete_after_cleanup "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		printf 'Run full-loop-helper.sh help for supported commands.\n' >&2
		return 1
		;;
	esac
}

main "$@"
