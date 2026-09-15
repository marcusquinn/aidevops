#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-feedback.sh — Worker-PR feedback routing for the deterministic merge pass.
#
# Extracted from pulse-merge.sh (GH#19836) to bring that file below the
# 2000-line simplification gate.
#
# This module contains the "route feedback to linked issue + close PR"
# cluster: the three dispatch helpers invoked by _check_pr_merge_gates
# when a worker-authored PR hits a dead-end state (CI red, conflicts
# unresolvable by update-branch, or CHANGES_REQUESTED review). Each
# helper appends a feedback section to the linked issue body (marker-
# guarded for idempotency), transitions the issue to status:available,
# and closes the PR so the dispatch queue can re-pick the work.
#
# None of these functions call back into the merge core or pr-gates
# clusters — they only call low-level `gh` commands, `set_issue_status`
# from shared-constants.sh, and the local `_build_review_feedback_section`
# helper. Safe to extract into its own module.
#
# This module is sourced by pulse-wrapper.sh AFTER pulse-merge.sh and
# pulse-merge-conflict.sh. It MUST NOT be executed directly — it relies
# on the orchestrator having sourced shared-constants.sh and having
# defined all PULSE_* configuration constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _build_review_feedback_section      (t2093)
#   - _review_feedback_has_trusted_body_change_request (GH#30703)
#   - _review_feedback_preserve_ready_pr  (GH#30821)
#   - _append_feedback_to_issue           (GH#20057, shared helper)
#   - _transition_issue_for_redispatch    (GH#20057, shared helper)
#   - _finalize_feedback_route            (GH#29288, sourced state machine)
#   - _build_ci_feedback_section          (GH#20057, extracted builder)
#   - _dispatch_ci_fix_worker             (t2093 follow-up)
#   - _classify_conflicts_by_pattern      (t2987, pattern classifier)
#   - _emit_pattern_guidance_blocks       (t2987, guidance emitter)
#   - _build_conflict_feedback_section    (t2426, extracted builder)
#   - _dispatch_conflict_fix_worker       (t2093 follow-up)
#   - _dispatch_pr_fix_worker             (t2093)
#
# Routing failures remain isolated from unrelated PRs, but incomplete
# finalization returns a typed deferred/maintainer outcome to the merge loop.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_FEEDBACK_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_LOADED=1

# t2863: Module-level variable defaults (set -u guards).
# Ensures LOGFILE is safe to dereference in all functions when this module
# is sourced outside the pulse-wrapper.sh bootstrap context.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${PULSE_REVIEW_FEEDBACK_ITEM_LIMIT:=4000}"
: "${PULSE_REVIEW_FEEDBACK_SECTION_LIMIT:=12000}"
PULSE_REVIEW_REPAIR_SOURCE_LABEL="source:review-repair"
PULSE_FEEDBACK_JSON_STRING_TYPE="string"
PULSE_REVIEW_FEEDBACK_NO_TRUSTED_REVIEW_RC=2

_CI_REPAIR_OUTCOME_SUMMARY=""

_pmf_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_feedback_finalizer_path="${BASH_SOURCE[0]%/*}/pulse-merge-feedback-finalizer.sh"
if [[ -r "$_feedback_finalizer_path" ]]; then
	# shellcheck source=./pulse-merge-feedback-finalizer.sh
	source "$_feedback_finalizer_path"
fi
unset _feedback_finalizer_path

# _dispatch_ci_fix_worker stays here to preserve its complexity identity key.
#######################################
# Route CI failure feedback from a worker/trusted PR to a bounded repair worker
# on the existing PR branch. Fall back to issue redispatch only when the branch
# cannot be repaired in place.
#
# The repair worker sees failing check names, URLs, and current-head context.
# Its durable lease is keyed by repo + PR + head SHA so reordered or changing
# check evidence cannot launch overlapping workers against one branch head. A
# newly-pushed head can enter repair independently if it is still red.
#
# Same pattern as _dispatch_pr_fix_worker (t2093) but for CI failures
# instead of review CHANGES_REQUESTED.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=checks_json (optional)
#######################################
_dispatch_ci_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local supplied_checks_json="${4:-}" initial_head_sha=""
	_CI_REPAIR_OUTCOME_SUMMARY=""

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids CI repair dispatch and feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	initial_head_sha=$(gh pr view "$pr_number" --repo "$repo_slug" --json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || initial_head_sha=""
	if [[ -z "$initial_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} head snapshot unavailable before collecting CI evidence — deferring repair routing" >>"$LOGFILE"
		return 0
	fi

	# Collect actionable failed required checks first. Pending/queued/in-progress
	# checks are not actionable repair evidence and must not be routed into the
	# linked issue as stale worker guidance. Likewise, cancelled/timed_out checks
	# usually reflect CI capacity, superseded runs, or job-budget kills; routing
	# those as code-fix feedback creates duplicate PR churn instead of retrying or
	# escalating CI infrastructure. If required checks contain no actionable
	# failures. Advisory failures do not justify branch ownership or repair work.
	local terminal_failed_check_filter='(.bucket == "fail" or .bucket == "cancel") and (((.conclusion // .state // "") | ascii_downcase) | test("^(failure|action_required)$")) and ((.link // "") != "")'
	local checks_json="" result_marker=$'\n__AIDEVOPS_CHECK_NAMES__'
	local check_results="" failing_checks_json="" failing_checks="" failing_names="" classification_output=""
	checks_json=$(_ci_repair_checks_for_dispatch "$repo_slug" "$pr_number" "$supplied_checks_json")
	check_results=$(_ci_terminal_failed_check_results "$checks_json" "$terminal_failed_check_filter")
	failing_checks_json="${check_results%%"$result_marker"*}"
	failing_names="${check_results#*"$result_marker"}"
	[[ "$failing_names" != "$check_results" ]] || failing_names=""
	failing_names="${failing_names#$'\n'}"
	failing_checks=$(_ci_actionable_failed_checks_markdown "$pr_number" "$repo_slug" "$failing_checks_json")

	if [[ -z "$failing_checks" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} in ${repo_slug} has no actionable failed checks with URLs — skipping CI repair routing" >>"$LOGFILE"
		return 0
	fi

	# t3225: Also collect raw failing check NAMES (one per line) for
	# pattern classification. Failure to collect names is non-fatal — we
	# fall back to the pre-t3225 behaviour (no pattern guidance block).
	if [[ -n "$failing_names" ]]; then
		classification_output=$(_classify_ci_failures_by_pattern "$failing_names" 2>/dev/null) || classification_output=""
	fi

	# Bind repair evidence to the current branch head. This refresh also proves
	# the branch is same-repository and writable before any worker is launched.
	local pr_info="" pr_head_sha="" pr_head_ref="" is_cross_repo="" maintainer_can_modify=""
	pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid,headRefName,isCrossRepository,maintainerCanModify \
		--jq '[(.headRefOid // ""),(.headRefName // ""),(.isCrossRepository // false),(.maintainerCanModify // false)] | @tsv' 2>/dev/null) || pr_info=""
	IFS=$'\t' read -r pr_head_sha pr_head_ref is_cross_repo maintainer_can_modify <<<"$pr_info"
	if [[ -n "$initial_head_sha" && "$pr_head_sha" != "$initial_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} head changed while collecting CI evidence (${initial_head_sha} -> ${pr_head_sha:-unknown}) — deferring repair routing" >>"$LOGFILE"
		return 0
	fi

	local failure_fingerprint=""
	failure_fingerprint=$(_ci_repair_hash_text "$(printf '%s\n' "$failing_checks_json" | jq -cS '.' 2>/dev/null)") || failure_fingerprint=""
	[[ -n "$failure_fingerprint" ]] || failure_fingerprint="unknown"

	# Build the CI Failure Feedback section (with optional pattern guidance).
	local feedback_section
	feedback_section=$(_build_ci_feedback_section "$pr_number" "$failing_checks" "$classification_output")

	local fallback_reason=""
	if [[ -z "$pr_head_sha" || -z "$pr_head_ref" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: current branch metadata unavailable for PR #${pr_number} in ${repo_slug} — preserving PR for a later repair pass" >>"$LOGFILE"
		return 0
	elif [[ "$is_cross_repo" == "true" ]]; then
		fallback_reason="the PR head is in a fork and is not an owned repair branch"
	elif ! declare -F _pulse_merge_repo_path_for_slug >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: repository-path resolver unavailable for PR #${pr_number} in ${repo_slug} — preserving PR for a later repair pass" >>"$LOGFILE"
		return 0
	elif _dispatch_ci_repair_session "$pr_number" "$repo_slug" "$linked_issue" \
		"$pr_head_sha" "$pr_head_ref" "$failure_fingerprint" "$failing_checks"; then
		if [[ "${_CI_REPAIR_DISPATCH_RESULT:-}" == "active" ]]; then
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: in-place CI repair already active for PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} in ${repo_slug}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: dispatched in-place CI repair for PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} in ${repo_slug}" >>"$LOGFILE"
		fi
		return 0
	elif [[ "${_CI_REPAIR_DISPATCH_RESULT:-}" == "exhausted" ]]; then
		fallback_reason="the bounded PR-branch repair session exhausted its retry budget"
	else
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: retryable in-place repair launch failure for PR #${pr_number} head ${pr_head_sha} in ${repo_slug} (result=${_CI_REPAIR_DISPATCH_RESULT:-unknown}) — preserving PR for a later bounded attempt" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] _dispatch_ci_fix_worker: durable fallback authorized for PR #${pr_number} in ${repo_slug}: ${fallback_reason}" >>"$LOGFILE"
	local route_rc=0
	_route_ci_repair_fallback "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"$pr_head_ref" "$failure_fingerprint" "$fallback_reason" "$feedback_section" "$failing_checks" \
		"$_CI_REPAIR_OUTCOME_SUMMARY" || route_rc=$?
	return "$route_rc"
}

_review_feedback_evidence_fingerprint() {
	local reviews_json="$1"
	local inline_json="$2"
	local canonical=""
	local fingerprint=""

	canonical=$(printf '%s\n%s\n' "$reviews_json" "$inline_json" | jq -csS '
		.[0] as $reviews | .[1] as $inline |
		{
			version: 1,
			reviews: ($reviews | map({
				id: (.id // "" | tostring), author: (.author // ""),
				state: (.state // ""), body: (.body // ""), url: (.url // ""),
				submitted_at: (.submitted_at // ""), commit_id: (.commit_id // "")
			}) | sort_by(.id, .submitted_at, .commit_id)),
			inline: ($inline | map({
				id: (.id // "" | tostring), author: (.author // ""), path: (.path // ""),
				line: (.line // 0), body: (.body // ""), url: (.url // ""),
				updated_at: (.updated_at // ""), commit_id: (.commit_id // "")
			}) | sort_by(.id, .updated_at, .commit_id))
		}
		| select(all(.reviews[]; .id != "") and all(.inline[]; .id != ""))
	' 2>/dev/null) || return 1
	[[ -n "$canonical" ]] || return 1
	fingerprint=$(_ci_repair_hash_text "$canonical") || return 1
	[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$fingerprint"
	return 0
}

# shellcheck source=./pulse-merge-feedback-review.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via BASH_SOURCE
source "${BASH_SOURCE[0]%/*}/pulse-merge-feedback-review.sh"

# shellcheck source=./pulse-merge-feedback-ci-repair.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via BASH_SOURCE
source "${BASH_SOURCE[0]%/*}/pulse-merge-feedback-ci-repair.sh"

# shellcheck source=./pulse-merge-feedback-conflict.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via BASH_SOURCE
source "${BASH_SOURCE[0]%/*}/pulse-merge-feedback-conflict.sh"

# shellcheck source=./pulse-merge-feedback-ci-patterns.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via BASH_SOURCE
source "${BASH_SOURCE[0]%/*}/pulse-merge-feedback-ci-patterns.sh"
