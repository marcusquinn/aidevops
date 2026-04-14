#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-issue-reconcile.sh — Issue state reconciliation — assignment normalization, close-on-merged-PR, stale status:done recovery.
#
# Extracted from pulse-wrapper.sh in Phase 5 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order):
#   - _normalize_reassign_self           (Phase 12: orphaned active issue → self-assign)
#   - _normalize_clear_status_labels     (Phase 12: reset one stale issue's labels/assignee)
#   - _normalize_unassign_stale          (Phase 12: detect + reset stale assignments)
#   - normalize_active_issue_assignments (coordinator — calls the three helpers above)
#   - close_issues_with_merged_prs
#   - reconcile_stale_done_issues

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_LOADED=1

#######################################
# (Phase 12 helper) Assign runner to orphaned active issues.
#
# Pass 1 of normalize_active_issue_assignments: scan all pulse repos for
# issues that have status:queued or status:in-progress but no assignee,
# and self-assign this runner. Includes the t1996 dedup guard to prevent
# the two-runner simultaneous-assign stuck state.
#
# Args:
#   $1 runner_user        — GH login of the current runner
#   $2 repos_json         — path to repos.json
#   $3 dedup_helper       — path to dispatch-dedup-helper.sh (may be absent)
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
_normalize_reassign_self() {
	local runner_user="$1"
	local repos_json="$2"
	local dedup_helper="$3"

	local total_checked=0
	local total_assigned=0
	local total_skipped_claimed=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issue_rows issue_rows_json issue_rows_err
		issue_rows_err=$(mktemp)
		issue_rows_json=$(gh issue list --repo "$slug" --state open --json number,assignees,labels --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$issue_rows_err") || issue_rows_json=""
		if [[ -z "$issue_rows_json" || "$issue_rows_json" == "null" ]]; then
			local _issue_rows_err_msg
			_issue_rows_err_msg=$(cat "$issue_rows_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] normalize_active_issue_assignments: gh issue list FAILED for ${slug}: ${_issue_rows_err_msg}" >>"$LOGFILE"
			rm -f "$issue_rows_err"
			continue
		fi
		rm -f "$issue_rows_err"
		local issue_rows
		issue_rows=$(printf '%s' "$issue_rows_json" | jq -r '.[] | select(((.labels | map(.name) | index("status:queued")) or (.labels | map(.name) | index("status:in-progress"))) and ((.assignees | length) == 0)) | .number' 2>/dev/null) || issue_rows=""
		[[ -n "$issue_rows" ]] || continue

		while IFS= read -r issue_number; do
			[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
			total_checked=$((total_checked + 1))

			# t1996: Guard against the multi-runner assignment race. Two runners
			# may both observe the same "status:queued, no assignee" issue in
			# their batch queries and race to self-assign. Without this check,
			# both succeed and the issue ends up with two assignees — each runner
			# sees the other as blocking, so neither can dispatch, and the issue
			# sits stuck until stale recovery clears it (up to 1h).
			#
			# Checking is_assigned() here re-reads the live issue state. If
			# another runner has already claimed it (exit 0 = assigned to other),
			# skip this issue and let that runner's pulse handle dispatch.
			# If still unassigned (exit 1 = safe), proceed with self-assignment.
			if [[ -x "$dedup_helper" ]]; then
				local _is_assigned_output=""
				if _is_assigned_output=$("$dedup_helper" is-assigned "$issue_number" "$slug" "$runner_user" 2>/dev/null); then
					# Another runner already claimed this issue — skip reconcile
					echo "[pulse-wrapper] Assignment normalization: skipping #${issue_number} in ${slug} — already claimed by another runner (${_is_assigned_output})" >>"$LOGFILE"
					total_skipped_claimed=$((total_skipped_claimed + 1))
					continue
				fi
			fi

			if gh issue edit "$issue_number" --repo "$slug" --add-assignee "$runner_user" >/dev/null 2>&1; then
				total_assigned=$((total_assigned + 1))
			fi
		done <<<"$issue_rows"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_checked" -gt 0 ]]; then
		echo "[pulse-wrapper] Assignment normalization: assigned ${total_assigned}/${total_checked} active unassigned issues to ${runner_user} (skipped_claimed=${total_skipped_claimed})" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# (Phase 12 helper) Reset a single stale issue's labels and assignee.
#
# Removes the active dispatch labels (status:queued, status:in-progress)
# and the runner's assignee from one issue, then marks it status:available
# so the deterministic fill floor can re-dispatch it.
#
# Called by _normalize_unassign_stale once it has confirmed that no worker
# process is actively handling the issue.
#
# Args:
#   $1 issue_num   — numeric GitHub issue number
#   $2 slug        — owner/repo
#   $3 runner_user — GH login to remove as assignee
# Returns: 0 on gh success, non-zero on gh failure
#######################################
_normalize_clear_status_labels() {
	local issue_num="$1"
	local slug="$2"
	local runner_user="$3"

	# t2033: atomic transition to status:available, clearing all sibling
	# core status labels in one edit (not just queued/in-progress).
	set_issue_status "$issue_num" "$slug" "available" \
		--remove-assignee "$runner_user" >/dev/null 2>&1
	return $?
}

#######################################
# (Phase 12 helper) Read the Worker PID and dispatch timestamp from the most
# recent dispatch comment on a GitHub issue.
#
# Outputs two lines to stdout: the Worker PID (blank if not found) followed by
# the ISO-8601 created_at timestamp (blank if not found). Uses a single gh api
# call with jq to avoid multiple round-trips.
#
# Args:
#   $1 slug       — owner/repo
#   $2 stale_num  — numeric GitHub issue number
# Returns: 0 always (best-effort)
#######################################
_normalize_stale_get_dispatch_info() {
	local slug="$1"
	local stale_num="$2"

	local dispatch_pid=""
	local dispatch_created_at=""

	# The || true prevents set -e from exiting if gh api returns no comments.
	{
		IFS= read -r dispatch_pid
		IFS= read -r dispatch_created_at
	} < <(gh api "repos/${slug}/issues/${stale_num}/comments" \
		--jq '[.[] | select(.body | contains("Dispatching worker"))] | sort_by(.created_at) | last | if . then ((.body | capture("\\*\\*Worker PID\\*\\*: (?<pid>[0-9]+)") // {pid: ""} | .pid), (.created_at | sub("\\.[0-9]+Z$"; "Z"))) else empty end' \
		2>/dev/null) || true

	printf '%s\n%s\n' "$dispatch_pid" "$dispatch_created_at"
	return 0
}

#######################################
# (Phase 12 helper) Decide whether a stale-assigned issue should be skipped
# (worker still active) or reset (worker gone).
#
# Applies three checks in order:
#   1. Local pgrep — is any process referencing this issue number still running?
#   2. Cross-runner PID guard (t1933) — PID absent locally but dispatch comment
#      still within WORKER_MAX_RUNTIME, suggesting the worker is on another machine.
#   3. Worker log recency — was the worker log written in the last 10 minutes?
#
# Returns: 0 = skip (worker still active), 1 = reset (worker gone)
#
# Args:
#   $1 stale_num               — numeric GitHub issue number
#   $2 slug                    — owner/repo
#   $3 now_epoch               — current Unix timestamp (date +%s)
#   $4 cross_runner_max_runtime — seconds before cross-runner dispatch expires
#######################################
_normalize_stale_should_skip_reset() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"

	# Check 1: local worker process still referencing this issue
	if pgrep -f "pulse-reconcile.*[^0-9]${stale_num}([^0-9]|$)" >/dev/null 2>&1 || pgrep -f "#${stale_num}([^0-9]|$)" >/dev/null 2>&1; then
		return 0
	fi

	# Read dispatch PID and timestamp from the most recent dispatch comment
	local dispatch_info dispatch_pid dispatch_created_at
	dispatch_info=$(_normalize_stale_get_dispatch_info "$slug" "$stale_num")
	dispatch_pid=$(printf '%s\n' "$dispatch_info" | head -1)
	dispatch_created_at=$(printf '%s\n' "$dispatch_info" | tail -1)

	local dispatch_comment_age=0
	if [[ -n "$dispatch_created_at" ]]; then
		local dispatch_epoch
		dispatch_epoch=$(date -u -d "$dispatch_created_at" '+%s' 2>/dev/null ||
			TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$dispatch_created_at" '+%s' 2>/dev/null ||
			echo "0")
		if [[ "$dispatch_epoch" -gt 0 ]]; then
			dispatch_comment_age=$((now_epoch - dispatch_epoch))
		fi
	fi

	# Check 2: t1933 cross-runner guard — PID absent locally but within max_runtime
	if [[ -n "$dispatch_pid" ]] && [[ "$dispatch_pid" =~ ^[0-9]+$ ]]; then
		if ! ps -p "$dispatch_pid" >/dev/null 2>&1; then
			# PID not running locally — could be cross-runner dispatch.
			# Only reset if the dispatch comment has aged beyond WORKER_MAX_RUNTIME.
			if [[ "$dispatch_comment_age" -lt "$cross_runner_max_runtime" ]]; then
				echo "[pulse-wrapper] Stale assignment skip (cross-runner guard): #${stale_num} in ${slug} — dispatch PID ${dispatch_pid} not local, comment age ${dispatch_comment_age}s < max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
				return 0
			fi
			echo "[pulse-wrapper] Stale assignment reset (cross-runner expired): #${stale_num} in ${slug} — dispatch PID ${dispatch_pid} not local, comment age ${dispatch_comment_age}s >= max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
		fi
	fi

	# Check 3: worker log recency — log written in last 10 min means worker may still be active
	local safe_slug_check
	safe_slug_check=$(printf '%s' "$slug" | tr '/:' '--')
	local worker_log="/tmp/pulse-${safe_slug_check}-${stale_num}.log"
	if [[ -f "$worker_log" ]]; then
		local log_mtime
		# Linux stat -c first (stat -f '%m' on macOS outputs file info in a different format)
		log_mtime=$(stat -c '%Y' "$worker_log" 2>/dev/null || stat -f '%m' "$worker_log" 2>/dev/null) || log_mtime=0
		if [[ $((now_epoch - log_mtime)) -lt 600 ]]; then
			return 0
		fi
	fi

	return 1
}

#######################################
# (Phase 12) Detect and reset stale runner assignments.
#
# Pass 2 of normalize_active_issue_assignments: find issues assigned to
# runner_user with status:queued/in-progress that have been idle for >1h,
# verify no worker process is handling them (via _normalize_stale_should_skip_reset),
# and reset via _normalize_clear_status_labels so they can be re-dispatched.
#
# t1933: PID-based checks are local-only. In multi-runner setups, a worker
# dispatched by another machine is invisible to pgrep on this machine.
# Gate PID checks on runner identity: if the dispatch comment's Worker PID
# is not running locally, fall back to WORKER_MAX_RUNTIME time-based expiry
# before resetting. This prevents false recovery of cross-runner dispatches.
#
# Args:
#   $1 runner_user              — GH login of the current runner
#   $2 repos_json               — path to repos.json
#   $3 now_epoch                — current Unix timestamp (date +%s)
#   $4 cross_runner_max_runtime — seconds before a cross-runner dispatch is
#                                  considered expired (default: WORKER_MAX_RUNTIME)
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
_normalize_unassign_stale() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"

	local total_reset=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Find issues assigned to runner_user with active-dispatch labels
		local stale_json
		stale_json=$(gh issue list --repo "$slug" --assignee "$runner_user" --state open \
			--json number,labels,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || stale_json=""
		[[ -n "$stale_json" && "$stale_json" != "null" ]] || continue

		# Filter: has status:queued or status:in-progress, updated >1h ago
		local stale_issues
		stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - 3600))" '
			[.[] | select(
				((.labels | map(.name)) | (index("status:queued") or index("status:in-progress")))
				and ((.updatedAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber))
			) | .number] | .[]
		' 2>/dev/null) || stale_issues=""
		[[ -n "$stale_issues" ]] || continue

		local stale_num
		while IFS= read -r stale_num; do
			[[ "$stale_num" =~ ^[0-9]+$ ]] || continue

			if _normalize_stale_should_skip_reset "$stale_num" "$slug" "$now_epoch" "$cross_runner_max_runtime"; then
				continue
			fi

			# No active worker and all guards passed — reset for re-dispatch
			echo "[pulse-wrapper] Stale assignment reset: #${stale_num} in ${slug} — assigned to ${runner_user} with active label but no worker process" >>"$LOGFILE"
			_normalize_clear_status_labels "$stale_num" "$slug" "$runner_user" || true
			total_reset=$((total_reset + 1))
		done <<<"$stale_issues"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_reset" -gt 0 ]]; then
		echo "[pulse-wrapper] Stale assignment cleanup: reset ${total_reset} issues for re-dispatch" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# (t2040 Phase 3 helper) Enforce label invariants across all open issues.
#
# Walks every open issue in every pulse-enabled repo and enforces:
#
#   1. At most one core `status:*` label. When multiple are present,
#      the survivor is picked by ISSUE_STATUS_LABEL_PRECEDENCE
#      (`done > in-review > in-progress > queued > claimed > available
#      > blocked`). `done` is terminal — it always wins if present.
#      Atomic migration via `set_issue_status`.
#
#   2. At most one `tier:*` label. Rank matches
#      .github/workflows/dedup-tier-labels.yml so this pass is idempotent
#      with the GH Action: rank `reasoning > standard > simple`.
#
# Also counts (but does not auto-fix) triage-missing issues — those with
# `origin:interactive` label AND no `tier:*` AND no `auto-dispatch` AND no
# `status:*` AND created >30min ago. These need human tier assignment and
# brief creation; surfaced via the summary log line so the LLM sweep
# (t2041) can highlight them in the Hygiene Anomalies section.
#
# This pass is the backfill path for the 14 already-polluted issues left
# by the write-without-remove bug (fixed forward by PR #18519 / t2033)
# and the tier concatenation bug (fixed forward by PR #18441 / t1997).
# After a single pulse cycle post-merge, polluted state should normalize.
#
# Args:
#   $1 runner_user — GH login of the current runner (unused, kept for
#                    symmetry with other _normalize_* helpers)
#   $2 repos_json  — path to repos.json
# Returns: 0 always (best-effort; logs counters to $LOGFILE)
#######################################
# Helper: filter a space-separated list of status names down to those
# that are members of ISSUE_STATUS_LABELS. Used by the status-invariant
# check to ignore out-of-band labels (needs-info, verify-failed, etc.)
# which can legitimately coexist with a core status.
#
# Writes the result to the global array _LI_FILTERED_STATUS (bash 3.2
# has no namerefs; eval-based output patterns break under `set -u` when
# the result array is empty).
#
# Args:
#   $1 - space-separated status names (e.g. "available queued")
_filter_core_status_labels() {
	local status_list="$1"
	_LI_FILTERED_STATUS=()
	local _s _core_label
	[[ -n "$status_list" ]] || return 0
	for _s in $status_list; do
		for _core_label in "${ISSUE_STATUS_LABELS[@]}"; do
			if [[ "$_s" == "$_core_label" ]]; then
				_LI_FILTERED_STATUS+=("$_s")
				break
			fi
		done
	done
	return 0
}

# Helper: given an array of core status names, pick the survivor per
# ISSUE_STATUS_LABEL_PRECEDENCE and emit it on stdout. Empty if none.
_pick_status_survivor() {
	local _precedent _current
	for _precedent in "${ISSUE_STATUS_LABEL_PRECEDENCE[@]}"; do
		for _current in "$@"; do
			if [[ "$_current" == "$_precedent" ]]; then
				echo "$_precedent"
				return 0
			fi
		done
	done
	return 0
}

# Helper: given an array of tier names, pick the survivor per
# ISSUE_TIER_LABEL_RANK and emit it on stdout. Empty if none.
_pick_tier_survivor() {
	local _rank _current_tier
	for _rank in "${ISSUE_TIER_LABEL_RANK[@]}"; do
		for _current_tier in "$@"; do
			if [[ "$_current_tier" == "$_rank" ]]; then
				echo "$_rank"
				return 0
			fi
		done
	done
	return 0
}

# Helper: enforce status invariant for one issue. Caller passes the
# already-filtered core_status names as positional args (guaranteed
# by the caller to have length >1). Returns 0 if a fix was applied.
_enforce_status_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	shift 2
	local survivor
	survivor=$(_pick_status_survivor "$@")
	[[ -n "$survivor" ]] || return 1

	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} had status labels [$*] -> keeping '${survivor}'" >>"$LOGFILE"
	set_issue_status "$issue_num" "$slug" "$survivor" >/dev/null 2>&1 || true
	return 0
}

# Helper: enforce tier invariant for one issue. Caller passes tier
# names as positional args (guaranteed to have length >1).
_enforce_tier_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	shift 2
	local tier_survivor
	tier_survivor=$(_pick_tier_survivor "$@")
	[[ -n "$tier_survivor" ]] || return 1

	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} had tier labels [$*] -> keeping 'tier:${tier_survivor}'" >>"$LOGFILE"
	local -a tier_flags=()
	local _losing
	for _losing in "$@"; do
		if [[ "$_losing" != "$tier_survivor" ]]; then
			tier_flags+=(--remove-label "tier:${_losing}")
		fi
	done
	[[ "${#tier_flags[@]}" -gt 0 ]] || return 1
	gh issue edit "$issue_num" --repo "$slug" "${tier_flags[@]}" >/dev/null 2>&1 || true
	return 0
}

# Helper: fetch issues for a repo and emit '|'-delimited rows per issue.
# See delimiter note in _normalize_label_invariants_for_repo.
_fetch_label_invariant_rows() {
	local slug="$1"
	local issues_json
	issues_json=$(gh issue list --repo "$slug" --state open \
		--json number,labels,createdAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || issues_json=""
	[[ -n "$issues_json" && "$issues_json" != "null" ]] || return 1

	# has_any_status counts ALL status:* labels (core + exception) so the
	# triage-missing counter correctly ignores issues that are actively
	# managed via an exception label (needs-info, verify-failed, stale,
	# needs-testing, orphaned). See CodeRabbit review on PR #18546.
	printf '%s' "$issues_json" | jq -r '
		.[] | [
			(.number | tostring),
			([.labels[].name | select(startswith("status:")) | sub("^status:"; "")] | join(" ")),
			([.labels[].name | select(startswith("tier:"))   | sub("^tier:";   "")] | join(" ")),
			((.labels | map(.name) | index("origin:interactive")) != null | tostring),
			((.labels | map(.name) | index("auto-dispatch"))      != null | tostring),
			(.createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring),
			(([.labels[].name | select(startswith("status:"))] | length) | tostring)
		] | join("|")
	' 2>/dev/null
	return 0
}

# Helper: process all issues for one repo. Updates the global
# _LI_* counters (caller accumulates into totals).
#
# Uses global accumulators rather than per-call output vars because
# the outer coordinator needs three counters and one checked count.
#
# DELIMITER CHOICE: '|' — a non-whitespace character that GitHub
# label names cannot contain. Do NOT use @tsv: bash read with
# IFS=$'\t' collapses consecutive tabs because tab is a whitespace
# character in bash's field-splitting rules, so empty fields silently
# disappear and the next field shifts into place, corrupting parses
# on issues with no status labels (tier-only pollution case).
_normalize_label_invariants_for_repo() {
	local slug="$1"
	local triage_cutoff="$2"

	local rows
	rows=$(_fetch_label_invariant_rows "$slug") || return 0
	[[ -n "$rows" ]] || return 0

	local issue_num status_list tier_list has_origin_i has_auto created_epoch all_status_count
	while IFS='|' read -r issue_num status_list tier_list has_origin_i has_auto created_epoch all_status_count; do
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
		_LI_CHECKED=$((_LI_CHECKED + 1))

		_filter_core_status_labels "$status_list"
		local core_count="${#_LI_FILTERED_STATUS[@]}"

		if [[ "$core_count" -gt 1 ]] &&
			_enforce_status_invariant_one_issue "$issue_num" "$slug" "${_LI_FILTERED_STATUS[@]}"; then
			_LI_STATUS_FIXED=$((_LI_STATUS_FIXED + 1))
		fi

		local -a tier_arr=()
		if [[ -n "$tier_list" ]]; then
			local _t
			for _t in $tier_list; do
				tier_arr+=("$_t")
			done
		fi

		local tier_count="${#tier_arr[@]}"
		if [[ "$tier_count" -gt 1 ]] &&
			_enforce_tier_invariant_one_issue "$issue_num" "$slug" "${tier_arr[@]}"; then
			_LI_TIER_FIXED=$((_LI_TIER_FIXED + 1))
		fi

		# Triage-missing count (flag only, no auto-fix). origin:interactive
		# + no tier + no auto-dispatch + no status:* AT ALL (including
		# exception labels like needs-info/verify-failed/stale — an issue
		# in those states is actively managed, not awaiting triage) +
		# created >30min ago = maintainer-intended issue not briefed into
		# the dispatch pipeline.
		if [[ "$has_origin_i" == "true" &&
			-z "$tier_list" &&
			"$has_auto" == "false" &&
			"$all_status_count" == "0" &&
			"$created_epoch" =~ ^[0-9]+$ &&
			"$created_epoch" -lt "$triage_cutoff" ]]; then
			_LI_TRIAGE_MISSING=$((_LI_TRIAGE_MISSING + 1))
		fi
	done <<<"$rows"
	return 0
}

# Helper: write the counter JSON file consumed by t2041 prefetch layer.
_write_label_invariants_counter_file() {
	local counters_dir="${HOME}/.aidevops/cache"
	local hostname_short
	hostname_short=$(hostname -s 2>/dev/null || echo unknown)
	local counters_file="${counters_dir}/pulse-label-invariants.${hostname_short}.json"
	mkdir -p "$counters_dir" 2>/dev/null || true
	{
		printf '{"timestamp": "%s", "checked": %d, "status_fixed": %d, "tier_fixed": %d, "triage_missing": %d}\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
			"$_LI_CHECKED" "$_LI_STATUS_FIXED" "$_LI_TIER_FIXED" "$_LI_TRIAGE_MISSING"
	} >"$counters_file" 2>/dev/null || true
	return 0
}

# t2040: coordinator for the label-invariant pass. Delegates the per-issue
# work to focused helpers so each function stays under the 100-line block
# threshold. Global accumulators (_LI_*) are used instead of per-call
# output vars because the coordinator needs four counters and bash 3.2
# lacks namerefs.
_normalize_label_invariants() {
	local runner_user="$1"
	local repos_json="$2"
	# shellcheck disable=SC2034  # runner_user kept for signature symmetry
	local _unused_runner="$runner_user"

	# Guard: requires the precedence arrays from shared-constants.sh.
	# Silently skip (fail-open) to avoid blocking the pulse on a bootstrap bug.
	if [[ -z "${ISSUE_STATUS_LABEL_PRECEDENCE+x}" || -z "${ISSUE_TIER_LABEL_RANK+x}" ]]; then
		echo "[pulse-wrapper] normalize_label_invariants skipped: precedence arrays not loaded" >>"$LOGFILE"
		return 0
	fi

	# Shared accumulators — reset at start of every pass.
	_LI_CHECKED=0
	_LI_STATUS_FIXED=0
	_LI_TIER_FIXED=0
	_LI_TRIAGE_MISSING=0

	local now_epoch
	now_epoch=$(date +%s)
	local triage_cutoff=$((now_epoch - 1800))

	local slug
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_normalize_label_invariants_for_repo "$slug" "$triage_cutoff"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	echo "[pulse-wrapper] label_invariants: checked=${_LI_CHECKED} status_fixed=${_LI_STATUS_FIXED} tier_fixed=${_LI_TIER_FIXED} triage_missing=${_LI_TRIAGE_MISSING}" >>"$LOGFILE"

	_write_label_invariants_counter_file
	return 0
}

#######################################
# Ensure active issues have an assignee (coordinator).
#
# Prevent overlap by normalizing assignment on issues already marked as
# actively worked (`status:queued` or `status:in-progress`). Coordinates
# three passes via private helpers:
#
#   Pass 1 — _normalize_reassign_self: find issues with active labels but
#     no assignee and self-assign this runner (with t1996 dedup guard).
#
#   Pass 2 — _normalize_unassign_stale: find issues assigned to this runner
#     with active labels but no running worker, and reset via
#     _normalize_clear_status_labels so they can be re-dispatched.
#
#   Pass 3 — _normalize_label_invariants (t2040): enforce at-most-one
#     `status:*` and at-most-one `tier:*` invariants, backfilling polluted
#     issues left by pre-t2033 / pre-t1997 write-without-remove bugs.
#
# Note: the combined "label AND assignee" rule (t1996) applies here:
#   - A status label without an assignee = degraded state (safe to claim)
#   - A status label WITH a non-self assignee = another runner claimed it
#   - Both signals are required; neither is sufficient alone
#
# Returns: 0 always (best-effort)
#######################################
normalize_active_issue_assignments() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local runner_user
	runner_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$runner_user" ]]; then
		echo "[pulse-wrapper] Assignment normalization skipped: unable to resolve runner user" >>"$LOGFILE"
		return 0
	fi

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	local now_epoch
	now_epoch=$(date +%s)
	# Default max runtime for cross-runner time-based expiry (3h, matches worker-watchdog.sh default)
	local cross_runner_max_runtime="${WORKER_MAX_RUNTIME:-10800}"

	# Pass 1: assign runner to orphaned active issues (active label, no assignee)
	_normalize_reassign_self "$runner_user" "$repos_json" "$dedup_helper"

	# Pass 2: reset stale assignments (active label, assignee present, no running worker)
	_normalize_unassign_stale "$runner_user" "$repos_json" "$now_epoch" "$cross_runner_max_runtime"

	# Pass 3 (t2040): enforce label invariants (at most one status:*, at most one tier:*).
	# Runs unconditionally on every cycle — the cost is bounded by
	# PULSE_QUEUED_SCAN_LIMIT per repo, and a clean backlog is a no-op
	# beyond the single gh issue list call.
	_normalize_label_invariants "$runner_user" "$repos_json"

	return 0
}

#######################################
# Close open issues whose work is already done — a merged PR exists
# that references the issue via "Closes #N" or matching task ID in
# the PR title (GH#16851).
#
# The dedup guard (Layer 4) detects these and blocks re-dispatch,
# but the issue stays open forever. This stage closes them with a
# comment linking to the merged PR, cleaning the backlog.
#######################################
close_issues_with_merged_prs() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Only check issues marked available for dispatch. Capped at 20
		# per repo to limit API calls (dedup helper makes 1 call per issue).
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "status:available" \
			--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Skip management issues (supervisor, persistent, quality-review)
			# — these are intentionally kept open
			local labels_csv
			labels_csv=$(printf '%s' "$issues_json" | jq -r ".[$((i - 1))].labels // [] | map(.name) | join(\",\")" 2>/dev/null) || labels_csv=""

			# Ask dedup helper if a merged PR exists for this issue
			local dedup_output=""
			if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
				# has-open-pr returns 0 when PR evidence found (open OR merged).
				# For closing, we MUST verify the PR is actually merged — an open
				# PR means work is in progress, not complete. (GH#17871 fix)
				local pr_ref
				pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
				local pr_num
				pr_num=$(printf '%s' "$pr_ref" | tr -d '#')

				# GH#17871: Verify PR is actually merged before closing.
				# The dedup helper's Check 1 matches OPEN PRs by title/commit.
				# An open PR blocks dispatch (correct) but must NOT trigger
				# issue closure — the work isn't done yet.
				if [[ -n "$pr_num" ]]; then
					local merged_at
					merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
					if [[ -z "$merged_at" ]]; then
						echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} exists but is NOT merged (GH#17871 guard)" >>"$LOGFILE"
						continue
					fi
				fi

				# GH#17372: Verify PR diff actually touches files from the issue.
				# A merged PR with "closes #NNN" may reference the issue without
				# fixing it (e.g., mentioned in a comment, not the actual fix).
				if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
					if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
						echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
						continue
					fi
				fi

				gh issue close "$issue_num" --repo "$slug" \
					--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"} (merged at ${merged_at:-unknown}). Issue was open but dedup guard was blocking re-dispatch." \
					>/dev/null 2>&1 || continue

				# Reset fast-fail counter now that the issue is confirmed resolved (GH#17384)
				fast_fail_reset "$issue_num" "$slug" || true
				# t1934: Unlock issue (locked at dispatch time)
				unlock_issue_after_worker "$issue_num" "$slug"

				echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
				total_closed=$((total_closed + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Close issues with merged PRs: closed ${total_closed} issue(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Reconcile status:done issues that are still open.
#
# Workers set status:done when they believe work is complete, but the
# issue may stay open if: (1) PR merged but Closes #N was missing,
# (2) worker declared done but never created a PR, (3) PR was rejected.
#
# Case 1: merged PR found → close the issue (work verified done).
# Cases 2+3: no merged PR → reset to status:available for re-dispatch.
#
# Capped at 20 per repo per cycle to limit API calls.
#######################################
reconcile_stale_done_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0
	local total_reset=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "status:done" \
			--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Check if a merged PR exists for this issue
			local dedup_output=""
			if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
				# Dedup helper returns 0 for open OR merged PRs.
				# For closing, verify the PR is actually merged (GH#17871).
				local pr_ref
				pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
				local pr_num
				pr_num=$(printf '%s' "$pr_ref" | tr -d '#')

				# GH#17871: Verify PR is actually merged before closing.
				local merged_at=""
				if [[ -n "$pr_num" ]]; then
					merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
					if [[ -z "$merged_at" ]]; then
						echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
						# Reset to available — PR exists but isn't merged yet (t2033: atomic)
						set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || continue
						total_reset=$((total_reset + 1))
						continue
					fi
				fi

				# GH#17372: Verify PR diff touches files from the issue
				if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
					if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
						echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} does not touch issue files (GH#17372 guard)" >>"$LOGFILE"
						# Reset to available for re-evaluation instead of closing (t2033: atomic)
						set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || continue
						total_reset=$((total_reset + 1))
						continue
					fi
				fi

				gh issue close "$issue_num" --repo "$slug" \
					--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup)"} (merged at ${merged_at:-unknown})." \
					>/dev/null 2>&1 || continue

				# Reset fast-fail counter now that the issue is confirmed resolved (GH#17384)
				fast_fail_reset "$issue_num" "$slug" || true
				# t1934: Unlock issue (locked at dispatch time)
				unlock_issue_after_worker "$issue_num" "$slug"

				echo "[pulse-wrapper] Reconcile done: closed #${issue_num} in ${slug} — merged PR: ${dedup_output:-"found"}" >>"$LOGFILE"
				total_closed=$((total_closed + 1))
			else
				# No merged PR — reset for re-evaluation (t2033: atomic)
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || continue
				echo "[pulse-wrapper] Reconcile done: reset #${issue_num} in ${slug} to status:available — no merged PR evidence" >>"$LOGFILE"
				total_reset=$((total_reset + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$((total_closed + total_reset))" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile stale done issues: closed=${total_closed}, reset=${total_reset}" >>"$LOGFILE"
	fi

	return 0
}
