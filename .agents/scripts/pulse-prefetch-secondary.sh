#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-secondary.sh — Secondary prefetch public functions
# =============================================================================
# Sub-library extracted from pulse-prefetch.sh (GH#19964).
# Covers the secondary prefetch functions that gather supplemental state
# beyond the primary PR/issue fetch:
#   - Active worker snapshot
#   - CI failure patterns
#   - Repo hygiene data
#   - External contribution watch
#   - Needs-info contributor reply status (helpers + main function)
#   - Failed notification summary
#
# Usage: source "${SCRIPT_DIR}/pulse-prefetch-secondary.sh"
#
# Dependencies:
#   - pulse-prefetch-infra.sh (rate-limit helpers)
#   - shared-constants.sh
#   - Environment vars: LOGFILE, SCRIPT_DIR, STATE_FILE,
#     GH_FAILURE_PREFETCH_HOURS, GH_FAILURE_PREFETCH_LIMIT,
#     GH_FAILURE_SYSTEMIC_THRESHOLD, GH_FAILURE_MAX_RUN_LOGS
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_PREFETCH_SECONDARY_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_SECONDARY_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Active Worker Snapshot (t216, t1367)
# =============================================================================

#######################################
# Pre-fetch active worker processes (t216, t1367)
#
# Captures a snapshot of running worker processes so the pulse agent
# can cross-reference open PRs with active workers. This is the
# deterministic data-fetch part — the intelligence about which PRs
# are orphaned stays in pulse.md.
#
# t1367: Also computes struggle_ratio for each worker with a worktree.
# High ratio = active but unproductive (thrashing). Informational only.
#
# Output: worker summary to stdout (appended to STATE_FILE by caller)
#######################################
# list_active_worker_processes: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.
# See worker-lifecycle-common.sh for the canonical implementation with:
#   - process chain deduplication (t5072)
#   - headless-runtime-helper.sh wrapper support (GH#12361, GH#14944)
#   - zombie/stopped process filtering (GH#6413)

prefetch_active_workers() {
	local worker_lines
	worker_lines=$(list_active_worker_processes || true)

	echo ""
	echo "# Active Workers"
	echo ""
	echo "Snapshot of running worker processes at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
	echo "Use this to determine whether a PR has an active worker (not orphaned)."
	echo "Struggle ratio: messages/max(1,commits) — high ratio + time = thrashing. See pulse.md."
	echo ""

	if [[ -z "$worker_lines" ]]; then
		echo "- No active workers"
	else
		local count
		count=$(echo "$worker_lines" | wc -l | tr -d ' ')
		echo "### Running Workers ($count)"
		echo ""
		echo "$worker_lines" | while IFS= read -r line; do
			local pid etime cmd
			read -r pid etime cmd <<<"$line"

			# Compute elapsed seconds for struggle ratio.
			# This is the AUTHORITATIVE process age — use it for kill comments.
			# Do NOT compute duration from dispatch comment timestamps or
			# branch/worktree creation times, which may reflect prior attempts.
			local elapsed_seconds
			elapsed_seconds=$(_get_process_age "$pid")
			local formatted_duration
			formatted_duration=$(_format_duration "$elapsed_seconds")

			# Compute struggle ratio (t1367)
			local sr_result
			sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
			local sr_ratio sr_commits sr_messages sr_flag
			IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"

			local sr_display=""
			if [[ "$sr_ratio" != "n/a" ]]; then
				sr_display=" [struggle_ratio: ${sr_ratio} (${sr_messages}msgs/${sr_commits}commits)"
				if [[ -n "$sr_flag" ]]; then
					sr_display="${sr_display} **${sr_flag}**"
				fi
				sr_display="${sr_display}]"
			fi

			echo "- PID $pid (process_uptime: ${formatted_duration}, elapsed_seconds: ${elapsed_seconds}): $cmd${sr_display}"
		done
	fi

	echo ""
	return 0
}

# =============================================================================
# CI Failure Patterns (GH#4480)
# =============================================================================

#######################################
# Pre-fetch CI failure patterns from notification mining (GH#4480)
#
# Runs gh-failure-miner-helper.sh prefetch to detect systemic CI
# failures across managed repos. The prefetch command mines ci_activity
# notifications (which contribution-watch-helper.sh explicitly excludes)
# and identifies checks that fail on multiple PRs — indicating workflow
# bugs rather than per-PR code issues.
#
# Previously used the removed 'scan' command (GH#4586). Now uses
# 'prefetch' which is the correct supported command.
#
# Output: CI failure summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_ci_failures() {
	local miner_script="${SCRIPT_DIR}/gh-failure-miner-helper.sh"

	if [[ ! -x "$miner_script" ]]; then
		echo ""
		echo "# CI Failure Patterns: miner script not found"
		echo ""
		return 0
	fi

	# Guard: verify the helper supports the 'prefetch' command before calling.
	# If the contract drifts again, this produces a clear compatibility warning
	# rather than a silent [ERROR] Unknown command in the log.
	if ! "$miner_script" --help 2>&1 | grep -q 'prefetch'; then
		echo "[pulse-wrapper] gh-failure-miner-helper.sh does not support 'prefetch' command — skipping CI failure prefetch (compatibility warning)" >>"$LOGFILE"
		echo ""
		echo "# CI Failure Patterns: helper command contract mismatch (see pulse.log)"
		echo ""
		return 0
	fi

	# Run prefetch — outputs compact pulse-ready summary to stdout
	"$miner_script" prefetch \
		--pulse-repos \
		--since-hours "$GH_FAILURE_PREFETCH_HOURS" \
		--limit "$GH_FAILURE_PREFETCH_LIMIT" \
		--systemic-threshold "$GH_FAILURE_SYSTEMIC_THRESHOLD" \
		--max-run-logs "$GH_FAILURE_MAX_RUN_LOGS" 2>/dev/null || {
		echo ""
		echo "# CI Failure Patterns: prefetch failed (non-fatal)"
		echo ""
	}

	return 0
}

# =============================================================================
# Repo Hygiene (t1417)
# =============================================================================

prefetch_hygiene() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	echo ""
	echo "# Repo Hygiene"
	echo ""
	echo "Non-deterministic cleanup candidates requiring LLM assessment."
	echo "Merged-PR worktrees and safe-to-drop stashes were already cleaned by the shell layer."
	echo ""

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "- repos.json not available — skipping hygiene prefetch"
		echo ""
		return 0
	fi

	local repo_paths
	repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path' "$repos_json" || echo "")

	local found_any=false

	local repo_path
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		[[ ! -d "$repo_path/.git" ]] && continue

		local repo_name
		repo_name=$(basename "$repo_path")

		local repo_issues
		repo_issues=$(_check_repo_hygiene "$repo_path" "$repos_json")

		# Output repo section if any issues found
		if [[ -n "$repo_issues" ]]; then
			found_any=true
			echo "### ${repo_name}"
			echo -e "$repo_issues"
		fi
	done <<<"$repo_paths"

	if [[ "$found_any" == "false" ]]; then
		echo "- All repos clean — no hygiene issues detected"
		echo ""
	fi

	_scan_pr_salvage "$repos_json"

	return 0
}

# =============================================================================
# External Contribution Watch (t1419)
# =============================================================================

#######################################
# Pre-fetch contribution watch scan results (t1419)
#
# Runs contribution-watch-helper.sh scan and appends a count-only
# summary to STATE_FILE. This is deterministic — only timestamps
# and authorship are checked, never comment bodies. The pulse agent
# sees "N external items need attention" without any untrusted content.
#
# Output: appends to STATE_FILE (called before prefetch_state writes it)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
prefetch_contribution_watch() {
	local helper="${SCRIPT_DIR}/contribution-watch-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	# Only run if state file exists (user has run 'seed' at least once)
	local cw_state="${HOME}/.aidevops/cache/contribution-watch.json"
	if [[ ! -f "$cw_state" ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan 2>/dev/null) || scan_output=""

	# Extract the machine-readable count
	local cw_count=0
	if [[ "$scan_output" =~ CONTRIBUTION_WATCH_COUNT=([0-9]+) ]]; then
		cw_count="${BASH_REMATCH[1]}"
	fi

	# Append to state file for the pulse agent (count only — no comment bodies)
	if [[ "$cw_count" -gt 0 ]]; then
		{
			echo ""
			echo "# External Contributions (t1419)"
			echo ""
			echo "${cw_count} external contribution(s) need your reply."
			echo "Run \`contribution-watch-helper.sh status\` in an interactive session for details."
			echo "**Do NOT fetch or process comment bodies in this pulse context.**"
			echo ""
		}
		echo "[pulse-wrapper] Contribution watch: ${cw_count} items need attention" >>"$LOGFILE"
	fi

	return 0
}

# =============================================================================
# Needs-Info Contributor Reply Status (GH#18554)
# =============================================================================

#######################################
# Fetch status:needs-info issues for a single repo via gh issue list.
# Outputs JSON array to stdout; emits "[]" on any failure.
# Handles rate-limit detection and logs errors to LOGFILE.
#
# Arguments:
#   $1 - slug (owner/repo)
# Output: JSON array of issue objects
# Returns: 0 always (best-effort)
#######################################
_prefetch_ni_fetch_issues() {
	local slug="$1"
	local ni_err ni_json
	ni_err=$(mktemp)
	ni_json=$(gh issue list --repo "$slug" --label "status:needs-info" \
		--state open --json number,title,author,createdAt,updatedAt \
		--limit 50 2>"$ni_err") || ni_json=""
	if [[ -z "$ni_json" || "$ni_json" == "null" ]]; then
		local _ni_err_msg
		_ni_err_msg=$(cat "$ni_err" 2>/dev/null || echo "unknown error")
		# GH#18979 (t2097): detect rate-limit exhaustion
		if _pulse_gh_err_is_rate_limit "$ni_err"; then
			_pulse_mark_rate_limited "prefetch_needs_info_replies:${slug}"
		fi
		echo "[pulse-wrapper] prefetch_needs_info_replies: gh issue list FAILED for ${slug}: ${_ni_err_msg}" >>"$LOGFILE"
		ni_json="[]"
	fi
	rm -f "$ni_err"
	echo "$ni_json"
	return 0
}

#######################################
# Resolve the timestamp when status:needs-info was applied to an issue.
# Uses the GitHub timeline API; falls back to the issue's updatedAt field
# when the timeline call fails or returns null.
#
# Arguments:
#   $1 - slug     (owner/repo)
#   $2 - number   (issue number)
#   $3 - ni_json  (full issues JSON array)
#   $4 - i        (index into ni_json for this issue)
# Output: ISO-8601 date string
# Returns: 0 always
#######################################
_prefetch_ni_get_label_date() {
	local slug="$1"
	local number="$2"
	local ni_json="$3"
	local i="$4"
	local label_date api_ok=true
	label_date=$(gh api "repos/${slug}/issues/${number}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "status:needs-info")] | last | .created_at' \
		2>/dev/null) || api_ok=false
	if [[ "$api_ok" != true || -z "$label_date" || "$label_date" == "null" ]]; then
		# Fall back: use issue updatedAt as approximate label time
		label_date=$(echo "$ni_json" | jq -r ".[$i].updatedAt")
	fi
	echo "$label_date"
	return 0
}

#######################################
# Determine whether the issue author replied after status:needs-info was applied.
# Fetches all issue comments and compares the latest author comment date
# against the label application timestamp.
#
# GH#18554: uses --arg to safely pass $author into jq (avoids injection if
# login contains special chars).
#
# Arguments:
#   $1 - slug       (owner/repo)
#   $2 - number     (issue number)
#   $3 - author     (GitHub login of the issue author)
#   $4 - label_date (ISO-8601 timestamp when needs-info was applied)
# Output: "true" if author replied after label date, "false" otherwise
# Returns: 0 always
#######################################
_prefetch_ni_check_author_replied() {
	local slug="$1"
	local number="$2"
	local author="$3"
	local label_date="$4"
	local latest_author_comment_date=""
	latest_author_comment_date=$(gh api "repos/${slug}/issues/${number}/comments" --paginate 2>/dev/null |
		jq -r --arg author "$author" '.[] | select(.user.login == $author) | .created_at' \
			2>/dev/null | tail -n 1) || latest_author_comment_date=""
	if [[ -n "$latest_author_comment_date" && "$latest_author_comment_date" != "null" &&
		"$latest_author_comment_date" > "$label_date" ]]; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Pre-fetch contributor reply status for status:needs-info issues
#
# For each pulse-enabled repo, finds issues with the status:needs-info
# label and checks whether the original issue author has commented since
# the label was applied. This enables the pulse to relabel issues back
# to needs-maintainer-review when the contributor provides the requested
# information.
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: needs-info reply status section to stdout
#######################################
prefetch_needs_info_replies() {
	local repo_entries="$1"
	local found_any=false
	local total_replied=0

	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue

		# GH#18984 (t2098): skip repos with 0 cached needs-info issues
		if _prefetch_cached_label_count_is_zero "$slug" "status:needs-info"; then
			echo "[pulse-wrapper] prefetch_needs_info_replies: SKIP ${slug} — 0 needs-info issues in cache" >>"$LOGFILE"
			continue
		fi

		local ni_json ni_count
		ni_json=$(_prefetch_ni_fetch_issues "$slug")
		ni_count=$(echo "$ni_json" | jq 'length')
		[[ "$ni_count" -gt 0 ]] || continue

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Needs Info — Contributor Reply Status"
			echo ""
			echo "Issues with \`status:needs-info\` label. For items marked **replied**, relabel to"
			echo "\`needs-maintainer-review\` so the triage pipeline re-evaluates with the new information."
			echo ""
			found_any=true
		fi

		echo "## ${slug}"
		echo ""

		local i=0
		while [[ "$i" -lt "$ni_count" ]]; do
			local number title author label_date author_replied status_label
			number=$(echo "$ni_json" | jq -r ".[$i].number")
			title=$(echo "$ni_json" | jq -r ".[$i].title")
			author=$(echo "$ni_json" | jq -r ".[$i].author.login")

			label_date=$(_prefetch_ni_get_label_date "$slug" "$number" "$ni_json" "$i")
			author_replied=$(_prefetch_ni_check_author_replied "$slug" "$number" "$author" "$label_date")

			if [[ "$author_replied" == true ]]; then
				status_label="replied"
				total_replied=$((total_replied + 1))
			else
				status_label="waiting"
			fi

			echo "- Issue #${number}: ${title} [author: @${author}] [status: **${status_label}**] [labeled: ${label_date}]"
			i=$((i + 1))
		done

		echo ""
	done <<<"$repo_entries"

	if [[ "$found_any" == true ]]; then
		echo "**Total contributor replies pending action: ${total_replied}**"
		echo ""
		echo "[pulse-wrapper] Needs-info reply status: ${total_replied} issues with contributor replies" >>"$LOGFILE"
	fi

	return 0
}

# =============================================================================
# Failed Notification Summary (t3960)
# =============================================================================

#######################################
# Pre-fetch failed notification summary (t3960)
#
# Uses gh-failure-miner-helper.sh to mine ci_activity notifications,
# cluster recurring failures, and append a compact summary to STATE_FILE.
# This gives the pulse early signal on systemic CI breakages.
#
# Returns: 0 always (best-effort)
#######################################
prefetch_gh_failure_notifications() {
	local helper="${SCRIPT_DIR}/gh-failure-miner-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local summary
	summary=$(bash "$helper" prefetch \
		--pulse-repos \
		--since-hours "$GH_FAILURE_PREFETCH_HOURS" \
		--limit "$GH_FAILURE_PREFETCH_LIMIT" \
		--systemic-threshold "$GH_FAILURE_SYSTEMIC_THRESHOLD" \
		--max-run-logs "$GH_FAILURE_MAX_RUN_LOGS" 2>/dev/null || true)

	if [[ -z "$summary" ]]; then
		return 0
	fi

	echo ""
	echo "$summary"
	echo "- action: for systemic clusters, create/update one bug+auto-dispatch issue per affected repo"
	echo ""
	echo "[pulse-wrapper] Failed-notification summary appended (hours=${GH_FAILURE_PREFETCH_HOURS}, threshold=${GH_FAILURE_SYSTEMIC_THRESHOLD})" >>"$LOGFILE"
	return 0
}
