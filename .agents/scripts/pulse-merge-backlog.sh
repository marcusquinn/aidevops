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
		# GH#38248: a retry hint on a draft/hold-for-review PR cannot progress
		# without a human, so it must not outrank merge-ready work. Ordering
		# only; the evaluator still re-reads and enforces every gate.
		printf '%s' "$pr_obj" | jq -e '._pulseDeferredRetry == true and (.isDraft // false) != true
			and (any((.labels // [])[]; (.name? // .) == "hold-for-review") | not)' >/dev/null 2>&1 && retry_priority=0
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
	# Bound nested GitHub reads by the effective (slice-aware) deadline.
	local AIDEVOPS_GH_DEADLINE_EPOCH="${AIDEVOPS_GH_DEADLINE_EPOCH:-}"
	_pmp_apply_merge_api_deadline

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
# GH#38248: true when a listed PR needs no REST enrichment. The evaluator
# rejects drafts from list fields before reading any enriched field, and
# backlog classification maps drafts to human-approval-needed first. Advisory
# mode keeps worker-owned drafts enriched because duplicate consolidation
# scores them (_pmp_pr_is_worker_owned_for_consolidation).
# Args: $1=PR object, $2=mode (advisory|authoritative)
#######################################
_pmp_draft_enrichment_unneeded() {
	local pr_obj="$1"
	local mode="${2:-authoritative}"
	if printf '%s' "$pr_obj" | jq -e --arg mode "$mode" '
		def names: [(.labels // [])[] | (.name? // .)];
		def worker_owned: (names | any(.[]; . == "origin:worker" or . == "origin:worker-takeover"))
			and (names | any(.[]; . == "origin:interactive" or . == "needs-maintainer-review") | not);
		(.isDraft // false) == true and ($mode == "authoritative" or (worker_owned | not))' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Stdout: the PR object with explicit unknown enrichment placeholders.
_pmp_pr_with_unknown_enrichment() {
	local pr_obj="$1"
	printf '%s' "$pr_obj" | jq -c '. + {mergeable:"UNKNOWN", reviewDecision:"UNKNOWN", statusCheckRollup:[]}' 2>/dev/null || return 1
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
		if _pmp_draft_enrichment_unneeded "$prepared_pr_obj" authoritative; then
			enriched_pr_obj=$(_pmp_pr_with_unknown_enrichment "$prepared_pr_obj") || enrichment_rc=1
		else
			enriched_pr_obj=$(_pmp_enrich_single_pr_for_processing "$repo_slug" "$prepared_pr_obj") || enrichment_rc=$?
		fi
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
	_PMP_MERGE_REPO_SLICE_PROGRESS=1 # one PR processed; repo slice now binds (GH#38213)
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
# Uses the effective deadline, so the per-repo slice also bounds blocking calls
# once it binds (GH#38213).
_pmp_apply_merge_api_deadline() {
	local effective_deadline="${_PMP_MERGE_PASS_DEADLINE_EPOCH:-0}"
	if declare -F _pmp_merge_effective_deadline_epoch >/dev/null 2>&1; then
		effective_deadline=$(_pmp_merge_effective_deadline_epoch)
	fi
	[[ "$effective_deadline" =~ ^[0-9]+$ ]] || effective_deadline=0
	if [[ "$effective_deadline" -gt 0 ]]; then
		if [[ ! "${AIDEVOPS_GH_DEADLINE_EPOCH:-}" =~ ^[0-9]+$ ]] ||
			[[ "$effective_deadline" -lt "$AIDEVOPS_GH_DEADLINE_EPOCH" ]]; then
			AIDEVOPS_GH_DEADLINE_EPOCH="$effective_deadline"
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
	local AIDEVOPS_GH_DEADLINE_EPOCH="${AIDEVOPS_GH_DEADLINE_EPOCH:-}"
	_pmp_apply_merge_api_deadline
	# GH#38259: start each PR with an empty stage record, skipped PRs included.
	declare -F _pmp_stage_timing_reset >/dev/null 2>&1 && _pmp_stage_timing_reset "$timing_prefix"
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
	# The processing phase gets its own one-PR progress guarantee (GH#38213).
	_PMP_MERGE_REPO_SLICE_PROGRESS=0
	pr_json="$prepared_pr_json"
	_pmp_log_pr_backlog_counts "$repo_slug" "$pr_json"
	pr_json=$(_pmp_sort_prs_by_backlog_priority "$pr_json" "$repo_slug")
	_pmp_consolidate_duplicate_pr_groups "$repo_slug" "$pr_json" || true
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || { pr_count=0; outcomes_complete=0; }
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	return 0
}

# GH#38248: the walk records `repo|number|head` for each PR whose
# authoritative evaluation saw it merge-ready (`<cursor file>.lane-served`),
# and `repo|number|head|epoch` for each lane refresh
# (`<cursor file>.lane-refreshed`). Both end with the cursor.
# Stdout: the record key for a PR object.
_pmp_lane_pr_key() {
	local repo_slug="$1" pr_obj="$2" number_head=""
	number_head=$(printf '%s' "$pr_obj" | jq -er '"\(.number)|\(.headRefOid // "")"' 2>/dev/null) || return 1
	printf '%s|%s' "$repo_slug" "$number_head"
	return 0
}

# Args: $1=repo slug, $2=authoritative PR object the evaluator received.
# Only a merge-ready classification counts: a PR blocked on pending checks
# stays eligible for the lane once they pass at the same head.
_pmp_record_lane_served() {
	local repo_slug="$1" pr_obj="$2" key=""
	[[ -n "${PULSE_MERGE_PR_CURSOR_FILE:-}" ]] || return 0
	[[ "$(_pmp_classify_pr_backlog_state "$pr_obj" "$repo_slug")" == "$_PMP_BACKLOG_MERGE_READY" ]] || return 0
	key=$(_pmp_lane_pr_key "$repo_slug" "$pr_obj") || return 0
	printf '%s\n' "$key" >>"${PULSE_MERGE_PR_CURSOR_FILE}.lane-served" 2>/dev/null || true
	return 0
}

# True when this walk already evaluated the PR merge-ready at this head.
_pmp_lane_already_served() {
	local repo_slug="$1" pr_obj="$2" key="" served_file="${PULSE_MERGE_PR_CURSOR_FILE:-}.lane-served"
	[[ -f "$served_file" ]] || return 1
	key=$(_pmp_lane_pr_key "$repo_slug" "$pr_obj") || return 1
	if grep -Fxq -- "$key" "$served_file" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Stdout: epoch of the latest lane refresh recorded for a key (empty if none).
_pmp_lane_last_refresh_epoch() {
	local refreshed_file="$1" key="$2" line="" epoch=""
	[[ -f "$refreshed_file" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "${line%|*}" == "$key" ]] && epoch="${line##*|}"
	done <"$refreshed_file"
	printf '%s' "$epoch"
	return 0
}

#######################################
# GH#38248: the advisory snapshot is cached per number/head for the whole
# walk, so it cannot see same-head transitions such as checks finishing or a
# rerun passing. Re-enrich one passed-over PR whose state can change at the
# same head, at most once per PULSE_MERGE_RESUME_REFRESH_MIN_AGE seconds
# (default 600). Updates the caller's dynamically scoped pr_json entry and the
# advisory cache, so sorting and later resumes see the fresh state.
# Args: $1=repo slug, $2=index, $3=output var for the refreshed object
# Returns: 0 refreshed, 1 not attempted, 2 attempted and failed
#######################################
_pmp_refresh_lane_candidate() {
	local repo_slug="$1" lane_idx="$2" out_var="$3"
	local lane_obj="" lane_key="" lane_now="" lane_last="" lane_fresh="" lane_rc=0
	local min_age="${PULSE_MERGE_RESUME_REFRESH_MIN_AGE:-600}" refreshed_file="${PULSE_MERGE_PR_CURSOR_FILE:-}.lane-refreshed"
	[[ "$out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${PULSE_MERGE_PR_CURSOR_FILE:-}" ]] || return 1
	[[ "$min_age" =~ ^[0-9]+$ ]] || min_age=600
	lane_obj=$(_pmp_pr_object_at_index "$pr_json" "$lane_idx") || return 1
	case "$(_pmp_classify_pr_backlog_state "$lane_obj" "$repo_slug")" in
	"$_PMP_BACKLOG_MERGE_READY" | "$_PMP_BACKLOG_CHECKS_IN_PROGRESS" | "$_PMP_BACKLOG_SMALL_FIX_NEEDED") ;;
	*) return 1 ;;
	esac
	lane_key=$(_pmp_lane_pr_key "$repo_slug" "$lane_obj") || return 1
	lane_now=$(_pmp_now_epoch)
	lane_last=$(_pmp_lane_last_refresh_epoch "$refreshed_file" "$lane_key")
	if [[ "$lane_last" =~ ^[0-9]+$ && "$lane_now" =~ ^[0-9]+$ && $((lane_now - lane_last)) -lt "$min_age" ]]; then
		return 1
	fi
	_pmp_merge_pass_budget_exhausted && return 1
	_pmp_rest_core_priority_allows_next progress "merge_resume_lane_refresh:${repo_slug}" || return 1
	# Stamp before the read so a failing read is not retried every resume.
	printf '%s|%s\n' "$lane_key" "$lane_now" >>"$refreshed_file" 2>/dev/null || true
	lane_obj=$(printf '%s' "$lane_obj" | jq -c 'del(.mergeable, .reviewDecision, .statusCheckRollup)') || return 2
	lane_fresh=$(_pmp_enrich_single_pr_for_processing "$repo_slug" "$lane_obj") || lane_rc=$?
	[[ "$lane_rc" -eq 0 && -n "$lane_fresh" ]] || return 2
	pr_json=$(printf '%s' "$pr_json" | jq -c --argjson i "$lane_idx" --argjson pr "$lane_fresh" '.[$i] = $pr') || return 2
	_pmp_update_merge_enrichment_cache_entry "$repo_slug" "$lane_fresh" || true
	printf -v "$out_var" '%s' "$lane_fresh"
	return 0
}

#######################################
# GH#38248: resolve the caller's resume index, then move up to
# PULSE_MERGE_RESUME_PRIORITY_LIMIT (default 2; 0 disables) lane candidates
# from before the cursor to just ahead of it. A candidate is a PR this walk
# has not evaluated merge-ready at its head that classifies merge-ready now,
# after up to PULSE_MERGE_RESUME_REFRESH_LIMIT (default 2) bounded refreshes.
# Work that became merge-ready after the walk passed it is evaluated now
# instead of after the walk wraps. The original resume item keeps its index
# (_PMP_RESUME_LANE_END) and predecessor (_PMP_RESUME_LANE_LAST_PR) so durable
# cursor writes never rewind the walk. Ordering only: every gate still runs.
# Uses the caller's dynamically scoped pr_json, pr_count, _PMP_RESUME_LANE_END
# and _PMP_RESUME_LANE_LAST_PR.
# Args: $1=repo slug, $2=start index output var
#######################################
_pmp_resume_cursor_with_priority_lane() {
	local repo_slug="$1" start_var="$2"
	# Not named start_index: the resume helper's own local would shadow it.
	local lane_resume_index=0 limit="${PULSE_MERGE_RESUME_PRIORITY_LIMIT:-2}" idx=0 moved=0 lane="" reordered=""
	local refresh_limit="${PULSE_MERGE_RESUME_REFRESH_LIMIT:-2}" refreshes=0 refresh_rc=0 candidate_obj=""
	[[ "$start_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_PMP_RESUME_LANE_END=0
	_PMP_RESUME_LANE_LAST_PR=""
	_pmp_prepare_merge_pr_cursor_resume "$repo_slug" "$pr_json" "$pr_count" "$PULSE_MERGE_PR_CURSOR_FILE" "$LOGFILE" lane_resume_index || lane_resume_index=0
	[[ "$lane_resume_index" =~ ^[0-9]+$ ]] || lane_resume_index=0
	printf -v "$start_var" '%s' "$lane_resume_index"
	if [[ "$lane_resume_index" -eq 0 ]]; then
		# A fresh walk starts with empty records (covers pruned cursors).
		_pmp_clear_merge_lane_records "${PULSE_MERGE_PR_CURSOR_FILE:-}" "$repo_slug"
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=2
	[[ "$refresh_limit" =~ ^[0-9]+$ ]] || refresh_limit=2
	[[ "$limit" -gt 0 ]] || return 0
	local start_index="$lane_resume_index"
	while [[ "$idx" -lt "$start_index" && "$moved" -lt "$limit" ]]; do
		candidate_obj=$(_pmp_pr_object_at_index "$pr_json" "$idx")
		if ! _pmp_lane_already_served "$repo_slug" "$candidate_obj"; then
			if [[ "$refreshes" -lt "$refresh_limit" ]]; then
				refresh_rc=0
				_pmp_refresh_lane_candidate "$repo_slug" "$idx" candidate_obj || refresh_rc=$?
				[[ "$refresh_rc" -eq 1 ]] || refreshes=$((refreshes + 1))
			fi
			if [[ "$(_pmp_classify_pr_backlog_state "$candidate_obj" "$repo_slug")" == "$_PMP_BACKLOG_MERGE_READY" ]]; then
				lane="${lane}${lane:+,}${idx}"
				moved=$((moved + 1))
			fi
		fi
		idx=$((idx + 1))
	done
	[[ "$moved" -gt 0 ]] || return 0
	_PMP_RESUME_LANE_LAST_PR=$(_pmp_pr_number_at_index "$pr_json" "$((start_index - 1))") || _PMP_RESUME_LANE_LAST_PR=""
	reordered=$(printf '%s' "$pr_json" | jq -c --argjson start "$start_index" --argjson lane "[${lane}]" '
		. as $all
		| [range(0; $start) | select(. as $i | $lane | any(.[]; . == $i) | not) | $all[.]]
			+ [$lane[] | $all[.]] + $all[$start:]' 2>/dev/null) || return 0
	[[ -n "$reordered" ]] || return 0
	pr_json="$reordered"
	_PMP_RESUME_LANE_END="$start_index"
	printf -v "$start_var" '%s' "$((start_index - moved))"
	echo "[pulse-wrapper] Merge pass: resume priority lane for ${repo_slug} moved ${moved} merge-ready PR(s) ahead of cursor index=${start_index} (GH#38248)" >>"$LOGFILE"
	return 0
}

# GH#38248: after the PR at next_index-1 was evaluated, record the
# authoritative object it received in the walk's lane record, then compute the
# durable cursor. While lane items run, cursor writes keep the original resume
# item and its original predecessor, so a pause, crash, or removed resume item
# cannot rewind the walk past already-processed PRs.
# Args: $1=repo slug, $2=next index, $3=index output var, $4=next-PR output var,
#       $5=evaluated PR object, $6=last-PR output var (optional),
#       $7=number of the PR just evaluated (the default last PR)
# Uses the caller's dynamically scoped pr_json, _PMP_RESUME_LANE_END and
# _PMP_RESUME_LANE_LAST_PR.
_pmp_lane_clamped_cursor() {
	local repo_slug="$1" next_index="$2" index_var="$3" next_pr_var="$4" evaluated_obj="${5:-}" last_pr_var="${6:-}"
	local write_last="${7:-}" lane_end="${_PMP_RESUME_LANE_END:-0}" next_pr=""
	[[ "$index_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$next_pr_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ -z "$last_pr_var" || "$last_pr_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$next_index" =~ ^[0-9]+$ ]] || next_index=0
	[[ -n "$evaluated_obj" ]] && _pmp_record_lane_served "$repo_slug" "$evaluated_obj"
	[[ "$lane_end" =~ ^[0-9]+$ ]] || lane_end=0
	if [[ "$lane_end" -gt 0 && "$next_index" -le "$lane_end" ]]; then
		# The PR just evaluated was a lane item.
		next_index="$lane_end"
		write_last="${_PMP_RESUME_LANE_LAST_PR:-}"
	fi
	[[ -z "$last_pr_var" ]] || printf -v "$last_pr_var" '%s' "$write_last"
	next_pr=$(_pmp_pr_number_at_index "$pr_json" "$next_index") || next_pr=""
	printf -v "$index_var" '%s' "$next_index"
	printf -v "$next_pr_var" '%s' "$next_pr"
	return 0
}
