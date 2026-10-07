#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-backlog.sh -- Per-Repo PR Backlog Preparation for the Merge Pass
# =============================================================================
# Extracted verbatim from pulse-merge-process.sh (GH#27171) to keep the merge
# orchestrator below the file-size-debt threshold. Covers the advisory backlog
# buckets and ordering, bounded PR-list reads, exact retry-target expansion,
# per-PR cursor enrichment, per-repo cache/deadline setup, and the deadline-
# bounded evaluator wrapper used by _merge_ready_prs_for_repo.
#
# Every merge safety gate remains in _process_single_ready_pr; nothing here
# decides merge eligibility.
#
# Usage: source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-backlog.sh"
#        (sourced by pulse-merge-process.sh; do not execute directly)
#
# Dependencies:
#   - pulse-merge-process.sh (_PMP_CHECK_FAILURE, LOGFILE, STOP_FLAG,
#     PULSE_MERGE_BATCH_LIMIT defaults)
#   - pulse-merge-rest-state.sh, pulse-merge-pass.sh, pulse-merge-timing.sh,
#     pulse-merge-unchanged-skip.sh (resolved at call time)
#   - pulse-merge.sh (_pulse_merge_ready_pr_json_fields, _process_single_ready_pr)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_BACKLOG_LIB_LOADED:-}" ]] && return 0
_PULSE_MERGE_BACKLOG_LIB_LOADED=1

_pmp_cache_key() {
	local raw_key="$1"
	local safe_key=""
	safe_key=$(printf '%s' "$raw_key" | tr -c '[:alnum:]._-' '_')
	[[ -n "$safe_key" ]] || safe_key="empty"
	printf '%s' "$safe_key"
	return 0
}

# PR backlog categories exposed in logs. These are scheduling/observability
# buckets only; _process_single_ready_pr still enforces every merge safety gate
# before approving, merging, closing, or dispatching a fix worker.
readonly _PMP_BACKLOG_MERGE_READY="merge-ready"
readonly _PMP_BACKLOG_CHECKS_IN_PROGRESS="checks-in-progress"
readonly _PMP_BACKLOG_SMALL_FIX_NEEDED="small-fix-needed"
readonly _PMP_BACKLOG_DIRTY_CONFLICTED="dirty-conflicted"
readonly _PMP_BACKLOG_HUMAN_APPROVAL_NEEDED="human-approval-needed"
readonly _PMP_BACKLOG_OTHER="other"

#######################################
# Classify one PR object into a scheduling/observability backlog bucket.
# This is intentionally advisory: it never decides merge eligibility. The
# existing per-PR gate stack remains authoritative.
#
# Args:
#   $1 - compact PR JSON object from gh_pr_list
# Output: one of the _PMP_BACKLOG_* values
#######################################
_pmp_classify_pr_backlog_state() {
	local pr_obj="$1"
	local repo_slug="${2:-}"
	local _RS=$'\x1e'
	local number="" mergeable="" review_decision="" is_draft="" labels="" failed_count="" pending_count=""
	IFS="$_RS" read -r number mergeable review_decision is_draft labels failed_count pending_count < <(
		printf '%s' "$pr_obj" | jq -r --arg failure "$_PMP_CHECK_FAILURE" '
			def up(v): (v // "" | ascii_upcase);
			def failed: [.statusCheckRollup[]? | select(up(.conclusion) == $failure or up(.state) == $failure)] | length;
			def pending: [.statusCheckRollup[]? | select(up(.status) == "QUEUED" or up(.status) == "IN_PROGRESS" or up(.state) == "PENDING" or up(.state) == "EXPECTED" or ((up(.conclusion) == "") and (up(.state) != "SUCCESS") and (up(.status) != "COMPLETED")))] | length;
			"\(.number // "")\u001e\(.mergeable // "UNKNOWN")\u001e\(if ((has("reviewDecision") | not) or .reviewDecision == null or (.reviewDecision | tostring | length) == 0) then "UNKNOWN" else .reviewDecision end)\u001e\(.isDraft // false)\u001e\([.labels[].name] | join(","))\u001e\(failed)\u001e\(pending)"' 2>/dev/null
	)
	_pmp_normalize_mergeable_state_into mergeable "$mergeable"
	_pmp_normalize_review_decision_into review_decision "$review_decision"

	[[ "$failed_count" =~ ^[0-9]+$ ]] || failed_count=0
	[[ "$pending_count" =~ ^[0-9]+$ ]] || pending_count=0

	if [[ "$is_draft" == "true" || ",${labels}," == *",hold-for-review,"* || "$review_decision" == "CHANGES_REQUESTED" ]] ||
		_pmp_review_decision_is_unknown "$review_decision"; then
		printf '%s' "$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED"
		return 0
	fi
	if [[ "$mergeable" == "CONFLICTING" ]]; then
		printf '%s' "$_PMP_BACKLOG_DIRTY_CONFLICTED"
		return 0
	fi
	if [[ "$failed_count" -gt 0 ]]; then
		if _pmp_review_decision_is_unknown "$review_decision"; then
			printf '%s' "$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED"
			return 0
		fi
		printf '%s' "$_PMP_BACKLOG_SMALL_FIX_NEEDED"
		return 0
	fi
	if [[ "$pending_count" -gt 0 || "$mergeable" == "UNKNOWN" ]]; then
		printf '%s' "$_PMP_BACKLOG_CHECKS_IN_PROGRESS"
		return 0
	fi
	if [[ "$mergeable" == "MERGEABLE" ]]; then
		printf '%s' "$_PMP_BACKLOG_MERGE_READY"
		return 0
	fi
	printf '%s' "$_PMP_BACKLOG_OTHER"
	return 0
}

_pmp_enrich_prs_with_rest_check_status() {
	local repo_slug="$1"
	local pr_json="$2"
	local status_json=""
	status_json=$(gh_pr_check_status_rest_batch "$repo_slug" "$pr_json" 2>/dev/null) || status_json="[]"
	[[ -n "$status_json" && "$status_json" != "null" ]] || status_json="[]"
	jq -n --arg failure "$_PMP_CHECK_FAILURE" --argjson prs "$pr_json" --argjson statuses "$status_json" '
		def rollup($s):
			if $s == "PASS" then [{status:"COMPLETED", conclusion:"SUCCESS", state:"SUCCESS"}]
			elif $s == "FAIL" then [{status:"COMPLETED", conclusion:$failure, state:$failure}]
			elif $s == "PENDING" then [{status:"IN_PROGRESS", conclusion:null, state:"PENDING"}]
			else [] end;
		$prs | map(. as $pr | ($statuses | map(select(.number == $pr.number)) | last | .status // "none") as $s | $pr + {statusCheckRollup: rollup($s)})' \
		2>/dev/null || printf '%s' "$pr_json"
	return 0
}

#######################################
# Convert a backlog bucket to a numeric scheduling priority.
# Lower number runs first. Merge-ready and fix-needed PRs are processed before
# unrelated dispatch stages get any budget because this sort happens inside the
# deterministic merge pass, which runs before dispatch_max.
#
# Args:
#   $1 - backlog category string
# Output: integer priority
#######################################
_pmp_backlog_priority() {
	local category="$1"
	case "$category" in
	"$_PMP_BACKLOG_MERGE_READY") printf '10' ;;
	"$_PMP_BACKLOG_SMALL_FIX_NEEDED") printf '20' ;;
	"$_PMP_BACKLOG_CHECKS_IN_PROGRESS") printf '30' ;;
	"$_PMP_BACKLOG_DIRTY_CONFLICTED") printf '40' ;;
	"$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED") printf '50' ;;
	*) printf '90' ;;
	esac
	return 0
}

#######################################
# Sort a PR JSON array by backlog attention priority, preserving original
# order inside each category. Emits a JSON array.
#
# Args:
#   $1 - JSON array of PR objects
# Output: JSON array sorted by backlog priority
#######################################
_pmp_sort_prs_by_backlog_priority() {
	local pr_json="$1"
	local repo_slug="${2:-}"
	local pr_count=""
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	if [[ "$pr_count" -eq 0 ]]; then
		printf '[]'
		return 0
	fi

	local _tmp_lines=""
	_tmp_lines=$(mktemp)
	local dirty_keys=""
	if declare -F _pulse_merge_queue_priority_keys >/dev/null 2>&1; then
		dirty_keys=$(_pulse_merge_queue_priority_keys "$repo_slug")
	fi
	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		local pr_obj="" category="" priority="" retry_priority=1 dirty_priority=1 pr_number=""
		pr_obj=$(printf '%s' "$pr_json" | jq -c ".[$i]" 2>/dev/null)
		category=$(_pmp_classify_pr_backlog_state "$pr_obj" "$repo_slug")
		priority=$(_pmp_backlog_priority "$category")
		printf '%s' "$pr_obj" | jq -e '._pulseDeferredRetry == true' >/dev/null 2>&1 && retry_priority=0
		if [[ -n "$dirty_keys" ]]; then
			pr_number=$(printf '%s' "$pr_obj" | jq -r '.number // empty')
			[[ "$pr_number" =~ ^[1-9][0-9]*$ && "$dirty_keys" == *"|${pr_number}|"* ]] && dirty_priority=0
		fi
		printf '%d\t%03d\t%d\t%06d\t%s\n' "$retry_priority" "$priority" "$dirty_priority" "$i" "$pr_obj" >>"$_tmp_lines"
		i=$((i + 1))
	done

	LC_ALL=C sort "$_tmp_lines" | cut -f5- | jq -s '.'
	rm -f "$_tmp_lines"
	return 0
}

#######################################
# Log PR backlog category counts for current-state diagnostics.
#
# Args:
#   $1 - repo slug
#   $2 - JSON array of PR objects
#######################################
_pmp_log_pr_backlog_counts() {
	local repo_slug="$1"
	local pr_json="$2"
	local merge_ready=0 checks_in_progress=0 small_fix_needed=0 dirty_conflicted=0 human_approval_needed=0 other=0
	local pr_count=""
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		local pr_obj="" category=""
		pr_obj=$(printf '%s' "$pr_json" | jq -c ".[$i]" 2>/dev/null)
		category=$(_pmp_classify_pr_backlog_state "$pr_obj" "$repo_slug")
		case "$category" in
		"$_PMP_BACKLOG_MERGE_READY") merge_ready=$((merge_ready + 1)) ;;
		"$_PMP_BACKLOG_CHECKS_IN_PROGRESS") checks_in_progress=$((checks_in_progress + 1)) ;;
		"$_PMP_BACKLOG_SMALL_FIX_NEEDED") small_fix_needed=$((small_fix_needed + 1)) ;;
		"$_PMP_BACKLOG_DIRTY_CONFLICTED") dirty_conflicted=$((dirty_conflicted + 1)) ;;
		"$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED") human_approval_needed=$((human_approval_needed + 1)) ;;
		*) other=$((other + 1)) ;;
		esac
		i=$((i + 1))
	done

	echo "[pulse-wrapper] PR backlog ${repo_slug}: total=${pr_count}, merge-ready=${merge_ready}, checks-in-progress=${checks_in_progress}, small-fix-needed=${small_fix_needed}, dirty-conflicted=${dirty_conflicted}, human-approval-needed=${human_approval_needed}, other=${other}" >>"$LOGFILE"
	return 0
}

#######################################
# Enrich one PR inside the durable PR-cursor boundary. A time-budget edge returns
# 5 and a REST-core launch-floor edge returns 6 after any potentially blocking
# phase so the caller persists the current PR before another network phase.
# Args: $1=repo slug, $2=PR object
# Stdout: enriched PR object
#######################################
_pmp_enrich_single_pr_for_processing() {
	local repo_slug="$1"
	local pr_obj="$2"
	local enriched_json=""

	[[ -n "$repo_slug" && -n "$pr_obj" ]] || return 1
	_pmp_merge_pass_budget_exhausted && return 5
	enriched_json=$(jq -cn --argjson pr "$pr_obj" '[$pr]' 2>/dev/null) || return 1
	enriched_json=$(_pmp_enrich_prs_with_mergeability "$repo_slug" "$enriched_json") || return 1
	_pmp_merge_pass_budget_exhausted && return 5
	_pmp_rest_core_priority_allows_next progress "merge_enrichment_mergeability:${repo_slug}" || return 6
	enriched_json=$(_pmp_enrich_prs_with_rest_check_status "$repo_slug" "$enriched_json") || return 1
	_pmp_merge_pass_budget_exhausted && return 5
	_pmp_rest_core_priority_allows_next progress "merge_enrichment_checks:${repo_slug}" || return 6
	enriched_json=$(_pmp_enrich_prs_with_review_decisions "$repo_slug" "$enriched_json") || return 1
	_pmp_merge_pass_budget_exhausted && return 5
	_pmp_rest_core_priority_allows_next progress "merge_enrichment_reviews:${repo_slug}" || return 6

	printf '%s' "$enriched_json" | jq -c '.[0] // empty' 2>/dev/null || return 1
	return 0
}

#######################################
# Prepare one cursor item for eligibility processing. Stop, budget, and
# cooldown pauses persist the current item before returning status 5.
# Args: $1=repo, $2=PR array, $3=index, $4=output var,
#       $5-$7=counter var names, $8-$10=counter values, $11-$12=cache dirs
#######################################
_pmp_prepare_pr_at_cursor() {
	local repo_slug="$1"
	local pr_json="$2"
	local cursor_index="$3"
	local output_var="$4"
	local merged_var="$5"
	local closed_var="$6"
	local failed_var="$7"
	local merged_count="$8"
	local closed_count="$9"
	local failed_count="${10}"
	local required_contexts_cache_dir="${11}"
	local author_permission_cache_dir="${12}"
	local prepared_pr_obj="" enriched_pr_obj="" enrichment_rc=0

	[[ "$output_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	if [[ -f "$STOP_FLAG" ]]; then
		_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$cursor_index" stop "$merged_var" "$closed_var" "$failed_var" "$merged_count" "$closed_count" "$failed_count" "$required_contexts_cache_dir" "$author_permission_cache_dir"
		return $?
	fi
	if _pmp_merge_pass_budget_exhausted; then
		_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$cursor_index" budget "$merged_var" "$closed_var" "$failed_var" "$merged_count" "$closed_count" "$failed_count" "$required_contexts_cache_dir" "$author_permission_cache_dir"
		return $?
	fi
	if declare -F _gh_secondary_cooldown_preflight >/dev/null 2>&1 && ! _gh_secondary_cooldown_preflight write >/dev/null 2>&1; then
		_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$cursor_index" cooldown "$merged_var" "$closed_var" "$failed_var" "$merged_count" "$closed_count" "$failed_count" "$required_contexts_cache_dir" "$author_permission_cache_dir"
		return $?
	fi
	if ! _pmp_rest_core_priority_allows_next progress "merge_pr:${repo_slug}"; then
		_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$cursor_index" rest-core "$merged_var" "$closed_var" "$failed_var" "$merged_count" "$closed_count" "$failed_count" "$required_contexts_cache_dir" "$author_permission_cache_dir"
		return $?
	fi

	prepared_pr_obj=$(_pmp_pr_object_at_index "$pr_json" "$cursor_index")
	if [[ -n "$prepared_pr_obj" ]]; then
		# Backlog cache values are advisory and may become stale without a head
		# change. Remove them so authoritative processing always refreshes all
		# eligibility state from bounded REST endpoints.
		prepared_pr_obj=$(printf '%s' "$prepared_pr_obj" | jq -c 'del(.mergeable, .reviewDecision, .statusCheckRollup)') || return 1
		enriched_pr_obj=$(_pmp_enrich_single_pr_for_processing "$repo_slug" "$prepared_pr_obj") || enrichment_rc=$?
		if [[ "$enrichment_rc" -eq 5 || "$enrichment_rc" -eq 6 ]]; then
			local pause_reason="budget"
			[[ "$enrichment_rc" -eq 6 ]] && pause_reason="rest-core"
			_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$cursor_index" "$pause_reason" "$merged_var" "$closed_var" "$failed_var" "$merged_count" "$closed_count" "$failed_count" "$required_contexts_cache_dir" "$author_permission_cache_dir"
			return $?
		fi
		if [[ "$enrichment_rc" -ne 0 || -z "$enriched_pr_obj" ]]; then
			echo "[pulse-wrapper] Merge pass: PR enrichment failed closed for ${repo_slug} at cursor index=${cursor_index}" >>"$LOGFILE"
			_PMU_EVALUATION_DEGRADED=1 # GH#33569: not authoritative no-op evidence
			prepared_pr_obj=$(printf '%s' "$prepared_pr_obj" | jq -c '. + {mergeable:"UNKNOWN", reviewDecision:"UNKNOWN", statusCheckRollup:[]}' 2>/dev/null) || prepared_pr_obj=""
		else
			prepared_pr_obj="$enriched_pr_obj"
		fi
	fi
	printf -v "$output_var" '%s' "$prepared_pr_obj"
	return 0
}

#######################################
# Apply one processed PR result to pass counters and durable same-pass evidence.
# Args: $1=repo, $2=PR number, $3=head SHA, $4=result code,
#       $5=merged var, $6=closed var, $7=failed var
#######################################
_pmp_record_processed_pr_result() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_sha="$3"
	local result_code="$4"
	local merged_var="$5"
	local closed_var="$6"
	local failed_var="$7"
	local outcome="blocked"

	case "$result_code" in
	0) _pmp_add_counter_var "$merged_var" 1 || return 1; outcome="merged" ;;
	2) _pmp_add_counter_var "$closed_var" 1 || return 1; outcome="progress" ;;
	3) _pmp_add_counter_var "$failed_var" 1 || return 1; outcome="eligible-unmerged" ;;
	4) outcome="deferred" ;;
	esac
	_pmp_record_same_pass_pr_outcome "$repo_slug" "$pr_number" "$head_sha" "$outcome" || return 1
	return 0
}

#######################################
# Resolve the merge pass's list-specific read timeout. PR-list reads need more
# headroom than ordinary point reads, but must remain inside the pass deadline.
#######################################
_pmp_merge_pr_list_timeout_seconds() {
	local timeout_seconds="${PULSE_MERGE_PR_LIST_TIMEOUT_SECONDS:-45}"
	local deadline="${_PMP_MERGE_PASS_DEADLINE_EPOCH:-0}"
	local now_epoch="" remaining_seconds=""
	[[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -ge 1 && "$timeout_seconds" -le 120 ]] || timeout_seconds=45
	if [[ "$deadline" =~ ^[0-9]+$ && "$deadline" -gt 0 ]]; then
		now_epoch=$(_pmp_now_epoch)
		remaining_seconds=$((deadline - now_epoch))
		[[ "$remaining_seconds" -ge 1 ]] || return 1
		[[ "$remaining_seconds" -lt "$timeout_seconds" ]] && timeout_seconds="$remaining_seconds"
	fi
	printf '%s' "$timeout_seconds"
	return 0
}

_pmp_fetch_ready_pr_list() {
	local repo_slug="$1"
	local timeout_seconds="$2"
	local error_file="$3"
	if declare -F pulse_pr_list_get >/dev/null 2>&1; then
		AIDEVOPS_GH_READ_TIMEOUT="$timeout_seconds" pulse_pr_list_get --repo "$repo_slug" --state open \
			--json "$(_pulse_merge_ready_pr_json_fields)" --limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$error_file"
		return $?
	fi
	AIDEVOPS_GH_READ_TIMEOUT="$timeout_seconds" gh_pr_list --repo "$repo_slug" --state open \
		--json "$(_pulse_merge_ready_pr_json_fields)" --limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$error_file"
	return $?
}

# Retire a terminal hint only after claiming its generation and refreshing its
# state. A reopen/new event during the read must remain eligible for polling.
_pmp_retire_terminal_queue_target() {
	local repo_slug="$1" pr_number="$2" target_timeout="$3"
	local _PULSE_MERGE_QUEUE_CONTEXT="" _PULSE_MERGE_QUEUE_OWNED=0 _PULSE_MERGE_QUEUE_DIRTY=0
	local terminal_json="" result=1
	declare -F _pulse_merge_queue_begin >/dev/null 2>&1 || return 1
	declare -F _pulse_merge_queue_refresh_object >/dev/null 2>&1 || return 1
	declare -F _pulse_merge_queue_finish >/dev/null 2>&1 || return 1
	_pulse_merge_queue_begin "$repo_slug" "$pr_number" poll || return 1
	[[ "$_PULSE_MERGE_QUEUE_OWNED" == 1 ]] || return 1
	if AIDEVOPS_GH_READ_TIMEOUT="$target_timeout" _pulse_merge_queue_refresh_object "$repo_slug" terminal_json &&
		printf '%s' "$terminal_json" | jq -e --argjson pr "$pr_number" \
			'.number == $pr and ((.state // "" | ascii_upcase) | . == "CLOSED" or . == "MERGED")' >/dev/null 2>&1; then
		result=2
	fi
	_pulse_merge_queue_finish "$result"
	[[ "$result" == 2 ]] || return 1
	return 0
}

#######################################
# Add due queue targets that fell outside the bounded broad PR list. Each
# target is fetched authoritatively and remains subject to the normal per-PR
# enrichment and action gates. Queue output and fetched objects are validated;
# failures leave the durable hint for a later pass.
#
# Args: $1=repo slug, $2=broad PR JSON
# Output: JSON array with due exact targets prepended and deduplicated
#######################################
_pmp_include_queued_pr_targets() {
	local repo_slug="$1"
	local pr_json="$2"
	local dirty_keys=""
	local remaining=""
	local pr_number=""
	local target_json=""
	local fetched=0
	local target_limit="${AIDEVOPS_PULSE_MERGE_DIRTY_TARGET_LIMIT:-5}"
	local target_timeout="${AIDEVOPS_PULSE_MERGE_DIRTY_TARGET_TIMEOUT_SECONDS:-10}"

	[[ "$target_limit" =~ ^[0-9]+$ && "$target_limit" -ge 1 && "$target_limit" -le 20 ]] || target_limit=5
	[[ "$target_timeout" =~ ^[0-9]+$ && "$target_timeout" -ge 1 && "$target_timeout" -le 30 ]] || target_timeout=10
	if ! declare -F _pulse_merge_queue_priority_keys >/dev/null 2>&1; then
		printf '%s' "$pr_json"
		return 0
	fi
	dirty_keys=$(_pulse_merge_queue_priority_keys "$repo_slug") || dirty_keys=""
	remaining="$dirty_keys"
	while [[ "$remaining" =~ ^\|([1-9][0-9]*)\|(.*)$ && "$fetched" -lt "$target_limit" ]]; do
		pr_number="${BASH_REMATCH[1]}"
		remaining="|${BASH_REMATCH[2]}"
		if printf '%s' "$pr_json" | jq -e --argjson pr "$pr_number" 'any(.number == $pr)' >/dev/null 2>&1; then
			pr_json=$(printf '%s' "$pr_json" | jq -c --argjson pr "$pr_number" \
				'map(if .number == $pr then . + {_pulseDeferredRetry:true} else . end)') || return 1
			continue
		fi
		fetched=$((fetched + 1))
		target_json=$(AIDEVOPS_GH_READ_TIMEOUT="$target_timeout" AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 AIDEVOPS_GH_REST_FIRST_READS=1 \
			gh_pr_view "$pr_number" --repo "$repo_slug" --json "$(_pulse_merge_ready_pr_json_fields)" 2>/dev/null) || target_json=""
		if ! printf '%s' "$target_json" | jq -e --argjson pr "$pr_number" \
			'type == "object" and .number == $pr and ((.state // "") | ascii_upcase) == "OPEN"' >/dev/null 2>&1; then
			if printf '%s' "$target_json" | jq -e --argjson pr "$pr_number" \
				'.number == $pr and ((.state // "" | ascii_upcase) | . == "CLOSED" or . == "MERGED")' >/dev/null 2>&1 &&
				_pmp_retire_terminal_queue_target "$repo_slug" "$pr_number" "$target_timeout"; then
				echo "[pulse-wrapper] Merge pass: terminal retry target PR #${pr_number} in ${repo_slug} rechecked under queue claim; handled generation acknowledged" >>"$LOGFILE"
				continue
			fi
			echo "[pulse-wrapper] Merge pass: due exact retry target PR #${pr_number} in ${repo_slug} was unavailable or no longer open; retaining hint for bounded recovery" >>"$LOGFILE"
			continue
		fi
		pr_json=$(jq -cn --argjson target "$target_json" --argjson current "$pr_json" \
			'[($target + {_pulseDeferredRetry:true})] + [$current[] | select(.number != $target.number)]') || return 1
	done
	printf '%s' "$pr_json"
	return 0
}

_pmp_include_queued_pr_targets_or_fallback() {
	local repo_slug="$1"
	local pr_json="$2"
	local error_file="${3:-}"
	local expanded_pr_json=""

	[[ -z "$error_file" ]] || rm -f "$error_file"
	expanded_pr_json=$(_pmp_include_queued_pr_targets "$repo_slug" "$pr_json") || {
		echo "[pulse-wrapper] Merge pass: exact retry target expansion failed for ${repo_slug}; retaining authoritative bounded broad-list fallback" >>"$LOGFILE"
		printf '%s' "$pr_json"
		return 1
	}
	printf '%s' "$expanded_pr_json"
	return 0
}

#######################################
# Record elapsed PR-list time and whether the observed list was authoritative.
#######################################
_pmp_record_pr_list_timing() {
	local timing_prefix="$1"
	local list_start="$2"
	local list_complete="$3"
	[[ -n "$timing_prefix" ]] || return 0
	_pmp_add_elapsed_seconds "${timing_prefix}list_s" "$list_start"
	if [[ "$list_complete" -eq 1 ]]; then
		printf -v "${timing_prefix}list_state" '%s' 'complete'
	else
		printf -v "${timing_prefix}list_state" '%s' 'incomplete'
	fi
	return 0
}

# Per-repo cache helpers for _merge_ready_prs_for_repo. They set/clean the
# caller's dynamically scoped AIDEVOPS_PULSE_*_CACHE_DIR locals.
_pmp_setup_merge_repo_caches() {
	local repo_slug="$1"
	AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-pulse-required-contexts.XXXXXX" 2>/dev/null) || AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR=""
	AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-pulse-author-perms.XXXXXX" 2>/dev/null) || AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR=""
	if [[ -z "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" || -z "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR" ]]; then
		echo "[pulse-wrapper] Merge pass: per-repo cache setup incomplete for ${repo_slug}; continuing without one or more caches (GH#25696)" >>"$LOGFILE"
	fi
	return 0
}

_pmp_cleanup_merge_repo_caches() {
	[[ -n "${AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR:-}" ]] && rm -rf -- "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR"
	[[ -n "${AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR:-}" ]] && rm -rf -- "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"
	return 0
}

# GH#33307: run backlog enrichment and attribute its wall time to
# <prefix>enrichment_s so per-repo total_s is explainable.
# Args: $1=repo slug, $2=PR JSON, $3=output var name, $4=timing prefix (optional)
_pmp_prepare_enriched_pr_backlog_timed() {
	local repo_slug="$1" backlog_json="$2" out_var="$3" timing_prefix="${4:-}"
	local enrichment_start="" enrichment_rc=0
	enrichment_start=$(_pmp_now_epoch)
	_pmp_prepare_enriched_pr_backlog "$repo_slug" "$backlog_json" "$out_var" || enrichment_rc=$?
	if [[ -n "$timing_prefix" ]]; then
		_pmp_add_elapsed_seconds "${timing_prefix}enrichment_s" "$enrichment_start" || true
	fi
	return "$enrichment_rc"
}

# Set the caller's dynamically scoped deadline, preserving an earlier bound.
_pmp_apply_merge_api_deadline() {
	if [[ "${_PMP_MERGE_PASS_DEADLINE_EPOCH:-0}" -gt 0 ]]; then
		if [[ ! "${AIDEVOPS_GH_DEADLINE_EPOCH:-}" =~ ^[0-9]+$ ]] ||
			[[ "$_PMP_MERGE_PASS_DEADLINE_EPOCH" -lt "$AIDEVOPS_GH_DEADLINE_EPOCH" ]]; then
			AIDEVOPS_GH_DEADLINE_EPOCH="$_PMP_MERGE_PASS_DEADLINE_EPOCH"
		fi
	fi
	export AIDEVOPS_GH_DEADLINE_EPOCH
	return 0
}

# All safety gates remain in the evaluator. Bound raw API calls and sleeps too;
# status 124 leaves the caller responsible for retaining the current PR cursor.
_pmp_evaluate_pr_with_deadline() {
	local repo_slug="$1" pr_obj="$2" timing_prefix="$3"
	local result=0 remaining=0
	_pmu_should_skip_pr "$repo_slug" "$pr_obj" && return 4
	if [[ "${_PMP_MERGE_PASS_DEADLINE_EPOCH:-0}" -gt 0 ]] && declare -F _gh_run_bounded_function >/dev/null 2>&1; then
		remaining=$((AIDEVOPS_GH_DEADLINE_EPOCH - $(_pmp_now_epoch)))
		[[ "$remaining" -gt 0 ]] || return 124
		_gh_run_bounded_function "$remaining" _process_single_ready_pr "$repo_slug" "$pr_obj" "$timing_prefix" || result=$?
	else
		_process_single_ready_pr "$repo_slug" "$pr_obj" "$timing_prefix" || result=$?
	fi
	[[ "$result" -eq 124 ]] || _pmu_record_pr_evaluation "$repo_slug" "$pr_obj" "$result"
	return "$result"
}

# Prepare the caller's dynamically scoped pr_json/pr_count and completeness
# flag. Advisory sorting never replaces the cursor's authoritative enrichment.
_pmp_prepare_repo_processing_backlog() {
	local repo_slug="$1" timing_prefix="$2" prepared_pr_json=""
	_pmp_prepare_enriched_pr_backlog_timed "$repo_slug" "$pr_json" prepared_pr_json "$timing_prefix" || return $?
	pr_json="$prepared_pr_json"
	_pmp_log_pr_backlog_counts "$repo_slug" "$pr_json"
	pr_json=$(_pmp_sort_prs_by_backlog_priority "$pr_json" "$repo_slug")
	_pmp_consolidate_duplicate_pr_groups "$repo_slug" "$pr_json" || true
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || { pr_count=0; outcomes_complete=0; }
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	return 0
}
