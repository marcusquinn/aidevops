#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Simplification — Review Scanners
# =============================================================================
# Post-merge review scanner, active-PR
# review-thread response scanner, and auto-decomposer scanner. Extracted from pulse-simplification.sh as part
# of the file-size-debt split (GH#21306, parent #21146).
#
# Usage: source "${SCRIPT_DIR}/pulse-simplification-review.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_issue_comment, gh_create_issue, etc.)
#   - pulse-simplification-scan.sh (_pulse_enabled_repo_slugs)
#   - worker-lifecycle-common.sh (get_repo_role_by_slug)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_SIMPLIFICATION_REVIEW_LIB_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_REVIEW_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Daily post-merge review scanner (t1993).
#
# Scans recently merged PRs in pulse-enabled repos for actionable AI bot
# review comments (active providers plus legacy Gemini Code Assist history)
# and creates review-followup issues. Idempotent via existing dedup in
# post-merge-review-scanner.sh's issue_exists() guard.
#
# Time-gated to run at most once per POST_MERGE_SCANNER_INTERVAL (default 24h).
# Reference pattern: _complexity_scan_check_interval.
#######################################
_post_merge_scanner_scan_repo() {
	local slug="$1" scanner="$2" scanner_cursor_dir="$3" stage_start_epoch="$4" stage_budget="$5" stage_reserve="$6"
	local repo_role
	repo_role=$(get_repo_role_by_slug "$slug")
	if [[ "$repo_role" != "maintainer" ]]; then
		return 3
	fi

	mkdir -p "$scanner_cursor_dir" 2>/dev/null || true
	printf '%s\n' "$slug" >"${scanner_cursor_dir}/repo.cursor" 2>/dev/null || true

	local now_for_budget="" elapsed_for_budget="" remaining_budget="" repo_budget=""
	now_for_budget=$(date +%s)
	elapsed_for_budget=$((now_for_budget - stage_start_epoch))
	remaining_budget=$((stage_budget - elapsed_for_budget))
	# The watchdog may shorten this stage to fit the remaining Pulse cycle.
	# Recompute at each repo so setup and earlier scans consume that deadline.
	local stage_deadline="${PULSE_STAGE_DEADLINE_EPOCH:-}" deadline_remaining=""
	if [[ "$stage_deadline" =~ ^[0-9]+$ ]]; then
		deadline_remaining=$((stage_deadline - now_for_budget))
		if [[ "$deadline_remaining" -lt "$remaining_budget" ]]; then
			remaining_budget="$deadline_remaining"
		fi
	fi
	if [[ "$remaining_budget" -le "$stage_reserve" ]]; then
		echo "[pulse-wrapper] Post-merge scanner: yielding before $slug (remaining=${remaining_budget}s reserve=${stage_reserve}s)" >>"${LOGFILE:-/dev/null}"
		return 2
	fi

	repo_budget=$((remaining_budget - stage_reserve))
	echo "[pulse-wrapper] Post-merge scanner: scanning $slug" >>"${LOGFILE:-/dev/null}"
	# The scan is deferrable maintenance: share the REST-core priority budget so
	# it yields with a cursor before draining quota needed by dispatch/merge.
	SCANNER_DAYS="${SCANNER_DAYS:-7}" \
		SCANNER_BUDGET_SECONDS="$repo_budget" \
		SCANNER_CURSOR_DIR="$scanner_cursor_dir" \
		SCANNER_REST_CORE_GATE="${SCANNER_REST_CORE_GATE:-1}" \
		"$scanner" scan "$slug" >>"${LOGFILE:-/dev/null}" 2>&1 || true

	local safe_slug="" repo_scan_cursor=""
	safe_slug=$(printf '%s' "$slug" | tr '/: ' '___')
	repo_scan_cursor="${scanner_cursor_dir}/${safe_slug}.cursor"
	if [[ -f "$repo_scan_cursor" ]]; then
		echo "[pulse-wrapper] Post-merge scanner: yielded in $slug; cursor preserved for next cycle" >>"${LOGFILE:-/dev/null}"
		return 2
	fi
	return 0
}

_pulse_slug_list_contains() {
	local needle="$1"
	local slugs="$2"
	local slug=""

	while IFS= read -r slug; do
		[[ "$slug" == "$needle" ]] && return 0
	done <<<"$slugs"
	return 1
}

_run_post_merge_review_scanner() {
	local now_epoch
	now_epoch=$(date +%s)
	local stage_start_epoch="$now_epoch"
	local stage_start_seconds="$SECONDS"
	local stage_budget="${AIDEVOPS_POST_MERGE_SCANNER_STAGE_BUDGET_SECONDS:-${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}}"
	[[ "$stage_budget" =~ ^[0-9]+$ ]] || stage_budget=600
	local stage_reserve="${AIDEVOPS_POST_MERGE_SCANNER_STAGE_RESERVE_SECONDS:-30}"
	[[ "$stage_reserve" =~ ^[0-9]+$ ]] || stage_reserve=30
	local post_merge_scanner_interval="${POST_MERGE_SCANNER_INTERVAL:-86400}"
	[[ "$post_merge_scanner_interval" =~ ^[0-9]+$ ]] || post_merge_scanner_interval=86400
	local scanner_cursor_dir="${AIDEVOPS_POST_MERGE_SCANNER_CURSOR_DIR:-${HOME:-}/.aidevops/logs/post-merge-review-scanner}"
	local repo_cursor_file="${scanner_cursor_dir}/repo.cursor"

	# Time gate: skip if last run was within the interval
	if [[ -f "$POST_MERGE_SCANNER_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$POST_MERGE_SCANNER_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -lt "$post_merge_scanner_interval" ]]; then
			return 0
		fi
	fi

	local scanner="${SCRIPT_DIR}/post-merge-review-scanner.sh"
	if [[ ! -x "$scanner" ]]; then
		echo "[pulse-wrapper] Post-merge scanner: helper not found or not executable: $scanner" >>"$LOGFILE"
		return 0
	fi

	# Iterate pulse-enabled repos; scan each. Scanner is idempotent —
	# existing review-followup issues are skipped via issue_exists().
	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local total_repos=0
	local skipped_contributor=0
	local scan_yielded=0
	local resume_slug=""
	local enabled_slugs=""
	enabled_slugs=$(_pulse_enabled_repo_slugs "$repos_json" || echo "")
	if [[ -f "$repo_cursor_file" ]]; then
		resume_slug=$(sed -n '1p' "$repo_cursor_file" 2>/dev/null || true)
		if [[ -n "$resume_slug" ]] && ! _pulse_slug_list_contains "$resume_slug" "$enabled_slugs"; then
			echo "[pulse-wrapper] Post-merge scanner: resume cursor repo $resume_slug is no longer enabled; starting fresh scan" >>"${LOGFILE:-/dev/null}"
			resume_slug=""
		fi
	fi
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		if [[ -n "$resume_slug" ]]; then
			if [[ "$slug" == "$resume_slug" ]]; then
				resume_slug=""
			else
				continue
			fi
		fi
		local scan_rc=0
		_post_merge_scanner_scan_repo "$slug" "$scanner" "$scanner_cursor_dir" \
			"$stage_start_epoch" "$stage_budget" "$stage_reserve" || scan_rc=$?
		case "$scan_rc" in
		0)
			total_repos=$((total_repos + 1))
			;;
		2)
			total_repos=$((total_repos + 1))
			scan_yielded=1
			break
			;;
		3)
			skipped_contributor=$((skipped_contributor + 1))
			;;
		*)
			total_repos=$((total_repos + 1))
			;;
		esac
	done <<<"$enabled_slugs"
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] Post-merge scanner: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"${LOGFILE:-/dev/null}"
	fi
	if [[ "$scan_yielded" -eq 1 ]]; then
		echo "[pulse-wrapper] Post-merge scanner: yielded after ${total_repos} repo(s); cursor state saved" >>"${LOGFILE:-/dev/null}"
		if declare -F _log_substage_timing >/dev/null; then
			_log_substage_timing "post_merge_scanner:yielded" "$stage_start_seconds" 0
		fi
		return 0
	fi

	rm -f "$repo_cursor_file" 2>/dev/null || true
	printf '%s\n' "$now_epoch" >"$POST_MERGE_SCANNER_LAST_RUN"
	echo "[pulse-wrapper] Post-merge scanner: completed ${total_repos} repo(s), next run in ~$(( post_merge_scanner_interval / 3600 ))h" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Active-PR review-thread response scanner (GH#24414).
#
# Scans pulse-enabled maintainer repos for open non-draft PRs with unresolved
# bot review threads and dispatches bounded response workers. The helper never
# resolves threads directly; workers must verify findings and respond via the
# PR-loop/review-bot-gate discipline.
# Reference pattern: _run_post_merge_review_scanner.
#######################################
_run_pr_review_thread_response_scanner() {
	if [[ "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_ENABLED:-1}" != "1" ]]; then
		echo "[pulse-wrapper] PR review-thread response: disabled by AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_ENABLED" >>"$LOGFILE"
		return 0
	fi

	local scanner="${SCRIPT_DIR}/pr-review-thread-response-scanner.sh"
	if [[ ! -x "$scanner" ]]; then
		echo "[pulse-wrapper] PR review-thread response: helper not found or not executable: $scanner" >>"$LOGFILE"
		return 0
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local total_repos=0
	local skipped_contributor=0
	local slug="" repo_path="" repo_role=""
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		repo_role=$(get_repo_role_by_slug "$slug")
		if [[ "$repo_role" != "maintainer" ]]; then
			skipped_contributor=$((skipped_contributor + 1))
			continue
		fi
		repo_path=$(jq -r --arg s "$slug" 'first(.initialized_repos[]? | select(.slug == $s)) | .path // ""' "$repos_json" 2>/dev/null) || repo_path=""
		repo_path="${repo_path/#\~/$HOME}"
		total_repos=$((total_repos + 1))
		echo "[pulse-wrapper] PR review-thread response: scanning $slug" >>"$LOGFILE"
		"$scanner" dispatch "$slug" "$repo_path" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_enabled_repo_slugs "$repos_json")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] PR review-thread response: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi

	echo "[pulse-wrapper] PR review-thread response: completed ${total_repos} repo(s)" >>"$LOGFILE"
	return 0
}

#######################################
# Per-cycle auto-decomposer scanner (t2442, tightened t2573).
#
# Scans pulse-enabled (maintainer-role) repos for parent-task issues
# whose <!-- parent-needs-decomposition --> nudge has aged without
# a human response, and files worker-ready tier:thinking issues asking
# the dispatched worker to decompose the parent into child issues.
#
# Closes the pre-t2442 dispatch black hole: before this, a parent-task
# with no children could sit forever because the `parent-task` label
# blocks dispatch unconditionally, but the reconciler's nudge comment
# was advisory-only.
#
# Idempotent via auto-decomposer-scanner.sh's title + source:auto-decomposer
# label dedup — re-runs skip parents that already have a decompose issue
# in any state. Per-parent state file (AUTO_DECOMPOSER_PARENT_STATE)
# prevents re-filing the same parent within AUTO_DECOMPOSER_INTERVAL
# (default 7 days). t2573 removed the global 24h run gate to allow
# scanning every pulse cycle and clearing multiple parents per day.
# Reference pattern: _run_post_merge_review_scanner.
#######################################
_run_auto_decomposer_scanner() {
	local scanner="${SCRIPT_DIR}/auto-decomposer-scanner.sh"
	if [[ ! -x "$scanner" ]]; then
		echo "[pulse-wrapper] Auto-decomposer: helper not found or not executable: $scanner" >>"$LOGFILE"
		return 0
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local total_repos=0
	local skipped_contributor=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		# t2145 parity with post-merge-review-scanner: skip contributor-role
		# repos. The auto-decomposer creates issues directly; we only want
		# that in repos where the user is the maintainer.
		local repo_role
		repo_role=$(get_repo_role_by_slug "$slug")
		if [[ "$repo_role" != "maintainer" ]]; then
			skipped_contributor=$((skipped_contributor + 1))
			continue
		fi
		total_repos=$((total_repos + 1))
		echo "[pulse-wrapper] Auto-decomposer: scanning $slug" >>"$LOGFILE"
		"$scanner" scan "$slug" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_enabled_repo_slugs "$repos_json")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-decomposer: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi

	echo "[pulse-wrapper] Auto-decomposer: completed ${total_repos} repo(s) (per-parent re-file gate: $((AUTO_DECOMPOSER_INTERVAL / 86400))d)" >>"$LOGFILE"
	return 0
}
