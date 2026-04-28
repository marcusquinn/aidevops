#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Simplification — Review Scanners
# =============================================================================
# Daily codebase review (CodeRabbit), post-merge review scanner, and
# auto-decomposer scanner. Extracted from pulse-simplification.sh as part
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

# Check if the daily CodeRabbit codebase review interval has elapsed.
# Models on _complexity_scan_check_interval which has never regressed (GH#17640).
# Arguments: $1 - now_epoch (current epoch seconds)
# Returns: 0 if review is due, 1 if not yet due
_coderabbit_review_check_interval() {
	local now_epoch="$1"
	if [[ ! -f "$CODERABBIT_REVIEW_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$CODERABBIT_REVIEW_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$CODERABBIT_REVIEW_INTERVAL" ]]; then
		local remaining=$(((CODERABBIT_REVIEW_INTERVAL - elapsed) / 3600))
		echo "[pulse-wrapper] CodeRabbit codebase review not due yet (${remaining}h remaining)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Daily full codebase review via CodeRabbit (GH#17640).
#
# Posts "@coderabbitai Please run a full codebase review" on issue #2632
# once per 24h. Uses a simple timestamp file gate (same pattern as
# _complexity_scan_check_interval) to avoid duplicate posts.
#
# Previous implementations regressed because they checked complex quality
# gate status instead of a plain time-based interval. This version uses
# the same pattern as the complexity scan which has never regressed.
#
# Actionable findings from the review are routed through
# quality-feedback-helper.sh to create tracked issues.
#######################################
run_daily_codebase_review() {
	local aidevops_slug="marcusquinn/aidevops"

	# t2145: CodeRabbit review triggers issue-creating scanners — maintainer-only.
	local _cr_role
	_cr_role=$(get_repo_role_by_slug "$aidevops_slug")
	if [[ "$_cr_role" != "maintainer" ]]; then
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)

	# Time gate: skip if last review was <24h ago
	_coderabbit_review_check_interval "$now_epoch" || return 0

	# Permission gate: only collaborators with write+ may trigger reviews
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -z "$current_user" ]]; then
		echo "[pulse-wrapper] CodeRabbit review: skipped — cannot determine current user" >>"$LOGFILE"
		return 0
	fi
	local perm_level
	perm_level=$(gh api "repos/${aidevops_slug}/collaborators/${current_user}/permission" \
		--jq '.permission' 2>/dev/null) || perm_level=""
	case "$perm_level" in
	admin | maintain | write) ;; # allowed
	*)
		echo "[pulse-wrapper] CodeRabbit review: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need write+)" >>"$LOGFILE"
		return 0
		;;
	esac

	echo "[pulse-wrapper] Posting daily CodeRabbit full codebase review request on #${CODERABBIT_REVIEW_ISSUE} (GH#17640)..." >>"$LOGFILE"

	# Post the review trigger comment
	if gh_issue_comment "$CODERABBIT_REVIEW_ISSUE" \
		--repo "$aidevops_slug" \
		--body "@coderabbitai Please run a full codebase review" 2>>"$LOGFILE"; then
		# Update timestamp only on successful post
		printf '%s\n' "$now_epoch" >"$CODERABBIT_REVIEW_LAST_RUN"
		echo "[pulse-wrapper] CodeRabbit review: posted successfully, next review in ~24h" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] CodeRabbit review: failed to post comment on #${CODERABBIT_REVIEW_ISSUE}" >>"$LOGFILE"
		return 1
	fi

	# Route actionable findings through quality-feedback-helper if available
	local qfh="${SCRIPT_DIR}/quality-feedback-helper.sh"
	if [[ -x "$qfh" ]]; then
		echo "[pulse-wrapper] CodeRabbit review: findings will be processed by quality-feedback-helper.sh on next cycle" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Daily post-merge review scanner (t1993).
#
# Scans recently merged PRs in pulse-enabled repos for actionable AI bot
# review comments (CodeRabbit, Gemini Code Assist, claude-review, gpt-review)
# and creates review-followup issues. Idempotent via existing dedup in
# post-merge-review-scanner.sh's issue_exists() guard.
#
# Time-gated to run at most once per POST_MERGE_SCANNER_INTERVAL (default 24h).
# Reference pattern: run_daily_codebase_review.
#######################################
_run_post_merge_review_scanner() {
	local now_epoch
	now_epoch=$(date +%s)

	# Time gate: skip if last run was within the interval
	if [[ -f "$POST_MERGE_SCANNER_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$POST_MERGE_SCANNER_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -lt "$POST_MERGE_SCANNER_INTERVAL" ]]; then
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
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		# t2145: skip repos where the user is a contributor, not the maintainer.
		# Scanners that scrape repo data (PR bot comments) duplicate what the
		# maintainer's own pulse already sees, creating NMR noise.
		local repo_role
		repo_role=$(get_repo_role_by_slug "$slug")
		if [[ "$repo_role" != "maintainer" ]]; then
			skipped_contributor=$((skipped_contributor + 1))
			continue
		fi
		total_repos=$((total_repos + 1))
		echo "[pulse-wrapper] Post-merge scanner: scanning $slug" >>"$LOGFILE"
		SCANNER_DAYS="${SCANNER_DAYS:-7}" "$scanner" scan "$slug" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_enabled_repo_slugs "$repos_json")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] Post-merge scanner: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi

	printf '%s\n' "$now_epoch" >"$POST_MERGE_SCANNER_LAST_RUN"
	echo "[pulse-wrapper] Post-merge scanner: completed ${total_repos} repo(s), next run in ~$((POST_MERGE_SCANNER_INTERVAL / 3600))h" >>"$LOGFILE"
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
