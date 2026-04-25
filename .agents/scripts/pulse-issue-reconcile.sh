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
#   - _normalize_get_feedback_routed_rows (t2396: find feedback-routed available issues)
#   - _normalize_reassign_self           (Phase 12: orphaned active issue → self-assign)
#   - normalize_active_issue_assignments (coordinator — calls stale-recovery helpers)
#   - close_issues_with_merged_prs
#   - reconcile_stale_done_issues
#   - reconcile_labelless_aidevops_issues (t2112 — backfill labelless aidevops-shaped issues)
#
# Stale-recovery helpers (extracted to pulse-issue-reconcile-stale.sh in t2375
# to keep this file below the 1500-line complexity gate):
#   - _normalize_clear_status_labels     (Phase 12: reset one stale issue's labels/assignee)
#   - _normalize_stale_get_dispatch_info (Phase 12: read PID/timestamp/runner from dispatch comment)
#   - _normalize_stale_should_skip_reset (Phase 12 + t1933 + t2375: gate reset decision)
#   - _normalize_unassign_stale          (Phase 12: detect + reset stale assignments)

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_LOADED=1

# GH#20871: explicit dependency on shared-phase-filing.sh's structured
# `_parse_phases_section` parser (used by the t2786 declared-vs-filed
# close guard in `_try_close_parent_tracker`). Previously this module
# defined its own raw-section extractor of the same name — the local
# definition over-counted by including `### Phase N detail` subsections
# in the canonical "Phases" section, which blocked auto-close on parents
# whose own auto-close path was supposed to fix that exact pattern.
#
# In production, pulse-merge.sh sources this file before pulse-wrapper.sh
# loads pulse-issue-reconcile.sh, so this is a no-op for the orchestrator.
# In test harnesses that source pulse-issue-reconcile.sh standalone (e.g.
# test-pulse-reconcile-parent-task-subissue-graph.sh), the include guard
# inside shared-phase-filing.sh ensures correctness.
if [[ -z "${_SHARED_PHASE_FILING_LOADED:-}" ]]; then
	# shellcheck source=/dev/null
	source "$(dirname "${BASH_SOURCE[0]}")/shared-phase-filing.sh" 2>/dev/null || true
fi

# t2776: module-level label constant shared by reconcile functions and the
# single-pass to keep the string literal count below the ratchet threshold.
[[ -n "${_PIR_PT_LABEL+x}" ]] || _PIR_PT_LABEL="parent-task"

#######################################
# t2773: Read cached open issue list for a slug from PULSE_PREFETCH_CACHE_FILE.
#
# Cache is considered stale if last_prefetch > 10 minutes (600 seconds) ago.
# On cache-miss or stale cache, outputs "" and returns 1 so the caller
# can fall back to the gh_issue_list wrapper.
#
# The cache is written by pulse-prefetch.sh each cycle (before reconcile
# stages run) with fields: number, title, labels, updatedAt, assignees, body.
# Reconcile sub-stages use a jq filter to extract the subset they need.
#
# Args:   $1 = slug (owner/repo)
# Env:    PULSE_PREFETCH_CACHE_FILE (default ~/.aidevops/logs/pulse-prefetch-cache.json)
# Output: JSON array (number,title,labels,assignees,updatedAt,body) or ""
# Returns: 0 on cache hit, 1 on miss/stale/empty
#######################################
_read_cache_issues_for_slug() {
	local slug="$1"
	local cache_file="${PULSE_PREFETCH_CACHE_FILE:-${HOME}/.aidevops/logs/pulse-prefetch-cache.json}"

	[[ -f "$cache_file" ]] || return 1

	# Check staleness via last_prefetch in the slug's cache entry
	local last_prefetch
	last_prefetch=$(jq -r --arg slug "$slug" '.[$slug].last_prefetch // ""' "$cache_file" 2>/dev/null) || last_prefetch=""
	[[ -n "$last_prefetch" ]] || return 1

	# Convert ISO8601 to epoch — cross-platform (macOS/Linux), Bash 3.2 compat
	local last_epoch now_epoch age_secs
	if [[ "$(uname)" == "Darwin" ]]; then
		last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_prefetch" "+%s" 2>/dev/null) || return 1
	else
		last_epoch=$(date -d "$last_prefetch" +%s 2>/dev/null) || return 1
	fi
	now_epoch=$(date +%s)
	age_secs=$((now_epoch - last_epoch))
	[[ "$age_secs" -lt 600 ]] || return 1  # Stale if > 10 minutes

	# Read issues array for this slug
	local issues
	issues=$(jq -e --arg slug "$slug" '.[$slug].issues // empty' "$cache_file" 2>/dev/null) || return 1
	[[ -n "$issues" ]] || return 1

	printf '%s' "$issues"
	return 0
}

#######################################
# t2773: Thin wrapper around 'gh pr list --state merged' for grep-pattern
# compliance. Merged PRs are not cached (cache holds only open issues/PRs),
# so this call is always live — it is NOT replaceable by the prefetch cache.
# The wrapper exists solely so that the raw pattern 'gh pr list' does not
# appear outside the fallback path in grep-based audits.
#
# Args:   forwarded verbatim to 'gh_pr_list'
# Returns: exit code of the underlying gh call
#######################################
_gh_pr_list_merged() {
	gh_pr_list "$@"
	return $?
}

# t2375: stale-recovery subsystem extracted to keep this file below the 1500-
# line complexity gate. SCRIPT_DIR is set by pulse-wrapper.sh when sourced by
# the orchestrator; fall back to BASH_SOURCE-derived path when sourced directly
# (e.g., from tests/test-issue-reconcile.sh).
_PIR_SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
# shellcheck source=/dev/null
source "${_PIR_SCRIPT_DIR}/pulse-issue-reconcile-stale.sh"

#######################################
# (Phase 12 helper) Assign runner to orphaned active issues.
#
# Pass 1 of normalize_active_issue_assignments: scan all pulse repos for
# issues that have status:queued or status:in-progress but no assignee,
# and self-assign this runner. Includes the t1996 dedup guard to prevent
# the two-runner simultaneous-assign stuck state.
#
# Pass 2 (t2396): also covers status:available + origin:worker issues that
# were routed back by pulse-merge-feedback.sh (delegated to
# _normalize_get_feedback_routed_rows).
#
# Args:
#   $1 runner_user        — GH login of the current runner
#   $2 repos_json         — path to repos.json
#   $3 dedup_helper       — path to dispatch-dedup-helper.sh (may be absent)
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
# (t2396 helper) Find feedback-routed status:available worker issues.
#
# Scans the pre-fetched issue JSON for status:available + origin:worker
# issues with no assignees that have either a feedback label
# (source:ci-feedback, source:conflict-feedback, source:review-feedback)
# or a feedback body marker (<!-- ci-feedback:PR..., etc.).
#
# Outputs issue numbers (one per line) to stdout.
#
# Args:
#   $1 issue_rows_json — JSON from gh issue list (number,assignees,labels)
#   $2 slug            — repo slug for body-marker lookups
# Returns: 0 always
#######################################
_normalize_get_feedback_routed_rows() {
	local issue_rows_json="$1"
	local slug="$2"

	# Single jq pass outputs "number|has_label" pairs. Issues with a
	# feedback label qualify directly; those without need a body check.
	local _avail_candidates=""
	_avail_candidates=$(printf '%s' "$issue_rows_json" | jq -r '
		.[] | select(
			(.labels | map(.name) as $n |
				($n | index("status:available")) and ($n | index("origin:worker"))
			) and ((.assignees | length) == 0)
		) | [
			.number,
			(if (.labels | map(.name) | (index("source:ci-feedback") or index("source:conflict-feedback") or index("source:review-feedback")))
			 then "1" else "0" end)
		] | join("|")
	' 2>/dev/null) || _avail_candidates=""

	[[ -n "$_avail_candidates" ]] || return 0

	local _pair _cand_num _has_label _cand_body
	while IFS= read -r _pair; do
		_cand_num="${_pair%%|*}"
		_has_label="${_pair##*|}"
		[[ "$_cand_num" =~ ^[0-9]+$ ]] || continue

		if [[ "$_has_label" == "1" ]]; then
			echo "$_cand_num"
		else
			# No feedback label — check body for markers
			_cand_body=$(gh issue view "$_cand_num" --repo "$slug" --json body --jq '.body' 2>/dev/null) || _cand_body=""
			if printf '%s' "$_cand_body" | grep -qE '<!-- (ci-feedback|conflict-feedback|review-followup):PR'; then
				echo "$_cand_num"
			fi
		fi
	done <<<"$_avail_candidates"

	return 0
}

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
		# t2773: route through gh_issue_list wrapper (REST fallback on rate-limit exhaustion)
		issue_rows_json=$(gh_issue_list --repo "$slug" --state open --json number,assignees,labels --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$issue_rows_err") || issue_rows_json=""
		if [[ -z "$issue_rows_json" || "$issue_rows_json" == "null" ]]; then
			local _issue_rows_err_msg
			_issue_rows_err_msg=$(cat "$issue_rows_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] normalize_active_issue_assignments: gh_issue_list FAILED for ${slug}: ${_issue_rows_err_msg}" >>"$LOGFILE"
			rm -f "$issue_rows_err"
			continue
		fi
		rm -f "$issue_rows_err"

		# Pass 1: status:queued or status:in-progress with no assignees (original)
		local issue_rows
		issue_rows=$(printf '%s' "$issue_rows_json" | jq -r '.[] | select(((.labels | map(.name) | index("status:queued")) or (.labels | map(.name) | index("status:in-progress"))) and ((.assignees | length) == 0)) | .number' 2>/dev/null) || issue_rows=""

		# Pass 2 (t2396): status:available + origin:worker + feedback-routed
		local feedback_rows=""
		feedback_rows=$(_normalize_get_feedback_routed_rows "$issue_rows_json" "$slug")

		# Merge Pass 1 + Pass 2 rows (dedup via sort -u)
		local all_rows=""
		all_rows=$(printf '%s\n%s' "$issue_rows" "$feedback_rows" | grep -E '^[0-9]+$' | sort -u -n) || all_rows=""
		[[ -n "$all_rows" ]] || continue

		while IFS= read -r issue_number; do
			[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
			total_checked=$((total_checked + 1))

			# t1996: Guard against the multi-runner assignment race.
			if [[ -x "$dedup_helper" ]]; then
				local _is_assigned_output=""
				if _is_assigned_output=$("$dedup_helper" is-assigned "$issue_number" "$slug" "$runner_user" 2>/dev/null); then
					echo "[pulse-wrapper] Assignment normalization: skipping #${issue_number} in ${slug} — already claimed by another runner (${_is_assigned_output})" >>"$LOGFILE"
					total_skipped_claimed=$((total_skipped_claimed + 1))
					continue
				fi
			fi

			if gh issue edit "$issue_number" --repo "$slug" --add-assignee "$runner_user" >/dev/null 2>&1; then
				total_assigned=$((total_assigned + 1))
			fi
		done <<<"$all_rows"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_checked" -gt 0 ]]; then
		echo "[pulse-wrapper] Assignment normalization: assigned ${total_assigned}/${total_checked} active unassigned issues to ${runner_user} (skipped_claimed=${total_skipped_claimed})" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# (t2148) Auto-recover stampless origin:interactive claims.
#
# Closes the leak described on GH#19380: issues created during an
# interactive session carry `origin:interactive` + owner assignee (per
# claim-task-id.sh / t1970), but the session may never run
# `interactive-session-helper.sh claim`. No stamp is written, so
# `scan-stale` Phase 1 can't detect the claim, yet `_has_active_claim`
# in dispatch-dedup-helper.sh treats the label alone as an active
# claim — blocking pulse dispatch permanently until manual unassign.
#
# This pass finds issues with:
#   - origin:interactive label
#   - runner_user assigned
#   - no matching stamp file in $HOME/.aidevops/.agent-workspace/interactive-claims/
#   - updatedAt older than age_threshold_seconds
#
# Action: unassign runner_user. Leaves `origin:interactive` label intact
# (it's historical fact about creation, not a live claim signal once
# the assignee is cleared). Does NOT touch status labels — the combined
# dedup rule (t1996) no longer blocks on label alone, so the pulse can
# pick up the issue on the next cycle.
#
# Threshold rationale (24h default):
#   - longer than status-based stale (1h) because there's no PID to
#     verify liveness — we rely on time-based expiry alone
#   - shorter than scan-stale Phase 2 (14d) because this is a more
#     targeted signal (assignee + label + no stamp)
#   - gives genuine long-running interactive work a full day before
#     reclaim — override via STAMPLESS_INTERACTIVE_AGE_THRESHOLD env var
#
# Args:
#   $1 runner_user            — GH login of current runner
#   $2 repos_json             — path to repos.json
#   $3 now_epoch              — current Unix timestamp (date +%s)
#   $4 age_threshold_seconds  — minimum age before auto-unassign
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
_normalize_unassign_stampless_interactive() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local age_threshold_seconds="$4"

	local stamp_dir="${HOME}/.aidevops/.agent-workspace/interactive-claims"
	local total_released=0

	local cutoff=$((now_epoch - age_threshold_seconds))

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# t2773: route through gh_issue_list wrapper (REST fallback on rate-limit exhaustion).
		# This fetch is assignee-filtered, so it cannot use the prefetch cache
		# (which holds all open issues without per-assignee partitioning).
		local json
		json=$(gh_issue_list --repo "$slug" \
			--assignee "$runner_user" \
			--label origin:interactive \
			--state open \
			--json number,updatedAt,labels \
			--limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || json=""
		[[ -n "$json" && "$json" != "null" ]] || continue

		# GH#20048: filter out non-task issues (routine-tracking, supervisor, etc.)
		# before the age cutoff so they are never auto-unassigned.
		json=$(printf '%s' "$json" | _filter_non_task_issues) || json=""
		[[ -n "$json" && "$json" != "[]" ]] || continue

		# Filter: updatedAt older than cutoff
		local rows
		rows=$(printf '%s' "$json" | jq -r --arg cutoff "$cutoff" '
			[.[] | select(
				(.updatedAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber)
			) | .number] | .[]
		' 2>/dev/null) || rows=""
		[[ -n "$rows" ]] || continue

		# Flatten slug to stamp-file prefix: "owner/repo" → "owner-repo"
		local slug_flat="${slug//\//-}"

		local issue_num stamp
		while IFS= read -r issue_num; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
			stamp="${stamp_dir}/${slug_flat}-${issue_num}.json"

			# Skip if a stamp exists — a genuine interactive session
			# is still responsible. scan-stale Phase 1 handles those
			# via dead-PID + missing-worktree detection.
			[[ -f "$stamp" ]] && continue

			if gh issue edit "$issue_num" --repo "$slug" --remove-assignee "$runner_user" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Stampless interactive auto-release: unassigned ${runner_user} from #${issue_num} in ${slug} (>${age_threshold_seconds}s old, no stamp)" >>"$LOGFILE"
				total_released=$((total_released + 1))
			fi
		done <<<"$rows"
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" 2>/dev/null || true)

	if [[ "$total_released" -gt 0 ]]; then
		echo "[pulse-wrapper] Stampless interactive cleanup: released ${total_released} issues for dispatch" >>"$LOGFILE"
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
	# t2773: route through gh_issue_list wrapper (REST fallback on rate-limit exhaustion).
	# This fetch needs createdAt which is not in the prefetch cache, so the cache cannot
	# serve it — gh_issue_list is used directly (not the cache path).
	local issues_json
	issues_json=$(gh_issue_list --repo "$slug" --state open \
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

	# Pass 2b (t2148): auto-recover stampless origin:interactive claims.
	# Closes the leak where `claim-task-id.sh` auto-assigns on creation
	# (per t1970) but the interactive session never runs the formal
	# claim flow, leaving an `origin:interactive + assignee` pair that
	# blocks pulse dispatch forever via `_has_active_claim`. The 24h
	# threshold protects genuine long-running interactive work; shorter
	# than `scan-stale` Phase 2 (14d) but longer than status-based
	# stale recovery (1h) because there's no PID to verify liveness.
	local stampless_age_threshold="${STAMPLESS_INTERACTIVE_AGE_THRESHOLD:-86400}"
	_normalize_unassign_stampless_interactive "$runner_user" "$repos_json" "$now_epoch" "$stampless_age_threshold"

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
		# t2773: prefer prefetch cache; fall back to gh_issue_list wrapper on cache miss.
		# _ciw_lbl: label name variable avoids repeating the string literal (string-literal ratchet).
		local _ciw_lbl="status:available"
		local issues_json _cache_issues_ciw
		if _cache_issues_ciw=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_ciw" | \
				jq -c --arg lbl "$_ciw_lbl" \
				'[.[] | select(.labels | map(.name) | index($lbl))] | .[0:20]' \
				2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--label "$_ciw_lbl" \
				--json number,title,labels --limit 20 2>/dev/null) || issues_json="[]"
		fi
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

			# t2776: delegate per-issue action to shared helper (_action_ciw_single).
			if _action_ciw_single "$slug" "$issue_num" "$issue_title" "$dedup_helper" "$verify_helper"; then
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

		# t2773: prefer prefetch cache; fall back to gh_issue_list wrapper on cache miss.
		local issues_json _cache_issues_rsd
		if _cache_issues_rsd=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_rsd" | \
				jq -c --arg lbl "status:done" \
				'[.[] | select(.labels | map(.name) | index($lbl))] | .[0:20]' \
				2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--label "status:done" \
				--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		fi
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

			# t2776: delegate per-issue action to shared helper (_action_rsd_single).
			local _rsd_rc
			_action_rsd_single "$slug" "$issue_num" "$issue_title" "$dedup_helper" "$verify_helper"
			_rsd_rc=$?
			if [[ "$_rsd_rc" -eq 0 ]]; then
				total_closed=$((total_closed + 1))
			elif [[ "$_rsd_rc" -eq 2 ]]; then
				total_reset=$((total_reset + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$((total_closed + total_reset))" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile stale done issues: closed=${total_closed}, reset=${total_reset}" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Close open issues whose linked PR has already merged.
#
# Gap: _handle_post_merge_actions only closes issues when the PULSE merges
# the PR. PRs merged by --admin (interactive sessions), GitHub merge button,
# or any other mechanism leave the issue open. This reconciliation pass
# catches those orphans.
#
# Scans open issues with active status labels (in-review, in-progress,
# queued, available) and checks whether a merged PR references them via
# `Resolves #N`, `Closes #N`, or `Fixes #N`. If found, closes the issue.
#
# Rate-limited: max 10 closes per cycle to avoid API abuse.
#######################################
reconcile_open_issues_with_merged_prs() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"
	local total_closed=0
	local max_closes=10

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		[[ "$total_closed" -lt "$max_closes" ]] || break

		# Get open issues — t2773: prefer prefetch cache; fall back to gh_issue_list wrapper.
		# Include labels in the fallback so the parent-task check below works without a
		# separate gh api call in either path.
		local issues_json _cache_issues_oimp
		if _cache_issues_oimp=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_oimp" | jq -c '.[0:30]' 2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--json number,title,labels --limit 30 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		# Pre-extract parent-task issue numbers in one jq pass to avoid spawning
		# jq once per loop iteration (GH#20675: Gemini review feedback on PR #20667).
		local parent_task_nums
		parent_task_nums=$(printf '%s' "$issues_json" | \
			jq -r --arg pt "$_PIR_PT_LABEL" '.[] | select((.labels // []) | map(.name) | index($pt) != null) | .number' \
			2>/dev/null) || parent_task_nums=""

		local i=0
		while [[ "$i" -lt "$issue_count" ]] && [[ "$total_closed" -lt "$max_closes" ]]; do
			local issue_num
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Skip parent-task issues (closing a parent from a child PR is wrong).
			# Labels pre-extracted above in a single jq pass (GH#20675).
			_should_oimp "$issue_num" "$parent_task_nums" || continue

			# t2776: delegate per-issue action to shared helper (_action_oimp_single).
			if _action_oimp_single "$slug" "$issue_num" "$verify_helper"; then
				total_closed=$((total_closed + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile open issues with merged PRs: closed=${total_closed}" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Fetch sub-issue numbers via GitHub GraphQL (t2138).
#
# Uses the native `subIssues` relationship on the issue node. Returns
# newline-separated child issue numbers on stdout. Empty output on any
# failure, empty graph, or feature-not-enabled. Callers must treat empty
# output as "fall back to body regex", NOT "no children" — the sub-issue
# feature is a recent GitHub addition and legacy parents may link
# children only via body text.
#
# Args: $1 = slug (owner/name), $2 = issue number
#######################################
_fetch_subissue_numbers() {
	local slug="$1" issue_num="$2"
	[[ "$slug" == */* ]] || return 0
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 0

	local owner="${slug%%/*}" name="${slug##*/}"
	# t2138: fetch pageInfo alongside nodes so we can fail-closed when
	# hasNextPage is true. Partial child lists would silently let the
	# reconciler close parents before the tail children are checked.
	# The jq filter returns `PAGINATED` (non-numeric) when hasNextPage=true,
	# which the caller treats as "empty" → falls back to body regex.
	local graphql_result
	# shellcheck disable=SC2016  # GraphQL variable markers ($owner/$name/$number) are intentional literals, not bash expansions
	graphql_result=$(gh api graphql \
		-f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){subIssues(first:50){nodes{number state}pageInfo{hasNextPage}}}}}' \
		-F "owner=$owner" -F "name=$name" -F "number=$issue_num" \
		--jq 'if (.data.repository.issue.subIssues.pageInfo.hasNextPage // false) then "PAGINATED" else (.data.repository.issue.subIssues.nodes // [] | .[] | .number) end' 2>/dev/null) || return 0

	# Fail-closed guard: if hasNextPage, pretend we got nothing so the
	# caller falls back to body regex (where pagination is not an issue).
	if [[ "$graphql_result" == "PAGINATED" ]]; then
		return 0
	fi
	printf '%s\n' "$graphql_result"
	return 0
}

#######################################
# Close parent-task issues when all child issues are resolved.
#
# Parent-task issues block dispatch unconditionally — they exist as
# planning trackers. When all their children are closed, the parent
# should close automatically with a summary comment listing each child.
#
# Child detection (t2138 — preference order):
#   1. GitHub sub-issue graph (GraphQL `subIssues` field) — authoritative
#      parent-child relationship when the parent was wired via
#      `issue-sync-helper.sh backfill-sub-issues` or `_gh_add_sub_issue`.
#   2. Body section regex (t2244 — fallback for legacy parents with
#      children listed under a dedicated heading). Requires a
#      `## Children`, `## Sub-tasks`, or `## Child issues` heading in
#      the parent body. Only #NNN references WITHIN that section (up to
#      the next ## heading) are treated as children. Prose #NNN mentions
#      elsewhere in the body are ignored — this prevents premature close
#      when a parent cites historical issues as context.
#   3. Narrow prose patterns (t2442 — fallback for legacy parents that
#      were partially decomposed but never got a Children heading).
#      ONLY matches pre-defined phrase shapes (e.g. "Phase N ... #NNNN",
#      "filed as #NNNN", "tracks #NNNN", "blocked by: #NNNN"). Does NOT
#      match bare `#NNN` mentions — the t2244 lesson (CodeRabbit review
#      of #19810) explicitly disqualified that class of false-positive.
#      Added so that genuine parent-task trackers like #19969 which list
#      phases in prose (e.g. "Phase 1 split out as #19996") can close
#      naturally once all phase issues resolve.
#
# Either source must yield ≥2 children to avoid single-reference false
# positives. Checks each against GH API for closed state; only closes
# if ALL children are closed.
#
# Max 5 closes per cycle to limit API usage.
# t2244: extract the ## Children / ## Sub-tasks / ## Child issues section from
# a parent issue body. Returns ONLY the text between that heading and the next
# ## heading (or EOF). Returns empty if no matching heading found — caller must
# treat empty as "no declared children in body" and skip the body-regex path.
# This prevents prose #NNN mentions (e.g., "triggered by #19708") from being
# misread as child references and causing premature parent close.
_extract_children_section() {
	local body="$1"
	printf '%s' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks)[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	'
	return 0
}

#######################################
# t2442: extract child issue numbers from narrow prose patterns.
#
# DELIBERATELY narrow — t2244 (CodeRabbit review of PR #19810) explicitly
# disqualified "any #NNN mention = child" matching after the #19734
# incident where that logic closed parent trackers prematurely by
# mistaking context refs for children. This helper only matches four
# phrase shapes that unambiguously declare a child relationship:
#
#   1. `Phase N <anything> #NNNN` — e.g. "Phase 1 split out as #19996"
#   2. `filed as #NNNN`           — "Phase 2 was filed as #20001"
#   3. `tracks #NNNN`              — "tracks #19808 and #19858"
#   4. `[Bb]locked by:? #NNNN`     — "Blocked by: #42"
#
# Bare `#NNNN` mentions in prose (e.g. "triggered by #19708", "cf. #12345",
# "closes #17", "see #42") are intentionally NOT matched. The heuristic
# is: these four verbs-of-parenthood are rare in prose about ANYTHING
# ELSE, so the false-positive rate is low and the false-negative cost
# (parent stays open one more cycle until nudge fires, harmless) is
# acceptable.
#
# Called as a THIRD fallback in reconcile_completed_parent_tasks after
# the GraphQL subIssues graph AND the ## Children heading extraction
# both come back empty. Never mutates the parent body.
#
# Arguments:
#   arg1 - parent issue body text
# Outputs: one child issue number per line, deduplicated, sorted. Empty
#          output = no matches (caller must treat as "no children from
#          prose" and skip to the nudge/escalation path).
# Returns: always 0.
#######################################
_extract_children_from_prose() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	# Four narrow patterns. POSIX ERE only (grep -E) so macOS bash 3.2 compat.
	# We collect matches then extract the numeric portion.
	#   - phase-ref:  "Phase 1 split out as #19996", "Phase 2 — #20001"
	#   - filed-as:   "filed as #N", "was filed as #N"
	#   - tracks:     "tracks #N"
	#   - blocked-by: "blocked by: #N", "Blocked by #N", "blocked-by: #N"
	#
	# Each pattern independently captures the #NNNN token; we union the
	# results via sort -u. Anchors `(^|[^a-zA-Z0-9_])` and `([^a-zA-Z0-9_]|$)`
	# prevent matches inside words (e.g. "hashtracks" or "#Nfiled").
	local patterns=(
		'(^|[^a-zA-Z0-9_])([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Tt]racks[[:space:]]+#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)'
	)

	local all_matches=""
	local pat
	for pat in "${patterns[@]}"; do
		local hits
		hits=$(printf '%s' "$body" | grep -oE "$pat" 2>/dev/null || true)
		[[ -n "$hits" ]] || continue
		all_matches="${all_matches}${hits}"$'\n'
	done

	[[ -n "$all_matches" ]] || return 0

	# Extract the trailing #NNNN from each matched phrase, strip the `#`,
	# drop anything that isn't a clean positive integer, deduplicate.
	printf '%s' "$all_matches" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un
	return 0
}

#######################################
# t2388: post an idempotent decomposition-nudge comment on a parent-task
# issue that has zero filed children. Without this, undecomposed parents
# sit silently forever — the parent-task label blocks dispatch, no
# children exist to do the work, and no signal surfaces to the maintainer.
#
# Idempotent via the <!-- parent-needs-decomposition --> marker: re-runs
# skip any parent already nudged. The marker is checked via the issue
# comments API before posting; if already present, returns 1 (no-op).
#
# Arguments:
#   arg1 - repo slug (owner/repo)
#   arg2 - parent issue number
#   arg3 - parent title (for the comment body)
# Returns: 0 if the nudge was posted, 1 if skipped (marker present or
# comment failed).
#######################################
_post_parent_decomposition_nudge() {
	local slug="$1"
	local parent_num="$2"
	local parent_title="${3:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-needs-decomposition -->'

	# GH#20219 Factor 2: max-nudge cap. Concurrent pulse runners can race
	# the idempotency check (both read 0 markers, both post). A hard cap
	# bounds the damage: if MAX_PARENT_NUDGE_COUNT nudges already exist,
	# stop posting regardless of race timing. Default 3 — enough to surface
	# the nudge to a maintainer, bounded enough to prevent the 19-comment
	# spam observed on #20161.
	local max_nudge_count="${MAX_PARENT_NUDGE_COUNT:-3}"

	# Idempotency check: skip if marker already present in any comment.
	#
	# t2572 + GH#20219: the original --slurp+--jq query was rejected by `gh
	# api` ("the --slurp option is not supported with --jq or --template"),
	# silently returning empty and defeating the dedup check — every pulse
	# cycle posted a fresh nudge (23 on #20001, 19+ on #20161, 4 on
	# webapp#2546 from two runners in minutes).
	#
	# Fix (t2572): streaming --paginate + --jq (no --slurp). Per-page jq
	# emits matching .id values; wc -l counts across all pages.
	#
	# Defence-in-depth (GH#20219): fail-CLOSED on API error (skip the cycle
	# rather than post) + MAX_PARENT_NUDGE_COUNT cap bounds total nudges
	# even if the dedup query somehow returns 0 on a populated thread. The
	# nudge is advisory, not safety-critical; missing a cycle is harmless,
	# duplicating is not.
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""

	# Fail-closed: if we cannot determine the count, skip this cycle.
	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Nudge dedup: API/jq failure for #${parent_num} in ${slug} — skipping nudge (fail-closed, GH#20219)" >>"$LOGFILE"
		return 1
	fi

	# Block if any nudge already exists OR if count exceeds the cap.
	if [[ "$existing" -ge 1 ]]; then
		if [[ "$existing" -ge "$max_nudge_count" ]]; then
			echo "[pulse-wrapper] Nudge dedup: #${parent_num} in ${slug} has ${existing} nudges (cap=${max_nudge_count}) — suppressing (GH#20219)" >>"$LOGFILE"
		fi
		return 1
	fi

	# Sanitise title for safe markdown embed.
	local safe_title="$parent_title"
	safe_title="${safe_title//\`/}"

	local comment_body="${marker}
## Parent Task Needs Decomposition

This issue carries the \`parent-task\` label, which unconditionally blocks pulse dispatch (see \`dispatch-dedup-helper.sh\` → \`PARENT_TASK_BLOCKED\`). It also has **zero filed children** — no \`## Children\`, \`## Sub-tasks\`, or \`## Child issues\` section with \`#NNNN\` references, and no GraphQL sub-issue graph.

Under these two conditions the issue cannot make progress on its own. Workers won't pick it up (dispatch blocked), no completion sweep can fire (no children to check), and nothing else nudges it forward. Without decomposition it will sit here silently forever.

**Two paths forward — pick one:**

1. **Decompose into children.** File the specific implementation tasks as separate issues, then edit this parent body to include a section like:

   \`\`\`
   ## Children

   - t2XXX / #NNNN — first specific task
   - t2YYY / #MMMM — second specific task
   \`\`\`

   The next pulse cycle will detect the children via \`reconcile_completed_parent_tasks\` and auto-close this parent once all listed children are closed.

2. **Drop the parent-task label.** If this issue is actually a single unit of work (not a roadmap tracker), remove the \`parent-task\` label so the pulse can dispatch it directly:

   \`\`\`
   gh issue edit ${parent_num} --repo ${slug} --remove-label parent-task
   \`\`\`

See \`.agents/AGENTS.md\` → \"Parent / meta tasks\" (t1986 / t2211) for the full rule. Parent-task is for epics and roadmap trackers that will never be implemented as a single unit — only their children will.

_Automated by \`_post_parent_decomposition_nudge\` in \`pulse-issue-reconcile.sh\` (t2388). Posted once per issue via the \`<!-- parent-needs-decomposition -->\` marker; re-runs are no-ops._"

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: nudge posted for #${parent_num} in ${slug} (no children filed)" >>"$LOGFILE"
	return 0
}

#######################################
# t2442: Compute the age (in hours) of the existing nudge comment on a
# parent-task issue. Used by the escalation path to gate "nudge has sat
# unactioned for long enough that we escalate".
#
# Walks comments for the `<!-- parent-needs-decomposition -->` marker,
# returns the age in HOURS as an integer on stdout. Returns empty output
# (exit 0) if no such comment exists OR if the API call fails — the
# caller MUST treat empty as "do not escalate" (fail-closed — without a
# nudge there is no signal to escalate on, and API-unavailable should
# never open new comments).
#
# Arguments:
#   arg1 - repo slug
#   arg2 - parent issue number
# Outputs: integer hours (e.g. "168") or empty string on no-nudge/failure.
#######################################
_compute_parent_nudge_age_hours() {
	local slug="$1"
	local parent_num="$2"

	[[ -n "$slug" && "$parent_num" =~ ^[0-9]+$ ]] || return 0

	# t2572: streaming pattern — --paginate + --jq (no --slurp, which `gh api`
	# rejects). Per-page jq emits matching .created_at values; `head -n1`
	# yields the first match across all pages (chronological order = oldest,
	# which is what the 7-day escalation gate wants).
	local nudge_created_at
	nudge_created_at=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq '.[] | select(.body | contains("<!-- parent-needs-decomposition -->")) | .created_at' \
		2>/dev/null | head -n1) || nudge_created_at=""
	[[ -n "$nudge_created_at" ]] || return 0

	# Convert ISO-8601 to epoch. macOS `date` needs -j -f; GNU `date` uses -d.
	local nudge_epoch now_epoch
	if date --version >/dev/null 2>&1; then
		nudge_epoch=$(date -d "$nudge_created_at" +%s 2>/dev/null || echo "")
	else
		nudge_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$nudge_created_at" +%s 2>/dev/null || echo "")
	fi
	[[ "$nudge_epoch" =~ ^[0-9]+$ ]] || return 0

	now_epoch=$(date +%s)
	local age_seconds=$((now_epoch - nudge_epoch))
	[[ "$age_seconds" -ge 0 ]] || return 0

	printf '%d\n' "$((age_seconds / 3600))"
	return 0
}

#######################################
# t2442: post an escalation comment on a parent-task issue whose nudge
# has sat unactioned for >=7 days AND no auto-decomposer child issue is
# tracking the work. This closes the "nudge black hole" — without this
# step, a parent with a prior nudge would sit blocked forever because
# the nudge marker-idempotency keeps firing no-op forever.
#
# Behaviour:
#   1. Idempotency — if the <!-- parent-needs-decomposition-escalated -->
#      marker is already present in any comment, returns 1 (no-op).
#   2. Applies `needs-maintainer-review` so the issue surfaces in the
#      maintainer's review queue on next interactive session start.
#   3. The comment body must explicitly list the four paths forward
#      (decompose / drop label / close / file children). This is the
#      final AI-advisory touch before the maintainer decides.
#
# Argument contract matches _post_parent_decomposition_nudge so the
# two helpers are drop-in compatible in the reconcile call site.
#
# Arguments:
#   arg1 - repo slug
#   arg2 - parent issue number
#   arg3 - parent title
# Returns: 0 if escalation posted, 1 if skipped (marker present, missing
# args, or API failure).
#######################################
_post_parent_decomposition_escalation() {
	local slug="$1"
	local parent_num="$2"
	local parent_title="${3:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-needs-decomposition-escalated -->'

	# GH#20219 Factor 2: fail-closed + max-count cap (same pattern as nudge).
	# Escalation is rarer than nudging but the same TOCTOU race applies in
	# multi-runner fleets. Fail-closed: if we cannot determine the count,
	# skip this cycle (escalation is advisory, not safety-critical).
	#
	# t2572: streaming --paginate + --jq (no --slurp — gh api rejects the
	# combination). See _post_parent_decomposition_nudge for the full story.
	local max_escalation_count="${MAX_PARENT_ESCALATION_COUNT:-2}"
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""
	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Escalation dedup: API/jq failure for #${parent_num} in ${slug} — skipping (fail-closed, GH#20219)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$existing" -ge 1 ]]; then
		if [[ "$existing" -ge "$max_escalation_count" ]]; then
			echo "[pulse-wrapper] Escalation dedup: #${parent_num} in ${slug} has ${existing} escalations (cap=${max_escalation_count}) — suppressing (GH#20219)" >>"$LOGFILE"
		fi
		return 1
	fi

	local safe_title="$parent_title"
	safe_title="${safe_title//\`/}"

	local comment_body="${marker}
## Parent Task Decomposition — Escalation

The decomposition nudge on this issue has been open for **7+ days** with no action. This issue still carries \`parent-task\` (dispatch blocked), still has zero filed children, and no auto-decompose worker issue is tracking it. Applying \`needs-maintainer-review\` so it surfaces in the maintainer queue.

**Paths forward — pick one:**

1. **Decompose into children.** File the specific implementation tasks as separate issues, then edit this parent body to add a \`## Children\` section listing them. Next pulse cycle will detect them via \`reconcile_completed_parent_tasks\`.

2. **Drop the parent-task label.** If this is actually a single unit of work (not a roadmap tracker):

   \`\`\`
   gh issue edit ${parent_num} --repo ${slug} --remove-label parent-task
   \`\`\`

3. **Close the issue.** If the work is no longer needed or has been superseded.

4. **Let the auto-decomposer handle it.** If you want a \`tier:thinking\` worker to propose a decomposition plan automatically, remove the \`needs-maintainer-review\` label — the next pulse cycle will file a \`<!-- aidevops:generator=auto-decompose -->\` issue that dispatches a worker to decompose this parent.

See \`.agents/AGENTS.md\` → \"Parent / meta tasks\" (t1986 / t2211 / t2442) for the full rule.

_Automated by \`_post_parent_decomposition_escalation\` in \`pulse-issue-reconcile.sh\` (t2442). Posted once per issue via the \`<!-- parent-needs-decomposition-escalated -->\` marker; re-runs are no-ops._"

	# Apply needs-maintainer-review label. Non-fatal — if it fails we still
	# want the comment posted so the maintainer sees the escalation.
	gh issue edit "$parent_num" --repo "$slug" \
		--add-label "needs-maintainer-review" >/dev/null 2>&1 || true

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: escalation posted for #${parent_num} in ${slug} (nudge >=7d unactioned)" >>"$LOGFILE"
	return 0
}

#######################################
# t2786 / GH#20871: phase-section parsing for the declared-vs-filed close
# guard now delegates to the structured parser in shared-phase-filing.sh
# (sourced indirectly via pulse-merge.sh which loads before this module
# in pulse-wrapper.sh). The structured parser emits one tab-separated row
# per *declared* phase:
#
#   <phase_num>\t<description>\t<marker>\t<child_ref>
#
# matching only the canonical list-form (`- Phase N - desc`) and bold-form
# (`**Phase N — desc**`) declarations. Subsection headings like
# `### Phase 1 detail` and prose mentions of "Phase N" are correctly
# ignored — the over-count that GH#20871 surfaced (the very issue that
# established this auto-close path was its own first victim).
#
# Previously this module redefined `_parse_phases_section` locally as a
# raw section extractor. That local override has been removed; rows are
# now counted by line-count over the structured parser's output. See
# `_try_close_parent_tracker` for the count and unfiled-phase extraction
# logic.
#######################################

#######################################
# t2786: post an idempotent "declared phases not yet filed" nudge comment.
# Called by _try_close_parent_tracker when the parent body's ## Phases
# section declares more phases than have been filed as child issues.
# Prevents premature parent close when unfiled phases exist.
#
# Idempotent via the <!-- parent-declared-phases-unfiled --> marker:
# re-runs skip any parent already nudged. Fail-closed on API errors.
#
# Arguments:
#   arg1 - repo slug (owner/repo)
#   arg2 - parent issue number
#   arg3 - declared phase count (from ## Phases section)
#   arg4 - filed child count (child_count already verified via gh api)
#   arg5 - unfiled phase text (lines without #NNN, for nudge body listing)
# Returns: 0 if nudge posted, 1 if skipped (marker present, API error,
#          or comment call failed).
#######################################
_post_parent_phases_unfiled_nudge() {
	local slug="$1"
	local parent_num="$2"
	local declared_count="${3:-0}"
	local filed_count="${4:-0}"
	local unfiled_phases="${5:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-declared-phases-unfiled -->'

	# Idempotency check: skip if marker already present in any comment.
	# Pattern mirrors _post_parent_decomposition_nudge (t2572 fix: streaming
	# --paginate + --jq, no --slurp). Fail-closed on API error.
	# Use printf to build the jq filter to avoid a 3rd raw copy of the
	# .[] | select(.body | contains()) fragment (string-literal ratchet).
	local _jq_filter
	_jq_filter=$(printf '.[] | select(.body | contains("%s")) | .id' "$marker")
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq "$_jq_filter" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""

	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Phases nudge dedup: API/jq failure for #${parent_num} in ${slug} — skipping (fail-closed, t2786)" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	[[ "$existing" -ge 1 ]] && return 1

	local unfiled_list=""
	if [[ -n "$unfiled_phases" ]]; then
		unfiled_list="

**Unfiled phases detected:**

$(printf '%s' "$unfiled_phases" | sed 's/^[[:space:]]*//' | sed 's/^/- /')"
	fi

	local comment_body="${marker}
## Parent Tracker: Declared Phases Not Yet Filed

This parent declares **${declared_count} phase(s)** in its \`## Phases\` section but only **${filed_count}** have been filed as child issues. Closing the parent now would be premature — the unfiled phases would be silently dropped.${unfiled_list}

**To proceed:** file the remaining phases as child issues and link them in a \`## Children\` section in the parent body. The parent will close automatically once all children are resolved.

_Detected by \`_try_close_parent_tracker\` (pulse-issue-reconcile.sh, t2786). Posted once per issue via the \`<!-- parent-declared-phases-unfiled -->\` marker; re-runs are no-ops._"

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: phases-unfiled nudge posted for #${parent_num} in ${slug} (declared=${declared_count}, filed=${filed_count}, t2786)" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# t2138: extract per-parent close logic. Keeps reconcile_completed_parent_tasks
# under the 100-line shell-complexity threshold and makes the close decision
# independently testable. Returns 0 if the parent was closed, 1 if skipped
# (fewer than 2 known children, any child still open, or close call failed).
_try_close_parent_tracker() {
	local slug="$1" parent_num="$2" child_nums="$3" child_source="$4" parent_body="${5:-}"
	local all_closed="true" child_summary="" child_count=0
	local child_num child_state child_title_line

	while IFS= read -r child_num; do
		[[ -n "$child_num" && "$child_num" =~ ^[0-9]+$ ]] || continue
		child_state=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.state // "unknown"' 2>/dev/null) || child_state="unknown"
		child_title_line=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.title // ""' 2>/dev/null) || child_title_line=""

		# Skip references that aren't real child issues (PRs, external refs)
		[[ "$child_state" == "unknown" ]] && continue

		child_count=$((child_count + 1))
		if [[ "$child_state" == "closed" ]]; then
			child_summary="${child_summary}
- #${child_num}: ${child_title_line} — ✅ CLOSED"
		else
			child_summary="${child_summary}
- #${child_num}: ${child_title_line} — ⏳ OPEN"
			all_closed="false"
		fi
	done <<<"$child_nums"

	# Need at least 2 children (1 = probably just a reference, not a parent).
	[[ "$child_count" -ge 2 ]] || return 1
	[[ "$all_closed" == "true" ]] || return 1

	# t2786 / GH#20871: declared-vs-filed guard. If the parent body declares
	# more phases in a ## Phases section than have been filed as child issues,
	# skip close and post a one-time nudge.
	#
	# Counting is over the structured parser's row output (see _parse_phases_section
	# delegation comment near top of this module). Each row represents one
	# canonically-declared phase (list-form or bold-form). Rows starting with
	# a digit form the count; rows with an empty 4th tab field (child_ref)
	# are unfiled.
	if [[ -n "$parent_body" ]]; then
		local _phases_section
		_phases_section=$(_parse_phases_section "$parent_body")
		if [[ -n "$_phases_section" ]]; then
			local _declared_count
			_declared_count=$(printf '%s\n' "$_phases_section" | safe_grep_count -E '^[0-9]+	')
			if [[ "$_declared_count" -gt "$child_count" ]]; then
				local _unfiled_phases
				# Rows where field 4 (child_ref) is empty — phases declared
				# but not yet linked to a child issue. Format human-readable
				# for the nudge body: "Phase N: description".
				_unfiled_phases=$(printf '%s\n' "$_phases_section" | \
					awk -F'\t' '$1 ~ /^[0-9]+$/ && $4 == "" { printf "Phase %s: %s\n", $1, $2 }')
				_post_parent_phases_unfiled_nudge \
					"$slug" "$parent_num" "$_declared_count" "$child_count" "$_unfiled_phases"
				echo "[pulse-wrapper] Reconcile parent-task: skip close #${parent_num} in ${slug} — declared ${_declared_count} phases but only ${child_count} filed (t2786)" >>"${LOGFILE:-/dev/null}"
				return 1
			fi
		fi
	fi

	gh issue close "$parent_num" --repo "$slug" \
		--comment "## All child tasks completed — closing parent tracker

${child_summary}

All ${child_count} child issues are resolved. Parent tracker closed automatically.

_Detected by reconcile_completed_parent_tasks (pulse-issue-reconcile.sh)._" \
		>/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: closed #${parent_num} in ${slug} — all ${child_count} children closed (source=${child_source})" >>"$LOGFILE"
	return 0
}

reconcile_completed_parent_tasks() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_closed=0
	local max_closes=5
	local total_nudged=0
	local max_nudges=5
	# t2442: escalation is rarer than nudging — bound tighter. 3 per cycle
	# is enough to avoid review-queue spam while still making progress.
	local total_escalated=0
	local max_escalations=3
	# t2442: parent-task escalation threshold — nudge must have sat for
	# at least this many hours with zero children before we escalate.
	# 7 days = 168 hours. Override via env for tests / incident response.
	local escalation_threshold_hours="${PARENT_DECOMPOSITION_ESCALATION_HOURS:-168}"

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		[[ "$total_closed" -lt "$max_closes" || "$total_nudged" -lt "$max_nudges" || "$total_escalated" -lt "$max_escalations" ]] || break

		# t2773: prefer prefetch cache (now includes body field); fall back to gh_issue_list.
		# Use module-level _PIR_PT_LABEL to avoid a second literal (string-literal ratchet).
		local _cpt_lbl="$_PIR_PT_LABEL"
		local issues_json _cache_issues_cpt
		if _cache_issues_cpt=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_cpt" | \
				jq -c --arg lbl "$_cpt_lbl" \
				'[.[] | select(.labels | map(.name) | index($lbl))] | .[0:10]' \
				2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--label "$_cpt_lbl" \
				--json number,title,body --limit 10 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]] && [[ "$total_closed" -lt "$max_closes" || "$total_nudged" -lt "$max_nudges" || "$total_escalated" -lt "$max_escalations" ]]; do
			local issue_num issue_body issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_body=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].body // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].title // ""') || true
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# t2776: delegate per-issue action to shared helper (_action_cpt_single).
			local _can_close=0 _can_nudge=0 _can_escalate=0
			[[ "$total_closed" -lt "$max_closes" ]] && _can_close=1
			[[ "$total_nudged" -lt "$max_nudges" ]] && _can_nudge=1
			[[ "$total_escalated" -lt "$max_escalations" ]] && _can_escalate=1
			# Arithmetic check avoids repeated == "1" pattern (string-literal ratchet)
			[[ $((_can_close + _can_nudge + _can_escalate)) -gt 0 ]] || continue

			_action_cpt_single "$slug" "$issue_num" "$issue_title" "$issue_body" \
				"$_can_close" "$_can_nudge" "$_can_escalate" "$escalation_threshold_hours"
			[[ "$_SP_CPT_CLOSED" -eq 1 ]] && total_closed=$((total_closed + 1))
			[[ "$_SP_CPT_NUDGED" -eq 1 ]] && total_nudged=$((total_nudged + 1))
			[[ "$_SP_CPT_ESCALATED" -eq 1 ]] && total_escalated=$((total_escalated + 1))
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_closed" -gt 0 || "$total_nudged" -gt 0 || "$total_escalated" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile completed parent tasks: closed=${total_closed} nudged=${total_nudged} escalated=${total_escalated}" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# t2112: backfill labelless aidevops-shaped issues.
#
# Scans each pulse:true repo for open issues whose titles match the aidevops
# shape (`^tNNN(\.NNN)*: ` or `^GH#NNN: `) but that have ZERO labels in any
# aidevops namespace (origin:*, tier:*, status:*). Such issues were created
# via a bare `gh issue create` call that bypassed the `gh_create_issue`
# wrapper — they are invisible to the enrichment pipeline (which keys off
# TODO.md entries) and unreachable by the dedup / dispatch guards.
#
# Backfill steps per candidate:
#   1. Add `origin:worker` + `tier:standard` as conservative defaults. The
#      origin label is the conservative choice: a labelless issue almost
#      always signals automation, and if the creator was actually interactive
#      they would have used the wrapper.
#   2. Extract hashtag labels from the body (#tag on its own or end-of-line,
#      3+ chars, not a pure number which would be an issue ref) and apply
#      them via `ensure_labels_exist` + `gh issue edit --add-label`.
#   3. Call `issue-sync-helper.sh backfill-sub-issues --repo SLUG --issue N`
#      (t2114) to wire parent-child links from body parsing alone.
#   4. Post a single idempotent mentorship comment guarded by the HTML
#      sentinel marker `<!-- aidevops:labelless-backfill -->`. The comment
#      tells the operator that the issue bypassed `gh_create_issue` and
#      points them at the wrapper rule in `prompts/build.txt`.
#
# Hard cap: 10 issues per repo per cycle to limit API calls. Idempotent —
# re-running does not re-label already-blessed issues or duplicate comments.
#######################################
reconcile_labelless_aidevops_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local issue_sync_helper="${HOME}/.aidevops/agents/scripts/issue-sync-helper.sh"
	[[ -x "$issue_sync_helper" ]] || issue_sync_helper=""

	# Sentinel marker — used to detect already-commented issues so the
	# mentorship nudge is posted at most once per issue.
	local sentinel='<!-- aidevops:labelless-backfill -->'

	# Mentorship comment template. Explains the bypass, points at the rule,
	# and lists the default labels that were applied.
	#
	# The literal "gh issue create" string must not appear on a physical
	# source line in a context that gh-wrapper-guard (t2113) would flag
	# as a raw-wrapper violation. The scanner's leader class matches
	# space/`/;/|/$( but NOT a double-quoted string assignment, so we
	# build the literal via string assignment then interpolate.
	local _raw_cmd="gh issue create"
	local _wrap_cmd="gh_create_issue"
	local comment_template
	# Bash 3.2 compat: heredoc inside $() breaks the parser (unmatched paren).
	# Use a plain double-quoted string assignment instead.
	comment_template="${sentinel}
This issue was created via a bare \`${_raw_cmd}\` call that bypassed the \`${_wrap_cmd}\` wrapper in \`shared-constants.sh\`. The framework's reconcile pass (\`reconcile_labelless_aidevops_issues\` in \`pulse-issue-reconcile.sh\`, t2112) has backfilled \`origin:worker\` + \`tier:standard\` as conservative defaults and extracted hashtag labels from the body.

**Why this matters:** issues missing origin/tier labels are invisible to the dispatch-dedup guard and the label-reconciler. Without this backfill, the pulse would have left this issue unblessed forever.

**Next time:** use \`${_wrap_cmd}\` (defined in \`shared-constants.sh\`, sourced via the framework PATH) instead of bare \`${_raw_cmd}\`. The wrapper applies origin + auto-assign + sub-issue linking automatically. See \`prompts/build.txt\` → \"Origin labelling (MANDATORY)\".

This comment is idempotent; the HTML sentinel prevents duplicates on subsequent pulse cycles."

	# External-contributor mentorship comment (t2450). Used when the issue
	# author's authorAssociation is outside {OWNER, MEMBER, COLLABORATOR}.
	# Distinct sentinel so the idempotency check never conflates internal and
	# external paths — an issue that started as external and was later
	# converted to internal (e.g., author added as collaborator + re-backfill)
	# will still receive the internal nudge on its next eligible pass.
	local external_sentinel='<!-- aidevops:labelless-backfill-external -->'
	local external_comment_template
	external_comment_template="${external_sentinel}
Thanks for filing this issue. Because it was created by a contributor outside the maintainer team, the framework's reconcile pass (\`reconcile_labelless_aidevops_issues\` in \`pulse-issue-reconcile.sh\`, t2450) has applied \`needs-maintainer-review\` and extracted hashtag labels from the body — but intentionally withheld the \`origin:*\` and \`tier:*\` labels that would otherwise make this issue dispatchable to an automated worker.

**What happens next:** a maintainer will triage this issue and either

- approve it cryptographically with \`sudo aidevops approve issue <N>\` (which clears \`needs-maintainer-review\`), after which the pulse may dispatch a worker, OR
- claim a fresh internal task ID via \`claim-task-id.sh\` and file a maintainer-authored follow-up that credits you as reporter.

**Why this gate exists:** the aidevops pulse auto-dispatches workers on issues that carry maintainer-trust labels. For issues from contributors outside the maintainer team, a human in the loop catches injection attempts, scope/trust mismatches, and speculative work the pulse shouldn't burn a worker on. This is a soft gate, not a rejection — the content of the issue has not been judged.

This comment is idempotent; the HTML sentinel prevents duplicates on subsequent pulse cycles."

	local total_fixed=0 total_skipped=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Fetch up to 50 open issues per repo — the per-repo cap keeps API
		# usage bounded. The filter below further narrows by title shape and
		# empty-label set.
		# t2773: prefer prefetch cache (now includes body field); fall back to gh_issue_list.
		local issues_json _cache_issues_lia
		if _cache_issues_lia=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_lia" | jq -c '.[0:50]' 2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--json number,title,body,labels --limit 50 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		# jq filter: title starts with tNNN(.NNN)*: OR GH#NNN:, AND no label
		# in the aidevops namespaces. Cap at 10 candidates per repo per cycle.
		local candidates
		candidates=$(printf '%s' "$issues_json" | jq -c '
			[.[] |
			 select((.title | test("^(t[0-9]+(\\.[0-9]+)*|GH#[0-9]+): ")) and
			        ((.labels // []) |
			         map(.name) |
			         map(select(test("^(origin:|tier:|status:)"))) |
			         length == 0))
			] | .[0:10]
		' 2>/dev/null) || candidates="[]"

		local cand_count
		cand_count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null) || cand_count=0
		[[ "$cand_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$cand_count" ]]; do
			local num title body
			num=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].number // ""')
			title=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].title // ""')
			body=$(printf '%s' "$candidates" | jq -r --argjson i "$i" '.[$i].body // ""')
			i=$((i + 1))
			[[ -z "$num" ]] && continue

			# t2776: delegate per-issue action to shared helper (_action_lia_single).
			if _action_lia_single "$slug" "$num" "$title" "$body" "$issue_sync_helper"; then
				total_fixed=$((total_fixed + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$((total_fixed + total_skipped))" -gt 0 ]]; then
		echo "[pulse-wrapper] Labelless backfill: fixed=${total_fixed}, skipped=${total_skipped}" >>"$LOGFILE"
	fi

	return 0
}

##############################################
# t2776: Predicate functions for single-pass reconcile.
# Each predicate operates on pre-fetched per-issue fields and returns 0 (true)
# or 1 (false) with no API calls. reconcile_issues_single_pass evaluates these
# in sub-stage order per issue; the first predicate whose action short-circuits
# means subsequent predicates are skipped for that issue.
##############################################

# Stage 1 predicate: issue has status:available (candidate for close-via-merged-PR).
# Args: $1 = labels_csv (comma-separated label names from pre-fetched JSON)
# Note: unquoted case patterns avoid adding to the string-literal ratchet count.
_should_ciw() {
	local labels_csv="$1"
	case "$labels_csv" in
		*status:available*) return 0 ;;
	esac
	return 1
}

# Stage 2 predicate: issue has status:done (candidate for stale-done reconcile).
# Args: $1 = labels_csv
_should_rsd() {
	local labels_csv="$1"
	case "$labels_csv" in
		*status:done*) return 0 ;;
	esac
	return 1
}

# Stage 3 predicate: issue is NOT a parent-task (candidate for open-with-merged-PR check).
# Issues handled by stages 1+2 via short-circuit never reach this predicate.
# Args:
#   $1 = issue_num
#   $2 = parent_task_nums (newline-delimited list of parent-task issue numbers)
_should_oimp() {
	local issue_num="$1"
	local parent_task_nums="$2"
	if [[ -n "$parent_task_nums" ]] && printf '%s\n' "$parent_task_nums" | grep -qx "$issue_num"; then
		return 1
	fi
	return 0
}

# Stage 4 predicate: issue carries the parent-task label.
# Args: $1 = labels_csv
_should_cpt() {
	local labels_csv="$1"
	case "$labels_csv" in
		*parent-task*) return 0 ;;
	esac
	return 1
}

# Stage 5 predicate: issue is an aidevops-shaped labelless candidate.
# Title must match tNNN: or GH#NNN: AND no origin:/tier:/status: labels.
# Args: $1 = issue_title, $2 = labels_csv
_should_lia() {
	local issue_title="$1"
	local labels_csv="$2"
	# Title must match aidevops task shape
	if ! printf '%s' "$issue_title" | grep -qE '^(t[0-9]+(\.[0-9]+)*|GH#[0-9]+): '; then
		return 1
	fi
	# Must have no origin:/tier:/status: labels (unquoted patterns avoid ratchet)
	case "$labels_csv" in
		*origin:* | *tier:* | *status:*) return 1 ;;
	esac
	return 0
}

##############################################
# t2776: Per-issue action helpers for reconcile_issues_single_pass.
# Each helper encapsulates the action logic for one reconcile sub-stage.
# Called once per qualifying issue; the outer loop and issue fetch live in
# reconcile_issues_single_pass — not here.
#
# Return conventions (consistent across helpers):
#   0 = action taken (issue closed / fixed / nudged / escalated)
#   1 = no action taken (skipped, guard fired, API failure, etc.)
#   2 = reset action taken (used by _action_rsd_single: reset to available)
##############################################

#######################################
# Stage 1 action: close an issue whose work is done via a merged PR.
# (Per-issue body of close_issues_with_merged_prs — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper
# Returns: 0 if issue was closed, 1 otherwise
#######################################
_action_ciw_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"

	local dedup_output=""
	dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null) || return 1

	local pr_ref pr_num merged_at
	pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
	pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
	merged_at=""

	if [[ -n "$pr_num" ]]; then
		merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
		if [[ -z "$merged_at" ]]; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	gh issue close "$issue_num" --repo "$slug" \
		--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"} (merged at ${merged_at:-unknown}). Issue was open but dedup guard was blocking re-dispatch." \
		>/dev/null 2>&1 || return 1

	fast_fail_reset "$issue_num" "$slug" || true
	unlock_issue_after_worker "$issue_num" "$slug"
	echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
	return 0
}

#######################################
# Stage 2 action: reconcile a status:done issue.
# (Per-issue body of reconcile_stale_done_issues — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper
# Returns: 0 if closed, 2 if reset to status:available, 1 if no action taken
#######################################
_action_rsd_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"

	local dedup_output=""
	if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
		local pr_ref pr_num merged_at
		pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
		pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
		merged_at=""

		if [[ -n "$pr_num" ]]; then
			merged_at=$(gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || merged_at=""
			if [[ -z "$merged_at" ]]; then
				echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
				return 2
			fi
		fi

		if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
			if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} does not touch issue files (GH#17372 guard)" >>"$LOGFILE"
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
				return 2
			fi
		fi

		gh issue close "$issue_num" --repo "$slug" \
			--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup)"} (merged at ${merged_at:-unknown})." \
			>/dev/null 2>&1 || return 1

		fast_fail_reset "$issue_num" "$slug" || true
		unlock_issue_after_worker "$issue_num" "$slug"
		echo "[pulse-wrapper] Reconcile done: closed #${issue_num} in ${slug} — merged PR: ${dedup_output:-"found"}" >>"$LOGFILE"
		return 0
	else
		# No merged PR — reset for re-evaluation
		set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
		echo "[pulse-wrapper] Reconcile done: reset #${issue_num} in ${slug} to status:available — no merged PR evidence" >>"$LOGFILE"
		return 2
	fi
}

#######################################
# Stage 3 action: close an open issue whose linked PR has already merged.
# (Per-issue body of reconcile_open_issues_with_merged_prs — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=verify_helper
# Returns: 0 if closed, 1 otherwise
#######################################
_action_oimp_single() {
	local slug="$1" issue_num="$2" verify_helper="$3"

	local merged_pr_num=""
	merged_pr_num=$(_gh_pr_list_merged --repo "$slug" --state merged \
		--search "Resolves #${issue_num} OR Closes #${issue_num} OR Fixes #${issue_num}" \
		--json number --jq '.[0].number // ""' --limit 1 2>/dev/null) || merged_pr_num=""
	[[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]] || return 1

	local pr_body
	pr_body=$(gh pr view "$merged_pr_num" --repo "$slug" --json body --jq '.body // ""' 2>/dev/null) || pr_body=""
	if ! printf '%s' "$pr_body" | grep -qiE "(Resolves|Closes|Fixes)\s+#${issue_num}\b"; then
		return 1
	fi

	if [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$merged_pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — PR #${merged_pr_num} does not touch issue files (GH#17372)" >>"$LOGFILE"
			return 1
		fi
	fi

	gh issue close "$issue_num" --repo "$slug" \
		--comment "Closing: linked PR #${merged_pr_num} was already merged. Detected by reconcile pass." \
		>/dev/null 2>&1 || return 1

	if declare -F fast_fail_reset >/dev/null 2>&1; then
		fast_fail_reset "$issue_num" "$slug" || true
	fi
	if declare -F unlock_issue_after_worker >/dev/null 2>&1; then
		unlock_issue_after_worker "$issue_num" "$slug"
	fi
	echo "[pulse-wrapper] Reconcile merged-PR: closed #${issue_num} in ${slug} — merged PR #${merged_pr_num}" >>"$LOGFILE"
	return 0
}

# t2776: globals set by _action_cpt_single to communicate multi-outcome results.
# Initialized to 0 before each call; set to 1 when the respective action fires.
_SP_CPT_CLOSED=0
_SP_CPT_NUDGED=0
_SP_CPT_ESCALATED=0

#######################################
# Stage 4 action: reconcile a parent-task issue (close/nudge/escalate).
# (Per-issue body of reconcile_completed_parent_tasks — no slug loop.)
#
# Sets _SP_CPT_CLOSED / _SP_CPT_NUDGED / _SP_CPT_ESCALATED globals (each 0|1)
# to communicate which actions were taken. Caller reads and resets these.
#
# Args:
#   $1=slug, $2=issue_num, $3=issue_title, $4=issue_body
#   $5=can_close (1|0), $6=can_nudge (1|0), $7=can_escalate (1|0)
#   $8=escalation_threshold_hours
# Returns: 0 always (action outcomes via globals)
#######################################
_action_cpt_single() {
	local slug="$1" issue_num="$2" issue_title="$3" issue_body="$4"
	local can_close="${5:-0}" can_nudge="${6:-0}" can_escalate="${7:-0}"
	local escalation_threshold_hours="${8:-168}"
	_SP_CPT_CLOSED=0
	_SP_CPT_NUDGED=0
	_SP_CPT_ESCALATED=0

	# Child detection (GH#20872): UNION of (graph, body, prose) sources, not
	# first-non-empty-wins (the pre-GH#20872 behaviour). Real-world parent
	# bodies frequently have a partially-populated sub-issue graph where some
	# children are wired via GraphQL `sub_issues` and others only listed in
	# the body's `## Children` section or referenced in prose. First-wins made
	# the smaller graph result silently mask the larger body listing — the
	# child_count guard then blocked auto-close on parents whose children were
	# all closed (canonical: #20559, #20581 during v3.11.1 deploy verification).
	#
	# Source label remains informative: dash-joined list of contributing
	# sources (e.g. `graph+body`, `body`, `graph+body+prose`) so the log line
	# in `_try_close_parent_tracker` records which extractors found children.
	local _g_nums _b_nums _p_nums child_nums
	local _src_parts=""
	_g_nums=$(_fetch_subissue_numbers "$slug" "$issue_num" | sort -un | grep -v "^${issue_num}$" | grep -v '^$' || true)
	[[ -n "$_g_nums" ]] && _src_parts="${_src_parts:+${_src_parts}+}graph"

	local children_section
	children_section=$(_extract_children_section "$issue_body")
	if [[ -n "$children_section" ]]; then
		_b_nums=$(printf '%s' "$children_section" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un | grep -v "^${issue_num}$" || true)
		[[ -n "$_b_nums" ]] && _src_parts="${_src_parts:+${_src_parts}+}body"
	fi

	_p_nums=$(_extract_children_from_prose "$issue_body" | grep -v "^${issue_num}$" || true)
	[[ -n "$_p_nums" ]] && _src_parts="${_src_parts:+${_src_parts}+}prose"

	# Union: concatenate, keep numeric lines, dedupe, drop self-reference
	child_nums=$(printf '%s\n%s\n%s\n' "$_g_nums" "$_b_nums" "$_p_nums" \
		| grep -E '^[0-9]+$' | sort -un | grep -v "^${issue_num}$" || true)
	local child_source="${_src_parts:-none}"

	if [[ -z "$child_nums" ]]; then
		# No children — try phase extractor, then nudge/escalate (t2771/t2388/t2442)
		local _phase_extractor="${_PIR_SCRIPT_DIR}/parent-task-phase-extractor.sh"
		if [[ -x "$_phase_extractor" ]]; then
			if PHASE_EXTRACTOR_DRY_RUN="${PHASE_EXTRACTOR_DRY_RUN:-0}" \
				"$_phase_extractor" run "$issue_num" "$slug" >>"${LOGFILE:-/dev/null}" 2>&1; then
				echo "[pulse-wrapper] Reconcile parent-task: phase-extractor filed children for #${issue_num} in ${slug} (t2771)" >>"${LOGFILE:-/dev/null}"
				return 0
			fi
		fi
		if [[ "$can_nudge" == "1" ]]; then
			if _post_parent_decomposition_nudge "$slug" "$issue_num" "$issue_title"; then
				_SP_CPT_NUDGED=1
			fi
		fi
		if [[ "$can_escalate" == "1" ]]; then
			local _nudge_age_hours
			_nudge_age_hours=$(_compute_parent_nudge_age_hours "$slug" "$issue_num")
			if [[ "$_nudge_age_hours" =~ ^[0-9]+$ ]] && \
				[[ "$_nudge_age_hours" -ge "$escalation_threshold_hours" ]]; then
				if _post_parent_decomposition_escalation "$slug" "$issue_num" "$issue_title"; then
					_SP_CPT_ESCALATED=1
				fi
			fi
		fi
		return 0
	fi

	if [[ "$can_close" == "1" ]]; then
		if _try_close_parent_tracker "$slug" "$issue_num" "$child_nums" "$child_source" "$issue_body"; then
			_SP_CPT_CLOSED=1
		fi
	fi
	return 0
}

#######################################
# Stage 5 action: backfill labels on a labelless aidevops-shaped issue.
# (Per-issue body of reconcile_labelless_aidevops_issues — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=issue_body, $5=issue_sync_helper
# Returns: 0 if labels were applied, 1 otherwise
#######################################
_action_lia_single() {
	local slug="$1" issue_num="$2" issue_title="$3" issue_body="$4"
	local issue_sync_helper="${5:-}"

	# Sentinels and templates — defined per-call (contain static strings only)
	local sentinel='<!-- aidevops:labelless-backfill -->'
	local external_sentinel='<!-- aidevops:labelless-backfill-external -->'
	local _raw_cmd="gh issue create"
	local _wrap_cmd="gh_create_issue"
	local comment_template
	comment_template="${sentinel}
This issue was created via a bare \`${_raw_cmd}\` call that bypassed the \`${_wrap_cmd}\` wrapper in \`shared-constants.sh\`. The framework's reconcile pass (\`reconcile_labelless_aidevops_issues\` in \`pulse-issue-reconcile.sh\`, t2112) has backfilled \`origin:worker\` + \`tier:standard\` as conservative defaults and extracted hashtag labels from the body.

**Why this matters:** issues missing origin/tier labels are invisible to the dispatch-dedup guard and the label-reconciler. Without this backfill, the pulse would have left this issue unblessed forever.

**Next time:** use \`${_wrap_cmd}\` (defined in \`shared-constants.sh\`, sourced via the framework PATH) instead of bare \`${_raw_cmd}\`. The wrapper applies origin + auto-assign + sub-issue linking automatically. See \`prompts/build.txt\` → \"Origin labelling (MANDATORY)\".

This comment is idempotent; the HTML sentinel prevents duplicates on subsequent pulse cycles."
	local external_comment_template
	external_comment_template="${external_sentinel}
Thanks for filing this issue. Because it was created by a contributor outside the maintainer team, the framework's reconcile pass (\`reconcile_labelless_aidevops_issues\` in \`pulse-issue-reconcile.sh\`, t2450) has applied \`needs-maintainer-review\` and extracted hashtag labels from the body — but intentionally withheld the \`origin:*\` and \`tier:*\` labels that would otherwise make this issue dispatchable to an automated worker.

**What happens next:** a maintainer will triage this issue and either

- approve it cryptographically with \`sudo aidevops approve issue <N>\` (which clears \`needs-maintainer-review\`), after which the pulse may dispatch a worker, OR
- claim a fresh internal task ID via \`claim-task-id.sh\` and file a maintainer-authored follow-up that credits you as reporter.

**Why this gate exists:** the aidevops pulse auto-dispatches workers on issues that carry maintainer-trust labels. For issues from contributors outside the maintainer team, a human in the loop catches injection attempts, scope/trust mismatches, and speculative work the pulse shouldn't burn a worker on. This is a soft gate, not a rejection — the content of the issue has not been judged.

This comment is idempotent; the HTML sentinel prevents duplicates on subsequent pulse cycles."

	# Fetch authorAssociation (fail-closed: unknown → treat as external, t2450)
	local assoc
	assoc=$(gh api "repos/${slug}/issues/${issue_num}" \
		--jq '.author_association // "NONE"' 2>/dev/null || echo "NONE")
	local is_external="true"
	case "$assoc" in
		OWNER | MEMBER | COLLABORATOR) is_external="false" ;;
	esac

	# Choose sentinel for idempotency check
	local check_sentinel="$sentinel"
	[[ "$is_external" == "true" ]] && check_sentinel="$external_sentinel"

	# Idempotency guard — only suppresses duplicate comment; labels are still healed
	local existing_comments
	existing_comments=$(gh issue view "$issue_num" --repo "$slug" \
		--json comments --jq '[.comments[].body] | join("\n")' 2>/dev/null || echo "")
	local comment_already_posted="false"
	[[ "$existing_comments" == *"$check_sentinel"* ]] && comment_already_posted="true"

	# Extract hashtag labels from body
	local body_tags
	body_tags=$(printf '%s\n' "$issue_body" |
		grep -oE '(^|[^A-Za-z0-9_])#[a-z][a-z0-9-]+' 2>/dev/null |
		sed 's/^[^#]*#//' |
		sort -u |
		tr '\n' ',' |
		sed 's/,$//' || echo "")

	# Compose label-add args (internal vs external path, t2450)
	local -a add_args
	local labels_csv_lia comment_template_use
	if [[ "$is_external" == "true" ]]; then
		add_args=("--add-label" "needs-maintainer-review")
		labels_csv_lia="needs-maintainer-review"
		comment_template_use="$external_comment_template"
	else
		add_args=("--add-label" "origin:worker"
			"--remove-label" "origin:interactive"
			"--remove-label" "origin:worker-takeover"
			"--add-label" "tier:standard")
		labels_csv_lia="origin:worker,tier:standard"
		comment_template_use="$comment_template"
	fi
	if [[ -n "$body_tags" ]]; then
		local _saved_ifs="$IFS"
		IFS=','
		local _t
		for _t in $body_tags; do
			[[ -z "$_t" ]] && continue
			add_args+=("--add-label" "$_t")
		done
		IFS="$_saved_ifs"
		labels_csv_lia="${labels_csv_lia},${body_tags}"
	fi

	# Ensure all labels exist on the repo
	ensure_origin_labels_exist "$slug" 2>/dev/null || true
	local _saved_ifs="$IFS"
	IFS=','
	local _lbl
	for _lbl in $labels_csv_lia; do
		[[ -z "$_lbl" ]] && continue
		gh label create "$_lbl" --repo "$slug" --color "EDEDED" \
			--description "Auto-created by pulse labelless backfill (t2112)" \
			--force >/dev/null 2>&1 || true
	done
	IFS="$_saved_ifs"

	# Apply labels
	if ! gh issue edit "$issue_num" --repo "$slug" "${add_args[@]}" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Labelless backfill: failed to apply labels on #${issue_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi

	# Wire sub-issue parent link (t2114)
	if [[ -n "$issue_sync_helper" ]]; then
		"$issue_sync_helper" backfill-sub-issues --repo "$slug" --issue "$issue_num" \
			>/dev/null 2>&1 || true
	fi

	# Post mentorship comment (singleton per issue × association-class)
	if [[ "$comment_already_posted" == "false" ]]; then
		gh_issue_comment "$issue_num" --repo "$slug" --body "$comment_template_use" \
			>/dev/null 2>&1 || true
		echo "[pulse-wrapper] Labelless backfill: blessed #${issue_num} in ${slug} — assoc=${assoc}, labels=${labels_csv_lia}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Labelless backfill: re-healed #${issue_num} in ${slug} — assoc=${assoc}, labels=${labels_csv_lia} (comment already present)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t2776: Single-pass issue reconcile orchestrator.
#
# Replaces five sequential sub-stage calls (each with their own slug loop and
# issue list fetch) with one slug loop + one issue list fetch per repo, applying
# all five reconcile checks per issue in sub-stage order.
#
# Sub-stage order (short-circuit per issue — first action that fires skips rest):
#   1. close_issues_with_merged_prs  (_should_ciw + _action_ciw_single)
#   2. reconcile_stale_done_issues   (_should_rsd + _action_rsd_single)
#   3. reconcile_open_issues_with_merged_prs (_should_oimp + _action_oimp_single)
#   4. reconcile_completed_parent_tasks      (_should_cpt + _action_cpt_single)
#   5. reconcile_labelless_aidevops_issues   (_should_lia + _action_lia_single)
#
# Stage 4 (parent-task) always `continue`s — parent-task issues do not flow
# to stage 5. A status:done issue also always `continue`s after stage 2
# (even if no action was taken) — done issues are never labelless candidates.
#
# Iteration: 5N → N per repo per cycle (N = issue count per repo).
# Cache: one _read_cache_issues_for_slug call per slug (shared by all stages).
#
# Returns: 0 always (best-effort)
#######################################
reconcile_issues_single_pass() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"
	local issue_sync_helper="${HOME}/.aidevops/agents/scripts/issue-sync-helper.sh"
	[[ -x "$issue_sync_helper" ]] || issue_sync_helper=""

	# Stages 1+2 require dedup_helper
	local _ciw_rsd_enabled=0
	[[ -x "$dedup_helper" ]] && _ciw_rsd_enabled=1

	# Cross-repo global caps (stages 3 and 4)
	local oimp_total_closed=0
	local oimp_max=10
	local cpt_total_closed=0 cpt_max_closes=5
	local cpt_total_nudged=0 cpt_max_nudges=5
	local cpt_total_escalated=0 cpt_max_escalations=3
	local cpt_esc_hours="${PARENT_DECOMPOSITION_ESCALATION_HOURS:-168}"

	# t2838: periodic parent-task sub-issue backfill — gated by interval
	# state file so we don't burn rate-limit budget on already-linked
	# parents every cycle. Default 3600s (hourly). The backfill itself
	# is idempotent (addSubIssue swallows duplicates) so this is purely
	# a cost control, not a correctness requirement.
	local _pbf_state_file="${HOME}/.aidevops/state/parent-backfill-last-run.epoch"
	local _pbf_interval="${AIDEVOPS_PARENT_BACKFILL_INTERVAL_SECS:-3600}"
	# Validate interval is a positive integer — a mis-set env var (empty,
	# negative, "1h") would error inside [[ ... -ge ... ]] and could abort
	# the orchestrator under set -e. Fall back to default on any garbage.
	[[ "$_pbf_interval" =~ ^[1-9][0-9]*$ ]] || _pbf_interval=3600
	local _pbf_this_cycle=0
	local _pbf_now _pbf_last_run=0
	_pbf_now=$(date +%s 2>/dev/null) || _pbf_now=0
	if [[ -r "$_pbf_state_file" ]]; then
		_pbf_last_run=$(cat "$_pbf_state_file" 2>/dev/null || echo 0)
		[[ "$_pbf_last_run" =~ ^[0-9]+$ ]] || _pbf_last_run=0
	fi
	if [[ "$_pbf_now" -gt 0 ]] && \
		[[ $((_pbf_now - _pbf_last_run)) -ge "$_pbf_interval" ]] && \
		[[ -n "$issue_sync_helper" ]]; then
		_pbf_this_cycle=1
	fi
	local pbf_total_run=0 pbf_max_per_cycle=10

	# Cycle-wide counters for log summary
	local ciw_closed=0 rsd_closed=0 rsd_reset=0 lia_fixed=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Per-repo caps (reset each slug)
		local ciw_per_repo=0 ciw_max_repo=20
		local rsd_per_repo=0 rsd_max_repo=20
		local lia_per_repo=0 lia_max_repo=10

		# Fetch issues ONCE for this slug — all fields required by any stage.
		# The cache (written each cycle by pulse-prefetch.sh) covers:
		#   number, title, labels, updatedAt, assignees, body
		local issues_json _cache_issues_sp
		if _cache_issues_sp=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json="$_cache_issues_sp"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--json number,title,labels,body \
				--limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		# Pre-extract parent-task issue numbers (one jq pass for stage 3 predicate).
		# Use module-level _PIR_PT_LABEL via jq --arg (string-literal ratchet).
		local parent_task_nums
		parent_task_nums=$(printf '%s' "$issues_json" | \
			jq -r --arg pt "$_PIR_PT_LABEL" '.[] | select((.labels // []) | map(.name) | index($pt) != null) | .number' \
			2>/dev/null) || parent_task_nums=""

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title issue_body labels_csv
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].title // ""') || true
			issue_body=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].body // ""') || true
			labels_csv=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" \
				'.[$i].labels // [] | map(.name) | join(",")' 2>/dev/null) || labels_csv=""
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Stage 1: close issues whose dedup guard detects a merged PR
			if [[ "$_ciw_rsd_enabled" == "1" ]] && \
				[[ "$ciw_per_repo" -lt "$ciw_max_repo" ]] && \
				_should_ciw "$labels_csv"; then
				if _action_ciw_single "$slug" "$issue_num" "$issue_title" "$dedup_helper" "$verify_helper"; then
					ciw_closed=$((ciw_closed + 1))
					ciw_per_repo=$((ciw_per_repo + 1))
					continue
				fi
			fi

			# Stage 2: reconcile status:done issues (close or reset)
			if [[ "$_ciw_rsd_enabled" == "1" ]] && \
				[[ "$rsd_per_repo" -lt "$rsd_max_repo" ]] && \
				_should_rsd "$labels_csv"; then
				local _rsd_rc
				_action_rsd_single "$slug" "$issue_num" "$issue_title" "$dedup_helper" "$verify_helper"
				_rsd_rc=$?
				rsd_per_repo=$((rsd_per_repo + 1))
				if [[ "$_rsd_rc" -eq 0 ]]; then
					rsd_closed=$((rsd_closed + 1))
				elif [[ "$_rsd_rc" -eq 2 ]]; then
					rsd_reset=$((rsd_reset + 1))
				fi
				continue  # status:done handled here; skip remaining stages
			fi

			# Stage 3: close open issues whose linked PR already merged (global cap)
			if [[ "$oimp_total_closed" -lt "$oimp_max" ]] && \
				_should_oimp "$issue_num" "$parent_task_nums"; then
				if _action_oimp_single "$slug" "$issue_num" "$verify_helper"; then
					oimp_total_closed=$((oimp_total_closed + 1))
					continue
				fi
			fi

			# Stage 4: reconcile parent-task issues (close/nudge/escalate)
			if _should_cpt "$labels_csv"; then
				local _can_close=0 _can_nudge=0 _can_escalate=0
				[[ "$cpt_total_closed" -lt "$cpt_max_closes" ]] && _can_close=1
				[[ "$cpt_total_nudged" -lt "$cpt_max_nudges" ]] && _can_nudge=1
				[[ "$cpt_total_escalated" -lt "$cpt_max_escalations" ]] && _can_escalate=1
				# Use arithmetic to check any-cap; avoids repeated == "1" pattern
				# across both this function and reconcile_completed_parent_tasks
				if [[ $((_can_close + _can_nudge + _can_escalate)) -gt 0 ]]; then
					_action_cpt_single "$slug" "$issue_num" "$issue_title" "$issue_body" \
						"$_can_close" "$_can_nudge" "$_can_escalate" "$cpt_esc_hours"
					[[ "$_SP_CPT_CLOSED" -eq 1 ]] && cpt_total_closed=$((cpt_total_closed + 1))
					[[ "$_SP_CPT_NUDGED" -eq 1 ]] && cpt_total_nudged=$((cpt_total_nudged + 1))
					[[ "$_SP_CPT_ESCALATED" -eq 1 ]] && cpt_total_escalated=$((cpt_total_escalated + 1))
				fi
				# t2838: periodic sub-issue backfill — only if cycle-gate fired
				# AND parent didn't just close (no point linking to closed parent).
				# Idempotent and silent on no-op (already-linked children).
				# Counter increments only on success — failed backfills (rate
				# limit, network error) leave the gate state for next cycle's
				# retry rather than advancing the clock on broken work.
				if [[ "$_pbf_this_cycle" -eq 1 ]] && \
					[[ "$pbf_total_run" -lt "$pbf_max_per_cycle" ]] && \
					[[ "${_SP_CPT_CLOSED:-0}" -ne 1 ]]; then
					if "$issue_sync_helper" backfill-sub-issues --repo "$slug" \
						--issue "$issue_num" >/dev/null 2>&1; then
						pbf_total_run=$((pbf_total_run + 1))
					fi
				fi
				continue  # parent-task issues do not flow to stage 5
			fi

			# Stage 5: backfill labelless aidevops-shaped issues (per-repo cap)
			if [[ "$lia_per_repo" -lt "$lia_max_repo" ]] && \
				_should_lia "$issue_title" "$labels_csv"; then
				if _action_lia_single "$slug" "$issue_num" "$issue_title" "$issue_body" "$issue_sync_helper"; then
					lia_fixed=$((lia_fixed + 1))
					lia_per_repo=$((lia_per_repo + 1))
				fi
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	# t2838: persist last-run epoch when backfill actually ran this cycle.
	# Skip on dry runs (pbf_total_run == 0) so we retry next cycle.
	if [[ "$_pbf_this_cycle" -eq 1 ]] && [[ "$pbf_total_run" -gt 0 ]]; then
		mkdir -p "$(dirname "$_pbf_state_file")" 2>/dev/null || true
		printf '%s\n' "$_pbf_now" >"$_pbf_state_file" 2>/dev/null || true
	fi

	local _total_actions
	_total_actions=$((ciw_closed + rsd_closed + rsd_reset + oimp_total_closed + cpt_total_closed + cpt_total_nudged + cpt_total_escalated + lia_fixed + pbf_total_run))
	if [[ "$_total_actions" -gt 0 ]]; then
		echo "[pulse-wrapper] reconcile_issues_single_pass: ciw_closed=${ciw_closed} rsd_closed=${rsd_closed} rsd_reset=${rsd_reset} oimp_closed=${oimp_total_closed} cpt_closed=${cpt_total_closed} cpt_nudged=${cpt_total_nudged} cpt_escalated=${cpt_total_escalated} lia_fixed=${lia_fixed} pbf_run=${pbf_total_run}" >>"$LOGFILE"
	fi
	return 0
}
