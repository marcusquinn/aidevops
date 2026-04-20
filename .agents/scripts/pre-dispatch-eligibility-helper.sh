#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pre-dispatch-eligibility-helper.sh — Generic pre-dispatch eligibility gate (t2424, GH#20030)
#
# Catches issues that are already resolved BEFORE spending worker dispatch overhead.
# Complements the generator-specific pre-dispatch-validator-helper.sh (GH#19118):
#   - pre-dispatch-validator-helper.sh: generator-tagged issues, premise-based checks
#   - THIS file: generic eligibility checks applied to ALL issues regardless of generator
#
# Problem solved: 5 `no_work skip-escalation` events from workers dispatched on
# already-closed issues. Each dispatch costs $0.05–$0.25 in auth + model tokens.
# The race window: issue is OPEN when scanned, closed (PR merged) before worker spawns.
#
# Checks run in order (cheap to expensive):
#   1. CLOSED state — issue.state == CLOSED → abort (exit 2)
#   2. Status labels — status:done or status:resolved → abort (exit 3)
#   3. Recent PR merge — linked PR merged in last 5 min → abort (exit 4)
#   4. Recent closing commit — commit on default branch within last ~10 min
#      with a GitHub closing keyword (close/fix/resolve) referencing this
#      issue → abort (exit 5). Ref/For commits are NOT closing references.
#
# Exit codes (returned by the `check` subcommand):
#   0  — eligible; dispatch proceeds
#   2  — issue is CLOSED
#   3  — issue has status:done or status:resolved label
#   4  — linked PR merged in recent window (5 min by default)
#   5  — recent closing commit on default branch (10 min by default)
#   20 — API error; caller should fail-open (dispatch proceeds with warning)
#
# Usage (standalone):
#   pre-dispatch-eligibility-helper.sh check <issue-number> <slug>
#
# Usage (sourced from pulse-dispatch-core.sh):
#   is_issue_eligible_for_dispatch <issue-number> <slug>   # returns same exit codes
#
# Environment overrides:
#   ISSUE_META_JSON — pre-fetched JSON (state,labels,closedAt) from caller; avoids extra gh call
#   AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1 — bypass entirely (emergency escape hatch)
#   AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW=<seconds> — recent-merge detection window (default 300)
#   AIDEVOPS_PREDISPATCH_RECENT_COMMIT_WINDOW=<seconds> — recent-commit detection window (default 600)
#
# Counter output:
#   Pre-dispatch aborts are tracked in ~/.aidevops/logs/pulse-stats.json
#   via pulse-stats-helper.sh (sourced below). The 24h count is surfaced
#   by `aidevops status` to make churn visible to operators.
#   Counters:
#     pre_dispatch_aborts           — total aborts across all gates
#     pre_dispatch_aborts_recent_commit — aborts caused specifically by gate 4

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source pulse-stats-helper.sh for counter support (optional — fail-open if missing).
# shellcheck source=pulse-stats-helper.sh
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pulse-stats-helper.sh"
fi

# LOGFILE for sourced-mode usage (caller sets it; standalone mode defines a default).
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

#######################################
# Record a pre-dispatch abort in the stats counter and log it.
# Non-fatal: logging/counter failures do not affect the abort decision.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - reason (e.g. "CLOSED", "status:done", "recent-merge")
#   $4 - exit_code (2, 3, or 4)
#######################################
_eligibility_record_abort() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local exit_code="$4"

	echo "[dispatch-precheck] #${issue_number} in ${repo_slug} NOT eligible — ${reason} (exit=${exit_code})" >>"$LOGFILE"

	# Increment the 24h abort counter if pulse-stats-helper.sh is available.
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pre_dispatch_aborts" 2>/dev/null || true
	fi

	return 0
}

#######################################
# Check whether any commit on the default branch within the recent-commit
# window contains a GitHub closing keyword referencing the candidate issue.
#
# Uses the same closing-keyword regex as pulse-merge.sh::_extract_linked_issue:
#   close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved + #NNN
# Does NOT match: Ref #NNN, For #NNN, GH#NNN, or other non-closing references.
#
# Fail-open: returns 0 (allow dispatch) on any gh API or date error so that
# network failures or auth expiry do not block legitimate dispatch.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Returns:
#   0 — no recent closing commit found (allow dispatch)
#   1 — recent closing commit found (caller should abort dispatch with exit 5)
#######################################
_check_recent_commit_closes_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	local commit_window="${AIDEVOPS_PREDISPATCH_RECENT_COMMIT_WINDOW:-600}"
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0

	if [[ "$now_epoch" -eq 0 ]]; then
		return 0
	fi

	# Compute ISO 8601 window start (cross-platform: macOS uses -r, Linux uses -d).
	local since_epoch=$(( now_epoch - commit_window ))
	local since_iso
	since_iso=$(date -r "$since_epoch" -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
		|| date -d "@${since_epoch}" -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || since_iso=""

	if [[ -z "$since_iso" ]]; then
		echo "[dispatch-precheck] WARNING: could not compute since_iso for recent-commit check on #${issue_number} — skipping (fail-open)" >>"$LOGFILE"
		return 0
	fi

	# Resolve the default branch for the repo (fail-open to "main").
	local repo_json default_branch
	repo_json=$(gh api "repos/${repo_slug}" 2>/dev/null) || repo_json=""
	default_branch=$(jq -r '.default_branch // "main"' <<<"$repo_json" 2>/dev/null) || default_branch=""
	[[ -z "$default_branch" ]] && default_branch="main"

	# Fetch commits on the default branch within the window.
	local commits_data
	commits_data=$(gh api "repos/${repo_slug}/commits?sha=${default_branch}&since=${since_iso}" 2>/dev/null) \
		|| commits_data=""

	if [[ -z "$commits_data" ]]; then
		# gh API error — fail-open: allow dispatch to proceed.
		echo "[dispatch-precheck] WARNING: gh API error fetching recent commits for ${repo_slug} — proceeding (fail-open)" >>"$LOGFILE"
		return 0
	fi

	# Extract issue numbers referenced by closing keywords in commit messages.
	# Regex: close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved + #NNN
	# This is the same regex as pulse-merge.sh::_extract_linked_issue (t2204).
	# Ref #NNN and For #NNN do NOT match — they are planning references, not closes.
	local referenced_issues
	referenced_issues=$(printf '%s' "$commits_data" \
		| jq -r '.[].commit.message' 2>/dev/null \
		| grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' \
		| grep -oE '[0-9]+$') || referenced_issues=""

	if [[ -z "$referenced_issues" ]]; then
		return 0
	fi

	# Check whether any extracted issue number matches the candidate issue.
	if printf '%s\n' "$referenced_issues" | grep -qx "$issue_number"; then
		return 1
	fi

	return 0
}

#######################################
# Core eligibility check. Runs 4 gates in order (cheap to expensive).
# Accepts pre-fetched JSON via ISSUE_META_JSON env var to avoid duplicate
# gh calls when the caller already has the metadata.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Returns:
#   0  — eligible; dispatch proceeds
#   2  — CLOSED state
#   3  — status:done or status:resolved label
#   4  — recent linked PR merge
#   5  — recent closing commit on default branch
#   20 — API error (fail-open: caller should proceed with dispatch + warning)
#######################################
is_issue_eligible_for_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"

	# Emergency bypass — allows operators to disable this gate without patching.
	if [[ "${AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY:-0}" == "1" ]]; then
		echo "[dispatch-precheck] AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1 — bypassing eligibility check for #${issue_number}" >>"$LOGFILE"
		return 0
	fi

	# --- Gate 1 & 2: State + Label checks (single gh call) ---
	local data state labels closed_at
	if [[ -n "${ISSUE_META_JSON:-}" ]] \
		&& printf '%s' "$ISSUE_META_JSON" | jq -e '.state and .labels' >/dev/null 2>&1; then
		# Use pre-fetched metadata from caller — avoids an extra gh API call.
		data="$ISSUE_META_JSON"
	else
		# Fetch fresh — includes closedAt for the log message.
		data=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json state,labels,closedAt 2>/dev/null) || data=""
	fi

	if [[ -z "$data" ]]; then
		# gh API failure — fail-open: dispatch proceeds, warn in log.
		echo "[dispatch-precheck] WARNING: gh API error fetching #${issue_number} in ${repo_slug} — proceeding (fail-open)" >>"$LOGFILE"
		return 20
	fi

	state=$(jq -r '.state // "OPEN"' <<<"$data" 2>/dev/null) || state="OPEN"
	labels=$(jq -r '[.labels[].name] | join(",")' <<<"$data" 2>/dev/null) || labels=""
	closed_at=$(jq -r '.closedAt // ""' <<<"$data" 2>/dev/null) || closed_at=""

	# Gate 1: CLOSED state check.
	if [[ "$state" == "CLOSED" ]]; then
		_eligibility_record_abort "$issue_number" "$repo_slug" "CLOSED (closed_at=${closed_at:-unknown})" "2"
		return 2
	fi

	# Gate 2: Resolved-status label check.
	if printf ',%s,' "$labels" | grep -qE ',(status:done|status:resolved),'; then
		_eligibility_record_abort "$issue_number" "$repo_slug" "label=${labels}" "3"
		return 3
	fi

	# --- Gate 3: Recent linked-PR merge check (one extra gh call) ---
	local merge_window="${AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW:-300}"
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	if [[ "$now_epoch" -gt 0 ]]; then
		local timeline_data recent_merged_count
		timeline_data=$(gh api "repos/${repo_slug}/issues/${issue_number}/timeline?per_page=50" 2>/dev/null) || timeline_data=""
		if [[ -n "$timeline_data" ]]; then
			local cutoff=$(( now_epoch - merge_window ))
			recent_merged_count=$(jq -r --argjson cutoff "$cutoff" \
				'[.[] | select(.event == "merged" and ((.created_at // "") | if . == "" then 0 else fromdateiso8601 end) > $cutoff)] | length' \
				<<<"$timeline_data" 2>/dev/null) || recent_merged_count=0
			if [[ "${recent_merged_count:-0}" -gt 0 ]]; then
				_eligibility_record_abort "$issue_number" "$repo_slug" "recent-merge within ${merge_window}s window" "4"
				return 4
			fi
		fi
	fi

	# --- Gate 4: Recent closing commit on default branch (one extra gh call) ---
	local commit_window="${AIDEVOPS_PREDISPATCH_RECENT_COMMIT_WINDOW:-600}"
	local recent_commit_rc=0
	_check_recent_commit_closes_issue "$issue_number" "$repo_slug" || recent_commit_rc=$?
	if [[ "$recent_commit_rc" -eq 1 ]]; then
		_eligibility_record_abort "$issue_number" "$repo_slug" "recent-commit closes issue within ${commit_window}s window" "5"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pre_dispatch_aborts_recent_commit" 2>/dev/null || true
		fi
		return 5
	fi

	# All gates passed — eligible for dispatch.
	echo "[dispatch-precheck] #${issue_number} in ${repo_slug} eligible for dispatch" >>"$LOGFILE"
	return 0
}

#######################################
# Wrapper called from pulse-dispatch-core.sh dispatch_with_dedup.
# Mirrors the _run_predispatch_validator pattern: non-fatal on missing
# helper (when sourced), but here we are the helper, so this is only
# used when invoked standalone or from a calling context that does NOT
# source this file directly.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#
# Exit codes: same as is_issue_eligible_for_dispatch (0, 2, 3, 4, 20)
#######################################
_run_predispatch_eligibility_check() {
	local issue_number="$1"
	local repo_slug="$2"

	local eligibility_rc=0
	is_issue_eligible_for_dispatch "$issue_number" "$repo_slug" || eligibility_rc=$?
	return "$eligibility_rc"
}

#######################################
# Standalone CLI entry point.
# Called as: pre-dispatch-eligibility-helper.sh check <issue> <slug>
#######################################
_main() {
	local cmd="${1:-help}"
	shift

	case "$cmd" in
		check)
			if [[ $# -lt 2 ]]; then
				echo "Usage: pre-dispatch-eligibility-helper.sh check <issue-number> <slug>" >&2
				return 1
			fi
			local check_issue="$1"
			local check_slug="$2"
			is_issue_eligible_for_dispatch "$check_issue" "$check_slug"
			return $?
			;;
		help | --help | -h)
			echo "pre-dispatch-eligibility-helper.sh — Generic pre-dispatch eligibility gate (t2424)"
			echo ""
			echo "Usage:"
			echo "  pre-dispatch-eligibility-helper.sh check <issue-number> <slug>"
			echo ""
			echo "Exit codes:"
			echo "  0  — eligible, dispatch proceeds"
			echo "  2  — CLOSED state"
			echo "  3  — status:done or status:resolved label"
			echo "  4  — recent linked PR merge"
			echo "  5  — recent closing commit on default branch"
			echo "  20 — API error (fail-open)"
			echo ""
			echo "Environment:"
			echo "  AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1    bypass (emergency)"
			echo "  AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW   merge window seconds (default 300)"
			echo "  AIDEVOPS_PREDISPATCH_RECENT_COMMIT_WINDOW  commit window seconds (default 600)"
			echo "  ISSUE_META_JSON                            pre-fetched JSON to reuse"
			return 0
			;;
		*)
			echo "Unknown command: ${cmd}" >&2
			echo "Run: pre-dispatch-eligibility-helper.sh help" >&2
			return 1
			;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
