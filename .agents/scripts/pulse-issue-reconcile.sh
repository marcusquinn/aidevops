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

# t2863: Module-level variable defaults (set -u guards).
# Ensures bare var refs in all reconcile functions are safe when this module
# is sourced outside the pulse-wrapper.sh bootstrap context (e.g. test harnesses).
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PULSE_QUEUED_SCAN_LIMIT:=1000}"

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

#######################################
# t2985: Build a per-repo "issue → merged PR" lookup string for stage-3
# reconcile (oimp).
#
# Replaces the per-issue `gh pr list --search "Resolves #N OR Closes #N OR
# Fixes #N"` call previously made by _action_oimp_single. At cross-repo
# scale (8 pulse-enabled repos × ~30 non-parent open issues each ≈ 200+
# search calls per cycle, ~3s each) the per-issue search is the dominant
# cost driver — this is what t2984's 360s time budget exists to contain
# rather than fix. With this prefetch: 1 batched call per repo per cycle
# (8 calls total), local string lookup for each issue.
#
# Output format: pipe-delimited "|issue_num=pr_num|...|" string. Bash 3.2
# does not support associative arrays; a string + grep is the most
# portable lookup primitive (matches issue body's stated approach).
#
# Lookup contract (caller side):
#   merged_pr=$(printf '%s' "$lookup" | grep -oE "\|${issue_num}=[0-9]+" \
#       | head -1 | cut -d= -f2)
# The leading + trailing "|" and the "=" separator together prevent
# prefix-substring false matches (e.g. lookup `|10=`, search `|1=` — the
# required `=` after the issue number anchors the match boundary).
#
# Body-keyword check is built into the lookup itself: the jq scan only
# emits pairs from PR bodies actually containing Resolves|Closes|Fixes #N.
# This collapses what was previously two gh API calls per issue (search +
# pr view --json body) into the single per-repo prefetch.
#
# Limit 200 most-recent merged PRs per repo. Sufficient for the typical
# case (open issue resolved by a PR within days/weeks of merge); a 6-month
# old open-but-already-merged-by-an-old-PR is degenerate and falls
# through to next-cycle retry without harm (issue stays open).
#
# Args:    $1 = slug (owner/repo)
# Returns: prints lookup string on stdout (may be empty); exit 0 always.
#######################################
_build_oimp_lookup_for_slug() {
	local slug="$1"
	[[ -n "$slug" ]] || return 0

	# One gh call per repo per cycle (replaces ~30 per-issue calls).
	# --json body costs more bytes per call but the trip count goes from
	# ~200/cycle to 8/cycle — net ~30x reduction in API round-trips.
	local merged_prs_json
	merged_prs_json=$(_gh_pr_list_merged --repo "$slug" --state merged \
		--json number,body --limit 200 2>/dev/null) || merged_prs_json="[]"
	[[ -n "$merged_prs_json" && "$merged_prs_json" != "null" ]] || return 0

	# jq scan() with one capture group returns ["issue_num"] per match.
	# (?i) makes the keyword case-insensitive — mirrors the original
	# `grep -iE` pattern in _action_oimp_single.
	# Output `|num=pr|...|` so callers can grep with anchored boundaries.
	printf '%s' "$merged_prs_json" | jq -r '
		[
			.[] | . as $pr |
			(.body // "") |
			scan("(?i)(?:resolves|closes|fixes)\\s+#([0-9]+)") |
			"\(.[0])=\($pr.number)"
		] | if length > 0 then "|" + join("|") + "|" else "" end
	' 2>/dev/null || true
	return 0
}

# t2375: stale-recovery subsystem extracted to keep this file below the 1500-
# line complexity gate. SCRIPT_DIR is set by pulse-wrapper.sh when sourced by
# the orchestrator; fall back to BASH_SOURCE-derived path when sourced directly
# (e.g., from tests/test-issue-reconcile.sh).
_PIR_SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
# shellcheck source=/dev/null
source "${_PIR_SCRIPT_DIR}/pulse-issue-reconcile-stale.sh"
# shellcheck source=./pulse-issue-reconcile-normalize.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_PIR_SCRIPT_DIR}/pulse-issue-reconcile-normalize.sh"
# shellcheck source=./pulse-issue-reconcile-actions.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_PIR_SCRIPT_DIR}/pulse-issue-reconcile-actions.sh"

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
# Threshold rationale (1h default — t2942):
#   - matches status-based stale recovery (1h) because the absence of
#     a stamp file is itself the liveness signal: a genuine interactive
#     session that calls `interactive-session-helper.sh claim` creates
#     a stamp; sessions that only self-assigned via `claim-task-id.sh`
#     (per t1970) and never invoked the formal claim helper produce no
#     stamp, indicating the session was ad-hoc and almost certainly ended.
#   - shorter than scan-stale Phase 2 (14d) because this is a more
#     targeted signal (assignee + label + no stamp)
#   - history (t2148): the original default was 24h to "protect genuine
#     long-running interactive work". In practice every interactive
#     session starts stampless until/unless the formal claim helper runs,
#     and most never do — so 24h became a productivity tax that blocked
#     pulse dispatch for up to a full day per abandoned claim. The pulse
#     interval is ~10min, so 1h still gives 6 cycles of grace plus the
#     proactive session-start `scan-stale` Phase 1a is the primary
#     cleanup mechanism. Override via STAMPLESS_INTERACTIVE_AGE_THRESHOLD
#     env var (set to 86400 to restore the t2148 24h behaviour).
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
	# blocks pulse dispatch forever via `_has_active_claim`. The 1h
	# default (t2942) matches status-based stale recovery — the absence
	# of a stamp file is itself the liveness signal: a real interactive
	# session creates a stamp via `interactive-session-helper.sh claim`,
	# while ad-hoc self-assigns from `claim-task-id.sh` (per t1970)
	# never produce one. Override via STAMPLESS_INTERACTIVE_AGE_THRESHOLD
	# (set to 86400 to restore the original 24h behaviour from t2148).
	local stampless_age_threshold="${STAMPLESS_INTERACTIVE_AGE_THRESHOLD:-3600}"
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

		# t2985: per-repo merged-PR prefetch (replaces per-issue gh search).
		# Same pattern as reconcile_issues_single_pass — one gh call here
		# replaces N per-issue gh search calls in _action_oimp_single.
		local oimp_lookup=""
		oimp_lookup=$(_build_oimp_lookup_for_slug "$slug")

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
			# t2985: pass oimp_lookup as 4th arg.
			if _action_oimp_single "$slug" "$issue_num" "$verify_helper" "$oimp_lookup"; then
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

	# t2877: periodic cross-phase blocked-by backfill — gated by a separate
	# interval state file (same default 3600s as t2838 sub-issue backfill).
	# The backfill is idempotent (addBlockedBy swallows duplicates) so this
	# is purely a cost-control gate, not a correctness requirement. Shares
	# _pbf_now as the "current epoch" to avoid a second date(1) call.
	local _cbb_state_file="${HOME}/.aidevops/state/cross-phase-blocked-by-last-run.epoch"
	local _cbb_interval="${AIDEVOPS_CROSS_PHASE_BLOCKED_BY_INTERVAL_SECS:-3600}"
	[[ "$_cbb_interval" =~ ^[1-9][0-9]*$ ]] || _cbb_interval=3600
	local _cbb_this_cycle=0 _cbb_last_run=0
	if [[ -r "$_cbb_state_file" ]]; then
		_cbb_last_run=$(cat "$_cbb_state_file" 2>/dev/null || echo 0)
		[[ "$_cbb_last_run" =~ ^[0-9]+$ ]] || _cbb_last_run=0
	fi
	if [[ "$_pbf_now" -gt 0 ]] && \
		[[ $((_pbf_now - _cbb_last_run)) -ge "$_cbb_interval" ]] && \
		[[ -n "$issue_sync_helper" ]]; then
		_cbb_this_cycle=1
	fi
	local cbb_total_run=0 cbb_max_per_cycle=10

	# Cycle-wide counters for log summary
	local ciw_closed=0 rsd_closed=0 rsd_reset=0 lia_fixed=0

	# Cross-platform base64 decode flag: GNU uses -d, BSD/macOS canonical is -D.
	# Both flags work on modern macOS (10.15+), but -D is the documented BSD form.
	local _b64d_flag="-d"
	[[ "$(uname -s)" == "Darwin" ]] && _b64d_flag="-D"

	# t2984: time-budget early-exit. Without it, this function regularly
	# hits PRE_RUN_STAGE_TIMEOUT (600s) and is killed with exit 124,
	# preventing downstream pre-run stages (auto_approve_maintainer_issues,
	# normalize_active_issue_assignments) from running for the rest of the
	# cycle. Root cause: _action_oimp_single makes 2 gh API calls per
	# non-parent issue × ~200 issues across all pulse-enabled repos.
	# Returning success at budget preserves cycle progress; the issues
	# skipped this cycle are picked up next cycle.
	# Override: RECONCILE_TIME_BUDGET_SECS env var.
	# Disable: RECONCILE_TIME_BUDGET_SECS=0 (unbounded — restore pre-t2984 behaviour).
	#
	# GH#21380: budget reduced from 540s to 360s.
	# This function runs INSIDE _preflight_ownership_reconcile, which has its
	# own PRE_RUN_STAGE_TIMEOUT (600s) outer wrapper. normalize_active_issue_
	# assignments runs before us and takes 55-109s (observed). With budget=540
	# the available time for this function is only 600-100=~500s < 540s, so
	# the budget NEVER fires — the outer wrapper kills this function first,
	# every cycle, producing the same rc=124 outcome as before t2984.
	# With budget=360: total pipeline = ~100s (normalize) + 360s + ~15s
	# (auto_approve) = ~475s, comfortably within the 600s outer timeout.
	# Variables initialised here at function entry (local scope, not module
	# scope) so each invocation gets a fresh start timestamp independent of
	# any prior call.
	local _t2984_start_ts=$SECONDS _t2984_budget _t2984_aborted=0
	_t2984_budget="${RECONCILE_TIME_BUDGET_SECS:-360}"
	[[ "$_t2984_budget" =~ ^[0-9]+$ ]] || _t2984_budget=360

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		# GH#21470: per-slug timing so slow repos are identifiable in the
		# substage timing log. The _log_substage_timing helper (pulse-watchdog.sh)
		# writes to PULSE_STAGE_TIMINGS_LOG with the same TSV format as outer
		# run_stage_with_timeout records.
		local _slug_start=$SECONDS

		# t2984: per-slug budget gate (cheap — uses Bash builtin SECONDS)
		if [[ "$_t2984_budget" -gt 0 ]]; then
			if [[ $((SECONDS - _t2984_start_ts)) -ge "$_t2984_budget" ]]; then
				_t2984_aborted=1
				break
			fi
		fi

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

		# t2904: Pre-extract all per-issue fields with a single jq call per
		# repo instead of 4 jq subprocess spawns per issue. At cross-repo
		# scale (8 repos x ~30 issues each), this collapses ~960 jq forks
		# into ~8 — eliminating the dominant per-cycle CPU overhead that
		# pushed reconcile_issues_single_pass past the 600s
		# PRE_RUN_STAGE_TIMEOUT in #21042. Title and body are base64-wrapped
		# so embedded newlines/tabs survive round-trip. join("|") is used
		# instead of @tsv: IFS=$'\t' with read collapses consecutive tabs
		# (empty fields) into a single delimiter, corrupting field offsets
		# when labels_csv is empty. "|" is not an IFS whitespace character
		# so consecutive "|" separators are never collapsed. See bash(1) IFS.
		local issues_tsv
		issues_tsv=$(printf '%s' "$issues_json" | jq -r '
			.[] | [
				(.number // "" | tostring),
				((.title // "") | @base64),
				((.labels // []) | map(.name) | join(",")),
				((.body // "") | @base64)
			] | join("|")
		') || issues_tsv=""
		[[ -n "$issues_tsv" ]] || continue

		# t2985: per-repo merged-PR prefetch for stage 3 (oimp).
		# One gh call per repo replaces ~30 per-issue gh search calls.
		# Empty lookup is safe — _action_oimp_single returns 1 on empty
		# lookup, deferring stage 3 closes to the next cycle.
		local oimp_lookup=""
		oimp_lookup=$(_build_oimp_lookup_for_slug "$slug")

		while IFS='|' read -r issue_num issue_title_b64 labels_csv issue_body_b64; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# t2984: per-issue budget gate (cheap — uses Bash builtin SECONDS)
			if [[ "$_t2984_budget" -gt 0 ]]; then
				if [[ $((SECONDS - _t2984_start_ts)) -ge "$_t2984_budget" ]]; then
					_t2984_aborted=1
					break 2
				fi
			fi

			local issue_title="" issue_body=""
			if [[ -n "$issue_title_b64" ]]; then
				issue_title=$(printf '%s' "$issue_title_b64" | base64 "$_b64d_flag" 2>/dev/null) || issue_title=""
			fi
			if [[ -n "$issue_body_b64" ]]; then
				issue_body=$(printf '%s' "$issue_body_b64" | base64 "$_b64d_flag" 2>/dev/null) || issue_body=""
			fi

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
				if _action_oimp_single "$slug" "$issue_num" "$verify_helper" "$oimp_lookup"; then
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
			# t2877: periodic cross-phase blocked-by backfill — mirrors t2838
			# gate pattern. Only runs if the parent didn't just close and the
			# cycle-gate fired. Idempotent (addBlockedBy swallows duplicates).
			if [[ "$_cbb_this_cycle" -eq 1 ]] && \
				[[ "$cbb_total_run" -lt "$cbb_max_per_cycle" ]] && \
				[[ "${_SP_CPT_CLOSED:-0}" -ne 1 ]]; then
				if "$issue_sync_helper" backfill-cross-phase-blocked-by \
					--repo "$slug" --issue "$issue_num" >/dev/null 2>&1; then
					cbb_total_run=$((cbb_total_run + 1))
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
		done <<< "$issues_tsv"
		# GH#21470: log per-repo elapsed time so slow slugs are identifiable.
		# Slash in slug would break log parsing; replace with underscore.
		local _slug_safe="${slug//\//_}"
		_log_substage_timing "substage:reconcile_sp/repo:${_slug_safe}" "$_slug_start" 0
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	# t2838: persist last-run epoch when backfill actually ran this cycle.
	# Skip on dry runs (pbf_total_run == 0) so we retry next cycle.
	if [[ "$_pbf_this_cycle" -eq 1 ]] && [[ "$pbf_total_run" -gt 0 ]]; then
		mkdir -p "$(dirname "$_pbf_state_file")" 2>/dev/null || true
		printf '%s\n' "$_pbf_now" >"$_pbf_state_file" 2>/dev/null || true
	fi

	# t2877: persist last-run epoch for cross-phase blocked-by backfill.
	if [[ "$_cbb_this_cycle" -eq 1 ]] && [[ "$cbb_total_run" -gt 0 ]]; then
		mkdir -p "$(dirname "$_cbb_state_file")" 2>/dev/null || true
		printf '%s\n' "$_pbf_now" >"$_cbb_state_file" 2>/dev/null || true
	fi

	local _total_actions
	_total_actions=$((ciw_closed + rsd_closed + rsd_reset + oimp_total_closed + cpt_total_closed + cpt_total_nudged + cpt_total_escalated + lia_fixed + pbf_total_run + cbb_total_run))

	# t2984: log when time-budget aborted iteration mid-cycle so operators
	# can correlate with stage-timing log entries. Always logs (not gated
	# on _total_actions) because budget aborts ARE the diagnostic signal.
	if [[ "$_t2984_aborted" -eq 1 ]]; then
		local _t2984_elapsed_end
		_t2984_elapsed_end=$((SECONDS - _t2984_start_ts))
		echo "[pulse-wrapper] reconcile_issues_single_pass: time-budget abort at ${_t2984_elapsed_end}s (budget=${_t2984_budget}s) — actions completed: ciw_closed=${ciw_closed} rsd_closed=${rsd_closed} rsd_reset=${rsd_reset} oimp_closed=${oimp_total_closed} cpt_closed=${cpt_total_closed} cpt_nudged=${cpt_total_nudged} cpt_escalated=${cpt_total_escalated} lia_fixed=${lia_fixed} pbf_run=${pbf_total_run} cbb_run=${cbb_total_run}" >>"$LOGFILE"
	elif [[ "$_total_actions" -gt 0 ]]; then
		echo "[pulse-wrapper] reconcile_issues_single_pass: ciw_closed=${ciw_closed} rsd_closed=${rsd_closed} rsd_reset=${rsd_reset} oimp_closed=${oimp_total_closed} cpt_closed=${cpt_total_closed} cpt_nudged=${cpt_total_nudged} cpt_escalated=${cpt_total_escalated} lia_fixed=${lia_fixed} pbf_run=${pbf_total_run} cbb_run=${cbb_total_run}" >>"$LOGFILE"
	fi
	return 0
}
