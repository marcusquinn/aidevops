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
	local prior_starts="${7:-0}"
	[[ "$prior_starts" =~ ^[0-9]+$ ]] || prior_starts=0
	local repo_role
	repo_role=$(get_repo_role_by_slug "$slug")
	if [[ "$repo_role" != "maintainer" ]]; then
		return 3
	fi

	mkdir -p "$scanner_cursor_dir" 2>/dev/null || true
	# Line 2 counts consecutive interrupted starts of this repo (GH#38204).
	local repo_cursor_file="${scanner_cursor_dir}/repo.cursor"
	printf '%s\n%s\n' "$slug" "$prior_starts" >"$repo_cursor_file" 2>/dev/null || true

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
	# GH#38171: the child checks the same deadline, so pass the scaled reserve.
	# GH#38204: count the start before launch. A watchdog kill leaves the count
	# raised; any return resets it, so only repeated kills defer this repo.
	printf '%s\n%s\n' "$slug" "$((prior_starts + 1))" >"$repo_cursor_file" 2>/dev/null || true
	SCANNER_DAYS="${SCANNER_DAYS:-7}" \
		SCANNER_BUDGET_SECONDS="$repo_budget" \
		AIDEVOPS_POST_MERGE_SCANNER_STAGE_RESERVE_SECONDS="$stage_reserve" \
		SCANNER_CURSOR_DIR="$scanner_cursor_dir" \
		SCANNER_REST_CORE_GATE="${SCANNER_REST_CORE_GATE:-1}" \
		"$scanner" scan "$slug" >>"${LOGFILE:-/dev/null}" 2>&1 || true
	printf '%s\n0\n' "$slug" >"$repo_cursor_file" 2>/dev/null || true

	local safe_slug="" repo_scan_cursor=""
	safe_slug=$(printf '%s' "$slug" | tr '/: ' '___')
	repo_scan_cursor="${scanner_cursor_dir}/${safe_slug}.cursor"
	if [[ -f "$repo_scan_cursor" ]]; then
		# A repository-local listing failure must not pin the traversal here.
		# Retain its PR cursor for the next scheduled traversal, but continue
		# other repos now. Global cooldown/budget yields still stop the stage.
		local cursor_reason=""
		cursor_reason=$(jq -r '.reason // empty' "$repo_scan_cursor" 2>/dev/null) || cursor_reason=""
		if [[ "$cursor_reason" == "merged-pr-list-failed" ]]; then
			echo "[pulse-wrapper] Post-merge scanner: deferred $slug to next scheduled traversal; continuing other repos" >>"${LOGFILE:-/dev/null}"
			return 0
		fi
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

#######################################
# GH#37555: round-robin repo order for scanners without per-repo cursors.
# Housekeeping slices (GH#37501) are shorter than a full traversal, so a
# scanner that restarts at the first repo never reaches the rest. Emit the
# slugs starting after the cursor slug, wrapping around; a missing or stale
# cursor (repo no longer enabled) keeps the original order.
#
# Args:
#   $1 - cursor file path
#   $2 - newline-separated enabled slugs
# Stdout: rotated newline-separated slugs
# Returns 0 always.
#######################################
_pulse_scanner_rotated_slugs() {
	local cursor_file="$1"
	local slugs="$2"
	local last_slug="" slug="" before="" after="" seen=0
	if [[ -f "$cursor_file" ]]; then
		last_slug=$(sed -n '1p' "$cursor_file" 2>/dev/null || true)
	fi
	if [[ -z "$last_slug" ]] || ! _pulse_slug_list_contains "$last_slug" "$slugs"; then
		printf '%s\n' "$slugs"
		return 0
	fi
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		if [[ "$seen" -eq 1 ]]; then
			after="${after}${slug}"$'\n'
			continue
		fi
		before="${before}${slug}"$'\n'
		if [[ "$slug" == "$last_slug" ]]; then
			seen=1
		fi
	done <<<"$slugs"
	printf '%s%s' "$after" "$before"
	return 0
}

#######################################
# GH#37555: record a repo as started before scanning it. Advancing before the
# scan means a repo slower than the whole slice cannot pin the rotation.
#
# Args:
#   $1 - cursor file path
#   $2 - slug about to be scanned
# Returns 0 always (cursor persistence is best-effort, but a failure is logged
# because an unwritable cursor silently restores first-repo starvation).
#######################################
_pulse_scanner_mark_started() {
	local cursor_file="$1"
	local slug="$2"
	if mkdir -p "${cursor_file%/*}" 2>/dev/null && printf '%s\n' "$slug" >"$cursor_file" 2>/dev/null; then
		return 0
	fi
	echo "[pulse-wrapper] Scanner rotation: cursor write failed (${cursor_file}); next slice restarts at the first repo" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# GH#38171: size a scanner's deadline reserve to fit its real watchdog window.
# Housekeeping gives cheap scanners a 12s slice (GH#37501), so a fixed 30s
# reserve left no window at all and the post-merge scanner yielded before its
# first repo on every run. Cap the reserve at a quarter of the window left at
# stage start (at least 1s). Without a deadline the configured reserve stands.
#
# Args:
#   $1 - configured reserve seconds
#   $2 - stage start epoch
# Stdout: effective reserve seconds
# Returns 0 always.
#######################################
_pulse_scanner_effective_reserve() {
	local configured="$1"
	local start_epoch="$2"
	[[ "$configured" =~ ^[0-9]+$ ]] || configured=30
	local deadline="${PULSE_STAGE_DEADLINE_EPOCH:-}"
	if [[ ! "$deadline" =~ ^[0-9]+$ || ! "$start_epoch" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$configured"
		return 0
	fi
	local scaled=$(((deadline - start_epoch) / 4))
	[[ "$scaled" -ge 1 ]] || scaled=1
	[[ "$scaled" -lt "$configured" ]] || scaled="$configured"
	printf '%s\n' "$scaled"
	return 0
}

#######################################
# GH#38171: cooperative deadline check before a scanner starts another repo.
# Yielding with the cursor kept is cheaper than the watchdog's SIGKILL, which
# can land mid-dispatch (worktree preparation, lock or state writes).
#
# Args:
#   $1 - reserve seconds to keep before PULSE_STAGE_DEADLINE_EPOCH
# Returns 0 when the scanner should yield now, 1 otherwise (no deadline set,
# or more than the reserve remains).
#######################################
_pulse_scanner_deadline_reached() {
	local reserve="$1"
	[[ "$reserve" =~ ^[0-9]+$ ]] || reserve=0
	local deadline="${PULSE_STAGE_DEADLINE_EPOCH:-}"
	[[ "$deadline" =~ ^[0-9]+$ ]] || return 1
	local now=""
	now=$(date +%s)
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	if [[ $((deadline - now)) -le "$reserve" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Post-merge scanner interval gate.
#
# Args:
#   $1 - current epoch
#   $2 - interval seconds
# Returns 0 when a traversal is due, 1 while the last completed one is recent.
#######################################
_post_merge_scanner_interval_due() {
	local now_epoch="$1"
	local interval="$2"
	[[ -f "$POST_MERGE_SCANNER_LAST_RUN" ]] || return 0
	local last_run=""
	last_run=$(cat "$POST_MERGE_SCANNER_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	if [[ $((now_epoch - last_run)) -lt "$interval" ]]; then
		return 1
	fi
	return 0
}

#######################################
# GH#38204: consecutive interrupted starts of the resume repo (repo.cursor
# line 2). The watchdog kills the whole stage, so a repo whose setup outlives
# the slice would otherwise pin the traversal and starve every later repo.
#
# Args:
#   $1 - repo cursor file
# Stdout: interrupted-start count (0 when absent, legacy or invalid)
# Returns 0 always.
#######################################
_post_merge_scanner_interrupted_starts() {
	local cursor_file="$1"
	local starts=""
	if [[ -f "$cursor_file" ]]; then
		starts=$(sed -n '2p' "$cursor_file" 2>/dev/null || true)
	fi
	[[ "$starts" =~ ^[0-9]+$ ]] || starts=0
	printf '%s\n' "$starts"
	return 0
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
	stage_reserve=$(_pulse_scanner_effective_reserve "$stage_reserve" "$stage_start_epoch")
	local post_merge_scanner_interval="${POST_MERGE_SCANNER_INTERVAL:-86400}"
	[[ "$post_merge_scanner_interval" =~ ^[0-9]+$ ]] || post_merge_scanner_interval=86400
	local scanner_cursor_dir="${AIDEVOPS_POST_MERGE_SCANNER_CURSOR_DIR:-${HOME:-}/.aidevops/logs/post-merge-review-scanner}"
	local repo_cursor_file="${scanner_cursor_dir}/repo.cursor"

	_post_merge_scanner_interval_due "$now_epoch" "$post_merge_scanner_interval" || return 0

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
	local resume_slug="" resume_starts=0 slug_starts=0
	local max_interrupted="${AIDEVOPS_POST_MERGE_SCANNER_MAX_INTERRUPTED_STARTS:-3}"
	[[ "$max_interrupted" =~ ^[1-9][0-9]*$ ]] || max_interrupted=3
	local enabled_slugs=""
	enabled_slugs=$(_pulse_enabled_repo_slugs "$repos_json" || echo "")
	if [[ -f "$repo_cursor_file" ]]; then
		resume_slug=$(sed -n '1p' "$repo_cursor_file" 2>/dev/null || true)
		resume_starts=$(_post_merge_scanner_interrupted_starts "$repo_cursor_file")
		if [[ -n "$resume_slug" ]] && ! _pulse_slug_list_contains "$resume_slug" "$enabled_slugs"; then
			echo "[pulse-wrapper] Post-merge scanner: resume cursor repo $resume_slug is no longer enabled; starting fresh scan" >>"${LOGFILE:-/dev/null}"
			resume_slug=""
		fi
	fi
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		slug_starts=0
		if [[ -n "$resume_slug" ]]; then
			[[ "$slug" == "$resume_slug" ]] || continue
			resume_slug=""
			slug_starts="$resume_starts"
			if [[ "$slug_starts" -ge "$max_interrupted" ]]; then
				echo "[pulse-wrapper] Post-merge scanner: deferring $slug after ${slug_starts} interrupted start(s); PR cursor kept for next traversal" >>"${LOGFILE:-/dev/null}"
				continue
			fi
		fi
		local scan_rc=0
		_post_merge_scanner_scan_repo "$slug" "$scanner" "$scanner_cursor_dir" \
			"$stage_start_epoch" "$stage_budget" "$stage_reserve" "$slug_starts" || scan_rc=$?
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
	local slug="" repo_path="" repo_role="" enabled_slugs=""
	local cursor_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_CURSOR_DIR:-${HOME:-}/.aidevops/logs/pr-review-thread-response-scanner}/repo.cursor"
	local stage_start_seconds="$SECONDS" stage_reserve="" yielded=0
	stage_reserve=$(_pulse_scanner_effective_reserve "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STAGE_RESERVE_SECONDS:-10}" "$(date +%s)")
	enabled_slugs=$(_pulse_enabled_repo_slugs "$repos_json" || echo "")
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		repo_role=$(get_repo_role_by_slug "$slug")
		if [[ "$repo_role" != "maintainer" ]]; then
			skipped_contributor=$((skipped_contributor + 1))
			continue
		fi
		# GH#38171: yield before the watchdog can kill a dispatch mid-flight;
		# the rotation cursor still names the last started repo.
		if _pulse_scanner_deadline_reached "$stage_reserve"; then
			echo "[pulse-wrapper] PR review-thread response: yielding before $slug (deadline reserve ${stage_reserve}s); rotation cursor kept" >>"$LOGFILE"
			yielded=1
			break
		fi
		repo_path=$(jq -r --arg s "$slug" 'first(.initialized_repos[]? | select(.slug == $s)) | .path // ""' "$repos_json" 2>/dev/null) || repo_path=""
		repo_path="${repo_path/#\~/$HOME}"
		total_repos=$((total_repos + 1))
		_pulse_scanner_mark_started "$cursor_file" "$slug"
		echo "[pulse-wrapper] PR review-thread response: scanning $slug" >>"$LOGFILE"
		"$scanner" dispatch "$slug" "$repo_path" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_scanner_rotated_slugs "$cursor_file" "$enabled_slugs")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] PR review-thread response: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi
	if [[ "$yielded" -eq 1 ]]; then
		if declare -F _log_substage_timing >/dev/null; then
			_log_substage_timing "pr_review_thread_response:yielded" "$stage_start_seconds" 0
		fi
		echo "[pulse-wrapper] PR review-thread response: yielded after ${total_repos} repo(s)" >>"$LOGFILE"
		return 0
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
	local enabled_slugs=""
	local cursor_file="${AIDEVOPS_AUTO_DECOMPOSER_CURSOR_DIR:-${HOME:-}/.aidevops/logs/auto-decomposer-scanner}/repo.cursor"
	local stage_start_seconds="$SECONDS" stage_reserve="" yielded=0
	stage_reserve=$(_pulse_scanner_effective_reserve "${AIDEVOPS_AUTO_DECOMPOSER_STAGE_RESERVE_SECONDS:-10}" "$(date +%s)")
	enabled_slugs=$(_pulse_enabled_repo_slugs "$repos_json" || echo "")
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
		# GH#38171: yield before the watchdog kills an issue filing mid-flight.
		if _pulse_scanner_deadline_reached "$stage_reserve"; then
			echo "[pulse-wrapper] Auto-decomposer: yielding before $slug (deadline reserve ${stage_reserve}s); rotation cursor kept" >>"$LOGFILE"
			yielded=1
			break
		fi
		total_repos=$((total_repos + 1))
		_pulse_scanner_mark_started "$cursor_file" "$slug"
		echo "[pulse-wrapper] Auto-decomposer: scanning $slug" >>"$LOGFILE"
		"$scanner" scan "$slug" >>"$LOGFILE" 2>&1 || true
	done < <(_pulse_scanner_rotated_slugs "$cursor_file" "$enabled_slugs")
	if [[ "$skipped_contributor" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-decomposer: skipped ${skipped_contributor} contributor-role repo(s) (t2145)" >>"$LOGFILE"
	fi
	if [[ "$yielded" -eq 1 ]]; then
		if declare -F _log_substage_timing >/dev/null; then
			_log_substage_timing "auto_decomposer_scanner:yielded" "$stage_start_seconds" 0
		fi
		echo "[pulse-wrapper] Auto-decomposer: yielded after ${total_repos} repo(s)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] Auto-decomposer: completed ${total_repos} repo(s) (per-parent re-file gate: $((AUTO_DECOMPOSER_INTERVAL / 86400))d)" >>"$LOGFILE"
	return 0
}
