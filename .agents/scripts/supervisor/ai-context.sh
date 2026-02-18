#!/usr/bin/env bash
# ai-context.sh - AI Supervisor context builder (t1085.1)
#
# Assembles a comprehensive project snapshot for the AI reasoning engine.
# Output: structured markdown document (< 50K tokens) giving the AI
# full situational awareness of the project state.
#
# Used by: ai-reason.sh (Phase 13 of supervisor pulse)
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), sql_escape()

#######################################
# Build the full AI context document
# Arguments:
#   $1 - repo path
#   $2 - (optional) context scope: "full" (default) or "quick"
# Outputs:
#   Structured markdown to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
build_ai_context() {
	local repo_path="${1:-$REPO_PATH}"
	local scope="${2:-full}"

	local context=""

	# Header
	context+="# AI Supervisor Context Snapshot\n\n"
	context+="Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')\n"
	context+="Repo: $(basename "$repo_path")\n"
	context+="Scope: $scope\n\n"

	# Section 1: Open GitHub Issues
	context+="$(build_issues_context "$repo_path" "$scope")\n\n"

	# Section 2: Recent PRs
	context+="$(build_prs_context "$repo_path" "$scope")\n\n"

	# Section 3: TODO.md State
	context+="$(build_todo_context "$repo_path")\n\n"

	# Section 4: Supervisor DB State
	context+="$(build_db_context)\n\n"

	# Section 5: Recent Worker Outcomes
	context+="$(build_outcomes_context)\n\n"

	# Section 6: Pattern Tracker Data (full scope only)
	if [[ "$scope" == "full" ]]; then
		context+="$(build_patterns_context)\n\n"
	fi

	# Section 7: Recent Memory Entries (full scope only)
	if [[ "$scope" == "full" ]]; then
		context+="$(build_memory_context)\n\n"
	fi

	# Section 8: Queue Health Metrics
	context+="$(build_health_context)\n\n"

	printf '%b' "$context"
	return 0
}

#######################################
# Section 1: Open GitHub Issues
# Fetches open issues with labels, age, comment count, linked PRs
#######################################
build_issues_context() {
	local repo_path="$1"
	local scope="$2"
	local limit=30
	[[ "$scope" == "quick" ]] && limit=15

	local output="## Open GitHub Issues\n\n"

	if ! command -v gh &>/dev/null; then
		output+="*gh CLI not available — skipping issue context*\n"
		printf '%b' "$output"
		return 0
	fi

	local issues_json
	issues_json=$(gh issue list --state open --limit "$limit" --json number,title,labels,createdAt,comments,assignees 2>/dev/null || echo "[]")

	local issue_count
	issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)

	if [[ "$issue_count" -eq 0 ]]; then
		output+="No open issues.\n"
		printf '%b' "$output"
		return 0
	fi

	output+="| # | Title | Labels | Age | Comments | Assignee |\n"
	output+="|---|-------|--------|-----|----------|----------|\n"

	local i=0
	while [[ $i -lt $issue_count ]]; do
		local num title labels created comments assignee age_days
		num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null || echo "?")
		title=$(printf '%s' "$issues_json" | jq -r ".[$i].title" 2>/dev/null || echo "?")
		labels=$(printf '%s' "$issues_json" | jq -r "[.[$i].labels[].name] | join(\", \")" 2>/dev/null || echo "")
		created=$(printf '%s' "$issues_json" | jq -r ".[$i].createdAt" 2>/dev/null || echo "")
		comments=$(printf '%s' "$issues_json" | jq -r ".[$i].comments | length" 2>/dev/null || echo "0")
		assignee=$(printf '%s' "$issues_json" | jq -r "[.[$i].assignees[].login] | join(\", \")" 2>/dev/null || echo "")

		# Calculate age in days
		if [[ -n "$created" && "$created" != "null" ]]; then
			local created_epoch now_epoch
			created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" "+%s" 2>/dev/null || date -d "$created" "+%s" 2>/dev/null || echo 0)
			now_epoch=$(date "+%s")
			age_days=$(((now_epoch - created_epoch) / 86400))
		else
			age_days="?"
		fi

		# Truncate title for table readability
		if [[ ${#title} -gt 60 ]]; then
			title="${title:0:57}..."
		fi

		output+="| #$num | $title | $labels | ${age_days}d | $comments | ${assignee:-none} |\n"
		i=$((i + 1))
	done

	output+="\nTotal open: $issue_count"
	if [[ "$issue_count" -ge "$limit" ]]; then
		output+=" (showing first $limit)"
	fi
	output+="\n"

	printf '%b' "$output"
	return 0
}

#######################################
# Section 2: Recent PRs (last 48h)
# State, reviews, CI status, merge status
#######################################
build_prs_context() {
	local repo_path="$1"
	local scope="$2"
	local limit=20
	[[ "$scope" == "quick" ]] && limit=10

	local output="## Recent Pull Requests (last 48h)\n\n"

	if ! command -v gh &>/dev/null; then
		output+="*gh CLI not available — skipping PR context*\n"
		printf '%b' "$output"
		return 0
	fi

	# Get recent PRs (open + recently closed/merged)
	local prs_json
	prs_json=$(gh pr list --state all --limit "$limit" --json number,title,state,createdAt,mergedAt,closedAt,reviews,statusCheckRollup,headRefName,author 2>/dev/null || echo "[]")

	local pr_count
	pr_count=$(printf '%s' "$prs_json" | jq 'length' 2>/dev/null || echo 0)

	if [[ "$pr_count" -eq 0 ]]; then
		output+="No recent PRs.\n"
		printf '%b' "$output"
		return 0
	fi

	output+="| # | Title | State | Branch | Author | Reviews | CI |\n"
	output+="|---|-------|-------|--------|--------|---------|----|\n"

	local i=0
	while [[ $i -lt $pr_count ]]; do
		local num title state branch author reviews_summary ci_status
		num=$(printf '%s' "$prs_json" | jq -r ".[$i].number" 2>/dev/null || echo "?")
		title=$(printf '%s' "$prs_json" | jq -r ".[$i].title" 2>/dev/null || echo "?")
		state=$(printf '%s' "$prs_json" | jq -r ".[$i].state" 2>/dev/null || echo "?")
		branch=$(printf '%s' "$prs_json" | jq -r ".[$i].headRefName" 2>/dev/null || echo "?")
		author=$(printf '%s' "$prs_json" | jq -r ".[$i].author.login" 2>/dev/null || echo "?")

		# Summarise reviews
		local approved rejected commented
		approved=$(printf '%s' "$prs_json" | jq "[.[$i].reviews[] | select(.state==\"APPROVED\")] | length" 2>/dev/null || echo 0)
		rejected=$(printf '%s' "$prs_json" | jq "[.[$i].reviews[] | select(.state==\"CHANGES_REQUESTED\")] | length" 2>/dev/null || echo 0)
		commented=$(printf '%s' "$prs_json" | jq "[.[$i].reviews[] | select(.state==\"COMMENTED\")] | length" 2>/dev/null || echo 0)
		reviews_summary="${approved}A/${rejected}R/${commented}C"

		# CI status rollup
		local success_count failure_count pending_count
		success_count=$(printf '%s' "$prs_json" | jq "[.[$i].statusCheckRollup[] | select(.conclusion==\"SUCCESS\")] | length" 2>/dev/null || echo 0)
		failure_count=$(printf '%s' "$prs_json" | jq "[.[$i].statusCheckRollup[] | select(.conclusion==\"FAILURE\")] | length" 2>/dev/null || echo 0)
		pending_count=$(printf '%s' "$prs_json" | jq "[.[$i].statusCheckRollup[] | select(.conclusion==null or .conclusion==\"PENDING\")] | length" 2>/dev/null || echo 0)

		if [[ "$failure_count" -gt 0 ]]; then
			ci_status="FAIL($failure_count)"
		elif [[ "$pending_count" -gt 0 ]]; then
			ci_status="PENDING($pending_count)"
		elif [[ "$success_count" -gt 0 ]]; then
			ci_status="PASS($success_count)"
		else
			ci_status="none"
		fi

		# Truncate title
		if [[ ${#title} -gt 50 ]]; then
			title="${title:0:47}..."
		fi

		output+="| #$num | $title | $state | $branch | $author | $reviews_summary | $ci_status |\n"
		i=$((i + 1))
	done

	printf '%b' "$output"
	return 0
}

#######################################
# Section 3: TODO.md State
# Open tasks, blocked tasks, stale tasks
#######################################
build_todo_context() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	local output="## TODO.md State\n\n"

	if [[ ! -f "$todo_file" ]]; then
		output+="*TODO.md not found*\n"
		printf '%b' "$output"
		return 0
	fi

	# Count open vs completed tasks (top-level only)
	local open_count completed_count
	open_count=$(grep -cE '^- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || echo 0)
	completed_count=$(grep -cE '^- \[x\] t[0-9]+' "$todo_file" 2>/dev/null || echo 0)

	output+="**Summary**: $open_count open, $completed_count completed\n\n"

	# List open top-level tasks (not subtasks)
	output+="### Open Tasks\n\n"
	local open_tasks
	open_tasks=$(grep -E '^- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || true)

	if [[ -z "$open_tasks" ]]; then
		output+="No open top-level tasks.\n"
	else
		while IFS= read -r line; do
			# Extract task ID and first 100 chars of description
			local task_id desc
			task_id=$(echo "$line" | grep -oE 't[0-9]+' | head -1)
			desc="${line:0:120}"
			if [[ ${#line} -gt 120 ]]; then
				desc+="..."
			fi
			output+="- $desc\n"
		done <<<"$open_tasks"
	fi

	# List tasks with blocked-by dependencies (skip format examples in header)
	output+="\n### Blocked Tasks\n\n"
	local blocked_tasks
	blocked_tasks=$(grep -E '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" 2>/dev/null || true)

	if [[ -z "$blocked_tasks" ]]; then
		output+="No blocked tasks.\n"
	else
		while IFS= read -r line; do
			local task_id blocker
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			blocker=$(echo "$line" | grep -oE 'blocked-by:[^ ]+' | head -1)
			output+="- $task_id ($blocker)\n"
		done <<<"$blocked_tasks"
	fi

	# Tasks with #auto-dispatch that haven't been picked up
	output+="\n### Dispatchable (not yet picked up)\n\n"
	local dispatchable
	dispatchable=$(grep -E '^\s*- \[ \].*#auto-dispatch' "$todo_file" 2>/dev/null | grep -v 'assignee:\|started:' || true)

	if [[ -z "$dispatchable" ]]; then
		output+="All #auto-dispatch tasks are claimed or in progress.\n"
	else
		local disp_count=0
		while IFS= read -r line; do
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			output+="- $task_id\n"
			disp_count=$((disp_count + 1))
		done <<<"$dispatchable"
		output+="Total dispatchable: $disp_count\n"
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 4: Supervisor DB State
# Running workers, queued tasks, recent state transitions
#######################################
build_db_context() {
	local output="## Supervisor DB State\n\n"

	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		output+="*Supervisor DB not found*\n"
		printf '%b' "$output"
		return 0
	fi

	# Task counts by status
	local status_counts
	status_counts=$(db "$SUPERVISOR_DB" "
		SELECT status, COUNT(*) as cnt
		FROM tasks
		GROUP BY status
		ORDER BY cnt DESC;
	" 2>/dev/null || echo "")

	output+="### Task Status Distribution\n\n"
	if [[ -n "$status_counts" ]]; then
		output+="| Status | Count |\n|--------|-------|\n"
		while IFS='|' read -r status cnt; do
			output+="| $status | $cnt |\n"
		done <<<"$status_counts"
	else
		output+="No tasks in DB.\n"
	fi

	# Currently running workers
	output+="\n### Running Workers\n\n"
	local running
	running=$(db "$SUPERVISOR_DB" "
		SELECT id, description, batch_id,
			   CAST((julianday('now') - julianday(updated_at)) * 24 * 60 AS INTEGER) as minutes_ago
		FROM tasks
		WHERE status IN ('running', 'dispatched')
		ORDER BY updated_at DESC
		LIMIT 10;
	" 2>/dev/null || echo "")

	if [[ -z "$running" ]]; then
		output+="No running workers.\n"
	else
		output+="| Task | Description | Batch | Running (min) |\n"
		output+="|------|-------------|-------|---------------|\n"
		while IFS='|' read -r tid desc batch mins; do
			local short_desc="${desc:0:50}"
			[[ ${#desc} -gt 50 ]] && short_desc+="..."
			output+="| $tid | $short_desc | ${batch:-none} | ${mins:-?} |\n"
		done <<<"$running"
	fi

	# Recently completed (last 24h)
	output+="\n### Recently Completed (24h)\n\n"
	local recent_complete
	recent_complete=$(db "$SUPERVISOR_DB" "
		SELECT id, status, pr_url, error
		FROM tasks
		WHERE status IN ('complete', 'verified', 'deployed', 'cancelled', 'failed')
		  AND updated_at > datetime('now', '-24 hours')
		ORDER BY updated_at DESC
		LIMIT 15;
	" 2>/dev/null || echo "")

	if [[ -z "$recent_complete" ]]; then
		output+="No completions in last 24h.\n"
	else
		output+="| Task | Status | PR | Notes |\n"
		output+="|------|--------|----|-------|\n"
		while IFS='|' read -r tid status pr_url error; do
			local pr_display="${pr_url:-none}"
			if [[ ${#pr_display} -gt 30 ]]; then
				pr_display="${pr_display:0:27}..."
			fi
			local notes="${error:-}"
			if [[ ${#notes} -gt 40 ]]; then
				notes="${notes:0:37}..."
			fi
			output+="| $tid | $status | $pr_display | $notes |\n"
		done <<<"$recent_complete"
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 5: Recent Worker Outcomes
# Last 10 evaluations with verdicts
#######################################
build_outcomes_context() {
	local output="## Recent Worker Outcomes\n\n"

	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		output+="*No DB*\n"
		printf '%b' "$output"
		return 0
	fi

	local outcomes
	outcomes=$(db "$SUPERVISOR_DB" "
		SELECT task_id, from_state, to_state, reason,
			   datetime(timestamp, 'localtime') as ts
		FROM state_log
		WHERE reason LIKE 'AI eval%'
		   OR reason LIKE 'Worker%'
		   OR reason LIKE 'Evaluate%'
		ORDER BY timestamp DESC
		LIMIT 10;
	" 2>/dev/null || echo "")

	if [[ -z "$outcomes" ]]; then
		output+="No recent evaluations.\n"
	else
		output+="| Task | From | To | Reason | Time |\n"
		output+="|------|------|----|--------|------|\n"
		while IFS='|' read -r tid from_s to_s reason ts; do
			local short_reason="${reason:0:50}"
			[[ ${#reason} -gt 50 ]] && short_reason+="..."
			output+="| $tid | $from_s | $to_s | $short_reason | $ts |\n"
		done <<<"$outcomes"
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 6: Pattern Tracker Data
# Success/failure rates by model tier and task type
#######################################
build_patterns_context() {
	local output="## Pattern Tracker Summary\n\n"

	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ ! -x "$pattern_helper" ]]; then
		# Try deployed location
		pattern_helper="$HOME/.aidevops/agents/scripts/pattern-tracker-helper.sh"
	fi

	if [[ ! -x "$pattern_helper" ]]; then
		output+="*Pattern tracker not available*\n"
		printf '%b' "$output"
		return 0
	fi

	local stats
	stats=$("$pattern_helper" stats 2>/dev/null || echo "")

	if [[ -n "$stats" ]]; then
		output+="$stats\n"
	else
		output+="No pattern data available.\n"
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 7: Recent Memory Entries
# Last 24h of cross-session memories
#######################################
build_memory_context() {
	local output="## Recent Memories (24h)\n\n"

	local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
	if [[ ! -x "$memory_helper" ]]; then
		memory_helper="$HOME/.aidevops/agents/scripts/memory-helper.sh"
	fi

	if [[ ! -x "$memory_helper" ]]; then
		output+="*Memory helper not available*\n"
		printf '%b' "$output"
		return 0
	fi

	local memories
	memories=$("$memory_helper" recall --recent --limit 10 2>/dev/null || echo "")

	if [[ -n "$memories" ]]; then
		output+="$memories\n"
	else
		output+="No recent memories.\n"
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 8: Queue Health Metrics
# Throughput, failure rates, average cycle time
#######################################
build_health_context() {
	local output="## Queue Health Metrics\n\n"

	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		output+="*No DB*\n"
		printf '%b' "$output"
		return 0
	fi

	# Tasks completed in last 7 days
	local completed_7d
	completed_7d=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE status IN ('complete', 'verified', 'deployed')
		  AND updated_at > datetime('now', '-7 days');
	" 2>/dev/null || echo 0)

	# Tasks failed in last 7 days
	local failed_7d
	failed_7d=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE status IN ('failed', 'cancelled')
		  AND updated_at > datetime('now', '-7 days');
	" 2>/dev/null || echo 0)

	# Tasks currently blocked
	local blocked_count
	blocked_count=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE status = 'blocked';
	" 2>/dev/null || echo 0)

	# Tasks currently queued
	local queued_count
	queued_count=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE status = 'queued';
	" 2>/dev/null || echo 0)

	# Average retries for completed tasks
	local avg_retries
	avg_retries=$(db "$SUPERVISOR_DB" "
		SELECT ROUND(AVG(retries), 1) FROM tasks
		WHERE status IN ('complete', 'verified', 'deployed')
		  AND updated_at > datetime('now', '-7 days');
	" 2>/dev/null || echo "0")

	local total_7d=$((completed_7d + failed_7d))
	local success_rate="N/A"
	if [[ "$total_7d" -gt 0 ]]; then
		success_rate=$(awk "BEGIN { printf \"%.0f\", ($completed_7d / $total_7d) * 100 }")
		success_rate="${success_rate}%"
	fi

	output+="| Metric | Value |\n|--------|-------|\n"
	output+="| Completed (7d) | $completed_7d |\n"
	output+="| Failed (7d) | $failed_7d |\n"
	output+="| Success rate (7d) | $success_rate |\n"
	output+="| Currently queued | $queued_count |\n"
	output+="| Currently blocked | $blocked_count |\n"
	output+="| Avg retries (7d) | ${avg_retries:-0} |\n"

	printf '%b' "$output"
	return 0
}

#######################################
# CLI entry point for standalone testing
# Usage: ai-context.sh [--scope full|quick] [--repo /path]
#######################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	# When run standalone, source common helpers
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=_common.sh
	source "$SCRIPT_DIR/_common.sh"

	# Colour codes (may not be set when run standalone)
	BLUE="${BLUE:-\033[0;34m}"
	GREEN="${GREEN:-\033[0;32m}"
	YELLOW="${YELLOW:-\033[1;33m}"
	RED="${RED:-\033[0;31m}"
	NC="${NC:-\033[0m}"

	# Default paths
	SUPERVISOR_DB="${SUPERVISOR_DB:-$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db}"
	SUPERVISOR_LOG="${SUPERVISOR_LOG:-$HOME/.aidevops/.agent-workspace/supervisor/cron.log}"
	REPO_PATH="${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	# Parse args
	scope="full"
	repo_path="$REPO_PATH"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--scope)
			scope="$2"
			shift 2
			;;
		--repo)
			repo_path="$2"
			shift 2
			;;
		--help | -h)
			echo "Usage: ai-context.sh [--scope full|quick] [--repo /path]"
			echo ""
			echo "Build AI supervisor context document for reasoning engine."
			echo ""
			echo "Options:"
			echo "  --scope full|quick   Context depth (default: full)"
			echo "  --repo /path         Repository path (default: git root)"
			echo "  --help               Show this help"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		esac
	done

	build_ai_context "$repo_path" "$scope"
fi
