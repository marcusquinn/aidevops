#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-process.sh — Merge Processing Orchestrator
# =============================================================================
# Extracted from pulse-merge.sh (GH#21301) to bring the parent file below
# the 1500-line file-size-debt threshold.
#
# Sources focused modules while retaining the core merge decision pipeline.
# Public and internal entry points remain available after this file is sourced:
#   - pulse-merge-timing.sh               — low-overhead timing aggregation
#   - pulse-merge-pass.sh                 — checkpoints, cursors, pass orchestration
#   - pulse-merge-backlog.sh              — backlog buckets/ordering, PR-list reads,
#                                           cursor enrichment (GH#27171)
#   - merge_ready_prs_all_repos           — top-level merge pass entry point
#   - _merge_ready_prs_for_repo           — per-repo PR iteration
#   - _pmp_consolidate_duplicate_pr_groups — safe superseded sibling PR cleanup
#   - _pmp_classify_pr_backlog_state      — PR backlog observability buckets
#   - _pmp_sort_prs_by_backlog_priority   — near-merge/fix-needed ordering
#   - _attempt_pr_update_branch           — fast-forward via update-branch
#   - _resolve_pr_mergeable_status        — UNKNOWN→MERGEABLE retry
#   - _pulse_merge_dismiss_coderabbit_nits — auto-dismiss CR-only reviews
#   - _pr_required_checks_pass            — required CI check verification
#   - _attempt_pr_ci_rebase_retry         — CI-drift rebase (t2805)
#   - _route_pr_to_fix_worker             — unified fix-worker dispatch (t2203)
#   - _retarget_stacked_children          — stacked PR retargeting (t2412)
#   - _attempt_worker_briefed_auto_merge  — worker-briefed trust chain (t2449)
#   - _attempt_green_behind_update_branch — green+BEHIND branch refresh (GH#26659)
#   - _check_required_checks_passing      — branch-protection context check (t2922)
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-process.sh"
#        (sourced by pulse-merge.sh after pulse-merge-gates.sh)
#
# Dependencies:
#   - shared-constants.sh (gh_pr_list, gh_pr_comment, gh_issue_comment, etc.)
#   - worker-lifecycle-common.sh (unlock_issue_after_worker)
#   - LOGFILE, STOP_FLAG, PULSE_MERGE_BATCH_LIMIT (set by pulse-merge.sh defaults)
#   - _OW_LABEL_PAT (defined in pulse-merge.sh before sourcing this file)
#   - _pm_issue_api (defined in pulse-merge.sh before sourcing this file)
#   - _process_single_ready_pr (defined in pulse-merge.sh, resolved at call time)
#   - _dispatch_pr_fix_worker, _dispatch_conflict_fix_worker, _dispatch_ci_fix_worker
#     (defined in pulse-merge-feedback.sh, resolved at call time)
#   - _interactive_pr_is_stale, _interactive_pr_trigger_handover
#     (defined in pulse-merge-conflict.sh, resolved at call time)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_PROCESS_LOADED:-}" ]] && return 0
_PULSE_MERGE_PROCESS_LOADED=1

# Defensive defaults for standalone sourcing (test harnesses, pulse-merge-routine.sh)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${STOP_FLAG:=${HOME}/.aidevops/logs/pulse-session.stop}"
: "${PULSE_MERGE_BATCH_LIMIT:=50}"
: "${PULSE_MERGE_CHECKPOINT_FILE:=${HOME}/.aidevops/logs/pulse-merge-checkpoint}"
: "${PULSE_MERGE_PR_CURSOR_FILE:=${PULSE_MERGE_CHECKPOINT_FILE}.pr-cursor}"
: "${AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_SECONDS:=3600}"
: "${AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_DIR:=${HOME}/.aidevops/cache/pulse-update-branch-conflicts}"
_PMP_ORIGIN_INTERACTIVE_PATTERN=",origin:interactive,"
_PMP_ORIGIN_WORKER_PATTERN=",origin:worker,"
_PMP_ORIGIN_TAKEOVER_PATTERN=",origin:worker-takeover,"
_PMP_CHECK_FAILURE="FAILURE"

#######################################
# Return the persistent state path for one interactive PR's semantic
# update-branch conflict. The head SHA in the state file is the freshness
# signal: a pushed head bypasses the stored cooldown immediately.
#
# Args: $1=pr_number, $2=repo_slug
#######################################
_pmp_update_branch_conflict_cooldown_file() {
	local pr_number="$1"
	local repo_slug="$2"
	local state_key=""

	state_key=$(printf '%s-%s' "$repo_slug" "$pr_number" | tr -c '[:alnum:]._-' '_')
	[[ -n "$state_key" ]] || return 1
	printf '%s/%s' "$AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_DIR" "$state_key"
	return 0
}

#######################################
# Check whether this exact PR head remains in a semantic-conflict cooldown.
#
# Args: $1=pr_number, $2=repo_slug, $3=head_sha
#######################################
_pmp_update_branch_conflict_cooldown_active() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local state_file=""
	local recorded_head_sha=""
	local expires_at=""
	local now=""

	[[ -n "$expected_head_sha" ]] || return 1
	state_file=$(_pmp_update_branch_conflict_cooldown_file "$pr_number" "$repo_slug") || return 1
	[[ -f "$state_file" ]] || return 1
	IFS=$'\t' read -r recorded_head_sha expires_at <"$state_file" || return 1
	[[ "$recorded_head_sha" == "$expected_head_sha" ]] || return 1
	[[ "$expires_at" =~ ^[0-9]+$ ]] || return 1
	now=$(date +%s)
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	[[ "$now" -lt "$expires_at" ]] || return 1
	return 0
}

#######################################
# Persist a semantic-conflict cooldown for this exact interactive PR head. The
# normal conflict path still runs after the first failed write, preserving
# worker feedback routing and close policy. Pulse serialises merge passes, so
# replacing this single-PR state atomically is sufficient.
#
# Args: $1=pr_number, $2=repo_slug, $3=head_sha
#######################################
_pmp_record_update_branch_conflict_cooldown() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local state_file=""
	local state_dir=""
	local state_tmp=""
	local now=""
	local expires_at=""

	[[ -n "$expected_head_sha" ]] || return 1
	[[ "$AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || return 1
	now=$(date +%s)
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	expires_at=$((now + AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_SECONDS))
	state_file=$(_pmp_update_branch_conflict_cooldown_file "$pr_number" "$repo_slug") || return 1
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" || return 1
	state_tmp=$(mktemp "${state_file}.XXXXXX") || return 1
	printf '%s\t%s\n' "$expected_head_sha" "$expires_at" >"$state_tmp" || {
		rm -f "$state_tmp"
		return 1
	}
	mv -f "$state_tmp" "$state_file" || {
		rm -f "$state_tmp"
		return 1
	}
	echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — recorded semantic update-branch conflict cooldown for head ${expected_head_sha:0:12} until ${expires_at} (GH#30396)" >>"$LOGFILE"
	return 0
}

_pmp_is_protected_release_pr() {
	local head_ref="$1"
	local labels_csv="$2"

	[[ ",${labels_csv}," == *",release,"* ]] || return 1
	[[ "$head_ref" =~ ^chore/release-v[0-9]+\.[0-9]+\.[0-9]+-provenance$ ]] || return 1
	return 0
}

# Load the exact-output PR-list provider cache for standalone module tests and
# direct routine sourcing. pulse-wrapper.sh also sources this before the merge
# modules, so the include guard in pulse-pr-list-cache.sh keeps this idempotent.
_PULSE_MERGE_PROCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_PULSE_MERGE_PROCESS_DIR}/pulse-pr-list-cache.sh" ]]; then
	# shellcheck source=./pulse-pr-list-cache.sh
	# shellcheck disable=SC1091
	source "${_PULSE_MERGE_PROCESS_DIR}/pulse-pr-list-cache.sh"
fi

# Focused sub-libraries keep timing and pass checkpoint mechanics out of the
# core merge decision pipeline while preserving the original public source path.
# shellcheck source=./pulse-merge-timing.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-timing.sh"
# shellcheck source=./pulse-merge-pass.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-pass.sh"
# shellcheck source=./pulse-merge-rest-state.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-rest-state.sh"
# shellcheck source=./pulse-merge-required-checks.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-required-checks.sh"
# shellcheck source=./pulse-merge-unchanged-skip.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-unchanged-skip.sh"
# shellcheck source=./pulse-merge-backlog.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-backlog.sh"

# --- Functions ---

#######################################
# Normalize known PR lifecycle states from mixed GitHub API paths.
#
# GraphQL emits uppercase enums while REST and cached projections can emit
# lowercase strings. Preserve unknown values so exact-state consumers still
# fail closed instead of accepting an unrecognised lifecycle state (t18168).
#
# Args: $1=destination variable name, $2=raw lifecycle state
#######################################
_pmp_normalize_pr_lifecycle_state_into() {
	local dest_var="$1"
	local raw_state="$2"
	local normalized_state=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	case "$raw_state" in
	[Oo][Pp][Ee][Nn]) normalized_state="OPEN" ;;
	[Cc][Ll][Oo][Ss][Ee][Dd]) normalized_state="CLOSED" ;;
	[Mm][Ee][Rr][Gg][Ee][Dd]) normalized_state="MERGED" ;;
	*) normalized_state="$raw_state" ;;
	esac
	printf -v "$dest_var" '%s' "$normalized_state"
	return 0
}

# Safe duplicate worker PR consolidation helpers (m-20260508-0e27c3 task 2.4).
_PULSE_MERGE_PROCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pulse-merge-duplicate-consolidation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-duplicate-consolidation.sh"

#######################################
# Merge ready PRs for a single repo.
#
# Fetches the PR list for the repo, iterates, and delegates each PR
# to _process_single_ready_pr. Uses eval to return counts to caller
# (Bash 3.2 compat: no nameref).
# GH#33569: opted-in callers skip an unchanged PR set that recently evaluated
# to a no-op (_pmu_skip_unchanged_repo); complete from-start evaluations record
# fresh evidence (_pmu_record_repo_evaluation). Skipped outcomes stay incomplete.
#
# Args:
#   $1 - repo slug
#   $2 - nameref for merged count
#   $3 - nameref for closed count
#   $4 - nameref for failed count
#######################################
_merge_ready_prs_for_repo() {
	local repo_slug="$1"
	# Bash 3.2 compat: no nameref. Use eval to set caller variables.
	local _merged_var="$2"
	local _closed_var="$3"
	local _failed_var="$4"
	local _pr_count_var="${5:-}"
	local _timing_prefix="${6:-}"

	local merged=0 closed=0 failed=0
	# Propagate the graceful deadline into every nested bounded GitHub read
	# and write, including the multi-call per-PR safety/eligibility evaluator.
	local AIDEVOPS_GH_DEADLINE_EPOCH="${AIDEVOPS_GH_DEADLINE_EPOCH:-}"
	_pmp_apply_merge_api_deadline
	local pr_json="" pr_merge_err="" _list_start="" pr_count="" pr_list_timeout="" pr_list_rc=0
	local pr_list_complete=1 outcomes_complete=1
	_list_start=$(_pmp_now_epoch)
	if ! pr_list_timeout=$(_pmp_merge_pr_list_timeout_seconds); then
		_pmp_record_pr_list_timing "$_timing_prefix" "$_list_start" 0
		if [[ -n "$_pr_count_var" ]]; then
			[[ "$_pr_count_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
			printf -v "$_pr_count_var" '%s' '0'
		fi
		eval "${_merged_var}=0; ${_closed_var}=0; ${_failed_var}=0"
		return 5
	fi
	pr_merge_err=$(mktemp)
	pr_json=$(_pmp_fetch_ready_pr_list "$repo_slug" "$pr_list_timeout" "$pr_merge_err") || pr_list_rc=$?
	if [[ "$pr_list_rc" -ne 0 || -z "$pr_json" || "$pr_json" == "null" ]]; then
		local _pr_merge_err_msg
		_pr_merge_err_msg=$(cat "$pr_merge_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _process_merge_batch: pulse_pr_list_get FAILED for ${repo_slug}: list_state=incomplete rc=${pr_list_rc} timeout_s=${pr_list_timeout}: ${_pr_merge_err_msg}" >>"$LOGFILE"
		pr_json="[]"
		pr_list_complete=0
	fi
	pr_json=$(_pmp_include_queued_pr_targets_or_fallback "$repo_slug" "$pr_json" "$pr_merge_err") || pr_list_complete=0
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || { pr_count=0; pr_list_complete=0; }
	[[ "$pr_count" =~ ^[0-9]+$ ]] || { pr_count=0; pr_list_complete=0; }
	_pmp_record_pr_list_timing "$_timing_prefix" "$_list_start" "$pr_list_complete"
	if [[ -n "$_pr_count_var" ]]; then
		[[ "$_pr_count_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
		printf -v "$_pr_count_var" '%s' "$pr_count"
	fi

	if [[ "$pr_count" -eq 0 ]] || _pmu_skip_unchanged_repo "$repo_slug" "$pr_json" "$pr_list_complete"; then
		eval "${_merged_var}=0; ${_closed_var}=0; ${_failed_var}=0"
		if [[ "$pr_count" -eq 0 && "$pr_list_complete" -eq 1 ]]; then
			_pmp_clear_merge_enrichment_state; _pmp_mark_same_pass_repo_complete "$repo_slug" 2>/dev/null || true
		fi
		return 0
	fi

	local AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR="" AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR=""
	_pmp_setup_merge_repo_caches "$repo_slug"

	local preparation_rc=0
	_pmp_prepare_repo_processing_backlog "$repo_slug" "$_timing_prefix" || preparation_rc=$?
	if [[ "$preparation_rc" -ne 0 ]]; then
		_pmp_cleanup_merge_repo_caches
		eval "${_merged_var}=0; ${_closed_var}=0; ${_failed_var}=0"
		return "$preparation_rc"
	fi

	local i=0
	_pmp_prepare_merge_pr_cursor_resume "$repo_slug" "$pr_json" "$pr_count" "$PULSE_MERGE_PR_CURSOR_FILE" "$LOGFILE" i || i=0
	local _evaluated_from_start=$((i == 0))
	while [[ "$i" -lt "$pr_count" ]]; do
		local pr_obj="" _pr_start=""
		_pr_start=$(_pmp_now_epoch) # GH#33307: time the whole per-PR unit
		_pmp_prepare_pr_at_cursor "$repo_slug" "$pr_json" "$i" pr_obj "$_merged_var" "$_closed_var" "$_failed_var" "$merged" "$closed" "$failed" "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR" || return $?
		[[ -n "$pr_obj" ]] || {
			[[ -n "$_timing_prefix" ]] && _pmp_record_pr_processing_timing "$_timing_prefix" "$_pr_start" ""
			i=$((i + 1))
			continue
		}
		local _cursor_last_pr="" _cursor_next_pr="" _pr_head_sha=""
		_cursor_last_pr=$(printf '%s' "$pr_obj" | jq -r '.number // empty' 2>/dev/null) || _cursor_last_pr=""
		_pr_head_sha=$(printf '%s' "$pr_obj" | jq -r '.headRefOid // empty' 2>/dev/null) || _pr_head_sha=""

		local _pr_rc=0
		_pmp_evaluate_pr_with_deadline "$repo_slug" "$pr_obj" "$_timing_prefix" || _pr_rc=$?
		if [[ "$_pr_rc" -eq 124 ]]; then
			_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$i" budget "$_merged_var" "$_closed_var" "$_failed_var" "$merged" "$closed" "$failed" "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"
			return $?
		fi
		i=$((i + 1))
		_cursor_next_pr=$(_pmp_pr_number_at_index "$pr_json" "$i") || _cursor_next_pr=""
		[[ -n "$_timing_prefix" ]] && _pmp_record_pr_processing_timing "$_timing_prefix" "$_pr_start" "$_cursor_last_pr"
		_pmp_record_processed_pr_result "$repo_slug" "$_cursor_last_pr" "$_pr_head_sha" "$_pr_rc" merged closed failed || outcomes_complete=0
		_pmp_write_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE" "$repo_slug" "$i" "$_cursor_last_pr" "$_cursor_next_pr"
	done
	_pmp_clear_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE"
	_pmp_clear_merge_enrichment_state

	_pmp_cleanup_merge_repo_caches
	if [[ "$pr_list_complete" -eq 1 && "$outcomes_complete" -eq 1 ]]; then _pmp_mark_same_pass_repo_complete "$repo_slug" 2>/dev/null || true; fi
	_pmu_record_repo_evaluation "$repo_slug" "$merged" "$closed" "$failed" "$((pr_list_complete * _evaluated_from_start))"

	eval "${_merged_var}=${merged}; ${_closed_var}=${closed}; ${_failed_var}=${failed}"
	return 0
}

#######################################
# Attempt to fast-forward the PR's branch to the latest base branch head
# via GitHub's update-a-pull-request-branch REST endpoint. The server-side
# merger will merge main
# into the branch when the changes don't semantically conflict; this
# salvages a large class of CONFLICTING PRs where the only issue is that
# main advanced while the worker was finishing or waiting (t2116).
#
# Returns 0 on success (branch now up to date, caller should re-fetch
# mergeable state), 1 on failure (true semantic conflict, caller should
# fall through to the close path).
#
# Rate-limit considerations: one REST update-branch call per CONFLICTING
# PR per merge cycle. A confirmed interactive semantic conflict is persisted
# for a bounded cooldown so later cycles do not retry an impossible write
# until the head changes or the cooldown expires (GH#30396).
#
# Args: $1=pr_number, $2=repo_slug, $3=expected current head SHA
#######################################
_attempt_pr_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="${3:-}"
	_PMP_UPDATE_BRANCH_SEMANTIC_CONFLICT_PR=""
	_PMP_UPDATE_BRANCH_SEMANTIC_CONFLICT_REPO=""
	_PMP_UPDATE_BRANCH_SEMANTIC_CONFLICT_HEAD=""

	if _pmp_update_branch_conflict_cooldown_active "$pr_number" "$repo_slug" "$expected_head_sha"; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — skipping update-branch; semantic conflict cooldown active for unchanged head ${expected_head_sha:0:12} (GH#30396)" >>"$LOGFILE"
		return 1
	fi

	local _ub_output _ub_exit
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$expected_head_sha" 2>&1)
	_ub_exit=$?

	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch succeeded (t2116)" >>"$LOGFILE"
		# Brief pause so GitHub recomputes mergeable state before the
		# caller re-fetches it.
		sleep 2
		return 0
	fi

	if [[ "$_ub_output" == *"HTTP 422"* ]]; then
		_PMP_UPDATE_BRANCH_SEMANTIC_CONFLICT_PR="$pr_number"
		_PMP_UPDATE_BRANCH_SEMANTIC_CONFLICT_REPO="$repo_slug"
		_PMP_UPDATE_BRANCH_SEMANTIC_CONFLICT_HEAD="$expected_head_sha"
		local _ub_labels=""
		_ub_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels \
			--jq '[.labels[]?.name] | join(",")' 2>/dev/null) || _ub_labels=""
		if [[ ",${_ub_labels}," == *"$_PMP_ORIGIN_INTERACTIVE_PATTERN"* ]]; then
			_pmp_record_update_branch_conflict_cooldown "$pr_number" "$repo_slug" "$expected_head_sha" || true
		fi
	fi
	echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch failed, falling through to close (t2116): ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Resolve PR mergeable status, retrying once for UNKNOWN state.
# Returns 0 if MERGEABLE, 1 if not (caller should skip this PR).
# Args: $1=pr_number, $2=repo_slug, $3=current_mergeable_state
#######################################
_resolve_pr_mergeable_status() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_mergeable="$3"
	local original_mergeable="$pr_mergeable"
	_pmp_normalize_mergeable_state_into pr_mergeable "$pr_mergeable"

	if [[ "$pr_mergeable" == "UNKNOWN" || -z "$pr_mergeable" ]]; then
		local _was_label="$original_mergeable"
		[[ -z "$original_mergeable" ]] && _was_label="empty"
		# Separate local declaration from assignment to preserve exit code (SC2181).
		local _retry_output _retry_exit
		_retry_output=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json mergeable --jq '.mergeable // ""')
		_retry_exit=$?
		[[ $_retry_exit -eq 0 && -n "$_retry_output" ]] && pr_mergeable="$_retry_output" || pr_mergeable="UNKNOWN"
		_pmp_normalize_mergeable_state_into pr_mergeable "$pr_mergeable"
		if [[ "$pr_mergeable" == "MERGEABLE" ]]; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — mergeable resolved to MERGEABLE after retry" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — mergeable=${pr_mergeable} (was ${_was_label}, still not MERGEABLE after retry)" >>"$LOGFILE"
			return 1
		fi
	fi
	if [[ "$pr_mergeable" != "MERGEABLE" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — mergeable=${pr_mergeable}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Auto-dismiss CodeRabbit-only CHANGES_REQUESTED reviews when the
# coderabbit-nits-ok PR label has been applied by a maintainer (t2179).
#
# Delegates reviewer enumeration and dismissal to review-bot-gate-helper.sh so
# the maintainer override and exact-head reconciliation share one trust boundary.
#
# Returns: 0 if all CR reviews dismissed (or none existed)
#          1 if a non-CR human review is blocking dismissal
#
# Arguments: $1=pr_number, $2=repo_slug
#######################################
_pulse_merge_dismiss_coderabbit_nits() {
	local pr_number="$1"
	local repo_slug="$2"
	local review_helper="${AIDEVOPS_REVIEW_BOT_GATE_HELPER:-${_PULSE_MERGE_PROCESS_DIR}/review-bot-gate-helper.sh}"
	local helper_output=""

	if [[ ! -f "$review_helper" ]]; then
		review_helper="${HOME}/.aidevops/agents/scripts/review-bot-gate-helper.sh"
	fi
	[[ -f "$review_helper" ]] || return 1
	if ! helper_output=$(bash "$review_helper" dismiss-coderabbit-nits "$pr_number" "$repo_slug" 2>&1); then
		[[ -n "$helper_output" ]] && printf '%s\n' "$helper_output" >>"$LOGFILE"
		return 1
	fi
	[[ -n "$helper_output" ]] && printf '%s\n' "$helper_output" >>"$LOGFILE"

	return 0
}

#######################################
# Verify no branch-protection-required check on a PR is in a terminal failed
# state. Skips PRs with terminal failed CI even when the merge would use
# --admin (which bypasses branch protection), but leaves queued/pending/
# in-progress/expected checks on the normal non-terminal path.
#
# t3514: delegate to REST-backed branch-protection context verification so
# merge readiness does not spend GraphQL on `gh pr checks --required`.
#
# An empty result (no required checks defined in branch protection) is
# treated as "nothing is failing" → merge allowed. Fail-closed on API
# errors — a bubbling gh failure should never auto-merge.
#
# Arguments: $1=pr_number, $2=repo_slug
# Returns: 0 if no required check is terminal failed, 1 if any terminal failed
#          or required-check state cannot be verified.
#######################################
_pr_required_checks_pass() {
	local pr_number="$1"
	local repo_slug="$2"
	local _terminal_rc=0
	_check_required_checks_has_terminal_failure "$repo_slug" "$pr_number"
	_terminal_rc=$?
	if [[ $_terminal_rc -eq 0 ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — REST required checks have terminal failure (t3567)" >>"$LOGFILE"
		return 1
	fi
	if [[ $_terminal_rc -ne 1 ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — REST required checks could not be classified (t3567)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Attempt to rebase a MERGEABLE PR with failing CI before routing to a
# fix-worker. When a PR is behind its base branch, failing CI is often
# caused by base-drift (e.g. a pre-existing test failure fixed in a
# later commit to the base branch), not by the PR's own code.
#
# Returns 0 if update-branch succeeded (caller should skip fix-worker
# routing and let the next pulse cycle re-check CI on the rebased HEAD).
# Returns 1 if the PR is already up-to-date with its base or if update-branch
# failed. Standard callers may route a fix worker. Review-repair callers must
# preserve CHANGES_REQUESTED; a typed caller may separately evaluate trust-gated
# CI repair after a no-op, but must always return before merge.
#
# Rate-limit: one call per PR per merge cycle — same as t2116.
#
# t2805
#######################################
_attempt_pr_ci_rebase_retry() {
	local pr_number="$1"
	local repo_slug="$2"
	local _base_branch="${3:-}"
	local _head_oid="${4:-}"
	local _rebase_policy="${5:-standard}"
	local _review_repair_policy="review-repair"

	if [[ "$_rebase_policy" != "standard" && "$_rebase_policy" != "$_review_repair_policy" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: refusing unknown CI-drift rebase policy ${_rebase_policy}" >>"$LOGFILE"
		return 1
	fi

	# Prefer per-cycle PR list context; direct/webhook callers may omit it.
	if [[ -z "$_base_branch" || -z "$_head_oid" ]]; then
		local _pr_info
		_pr_info=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json baseRefName,headRefOid --jq '(.baseRefName // "") + " " + (.headRefOid // "")' 2>/dev/null) || _pr_info=""
		read -r _base_branch _head_oid <<< "$_pr_info"
	fi

	if [[ "$_rebase_policy" == "$_review_repair_policy" && ( -z "$_base_branch" || -z "$_head_oid" ) ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: strict review-repair rebase lacks current base/head evidence; preserving CHANGES_REQUESTED" >>"$LOGFILE"
		return 1
	fi

	if [[ -n "$_base_branch" && -n "$_head_oid" ]]; then
		local _compare_behind
		_compare_behind=$(gh api "repos/${repo_slug}/compare/${_base_branch}...${_head_oid}" \
			--jq '.behind_by' 2>/dev/null) || _compare_behind=""
		if [[ "$_rebase_policy" == "$_review_repair_policy" && ! "$_compare_behind" =~ ^[1-9][0-9]*$ ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: strict review-repair rebase requires explicit behind_by>0 evidence; preserving CHANGES_REQUESTED" >>"$LOGFILE"
			return 1
		fi
		if [[ "$_compare_behind" == "0" ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: already up-to-date with ${_base_branch}, skipping CI-drift rebase (t2805)" >>"$LOGFILE"
			return 1
		fi
	fi

	# GH#26406: branch updates restart the current head's check suite. Only use
	# update-branch as a CI-drift repair when the current head has a terminal
	# required-check failure. Pending/in-progress required checks are not failures,
	# and stale failures from older head SHAs must not trigger a branch refresh.
	local _terminal_check_rc=0
	_check_required_checks_has_terminal_failure "$repo_slug" "$pr_number" "$_head_oid"
	_terminal_check_rc=$?
	if [[ $_terminal_check_rc -eq 1 ]]; then
		if _check_required_checks_have_pending_or_in_progress "$repo_slug" "$pr_number" "$_head_oid" >/dev/null 2>&1; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: skipping CI-drift update-branch because required checks are active on the current head; wait for current CI or rely on native auto-merge to avoid restarting checks (GH#26406)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: skipping CI-drift update-branch because no terminal required-check failure belongs to the current head; stale/non-required failure ignored (GH#26406)" >>"$LOGFILE"
		return 1
	fi
	if [[ $_terminal_check_rc -ne 0 ]]; then
		if [[ "$_rebase_policy" == "$_review_repair_policy" ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: terminal required-check evidence unavailable before strict review-repair rebase; preserving CHANGES_REQUESTED" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: required-check head-state unavailable before CI-drift update-branch; fail-open to existing update-branch behaviour (GH#26406)" >>"$LOGFILE"
	fi
	if [[ "$_rebase_policy" == "$_review_repair_policy" ]]; then
		local _pending_check_rc=0
		_check_required_checks_have_pending_or_in_progress "$repo_slug" "$pr_number" "$_head_oid" >/dev/null 2>&1 || _pending_check_rc=$?
		if [[ "$_pending_check_rc" -ne 1 ]]; then
			if [[ "$_pending_check_rc" -eq 0 ]]; then
				echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: strict review-repair rebase deferred because required checks remain active on the current head" >>"$LOGFILE"
			else
				echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: active required-check state unavailable before strict review-repair rebase; preserving CHANGES_REQUESTED" >>"$LOGFILE"
			fi
			return 1
		fi
		# #aidevops:trust-boundary — update-branch is a write. Revalidate live PR
		# labels, linked-issue holds, author permission, external authority, and
		# the exact expected head immediately before the repair mutation. This
		# keeps PR-level needs-maintainer-review authoritative even though the
		# repair-only gate intentionally stops before merge-only final checks.
		if ! declare -F _pulse_merge_admin_safety_check >/dev/null 2>&1 \
			|| ! _pulse_merge_admin_safety_check "$pr_number" "$repo_slug" "$_head_oid"; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: live PR authority failed before strict review-repair rebase; preserving CHANGES_REQUESTED" >>"$LOGFILE"
			return 1
		fi
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: attempting CI-drift rebase via update-branch (t2805)" >>"$LOGFILE"

	local _ub_output _ub_exit
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$_head_oid" 2>&1)
	_ub_exit=$?

	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI-drift rebase succeeded via update-branch, deferring to next cycle (t2805)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI-drift rebase failed (update-branch exit ${_ub_exit}), falling through to fix-worker routing (t2805): ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Update an already-auto-merge-enabled PR that is otherwise green but behind.
#
# GitHub native auto-merge does not merge a PR while mergeStateStatus=BEHIND;
# it waits for the branch to be updated first. Pulse used to defer forever once
# autoMergeRequest was present because _set_native_auto_merge_or_skip treated
# every existing auto-merge request as GitHub-owned unless it was BLOCKED+stuck.
#
# Caller must have already passed maintainer/review/security gates and stopped
# DRY_RUN before invoking because this helper performs a GitHub write.
#
# Returns 0 if update-branch succeeded and caller should defer to the next
# cycle; 1 if no update was needed or update-branch failed.
# GH#24839 / GH#24840
#######################################
_attempt_existing_auto_merge_behind_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"

	local _pr_state=""
	_pr_state=$(_pmp_rest_pr_merge_state "$pr_number" "$repo_slug" 2>/dev/null) || _pr_state=""
	[[ -n "$_pr_state" ]] || return 1

	local _existing_auto="" _merge_state="" _mergeable="" _head_oid=""
	_pmp_extract_update_branch_state _existing_auto _merge_state _mergeable "$_pr_state" _head_oid

	[[ -n "$_existing_auto" ]] || return 1
	[[ "$_merge_state" == BEHIND ]] || return 1
	[[ "$_mergeable" == MERGEABLE ]] || return 1
	_check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1 || return 1

	local _ub_output="" _ub_exit=0
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$_head_oid" 2>&1)
	_ub_exit=$?
	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge is green but BEHIND — update-branch succeeded, deferring to next cycle (GH#24839)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge is green but BEHIND — update-branch failed, falling through: ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Update a green PR that is BEHIND when no native auto-merge request exists.
#
# Repositories with allow_auto_merge disabled cannot use the native auto-merge
# fallback. If a protected green PR is behind, admin/direct merge attempts can
# fail forever with "head branch is not up to date" unless pulse updates the
# branch before trying those merge paths.
#
# Caller must have already passed maintainer/review/security gates and stopped
# DRY_RUN before invoking because this helper performs a GitHub write.
#
# Returns 0 if update-branch succeeded and caller should defer to the next
# cycle; 1 if no update was needed or update-branch failed.
# GH#26659
#######################################
_attempt_green_behind_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"

	local _pr_state=""
	_pr_state=$(_pmp_rest_pr_merge_state "$pr_number" "$repo_slug" 2>/dev/null) || _pr_state=""
	[[ -n "$_pr_state" ]] || return 1

	local _existing_auto="" _merge_state="" _mergeable="" _head_oid=""
	_pmp_extract_update_branch_state _existing_auto _merge_state _mergeable "$_pr_state" _head_oid

	[[ -z "$_existing_auto" ]] || return 1
	[[ "$_merge_state" == BEHIND ]] || return 1
	[[ "$_mergeable" == MERGEABLE ]] || return 1
	_check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1 || return 1

	local _ub_output="" _ub_exit=0
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$_head_oid" 2>&1)
	_ub_exit=$?
	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: green but BEHIND without native auto-merge — update-branch succeeded, deferring to next cycle (GH#26659)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: green but BEHIND without native auto-merge — update-branch failed, falling through: ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Keep a converged CHANGES_REQUESTED PR on a strictly non-merge path while
# evaluating bounded branch refresh and CI repair. All caller-side trust gates
# have already passed for the exact PR/head; the CI router independently binds
# actionable terminal failures to the live head before dispatch.
#
# Args: $1=pr_number, $2=repo_slug, $3=base_ref, $4=head_sha,
#       $5=linked_issue, $6=pr_labels, $7=updated_at, $8=repair_mode
# Returns: 1 always so review-blocked PRs never fall through toward merge.
#######################################
_handle_review_blocked_ci_repair() {
	local pr_number="$1"
	local repo_slug="$2"
	local base_ref="$3"
	local head_sha="$4"
	local linked_issue="$5"
	local pr_labels="$6"
	local updated_at="$7"
	local repair_mode="$8"
	local ci_rebase_only="${PULSE_REVIEW_GATE_MODE_CI_REBASE_ONLY:-ci-rebase-only}"
	local ci_repair_only="${PULSE_REVIEW_GATE_MODE_CI_REPAIR_ONLY:-ci-repair-only}"
	local route_rc=0

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] DRY-RUN: PR #${pr_number} in ${repo_slug} remains CHANGES_REQUESTED; would evaluate ${repair_mode}" >>"$LOGFILE"
		return 1
	fi
	if _attempt_pr_ci_rebase_retry "$pr_number" "$repo_slug" "$base_ref" "$head_sha" "review-repair"; then
		return 1
	fi
	if [[ "$repair_mode" == "$ci_rebase_only" ]]; then
		echo "[pulse-wrapper] Merge pass: preserving PR #${pr_number} in ${repo_slug} — CHANGES_REQUESTED remains blocking and strict CI-drift rebase was not eligible or did not succeed" >>"$LOGFILE"
		return 1
	fi
	if [[ "$repair_mode" != "$ci_repair_only" ]]; then
		echo "[pulse-wrapper] Merge pass: preserving PR #${pr_number} in ${repo_slug} — unknown review-blocked CI repair mode ${repair_mode}" >>"$LOGFILE"
		return 1
	fi
	if _pr_required_checks_pass "$pr_number" "$repo_slug"; then
		echo "[pulse-wrapper] Merge pass: preserving PR #${pr_number} in ${repo_slug} — CHANGES_REQUESTED remains blocking and required checks do not need CI repair" >>"$LOGFILE"
		return 1
	fi

	_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "ci" "$pr_labels" "" "$updated_at" "$head_sha" || route_rc=$?
	if [[ "$route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$route_rc" -eq "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]]; then
		echo "[pulse-wrapper] Merge pass: CI repair-only route for PR #${pr_number} in ${repo_slug} remains partial; preserving the PR for retry or maintainer review" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Merge pass: preserving PR #${pr_number} in ${repo_slug} — CHANGES_REQUESTED remains blocking after trust-gated CI repair evaluation" >>"$LOGFILE"
	fi
	return 1
}

_dispatch_pr_repair_by_kind() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local pr_title="$5"
	local checks_json="$6"
	local dispatch_rc=0
	case "$kind" in
		review) _dispatch_pr_fix_worker "$pr_number" "$repo_slug" "$linked_issue" || dispatch_rc=$? ;;
		conflict) _dispatch_conflict_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" || dispatch_rc=$? ;;
		ci) _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$checks_json" || dispatch_rc=$? ;;
	esac
	return "$dispatch_rc"
}

_route_issue_origin_is_trusted() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local fallback_pr_author=""
	fallback_pr_author=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json author --jq '.author.login // ""' 2>/dev/null) || fallback_pr_author=""
	#aidevops:trust-boundary — issue-origin fallback is only for same-repo collaborator PRs whose PR labels lost origin metadata.
	if [[ -z "$fallback_pr_author" ]] \
		|| ! declare -F _is_collaborator_author >/dev/null 2>&1 \
		|| ! _is_collaborator_author "$fallback_pr_author" "$repo_slug"; then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} linked issue #${linked_issue} has origin:worker but PR author trust could not be confirmed" >>"$LOGFILE"
		return 1
	fi
	if ! declare -F set_origin_label >/dev/null 2>&1 \
		|| ! set_origin_label "$pr_number" "$repo_slug" worker --pr >/dev/null 2>&1; then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} trusted linked issue #${linked_issue} has origin:worker, but PR origin reconciliation failed — deferring routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	local reconciled_labels=""
	if ! reconciled_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null); then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} origin:worker reconciliation from trusted linked issue #${linked_issue} was not verified — deferring routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	local reconciled_label_list=",${reconciled_labels},"
	if [[ "$reconciled_label_list" != *"$_PMP_ORIGIN_WORKER_PATTERN"* \
		|| "$reconciled_label_list" == *"$_PMP_ORIGIN_INTERACTIVE_PATTERN"* \
		|| "$reconciled_label_list" == *"$_PMP_ORIGIN_TAKEOVER_PATTERN"* ]]; then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} origin:worker reconciliation from trusted linked issue #${linked_issue} was not verified — deferring routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} restored origin:worker from trusted linked issue #${linked_issue}" >>"$LOGFILE"
	return 0
}

_route_pr_issue_supplies_worker_origin() {
	local label_list="$1"
	local issue_labels="$2"
	[[ "$label_list" != *"$_PMP_ORIGIN_WORKER_PATTERN"* \
		&& "$label_list" != *"$_PMP_ORIGIN_TAKEOVER_PATTERN"* \
		&& "$label_list" != *"$_PMP_ORIGIN_INTERACTIVE_PATTERN"* \
		&& ",${issue_labels}," == *"$_PMP_ORIGIN_WORKER_PATTERN"* ]]
}

_route_pr_log_unroutable() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	local label_list="$5"
	if [[ "$label_list" == *"$_PMP_ORIGIN_INTERACTIVE_PATTERN"* ]]; then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} retains active origin:interactive ownership; ${kind} repair routing is not eligible" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} and linked issue #${linked_issue} have no trusted origin metadata for ${kind} repair routing" >>"$LOGFILE"
	fi
	return 0
}

_route_pr_has_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	[[ -n "$linked_issue" ]] && return 0
	echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} has no linked issue for ${kind} repair routing" >>"$LOGFILE"
	return 1
}

# Conflict checkpoints intentionally use For/Ref, not closing keywords.
# Resolve independently of the caller's closing-only target, retaining the
# existing linked-issue validation and all later routing guards (GH#33763).
_route_pr_resolve_work_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	if [[ "$kind" == "conflict" ]]; then
		linked_issue=$(_extract_pr_work_issue "$pr_number" "$repo_slug") || return 1
	fi
	_route_pr_has_linked_issue "$pr_number" "$repo_slug" "$linked_issue" "$kind" || return 1
	printf '%s' "$linked_issue"
	return 0
}

_route_pr_issue_labels_for_dispatch() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local issue_labels=""

	if ! issue_labels=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
		--jq '[.labels[].name] | join(",")' 2>/dev/null); then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: linked issue #${linked_issue} metadata unavailable for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	[[ ",${issue_labels}," != *",needs-maintainer-review,"* ]] || return 1
	printf '%s\n' "$issue_labels"
	return 0
}

_route_pr_feedback_terminal_guard() {
	local has_routed_label="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local kind="$5"
	local routed_label="$6"

	[[ "$has_routed_label" -eq 1 ]] || return 0
	# Review routing owns finer-grained idempotency: immutable review/comment
	# evidence distinguishes a genuinely new review generation from a replay.
	# The PR-level terminal label therefore cannot permanently suppress review
	# inspection. Conflict and CI routes remain terminal per PR/head.
	[[ "$kind" != "review" ]] || return 0
	if ! declare -F _feedback_route_guard_existing_terminal_label >/dev/null 2>&1; then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: feedback finalizer unavailable behind ${routed_label} on PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	_feedback_route_guard_existing_terminal_label "$pr_number" "$repo_slug" "$linked_issue" "$kind"
	return $?
}

_route_pr_preserve_deferred_retry() {
	local route_rc="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local kind="$5"
	local queue_action="unavailable"

	[[ "$route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" ]] || return "$route_rc"
	if declare -F _pulse_merge_queue_defer >/dev/null 2>&1; then
		queue_action=$(_pulse_merge_queue_defer "$repo_slug" "$pr_number" 2>>"$LOGFILE") || queue_action="unavailable"
	elif declare -F _pulse_merge_queue_enqueue >/dev/null 2>&1; then
		queue_action=$(_pulse_merge_queue_enqueue "$repo_slug" "$pr_number" 2>>"$LOGFILE") || queue_action="unavailable"
	fi
	echo "[pulse-wrapper] _route_pr_to_fix_worker: preserved deferred ${kind} route for PR #${pr_number} and issue #${linked_issue} in ${repo_slug} (retry_hint=${queue_action})" >>"$LOGFILE"
	return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
}

_route_pr_issue_labels_with_retry() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	local issue_labels=""
	local route_rc=0

	issue_labels=$(_route_pr_issue_labels_for_dispatch "$pr_number" "$repo_slug" "$linked_issue") || route_rc=$?
	if [[ "$route_rc" -ne 0 ]]; then
		_route_pr_preserve_deferred_retry "$route_rc" "$pr_number" "$repo_slug" "$linked_issue" "$kind"
		return $?
	fi
	printf '%s' "$issue_labels"
	return 0
}

_route_pr_guard_and_dispatch_with_retry() {
	local has_routed_label="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local kind="$5"
	local routed_label="$6"
	local pr_title="$7"
	local checks_json="$8"
	local route_rc=0

	_route_pr_feedback_terminal_guard "$has_routed_label" "$pr_number" "$repo_slug" \
		"$linked_issue" "$kind" "$routed_label" || route_rc=$?
	if [[ "$route_rc" -eq 0 ]]; then
		_dispatch_pr_repair_by_kind "$kind" "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" "$checks_json" || route_rc=$?
	fi
	if [[ "$route_rc" -eq 0 ]] && declare -F _pulse_merge_queue_finish >/dev/null 2>&1; then
		_pulse_merge_queue_finish 2
	fi
	_route_pr_preserve_deferred_retry "$route_rc" "$pr_number" "$repo_slug" "$linked_issue" "$kind"
	return $?
}

#######################################
# Route a PR to the appropriate fix worker based on origin label and kind.
#
# Consolidates the shared routing pattern used by the review, conflict, and CI
# gates. Each gate checks exclusion labels, then dispatches worker-origin PRs
# directly and hands over stale interactive PRs before dispatch.
#
# Args:
#   $1 = pr_number
#   $2 = repo_slug
#   $3 = linked_issue (empty string → no routing possible)
#   $4 = kind          (review | conflict | ci)
#   $5 = pr_labels     (optional — comma-separated; fetched if empty)
#   $6 = pr_title      (optional — passed to conflict dispatch)
#   $7 = updated_at    (optional — passed to staleness check)
#   $8 = head_ref_oid  (optional — passed to staleness check)
#   $9 = checks_json   (optional — head-bound terminal blocker evidence for CI repair)
#
# Returns: 0 if dispatched, 1 if not routable, 75 if finalization is deferred,
#          or 76 if ambiguous state was preserved for maintainer review.
#
# Design: case-statement dispatch over kind — no dynamic function calls.
# Per-kind return semantics are handled by the CALLER, not here.
# t2203 — extracted from three inline blocks in _check_pr_merge_gates
# and _process_single_ready_pr.
#######################################
_route_pr_to_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	local pr_labels="${5:-}"
	local pr_title="${6:-}"
	local updated_at="${7:-}"
	local head_ref_oid="${8:-}"
	local checks_json="${9:-}"
	local issue_labels=""
	local issue_has_worker_origin=0
	local label_list=""
	local takeover_pattern="$_PMP_ORIGIN_TAKEOVER_PATTERN"
	local has_routed_label=0

	linked_issue=$(_route_pr_resolve_work_issue "$pr_number" "$repo_slug" "$linked_issue" "$kind") || return 1

	# Fetch labels if not provided by caller
	if [[ -z "$pr_labels" ]]; then
		if ! pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null); then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: current labels unavailable for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
	fi
	label_list=",${pr_labels},"

	# Kind-specific "already routed" exclusion label
	local routed_label
	case "$kind" in
		review)   routed_label="review-routed-to-issue" ;;
		conflict) routed_label="conflict-feedback-routed" ;;
		ci)       routed_label="ci-feedback-routed" ;;
		*)
			echo "[pulse-wrapper] _route_pr_to_fix_worker: unknown kind '${kind}'" >>"$LOGFILE"
			return 1
			;;
	esac

	# These labels preserve explicit human/external ownership before any route
	# recovery can inspect or mutate the PR and linked issue.
	if [[ "$label_list" == *",no-takeover,"* \
		|| "$label_list" == *",needs-maintainer-review,"* \
		|| "$label_list" == *",external-contributor,"* ]]; then
		return 1
	fi
	if [[ "$label_list" == *",${routed_label},"* ]]; then
		has_routed_label=1
	fi

	# A linked issue on explicit maintainer hold is never rewritten or reopened.
	issue_labels=$(_route_pr_issue_labels_with_retry "$pr_number" "$repo_slug" "$linked_issue" "$kind") || return $?

	if _route_pr_issue_supplies_worker_origin "$label_list" "$issue_labels"; then
		issue_has_worker_origin=1
	fi

	# Worker-origin PRs: dispatch directly
	if [[ ( -n "${_OW_LABEL_PAT:-}" && "$label_list" == *"${_OW_LABEL_PAT:-}"* ) ]] \
		|| [[ "$label_list" == *"$takeover_pattern"* ]] \
		|| [[ "$issue_has_worker_origin" -eq 1 ]]; then
		if [[ "$issue_has_worker_origin" -eq 1 ]]; then
			local origin_reconcile_rc=0
			_route_issue_origin_is_trusted "$pr_number" "$repo_slug" "$linked_issue" \
				|| origin_reconcile_rc=$?
			if [[ "$origin_reconcile_rc" -ne 0 ]]; then
				_route_pr_preserve_deferred_retry "$origin_reconcile_rc" "$pr_number" "$repo_slug" "$linked_issue" "$kind"
				return $?
			fi
		fi
		_route_pr_guard_and_dispatch_with_retry "$has_routed_label" "$pr_number" "$repo_slug" \
			"$linked_issue" "$kind" "$routed_label" "$pr_title" "$checks_json"
		return $?
	fi

	# Stale interactive PRs: handover first, then dispatch
	if [[ "$label_list" == *"$_PMP_ORIGIN_INTERACTIVE_PATTERN"* ]] \
		&& _interactive_pr_is_stale "$pr_number" "$repo_slug" "$updated_at" "$head_ref_oid"; then
		if ! _interactive_pr_trigger_handover "$pr_number" "$repo_slug"; then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: interactive handover was not confirmed for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
		if ! pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) \
			|| [[ ",${pr_labels}," != *"$takeover_pattern"* ]]; then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: origin:worker-takeover not confirmed for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
		_route_pr_guard_and_dispatch_with_retry "$has_routed_label" "$pr_number" "$repo_slug" \
			"$linked_issue" "$kind" "$routed_label" "$pr_title" "$checks_json"
		return $?
	fi

	# Not routable (no matching origin label or not stale). Keep one bounded,
	# terminal diagnostic so a lost provenance label cannot become a silent loop.
	_route_pr_log_unroutable "$pr_number" "$repo_slug" "$linked_issue" "$kind" "$label_list"
	return 1
}

#######################################
# Retarget direct child PRs before deleting the merged parent branch.
#
# Args:
#   $1 - parent PR number
#   $2 - repo slug
#   $3 - parent head ref from per-cycle PR context (optional)
# Returns: 0 always (errors are non-fatal)
#######################################
_retarget_stacked_children() {
	local parent_pr_number="$1"
	local repo_slug="$2"
	local parent_head_ref="${3:-}"
	if [[ -z "$parent_head_ref" ]]; then
		parent_head_ref=$(gh_pr_view "$parent_pr_number" --repo "$repo_slug" --json headRefName -q '.headRefName' 2>/dev/null) || parent_head_ref=""
	fi
	if [[ -z "$parent_head_ref" ]]; then
		return 0
	fi

	local children
	children=$(gh_pr_list --repo "$repo_slug" --base "$parent_head_ref" --state open --json number -q '.[].number' 2>/dev/null) || children=""
	if [[ -z "$children" ]]; then
		return 0
	fi

	local default_branch
	default_branch=$(gh repo view "$repo_slug" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
	default_branch="${default_branch:-main}"

	local child
	while IFS= read -r child; do
		[[ -z "$child" ]] && continue
		echo "[pulse-merge] retargeting stacked PR #${child} from '${parent_head_ref}' to '${default_branch}' before deleting parent PR #${parent_pr_number} branch (t2412)" >>"$LOGFILE"
		gh pr edit "$child" --repo "$repo_slug" --base "$default_branch" 2>&1 | tee -a "$LOGFILE" || true
	done <<<"$children"
	return 0
}

#######################################
# Check if a GitHub login appears in the trusted-issue-author allowlist (t3062).
#
# Peer runners with COLLABORATOR association can be added to the allowlist to
# bypass the OWNER/MEMBER author_association gate without requiring per-issue
# cryptographic approval (sudo aidevops approve issue N).
#
# Config: AIDEVOPS_TRUSTED_AUTHORS_CONF env var (override) or
#         <_PULSE_MERGE_DIR>/../configs/trusted-issue-authors.conf (default).
# Empty/missing config = no trusted authors = returns 1 (not trusted).
#
# Args: $1=github_login
# Returns: 0=login is trusted, 1=not trusted
#######################################
_is_trusted_issue_author() {
	local login="$1"
	[[ -z "$login" ]] && return 1
	local _trusted_conf="${AIDEVOPS_TRUSTED_AUTHORS_CONF:-${_PULSE_MERGE_DIR:+${_PULSE_MERGE_DIR}/../configs/trusted-issue-authors.conf}}"
	[[ -z "$_trusted_conf" || ! -f "$_trusted_conf" ]] && return 1
	local _tentry
	while IFS= read -r _tentry || [[ -n "$_tentry" ]]; do
		[[ -z "$_tentry" || "$_tentry" == "#"* ]] && continue
		[[ "$_tentry" == "$login" ]] && return 0
	done < "$_trusted_conf"
	return 1
}

#######################################
# Check whether an issue author has maintainer-equivalent repository access.
#
# GitHub can expose maintainer-operated issues/PRs as COLLABORATOR rather than
# OWNER/MEMBER. For worker-briefed auto-merge, verify that ambiguous metadata
# through the authenticated collaborator permission endpoint instead of forcing
# per-issue cryptographic approvals for every maintainer-run aidevops worker.
#
# Args: $1=repo_slug, $2=github_login, $3=precomputed_permission(optional)
# Returns: 0=trusted maintainer-equivalent access, 1=not trusted or API error
#######################################
_issue_author_has_maintainer_authority() {
	local repo_slug="$1"
	local login="$2"
	local permission="${3:-}"

	[[ -n "$repo_slug" && -n "$login" ]] || return 1

	if [[ -z "$permission" ]]; then
		#aidevops:trust-boundary GH#24958: ambiguous GitHub issue
		# author_association values are not sufficient to auto-merge worker PRs.
		# Confirm maintainer-equivalent access with authenticated metadata and fail
		# closed on API errors or permissions below write.
		permission=$(gh api "repos/${repo_slug}/collaborators/${login}/permission" \
			--jq '.permission // ""' 2>/dev/null) || return 1
	fi

	case "$permission" in
		admin | maintain | write)
			return 0
			;;
	esac
	return 1
}

#######################################
# Verify that a linked issue has a maintainer cryptographic approval (t3052).
#
# Marker-string presence is not a trust signal: any user able to comment could
# paste the marker. This helper delegates to approval-helper.sh, which verifies
# the SSH signature against the maintainer approval public key.
#
# Args: $1=issue_number, $2=repo_slug
# Returns: 0=verified approval, 1=no verified approval
#######################################
_issue_has_verified_crypto_approval() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 1

	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	[[ ! -f "$approval_helper" ]] && return 1

	local verify_result=""
	verify_result=$(bash "$approval_helper" verify "$issue_number" "$repo_slug" 2>/dev/null) || verify_result=""
	[[ "$verify_result" == "VERIFIED" ]]
	return $?
}

#######################################
# Classify how a worker PR links its issue (GH#33999). Prints "closing" for a
# closing-keyword link (unchanged behaviour). For a For/Ref-only association
# #aidevops:trust-boundary — the issue must be open and not parent-task; prints
# "non-closing reference". Never writes a closing keyword.
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=issue API path
# Returns: 0=eligible link kind printed, 1=ineligible or lookup failure
#######################################
_worker_briefed_link_kind() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local issue_api="$4"
	local closing_issue="" state_labels="" issue_state="" issue_labels=""
	closing_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || return 1
	if [[ -n "$closing_issue" ]]; then
		printf '%s' "closing"
		return 0
	fi
	state_labels=$(gh api "${issue_api}" --jq '[.state // "", ([.labels[].name] | join(","))] | @tsv' 2>/dev/null) || return 1
	issue_state="${state_labels%%$'\t'*}"
	issue_labels="${state_labels#*$'\t'}"
	if [[ "$issue_state" != "open" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked via non-closing reference to issue #${linked_issue} which is not open (GH#33999)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$issue_labels" =~ (^|,)parent-task(,|$) ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked via non-closing reference to parent-task issue #${linked_issue} (GH#33999)" >>"$LOGFILE"
		return 1
	fi
	printf '%s' "non-closing reference"
	return 0
}

#######################################
# Check origin:worker worker-briefed auto-merge gates (t2449).
#
# Sibling to _check_interactive_pr_gates — validates that an origin:worker
# PR is eligible for auto-merge based on the maintainer-briefed trust chain.
# Called from _check_pr_merge_gates when the PR carries origin:worker.
#
# The trust-chain equivalence argument: if the underlying issue was filed by
# the repo OWNER/MEMBER, the worker faithfully implemented, CI confirms
# correctness, and no human reviewer objected, the trust chain is equivalent
# to (or stronger than) an origin:interactive auto-merge.
#
# Nine criteria (see GH#20204):
#   1. PR carries origin:worker label (caller pre-checks)
#   2. Linked issue authored by OWNER or MEMBER
#   3. Linked issue has live maintainer-author authority or cryptographic approval
#   4. All required status checks PASS/SKIPPED (checked by general gates)
#   5. No CHANGES_REQUESTED from human reviewers (checked by general gates)
#   6. PR is not a draft
#   7. No hold-for-review label
#   8. Passes review-bot-gate (checked by general gates)
#   9. No origin:worker-takeover label (caller pre-checks)
#
# Feature flag: AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE (default: 1=on, 0=off)
# When OFF, all origin:worker PRs fall back to manual merge only.
#
# Args: $1=pr_number, $2=repo_slug, $3=labels_str (comma-separated),
#       $4=is_draft, $5=linked_issue,
#       $6=precomputed_pr_author_permission(optional),
#       $7=precomputed_pr_author_login(optional)
# Returns: 0=all gates pass (eligible for auto-merge), 1=blocked
#######################################
_attempt_worker_briefed_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	local is_draft="$4"
	local linked_issue="$5"
	local precomputed_pr_author_permission="${6:-}"
	local precomputed_pr_author_login="${7:-}"

	# Feature flag — when OFF, all origin:worker PRs fall back to manual merge
	if [[ "${AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE:-1}" == "0" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 for PR #${pr_number} in ${repo_slug} (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: not a draft
	if [[ "$is_draft" == "true" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — draft PR not eligible (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: no hold-for-review opt-out label
	if [[ ",${labels_str}," == *",hold-for-review,"* ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — hold-for-review label (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: must have a linked issue (the "brief" in "maintainer-briefed")
	if [[ -z "$linked_issue" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — no linked issue (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Reuse the issue API base path for author-association and NMR checks.
	local _issue_api
	_issue_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
	# Fetch author_association and user.login in one API call (t3062 needs login).
	local _issue_meta
	_issue_meta=$(gh api "${_issue_api}" \
		--jq 'select(.pull_request == null) | [.author_association // "", .user.login // ""] | @tsv' 2>/dev/null) || return 1
	# Explicit body references must resolve to an actual local issue, not a PR
	# sharing the repository number space or unavailable metadata.
	[[ -n "${_issue_meta//[[:space:]]/}" ]] || return 1
	local issue_author_assoc=""
	local issue_author_login=""
	read -r issue_author_assoc issue_author_login <<< "$_issue_meta"

	# GH#33999: a PR with only a non-closing For/Ref reference may be associated
	# with an issue that stays open for later phases. #aidevops:trust-boundary —
	# that association is eligible only for an open, non-parent issue; all trust
	# gates below still apply unchanged. Closing-keyword links are untouched.
	local _link_kind=""
	_link_kind=$(_worker_briefed_link_kind "$pr_number" "$repo_slug" "$linked_issue" "$_issue_api") || return 1
	local issue_author_permission=""
	#aidevops:trust-boundary — reuse PR-author permission only for the same non-empty issue-author login.
	if [[ -n "$precomputed_pr_author_permission" && -n "$precomputed_pr_author_login" && "$precomputed_pr_author_login" == "$issue_author_login" ]]; then
		issue_author_permission="$precomputed_pr_author_permission"
	fi

	local _not_true_status="not-verified"
	local _has_crypto="$_not_true_status"
	if _issue_has_verified_crypto_approval "$linked_issue" "$repo_slug"; then
		_has_crypto="true"
	fi

	# Gate: linked issue authored by OWNER/MEMBER, OR login has authenticated
	# maintainer-equivalent repo permission (GH#24958), OR login is in the
	# trusted-issue-author allowlist (t3062), OR cryptographically approved
	# by maintainer (t3052). The trust chain "maintainer SSH-signed
	# an approval on the issue" is at least as strong as the OWNER/MEMBER
	# author check — the maintainer personally vouched with their private key.
	if [[ "$issue_author_assoc" != "OWNER" && "$issue_author_assoc" != "MEMBER" ]]; then
		if _issue_author_has_maintainer_authority "$repo_slug" "$issue_author_login" "$issue_author_permission"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via authenticated maintainer permission fallback (GH#24958)" >>"$LOGFILE"
		elif _is_trusted_issue_author "$issue_author_login"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via trusted-issue-author allowlist (t3062)" >>"$LOGFILE"
		elif [[ "$_has_crypto" != "true" ]]; then
			echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} (not OWNER/MEMBER) and no cryptographic approval signature found (t2449/t3052)" >>"$LOGFILE"
			return 1
		else
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} but cryptographic approval signature present, proceeding (t3052)" >>"$LOGFILE"
		fi
	fi

	# Historical NMR/normalization comments are not current authority signals.
	# Live issue-author authority above is sufficient; external authors still
	# require verified cryptographic approval and live NMR remains blocked by the
	# general merge gates.
	echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} passed all gates (issue #${linked_issue}, link=${_link_kind}, author_assoc=${issue_author_assoc}, crypto_approved=${_has_crypto}) (t2449/t3052)" >>"$LOGFILE"
	return 0
}

#######################################
# Verify all branch-protection-required check contexts have passed on a PR.
#
# Uses the branch protection API as the authoritative source for required
# contexts — more precise than `gh pr checks --required` which can be
# confused by null-status non-required checks (CodeRabbit, qlty, linked-
# issue-check, url-allowlist, etc.) that report indefinitely and trigger the
# fail-closed path spuriously. (t2922)
#
# Called from _process_single_ready_pr to provide an escape hatch for
# origin:worker PRs when _pr_required_checks_pass fires on phantom pending
# contexts that are absent from branch_protection.required_status_checks.
#
# Passing state for each required context:
#   - StatusContext: state == SUCCESS
#   - CheckRun: conclusion in {SUCCESS, NEUTRAL, SKIPPED}
# Any context absent from the rollup, or in any other state, is non-passing.
# Fail-closed on API errors.
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=all required contexts passing, 1=some not passing or API error
#######################################
_check_required_checks_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_sha="${3:-}"

	# GH#32951: expose why contexts are not passing so native auto-merge can
	# tell never-reported contexts from in-flight ones. Empty = unknown.
	_PULSE_REQUIRED_CHECKS_NONPASS_COUNT=""
	_PULSE_REQUIRED_CHECKS_MISSING_COUNT=""
	_PULSE_CHECKS_IN_FLIGHT_COUNT=""

	# Resolve required contexts (delegates default-branch lookup + branch
	# protection API + 404 distinction to the helper). Empty stdout + exit 0
	# means "no enforcement required, treat as PASS"; exit 1 means real error.
	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 1

	# No required contexts → nothing required, treat as passing.
	if [[ -z "$required_contexts" ]]; then
		local fallback_rc=0
		_check_required_pr_checks_passing_fallback "$repo_slug" "$pr_number" >/dev/null
		fallback_rc=$?
		if [[ $fallback_rc -eq 0 ]]; then
			echo "[pulse-merge] _check_required_checks_passing: no branch/ruleset contexts and PR required checks are passing or absent for PR #${pr_number} in ${repo_slug} — allowing (t2922)" >>"$LOGFILE"
			return 0
		fi
		if [[ $fallback_rc -eq 1 ]]; then
			echo "[pulse-merge] _check_required_checks_passing: PR-level required checks are not passing for PR #${pr_number} in ${repo_slug} despite no branch/ruleset contexts — failing closed (t2922)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-merge] _check_required_checks_passing: PR-level required checks fallback failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	# GH#21799: replace GraphQL statusCheckRollup with REST check-runs (single
	# PR, separate budget pool). check-runs is heavier than check-suites
	# (~111KB/PR) but exposes per-context .name fields needed for matching
	# branch-protection required_status_checks. Single-PR path → cost is fine.
	if [[ -z "$pr_sha" ]]; then
		pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_sha=""
	fi
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922, GH#21799)" >>"$LOGFILE"
		return 1
	fi

	# REST check-runs returns the granular per-context list with .name +
	# .conclusion + .status. Need check-runs (not check-suites) because
	# branch-protection required_status_checks are matched by NAME.
	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == "null" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922, GH#21799)" >>"$LOGFILE"
		return 1
	fi

	# Build JSON array from newline-delimited required_contexts string.
	local req_json
	req_json=$(printf '%s' "$required_contexts" \
		| jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	# Count required contexts that are not in a passing state. check-runs
	# objects expose `.name`, `.conclusion`, and `.status`. Status
	# `completed` + conclusion in {success, neutral, skipped} → PASS.
	# Also count required contexts absent from the exact-head rollup and any
	# check still in flight (GH#32951).
	local counts="" failing_count="" missing_count="" in_flight_count="" _fc_exit=0
	counts=$(jq -nr \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'($req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then "NOT_FOUND"
			elif (($c.conclusion // "" | ascii_upcase)
				| . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "PASS"
			else "FAIL"
			end
		)) as $states |
		($checks | map(select(((.status // "completed") | ascii_downcase) != "completed")) | length) as $in_flight |
		"\($states | map(select(. != "PASS")) | length) \($states | map(select(. == "NOT_FOUND")) | length) \($in_flight)"' 2>/dev/null) || _fc_exit=$?
	read -r failing_count missing_count in_flight_count <<<"$counts"

	if [[ $_fc_exit -ne 0 || ! "$failing_count" =~ ^[0-9]+$ || ! "$missing_count" =~ ^[0-9]+$ || ! "$in_flight_count" =~ ^[0-9]+$ ]]; then
		echo "[pulse-merge] _check_required_checks_passing: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi
	_PULSE_REQUIRED_CHECKS_NONPASS_COUNT="$failing_count"
	_PULSE_REQUIRED_CHECKS_MISSING_COUNT="$missing_count"
	_PULSE_CHECKS_IN_FLIGHT_COUNT="$in_flight_count"

	if [[ "$failing_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_passing: ${failing_count} required context(s) not passing for PR #${pr_number} in ${repo_slug} (${missing_count} never reported, ${in_flight_count} check(s) in flight) (t2922)" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-merge] _check_required_checks_passing: all required contexts passing for PR #${pr_number} in ${repo_slug} (t2922)" >>"$LOGFILE"
	return 0
}

#######################################
# Cached check: does the repo have allow_auto_merge enabled (t3070)?
#
# Caches per repo slug in a tempdir keyed on PID for the lifetime of the
# calling process. allow_auto_merge is a repo-level setting that rarely
# changes; a stale cache at worst falls through to the existing immediate-
# merge path on the next pulse cycle.
#
# Args: $1=repo slug
# Returns: 0=enabled, 1=disabled or query error (fail-closed)
#######################################
_repo_allows_auto_merge() {
	local repo_slug="$1"
	local cache_dir="${TMPDIR:-/tmp}/aidevops-pulse-allow-auto-merge-$$"
	local cache_key
	cache_key=$(printf '%s' "$repo_slug" | tr '/' '_')
	local cache_file="${cache_dir}/${cache_key}"

	if [[ -f "$cache_file" ]]; then
		local cached
		cached=$(<"$cache_file")
		case "$cached" in
			true) return 0 ;;
			false) return 1 ;;
		esac
	fi

	mkdir -p "$cache_dir" 2>/dev/null || true

	local _flag=""
	local _f_exit=0
	_flag=$(gh api "repos/${repo_slug}" --jq '.allow_auto_merge // false' 2>/dev/null)
	_f_exit=$?
	if [[ $_f_exit -ne 0 ]]; then
		# Fail-closed: don't try native auto-merge if we can't verify.
		echo "[pulse-merge] _repo_allows_auto_merge: gh api failed for ${repo_slug} (exit ${_f_exit}), treating as disabled (t3070)" >>"$LOGFILE"
		printf '%s' "false" >"$cache_file" 2>/dev/null || true
		return 1
	fi

	if [[ "$_flag" == "true" ]]; then
		printf '%s' "true" >"$cache_file" 2>/dev/null || true
		return 0
	fi
	printf '%s' "false" >"$cache_file" 2>/dev/null || true
	return 1
}

#######################################
# Detect a wedged auto_merge request (t3192).
#
# GitHub's `mergeable_state` recomputation is async and lazy; setting
# `auto_merge: true` does not trigger immediate recompute, and once
# `BLOCKED` is cached on a PR the state can stick for hours even after the
# original cause (pending CI, missing approval) has been resolved. Pulse
# cycles see `auto_merge` set, the t3070 fast path returns 0, and the PR
# sits indefinitely. Observed 2026-04-30 on PRs that sat 8-9h despite
# 100% required-check SUCCESS and `mergeable=MERGEABLE`.
#
# Stuck means ALL of:
#   * mergeStateStatus == BLOCKED
#   * mergeable == MERGEABLE
#   * reviewDecision is known-safe for this already-gated cycle
#   * autoMergeRequest.enabledAt > $threshold seconds ago
#   * No required check is in fail/pending/cancel bucket (only pass/skipping)
#
# Threshold defaults to 300s, overridable via
# AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS.
#
# Args: $1=pr_number, $2=repo_slug, $3=normalized current-cycle PR state JSON
# Stdout: stuck-seconds count when stuck (caller logs it)
# Returns: 0=stuck, safe to fall through to --admin; 1=defer to GitHub
#######################################
_auto_merge_stuck_seconds() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_state="$3"
	local threshold="${AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS:-300}"

	local enabled_at merge_state mergeable review_decision
	IFS=$'\t' read -r enabled_at merge_state mergeable review_decision <<<"$(printf '%s' "$pr_state" \
		| jq -r '[.autoMergeRequest.enabledAt // "", .mergeStateStatus // "", .mergeable // "", .reviewDecision // ""] | @tsv' \
		|| true)"

	# Glob form (unquoted RHS inside [[ ]]) avoids adding new repeated string
	# literals — the validator counts only quoted 4+-char literals.
	[[ "$merge_state" == BLOCKED ]] || return 1
	[[ "$mergeable" == MERGEABLE ]] || return 1
	[[ -n "$enabled_at" ]] || return 1

	local enabled_epoch now_epoch stuck_seconds
	enabled_epoch=$(date -u -d "$enabled_at" +%s 2>/dev/null \
		|| TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$enabled_at" +%s 2>/dev/null \
		|| echo "0")
	[[ "$enabled_epoch" =~ ^[0-9]+$ && "$enabled_epoch" -gt 0 ]] || return 1
	now_epoch=$(date -u +%s)
	stuck_seconds=$((now_epoch - enabled_epoch))
	[[ "$stuck_seconds" -gt "$threshold" ]] || return 1

	# The cycle's review projection can become stale between its gate and this
	# destructive wedge bypass. Re-read bounded REST history now; unavailable or
	# contradictory evidence must not authorize an admin fall-through.
	local fresh_review_decision=""
	_pmp_refresh_native_auto_review_into fresh_review_decision "$pr_number" "$repo_slug" "$review_decision" || return 1
	case "$fresh_review_decision" in
	OBSERVED_APPROVED | NONE) ;;
	*) return 1 ;;
	esac

	# Confirm no required check is still pending or has failed. We require
	# every required check to be in `pass` or `skipping` bucket — anything
	# else means the PR has a legitimate reason to stay blocked, and
	# falling through to --admin would bypass that signal.
	_check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1 || return 1

	printf '%s' "$stuck_seconds"
	return 0
}

# Disarm an already-deferred merge whose mutable approval state now requires a
# synchronous final gate. Draft conversion is the independent server-side hold
# when GitHub rejects disable-auto.
_stop_external_native_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local hold_reason="${3:-external approval state must be revalidated at the actual merge call}"
	local disable_output=""
	local draft_hold_output=""

	if disable_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --disable-auto 2>&1); then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: disabled deferred native auto-merge because ${hold_reason}" >>"$LOGFILE"
		return 0
	fi
	if draft_hold_output=$(gh pr ready "$pr_number" --repo "$repo_slug" --undo 2>&1); then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: disable-auto failed, so PR was returned to draft because ${hold_reason}: ${disable_output}" >>"$LOGFILE"
		return 2
	fi
	echo "[pulse-merge] SECURITY HOLD FAILED for PR #${pr_number} in ${repo_slug}: could not disable external auto-merge or return PR to draft because ${hold_reason}; manual intervention required. disable=${disable_output}; draft=${draft_hold_output}" >>"$LOGFILE"
	return 3
}

_enable_native_auto_merge_for_head() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local pending_count="$4"
	local auto_output=""
	local auto_exit=0

	if [[ -z "$expected_head_sha" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: native auto-merge not set because the gated head SHA is unavailable" >>"$LOGFILE"
		return 1
	fi
	auto_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --auto --squash \
		--match-head-commit "$expected_head_sha" 2>&1)
	auto_exit=$?
	if [[ "$auto_exit" -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: native auto-merge set (CI ${pending_count} pending), GitHub merges on green (t3070)" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: gh pr merge --auto failed (exit ${auto_exit}): ${auto_output} — falling through to immediate merge (t3070)" >>"$LOGFILE"
	return 1
}

_pmp_issue_sync_run_api() {
	local operation="$1"
	shift
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout "$operation" "$@"
	else
		"$@"
	fi
}

_pmp_audit_issue_sync_run_approval() {
	local repo_slug="$1"
	local pr_number="$2"
	local expected_head_sha="$3"
	local run_id="$4"
	local outcome="$5"
	local audit_helper="${_PULSE_MERGE_PROCESS_DIR}/audit-log-helper.sh"

	[[ -x "$audit_helper" ]] || return 0
	"$audit_helper" log operation.verify \
		"pulse approved trusted Issue Sync workflow run ${run_id} for PR #${pr_number} in ${repo_slug} — ${outcome}" \
		--detail "op=pulse.issue-sync-run-approval" \
		--detail "repo=${repo_slug}" \
		--detail "pr=${pr_number}" \
		--detail "head=${expected_head_sha}" \
		--detail "run=${run_id}" \
		--detail "outcome=${outcome}" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Approve pull_request workflow runs that GitHub held for a repository-generated
# Issue Sync PR. The shared immutable trust predicate remains the authority;
# every candidate and the live PR head are checked again before each mutation.
#
# Args: $1=pr_number, $2=repo_slug, $3=expected_head_sha
# Returns: 0=no candidates or all candidates approved/idempotently cleared;
#          1=API, schema, identity, association, or freshness failure
# Sets: _PULSE_ISSUE_SYNC_RUNS_APPROVED to the number of approved/cleared runs
#######################################
_pmp_approve_issue_sync_action_required_runs() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local runs_json="" candidates_json="" run_ids="" run_id=""
	local live_identity="" live_head_sha="" live_head_repo=""
	local approve_output="" run_conclusion="" approved_count=0
	_PULSE_ISSUE_SYNC_RUNS_APPROVED=0

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" && -n "$expected_head_sha" ]] || return 1
	#aidevops:trust-boundary -- workflow approval is available only to the shared
	# immutable exact-head Issue Sync authority predicate.
	_pulse_is_trusted_issue_sync_pr "$pr_number" "$repo_slug" "$expected_head_sha" || return 0

	runs_json=$(_pmp_issue_sync_run_api read gh api \
		"repos/${repo_slug}/actions/runs?event=pull_request&head_sha=${expected_head_sha}&per_page=100") || {
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: trusted Issue Sync action-required run listing failed; refusing workflow approval" >>"$LOGFILE"
		return 1
	}
	if ! printf '%s' "$runs_json" | jq -e '
		type == "object"
		and (.total_count | type == "number" and . >= 0 and . <= 100)
		and (.workflow_runs | type == "array")
		and (.total_count == (.workflow_runs | length))
	' >/dev/null 2>&1; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: trusted Issue Sync workflow-run response was malformed or exceeded the 100-run bound; refusing workflow approval" >>"$LOGFILE"
		return 1
	fi
	candidates_json=$(printf '%s' "$runs_json" | jq -c '[.workflow_runs[] | select((.conclusion // "") == "action_required")]') || return 1
	[[ "$candidates_json" != "[]" ]] || return 0
	if ! printf '%s' "$candidates_json" | jq -e --arg repo "$repo_slug" --arg head "$expected_head_sha" --argjson pr "$pr_number" '
		all(.[ ];
			(.id | type == "number")
			and .event == "pull_request"
			and .conclusion == "action_required"
			and .head_sha == $head
			and .head_repository.full_name == $repo
			and (.pull_requests | type == "array" and length == 1)
			and .pull_requests[0].number == $pr)
	' >/dev/null 2>&1; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: action-required run identity, repository, head, or PR association did not match; refusing workflow approval" >>"$LOGFILE"
		return 1
	fi
	run_ids=$(printf '%s' "$candidates_json" | jq -r '.[].id') || return 1

	while IFS= read -r run_id; do
		[[ "$run_id" =~ ^[0-9]+$ ]] || return 1
		live_identity=$(_pmp_issue_sync_run_api read gh api "repos/${repo_slug}/pulls/${pr_number}" \
			--jq '[.head.sha // "", .head.repo.full_name // ""] | @tsv') || return 1
		IFS=$'\t' read -r live_head_sha live_head_repo <<<"$live_identity"
		#aidevops:trust-boundary -- revalidate both current ownership and the shared
		# immutable Issue Sync predicate immediately before every run approval.
		if [[ "$live_head_sha" != "$expected_head_sha" || "$live_head_repo" != "$repo_slug" ]] \
			|| ! _pulse_is_trusted_issue_sync_pr "$pr_number" "$repo_slug" "$expected_head_sha"; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: head or Issue Sync trust changed before workflow run ${run_id} approval; refusing remaining approvals" >>"$LOGFILE"
			return 1
		fi
		if approve_output=$(_pmp_issue_sync_run_api write gh api -X POST \
			"repos/${repo_slug}/actions/runs/${run_id}/approve" 2>&1); then
			approved_count=$((approved_count + 1))
			_pmp_audit_issue_sync_run_approval "$repo_slug" "$pr_number" "$expected_head_sha" "$run_id" approved
			continue
		fi
		run_conclusion=$(_pmp_issue_sync_run_api read gh api \
			"repos/${repo_slug}/actions/runs/${run_id}" --jq '.conclusion // ""' 2>/dev/null) || return 1
		if [[ "$run_conclusion" != "action_required" && -n "$run_conclusion" ]]; then
			approved_count=$((approved_count + 1))
			_pmp_audit_issue_sync_run_approval "$repo_slug" "$pr_number" "$expected_head_sha" "$run_id" already-cleared
			continue
		fi
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: approval failed for trusted Issue Sync workflow run ${run_id}; refusing remaining approvals: ${approve_output}" >>"$LOGFILE"
		return 1
	done <<<"$run_ids"

	_PULSE_ISSUE_SYNC_RUNS_APPROVED="$approved_count"
	if declare -F gh_pr_check_status_cache_invalidate >/dev/null 2>&1 \
		&& ! gh_pr_check_status_cache_invalidate "$repo_slug" "$expected_head_sha"; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: approved Issue Sync runs but required-check cache invalidation failed; deferring for a fresh pass" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: approved or confirmed cleared ${approved_count} exact-head action-required Issue Sync workflow run(s); refreshing required checks on the next pass" >>"$LOGFILE"
	return 0
}

_handle_existing_native_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local require_synchronous_final_gate="$3"
	local expected_head_sha="$4"
	local pr_state="$5"
	local snapshot_head_sha="" stop_rc=0

	if [[ "$require_synchronous_final_gate" == "1" ]]; then
		_stop_external_native_auto_merge "$pr_number" "$repo_slug" || stop_rc=$?
		[[ "$stop_rc" -eq 0 ]] && return 2
		return "$stop_rc"
	fi
	snapshot_head_sha=$(printf '%s' "$pr_state" | jq -r '.headRefOid // empty' 2>/dev/null) || snapshot_head_sha=""
	if [[ -z "$expected_head_sha" || -z "$snapshot_head_sha" || "$snapshot_head_sha" != "$expected_head_sha" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: existing native auto-merge head no longer matches the gated head; disarming and deferring" >>"$LOGFILE"
		_stop_external_native_auto_merge "$pr_number" "$repo_slug" \
			"the live head no longer matches the gated head" || stop_rc=$?
		[[ "$stop_rc" -eq 0 ]] && return 2
		return "$stop_rc"
	fi

	local stuck_seconds=""
	if stuck_seconds=$(_auto_merge_stuck_seconds "$pr_number" "$repo_slug" "$pr_state"); then
		local threshold="${AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS:-300}"
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge stuck ${stuck_seconds}s (>${threshold}s) in BLOCKED+MERGEABLE with no failing/pending required checks — attempting synchronous recovery (t3192)" >>"$LOGFILE"
		stop_rc=0
		_stop_external_native_auto_merge "$pr_number" "$repo_slug" \
			"stale wedge recovery requires a fresh synchronous merge (GH#26897)" || stop_rc=$?
		if [[ "$stop_rc" -eq 0 ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: disabled stale native auto-merge before immediate merge (GH#26897)" >>"$LOGFILE"
			return 1
		fi
		return "$stop_rc"
	fi

	local pending_count=0
	if ! _check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1; then
		pending_count=1
	fi
	if [[ "$pending_count" -gt 0 ]] \
		&& _pmp_remediate_missing_required_checks "$pr_number" "$repo_slug" "$expected_head_sha"; then
		# GH#32951: required contexts never reported; CI retrigger requested
		# or bounded. Keep the existing request instead of churning it.
		return 0
	fi
	if [[ "$pending_count" -gt 0 ]]; then
		local enabled_at="" enabled_epoch="0" now_epoch="0" age_seconds="0"
		enabled_at=$(printf '%s' "$pr_state" | jq -r '.autoMergeRequest.enabledAt // ""' 2>/dev/null) || enabled_at=""
		enabled_epoch=$(date -u -d "$enabled_at" +%s 2>/dev/null \
			|| TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$enabled_at" +%s 2>/dev/null \
			|| echo "0")
		[[ "$enabled_epoch" =~ ^[0-9]+$ ]] || enabled_epoch=0
		now_epoch=$(date -u +%s)
		age_seconds=$((now_epoch - enabled_epoch))
		local threshold="${AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS:-300}"
		if [[ "$enabled_epoch" -gt 0 && "$age_seconds" -gt "$threshold" ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge has ${pending_count} required check(s) pending for ${age_seconds}s (>${threshold}s) — deferring as non-terminal (t3567)" >>"$LOGFILE"
			return 0
		fi
	fi
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge already set, deferring to GitHub (t3070)" >>"$LOGFILE"
	return 0
}

#######################################
# Conditionally hand a PR off to GitHub native auto-merge (t3070).
#
# Eliminates the ~120s pulse poll-cycle latency between CI green and merge
# call. When the repo has allow_auto_merge enabled and at least one
# required check is currently pending, ask GitHub to merge as soon as CI
# turns green via `gh pr merge --auto --squash`. GitHub then merges within
# seconds of the last required check completing instead of waiting for the
# next pulse cycle to detect green.
#
# Decision tree:
#   * PR already has auto_merge set + STUCK green → return 1 (caller --admin path,
#                                                             t3192 stuck fallback)
#   * PR already has auto_merge set + stale pending → return 0 (non-terminal;
#                                                               keep deferring)
#   * PR already has auto_merge set + healthy → return 0 (no-op, GitHub
#                                                         finishes the job)
#   * Repo allow_auto_merge=false      → return 1 (caller --admin path)
#   * No required check pending        → return 1 (caller --admin path —
#                                                  immediate merge fastest)
#   * Required contexts never reported → return 2 (bounded update-branch
#     on an aged head, nothing in flight   retriggers CI; GH#32951)
#   * gh pr merge --auto succeeds      → return 0 (caller skips merge)
#   * gh pr merge --auto fails         → return 1 (caller --admin fallback)
#
# Caller MUST verify all other merge gates (review, maintainer, scope,
# review-bot-gate, complexity) BEFORE invoking. This helper only chooses
# between native-auto and immediate-merge — it does not gate trust.
#
# Native auto-merge respects branch protection (no --admin bypass). Repos
# bypass-merging through pending checks should keep the immediate-merge
# fallback (returns 1 path) — this trade-off is acceptable for owned-org
# repos where allow_auto_merge=true is bulk-enabled and CI is fast.
#
# Args: $1=pr_number, $2=repo_slug, $3=require synchronous final gate (0|1),
#       $4=current already-gated review state, $5=gated head SHA
# Returns: 0=native-auto requested/deferred, 1=fall through,
#          2=defer without native auto-merge so mutable approval state is
#            revalidated on a later synchronous merge cycle
#######################################
_set_native_auto_merge_or_skip() {
	local pr_number="$1"
	local repo_slug="$2"
	local require_synchronous_final_gate="${3:-0}"
	local current_review="${4:-UNKNOWN}"
	local expected_head_sha="${5:-}"

	# Fetch auto_merge metadata + merge state through exact-attribution routes.
	# Carry forward the review state that passed this cycle's gate; unknown or
	# blocking states cannot authorize stale native-auto wedge recovery.
	local _pr_state
	_pr_state=$(_pmp_native_auto_merge_state "$pr_number" "$repo_slug" "$current_review" 2>/dev/null) || _pr_state=""

	local _existing_auto=""
	if [[ -n "$_pr_state" ]]; then
		_existing_auto=$(printf '%s' "$_pr_state" | jq -r '.autoMergeRequest // empty' 2>/dev/null)
	fi

	if [[ -n "$_existing_auto" ]]; then
		_handle_existing_native_auto_merge "$pr_number" "$repo_slug" \
			"$require_synchronous_final_gate" "$expected_head_sha" "$_pr_state"
		return $?
	fi

	# Skip if repo does not allow auto-merge — fall through to immediate merge.
	if ! _repo_allows_auto_merge "$repo_slug"; then
		return 1
	fi

	# Determine if any required check is currently pending. If everything is
	# already done (success/skipped — failures filtered upstream by
	# _pr_required_checks_pass), the immediate --admin path is faster than
	# round-tripping through GitHub's auto-merge engine.
	local pending_count=0
	if ! _check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1; then
		pending_count=1
	fi

	if [[ "$pending_count" -eq 0 ]]; then
		# No pending required checks — immediate --admin merge is faster.
		return 1
	fi
	if [[ "$require_synchronous_final_gate" == "1" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI pending; external approval state requires synchronous final revalidation, so native auto-merge remains disabled" >>"$LOGFILE"
		return 2
	fi
	# GH#32951: never-reported required contexts cannot turn green; retrigger
	# CI (bounded) instead of arming a native auto-merge that cannot finish.
	if _pmp_remediate_missing_required_checks "$pr_number" "$repo_slug" "$expected_head_sha"; then
		return 2
	fi

	# CI in flight — ask GitHub to merge on green, bound to the gated head.
	_enable_native_auto_merge_for_head "$pr_number" "$repo_slug" "$expected_head_sha" "$pending_count"
	return $?
}
