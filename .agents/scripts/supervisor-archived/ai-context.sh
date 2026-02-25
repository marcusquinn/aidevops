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

	# Section 0: Exclusion List (completed tasks + recently-acted-on issues)
	# Placed first so the AI sees it before any issue/task lists.
	context+="$(build_exclusion_context)\n\n"

	# Section 1: Open GitHub Issues (multi-repo, t1333)
	# Include issues from all registered repos, not just the primary one.
	# Previously only queried the cwd repo, missing issues from other managed repos.
	local all_issue_repos
	all_issue_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	if [[ -n "$all_issue_repos" ]]; then
		while IFS= read -r issue_repo; do
			[[ -z "$issue_repo" || ! -d "$issue_repo" ]] && continue
			context+="$(build_issues_context "$issue_repo" "$scope")\n\n"
		done <<<"$all_issue_repos"
		# If primary repo wasn't in the DB list, include it too
		if ! echo "$all_issue_repos" | grep -qF "$repo_path"; then
			context+="$(build_issues_context "$repo_path" "$scope")\n\n"
		fi
	else
		context+="$(build_issues_context "$repo_path" "$scope")\n\n"
	fi

	# Section 2: Recent PRs (multi-repo, t1333)
	if [[ -n "$all_issue_repos" ]]; then
		while IFS= read -r pr_repo; do
			[[ -z "$pr_repo" || ! -d "$pr_repo" ]] && continue
			context+="$(build_prs_context "$pr_repo" "$scope")\n\n"
		done <<<"$all_issue_repos"
		if ! echo "$all_issue_repos" | grep -qF "$repo_path"; then
			context+="$(build_prs_context "$repo_path" "$scope")\n\n"
		fi
	else
		context+="$(build_prs_context "$repo_path" "$scope")\n\n"
	fi

	# Section 3: TODO.md State (multi-repo, t1188)
	# Include TODO.md from all registered repos, not just the primary one.
	# This enables the AI reasoner to see and assess tasks across all projects.
	local all_context_repos
	all_context_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	if [[ -n "$all_context_repos" ]]; then
		local repo_count=0
		while IFS= read -r ctx_repo; do
			[[ -z "$ctx_repo" || ! -d "$ctx_repo" ]] && continue
			context+="$(build_todo_context "$ctx_repo")\n\n"
			repo_count=$((repo_count + 1))
		done <<<"$all_context_repos"
		# If primary repo wasn't in the DB list, include it too
		if ! echo "$all_context_repos" | grep -qF "$repo_path"; then
			context+="$(build_todo_context "$repo_path")\n\n"
		fi
	else
		context+="$(build_todo_context "$repo_path")\n\n"
	fi

	# Section 3b: Auto-Dispatch Eligibility Assessment (t1188)
	context+="$(build_autodispatch_eligibility_context)\n\n"

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

	# Section 9: Issue Audit Findings (full scope only, t1085.6)
	if [[ "$scope" == "full" ]]; then
		context+="$(build_audit_context "$repo_path")\n\n"
	fi

	# Section 10: AI Self-Reflection (own execution history, t1118)
	if [[ "$scope" == "full" ]]; then
		context+="$(build_self_reflection_context)\n\n"
	fi

	# Section 11: Auto-dispatch eligibility assessment (t1134)
	if [[ "$scope" == "full" ]]; then
		context+="$(build_auto_dispatch_eligibility_context "$repo_path")\n\n"
	fi

	# Section 12: Recently Fixed Systemic Issues (t1284)
	# Shows improvement/bugfix tasks completed in the last 30 days so the AI
	# reasoner doesn't re-create investigation tasks for already-fixed problems.
	# The create_improvement dedup only checks 24h; this section provides broader
	# awareness of recent fixes to prevent stale-data false positives.
	if [[ "$scope" == "full" ]]; then
		context+="$(build_recent_fixes_context "$repo_path")\n\n"
	fi

	printf '%b' "$context"
	return 0
}

#######################################
# Section 0: Exclusion List (t1148)
# Builds a deduplicated list of task IDs and issue numbers that the AI
# should NOT act on this cycle. Sources:
#   1. Tasks completed/verified/deployed in the last 48h (from supervisor DB)
#   2. Issue numbers acted on in the last 5 action log cycles
# Placed at the top of the context so the AI sees it before any issue/task
# lists, preventing redundant actions and saving reasoning tokens.
#######################################
build_exclusion_context() {
	local output="## DO NOT ACT — Exclusion List\n\n"
	output+="**CRITICAL**: Do NOT propose any action targeting the task IDs or issue numbers\n"
	output+="listed below. These have already been completed or acted on recently.\n"
	output+="Proposing actions for excluded targets wastes tokens and creates duplicate work.\n\n"

	local excluded_tasks=""
	local excluded_issues=""

	# Source 1: recently completed/verified/deployed tasks from supervisor DB
	if [[ -f "$SUPERVISOR_DB" ]]; then
		local db_completed
		db_completed=$(db "$SUPERVISOR_DB" "
			SELECT id FROM tasks
			WHERE status IN ('complete', 'verified', 'deployed', 'cancelled')
			  AND updated_at > datetime('now', '-48 hours')
			ORDER BY updated_at DESC
			LIMIT 30;
		" 2>/dev/null || echo "")

		if [[ -n "$db_completed" ]]; then
			while IFS= read -r tid; do
				tid="${tid// /}"
				[[ -n "$tid" ]] && excluded_tasks+="$tid\n"
			done <<<"$db_completed"
		fi
	fi

	# Source 2: issue numbers and task IDs acted on in recent action log cycles
	local log_dir="${AI_REASON_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"
	if [[ -d "$log_dir" ]]; then
		local action_logs
		action_logs=$(find "$log_dir" -maxdepth 1 -name 'actions-*.md' -print0 2>/dev/null |
			xargs -0 ls -t 2>/dev/null | head -5)

		if [[ -n "$action_logs" ]]; then
			while IFS= read -r log_file; do
				[[ -f "$log_file" ]] || continue

				# Extract issue numbers from action logs
				local issue_nums
				issue_nums=$(grep -oE '"issue_number":[0-9]+' "$log_file" 2>/dev/null |
					grep -oE '[0-9]+' || true)
				if [[ -n "$issue_nums" ]]; then
					while IFS= read -r inum; do
						[[ -n "$inum" ]] && excluded_issues+="$inum\n"
					done <<<"$issue_nums"
				fi

				# Extract task IDs from action logs
				local task_ids
				task_ids=$(grep -oE '"task_id":"t[0-9]+"' "$log_file" 2>/dev/null |
					grep -oE 't[0-9]+' || true)
				if [[ -n "$task_ids" ]]; then
					while IFS= read -r tid; do
						[[ -n "$tid" ]] && excluded_tasks+="$tid\n"
					done <<<"$task_ids"
				fi
			done <<<"$action_logs"
		fi
	fi

	# Deduplicate and format task exclusions
	if [[ -n "$excluded_tasks" ]]; then
		local deduped_tasks
		deduped_tasks=$(printf '%b' "$excluded_tasks" | sort -u | tr '\n' ' ' | sed 's/ $//')
		output+="### Excluded Task IDs (completed or recently acted on)\n\n"
		output+="$deduped_tasks\n\n"
		output+="Skip any action with \`task_id\` matching the above.\n\n"
	else
		output+="### Excluded Task IDs\n\n_None in last 48h_\n\n"
	fi

	# Deduplicate and format issue exclusions
	if [[ -n "$excluded_issues" ]]; then
		local deduped_issues
		deduped_issues=$(printf '%b' "$excluded_issues" | sort -un | tr '\n' ' ' | sed 's/ $//')
		output+="### Excluded Issue Numbers (acted on in recent cycles)\n\n"
		output+="$deduped_issues\n\n"
		output+="Skip any action with \`issue_number\` matching the above.\n\n"
	else
		output+="### Excluded Issue Numbers\n\n_None in recent cycles_\n\n"
	fi

	printf '%b' "$output"
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

	# Resolve repo slug for --repo flag (t1333: cross-repo visibility)
	local repo_slug repo_label
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	repo_label=$(basename "$repo_path")

	local output="## Open GitHub Issues — ${repo_label}\n\n"

	if ! command -v gh &>/dev/null; then
		output+="*gh CLI not available — skipping issue context*\n"
		printf '%b' "$output"
		return 0
	fi

	# Use --repo flag to query the correct repo regardless of cwd (t1333)
	local repo_flag=""
	if [[ -n "$repo_slug" ]]; then
		repo_flag="--repo $repo_slug"
	fi

	local issues_json
	# shellcheck disable=SC2086
	issues_json=$(gh issue list $repo_flag --state open --limit "$limit" --json number,title,labels,createdAt,comments,assignees 2>/dev/null || echo "[]")

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

	# Resolve repo slug for --repo flag (t1333: cross-repo visibility)
	local repo_slug repo_label
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	repo_label=$(basename "$repo_path")

	local output="## Recent Pull Requests (last 48h) — ${repo_label}\n\n"

	if ! command -v gh &>/dev/null; then
		output+="*gh CLI not available — skipping PR context*\n"
		printf '%b' "$output"
		return 0
	fi

	# Use --repo flag to query the correct repo regardless of cwd (t1333)
	local repo_flag=""
	if [[ -n "$repo_slug" ]]; then
		repo_flag="--repo $repo_slug"
	fi

	# Get recent PRs (open + recently closed/merged)
	local prs_json
	# shellcheck disable=SC2086
	prs_json=$(gh pr list $repo_flag --state all --limit "$limit" --json number,title,state,createdAt,mergedAt,closedAt,reviews,statusCheckRollup,headRefName,author 2>/dev/null || echo "[]")

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
# Get task IDs that are verified/cancelled/complete/deployed in the supervisor DB.
# Used by build_todo_context() to filter stale tasks from the AI context (t1178).
# Arguments: none
# Outputs: newline-separated task IDs to stdout (empty if DB unavailable)
# Returns: 0 always
#######################################
_get_db_completed_task_ids() {
	if [[ ! -f "${SUPERVISOR_DB:-}" ]]; then
		return 0
	fi
	db "$SUPERVISOR_DB" "
		SELECT id FROM tasks
		WHERE status IN ('complete', 'verified', 'deployed', 'cancelled')
		ORDER BY updated_at DESC;
	" 2>/dev/null || true
	return 0
}

#######################################
# Section 3: TODO.md State
# Open tasks, blocked tasks, stale tasks
# Cross-references supervisor DB to exclude verified/cancelled tasks (t1178).
#######################################
build_todo_context() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local repo_name
	repo_name=$(basename "$repo_path")

	local output="## TODO.md State — $repo_name\n\n"

	if [[ ! -f "$todo_file" ]]; then
		output+="*TODO.md not found*\n"
		printf '%b' "$output"
		return 0
	fi

	# Fetch DB-verified/cancelled task IDs for context-layer filtering (t1178).
	# This prevents the AI from seeing tasks that are already done in the DB
	# even if TODO.md hasn't been updated yet (stale checkbox lag).
	local db_completed_ids=""
	db_completed_ids=$(_get_db_completed_task_ids)

	# Build a fast lookup: newline-separated string of completed task IDs
	# (bash 3.2-compatible alternative to declare -A associative arrays)
	local _db_done_ids="$db_completed_ids"

	# Count open vs completed tasks (top-level only)
	local open_count completed_count
	open_count=$(grep -cE '^- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || echo 0)
	completed_count=$(grep -cE '^- \[x\] t[0-9]+' "$todo_file" 2>/dev/null || echo 0)

	output+="**Summary**: $open_count open, $completed_count completed\n\n"

	# List open top-level tasks (not subtasks), excluding DB-verified tasks
	output+="### Open Tasks\n\n"
	local open_tasks
	open_tasks=$(grep -E '^- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || true)

	local filtered_count=0
	if [[ -z "$open_tasks" ]]; then
		output+="No open top-level tasks.\n"
	else
		local shown_any=0
		while IFS= read -r line; do
			local task_id desc
			task_id=$(echo "$line" | grep -oE 't[0-9]+' | head -1)
			# Skip tasks already verified/cancelled/complete in supervisor DB (t1178)
			if [[ -n "$task_id" ]] && echo "$_db_done_ids" | grep -qxF "$task_id"; then
				filtered_count=$((filtered_count + 1))
				continue
			fi
			desc="${line:0:120}"
			if [[ ${#line} -gt 120 ]]; then
				desc+="..."
			fi
			output+="- $desc\n"
			shown_any=1
		done <<<"$open_tasks"
		if [[ "$shown_any" -eq 0 ]]; then
			output+="No open top-level tasks.\n"
		fi
	fi

	if [[ "$filtered_count" -gt 0 ]]; then
		output+="\n> **Context filter (t1178)**: $filtered_count task(s) omitted — verified/cancelled in supervisor DB but checkbox not yet updated in TODO.md. Do NOT act on them.\n"
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
			# Skip DB-verified tasks from blocked list too (t1178)
			if [[ -n "$task_id" ]] && echo "$_db_done_ids" | grep -qxF "$task_id"; then
				continue
			fi
			blocker=$(echo "$line" | grep -oE 'blocked-by:t[0-9][^ ]*' | head -1)
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
			# Exclude DB-verified tasks from dispatchable list (t1178)
			if [[ -n "$task_id" ]] && echo "$_db_done_ids" | grep -qxF "$task_id"; then
				continue
			fi
			output+="- $task_id\n"
			disp_count=$((disp_count + 1))
		done <<<"$dispatchable"
		if [[ "$disp_count" -eq 0 ]]; then
			output+="All #auto-dispatch tasks are claimed or in progress.\n"
		else
			output+="Total dispatchable: $disp_count\n"
		fi
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 3b: Auto-Dispatch Eligibility Assessment (t1188)
# Scans all registered repos for open tasks without #auto-dispatch
# and assesses whether they could be candidates.
# Also detects common blocker statuses that prevent dispatch.
#
# Blocker statuses (user-defined, non-dispatchable reasons):
#   account-needed, hosting-needed, login-needed, api-key-needed,
#   clarification-needed, resources-needed, payment-needed,
#   approval-needed, decision-needed, design-needed, content-needed,
#   dns-needed, domain-needed, testing-needed
#######################################
build_autodispatch_eligibility_context() {
	local output="## Auto-Dispatch Eligibility Assessment\n\n"
	output+="Tasks from all registered repos that are open but NOT tagged #auto-dispatch.\n"
	output+="Assess each for auto-dispatch candidacy. Use \`propose_auto_dispatch\` for eligible tasks.\n\n"

	# Known blocker statuses that indicate a task cannot be auto-dispatched
	# These are human-action-required blockers, not technical dependencies
	local blocker_pattern="account-needed\|hosting-needed\|login-needed\|api-key-needed\|clarification-needed\|resources-needed\|payment-needed\|approval-needed\|decision-needed\|design-needed\|content-needed\|dns-needed\|domain-needed\|testing-needed"

	output+="### Eligibility Criteria\n\n"
	output+="- **Eligible**: Clear spec, bounded scope (~30m-~4h), no unresolved blockers, no assignee\n"
	output+="- **Trivial bugfix exception** (t1241): #bugfix + model:haiku + specific file/function target → eligible down to ~10m (93% success rate)\n"
	output+="- **Needs subtasking**: Estimate >~4h with no existing subtasks — use \`create_subtasks\` to break down before dispatch\n"
	output+="- **Ineligible**: Vague description, has assignee, has unresolved blocked-by, or has a blocker status\n"
	output+="- **Blocker statuses** (human action required): account-needed, hosting-needed, login-needed, api-key-needed, clarification-needed, resources-needed, payment-needed, approval-needed, decision-needed, design-needed, content-needed, dns-needed, domain-needed, testing-needed\n\n"

	local all_repos
	all_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")

	if [[ -z "$all_repos" ]]; then
		output+="No registered repos found.\n"
		printf '%b' "$output"
		return 0
	fi

	# Fetch DB-verified/cancelled task IDs for filtering
	local db_completed_ids=""
	db_completed_ids=$(_get_db_completed_task_ids)
	# bash 3.2-compatible lookup: newline-separated string (no declare -A needed)
	local _elig_done_ids="$db_completed_ids"

	local total_candidates=0

	while IFS= read -r repo_path; do
		[[ -z "$repo_path" || ! -f "$repo_path/TODO.md" ]] && continue
		local repo_name
		repo_name=$(basename "$repo_path")

		# Find open tasks WITHOUT #auto-dispatch, WITHOUT assignee/started
		local candidates
		candidates=$(grep -E '^- \[ \] t[0-9]+' "$repo_path/TODO.md" 2>/dev/null |
			grep -v '#auto-dispatch' |
			grep -v 'assignee:\|started:' || true)

		[[ -z "$candidates" ]] && continue

		output+="### $repo_name\n\n"

		while IFS= read -r line; do
			local task_id
			task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			[[ -z "$task_id" ]] && continue

			# Skip DB-verified tasks
			if echo "$_elig_done_ids" | grep -qxF "$task_id"; then
				continue
			fi

			local status="eligible"
			local reason=""

			# Check for blocker statuses
			if echo "$line" | grep -qE "$blocker_pattern"; then
				local blocker
				blocker=$(echo "$line" | grep -oE "(account|hosting|login|api-key|clarification|resources|payment|approval|decision|design|content|dns|domain|testing)-needed" | head -1)
				status="blocked"
				reason="$blocker"
			# Check for blocked-by dependency
			elif echo "$line" | grep -q 'blocked-by:'; then
				status="blocked"
				reason="has dependency"
			# Check for large estimates (>4h)
			elif echo "$line" | grep -qE '~[0-9]+(h|d)'; then
				local est_raw
				est_raw=$(echo "$line" | grep -oE '~[0-9]+(h|d)' | head -1)
				local est_num="${est_raw//[^0-9]/}"
				if [[ "$est_raw" == *"d"* ]] || [[ "$est_num" -gt 4 ]]; then
					# Check if subtasks already exist for this task (t1188.2)
					local has_subtasks
					has_subtasks=$(grep -c "^\s*- \[.\] ${task_id}\." "$repo_path/TODO.md" 2>/dev/null || echo 0)
					if [[ "$has_subtasks" -gt 0 ]]; then
						status="has-subtasks"
						reason="parent task (${has_subtasks} subtasks exist) — dispatch subtasks instead"
					else
						# Guard: only flag needs-subtasking if the task is registered in the
						# supervisor DB. If not registered, create_subtasks will always fail
						# (executor refuses to guess the repo). Mark as not-in-db instead to
						# prevent the AI from generating actions that will always fail (t1238).
						local db_registered=""
						if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
							db_registered=$(db "$SUPERVISOR_DB" "
								SELECT id FROM tasks WHERE id = '$(sql_escape "$task_id")' AND repo IS NOT NULL AND repo != '' LIMIT 1;
							" 2>/dev/null || echo "")
						fi
						if [[ -z "$db_registered" && -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB:-}" ]]; then
							status="not-in-db"
							reason="task not registered in supervisor DB — cannot create subtasks safely (cross-repo collision risk)"
						else
							status="needs-subtasking"
							reason="estimate ${est_raw} exceeds ~4h — use create_subtasks to break down"
						fi
					fi
				fi
			fi

			local short_desc="${line:0:100}"
			[[ ${#line} -gt 100 ]] && short_desc+="..."

			output+="- **$task_id** [repo:$repo_name] [$status${reason:+: $reason}]: $short_desc\n"
			total_candidates=$((total_candidates + 1))
		done <<<"$candidates"

		output+="\n"
	done <<<"$all_repos"

	if [[ "$total_candidates" -eq 0 ]]; then
		output+="No untagged open tasks found across registered repos.\n"
	else
		output+="**Total candidates assessed**: $total_candidates\n"
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

	# Tasks failed in last 7 days (t1248: exclude cancelled — cancelled tasks are
	# administrative cleanup, not worker failures; including them inflates the failure
	# rate and causes false alarms. Cancelled tasks have their own metric row.)
	local failed_7d
	failed_7d=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE status = 'failed'
		  AND updated_at > datetime('now', '-7 days');
	" 2>/dev/null || echo 0)

	# Tasks cancelled in last 7 days (separate from failures — cancellations are
	# intentional administrative actions: orphaned tasks, superseded work, cleanup)
	local cancelled_7d
	cancelled_7d=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE status = 'cancelled'
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

	# Success rate excludes cancelled tasks (t1248: cancelled != failed)
	local total_7d=$((completed_7d + failed_7d))
	local success_rate="N/A"
	if [[ "$total_7d" -gt 0 ]]; then
		success_rate=$(awk "BEGIN { printf \"%.0f\", ($completed_7d / $total_7d) * 100 }")
		success_rate="${success_rate}%"
	fi

	output+="| Metric | Value |\n|--------|-------|\n"
	output+="| Completed (7d) | $completed_7d |\n"
	output+="| Failed (7d) | $failed_7d |\n"
	output+="| Cancelled (7d) | $cancelled_7d |\n"
	output+="| Success rate (7d) | $success_rate |\n"
	output+="| Currently queued | $queued_count |\n"
	output+="| Currently blocked | $blocked_count |\n"
	output+="| Avg retries (7d) | ${avg_retries:-0} |\n"

	# Phase 3 throughput metrics (t1336: supervisor self-diagnosis)
	# Shows whether the AI lifecycle phase is actually processing tasks.
	# Phase 3 was silently broken for days — these metrics make that visible.
	local log_file="${SUPERVISOR_LOG:-$HOME/.aidevops/logs/supervisor.log}"
	if [[ -f "$log_file" ]]; then
		local last_lifecycle
		last_lifecycle=$(grep 'ai-lifecycle.*evaluated.*actioned' "$log_file" 2>/dev/null | tail -1 || echo "")
		if [[ -n "$last_lifecycle" ]]; then
			local p3_eval p3_action
			p3_eval=$(echo "$last_lifecycle" | grep -oE 'evaluated [0-9]+' | grep -oE '[0-9]+' || echo "0")
			p3_action=$(echo "$last_lifecycle" | grep -oE 'actioned [0-9]+' | grep -oE '[0-9]+' || echo "0")
			output+="| Phase 3 last eval | $p3_eval |\n"
			output+="| Phase 3 last actioned | $p3_action |\n"
		else
			output+="| Phase 3 last eval | no data |\n"
			output+="| Phase 3 last actioned | no data |\n"
		fi

		# Count zero-eval streaks in recent log (last 50 lifecycle entries)
		local recent_zeros total_recent
		total_recent=$(grep 'ai-lifecycle.*evaluated' "$log_file" 2>/dev/null | tail -50 | wc -l | tr -d ' ')
		recent_zeros=$(grep 'ai-lifecycle.*evaluated' "$log_file" 2>/dev/null | tail -50 | grep -c 'evaluated 0' || echo "0")
		if [[ "$total_recent" -gt 0 ]]; then
			output+="| Phase 3 zero-eval rate (last 50) | ${recent_zeros}/${total_recent} |\n"
		fi
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 9: Issue Audit Findings (t1085.6)
# Runs the four audit checks and formats findings for AI context.
# Only includes findings with medium+ severity to conserve tokens.
#######################################
build_audit_context() {
	local repo_path="$1"

	local output="## Issue Audit Findings\n\n"

	# Check if audit functions are available (sourced from issue-audit.sh)
	if ! declare -f run_full_audit &>/dev/null; then
		output+="_Audit module not loaded_\n"
		printf '%b' "$output"
		return 0
	fi

	local audit_json=""
	audit_json=$(run_full_audit "$repo_path" 2>/dev/null || echo '{"summary":{"total_findings":0}}')

	local total=""
	total=$(printf '%s' "$audit_json" | jq -r '.summary.total_findings' 2>/dev/null || echo "0")

	if [[ "$total" -eq 0 ]]; then
		output+="_No audit findings — all clear_\n"
		printf '%b' "$output"
		return 0
	fi

	local high=""
	high=$(printf '%s' "$audit_json" | jq -r '.summary.by_severity.high' 2>/dev/null || echo "0")
	local medium=""
	medium=$(printf '%s' "$audit_json" | jq -r '.summary.by_severity.medium' 2>/dev/null || echo "0")

	output+="**Total**: $total findings (high: $high, medium: $medium)\n\n"

	# Include high-severity findings in detail
	if [[ "$high" -gt 0 ]]; then
		output+="### High Severity\n\n"
		local high_findings=""
		high_findings=$(printf '%s' "$audit_json" | jq -c '
			[.closed_issues[], .stale_issues[], .orphan_prs[], .blocked_tasks[]]
			| map(select(.severity == "high"))
			| .[:10]' 2>/dev/null || echo "[]")

		while IFS= read -r finding; do
			local source=""
			source=$(printf '%s' "$finding" | jq -r '.source' 2>/dev/null || echo "")
			local desc=""
			case "$source" in
			closed_issue_audit)
				desc=$(printf '%s' "$finding" | jq -r '"Issue #\(.issue_number) (\(.task_id)): \(.issues | join(", ")). Action: \(.suggested_action)"' 2>/dev/null || echo "")
				;;
			stale_issue_audit)
				desc=$(printf '%s' "$finding" | jq -r '"Issue #\(.issue_number) (\(.task_id)): stale \(.stale_days)d, todo:\(.todo_status). Action: \(.suggested_action)"' 2>/dev/null || echo "")
				;;
			orphan_pr_audit)
				desc=$(printf '%s' "$finding" | jq -r '"PR #\(.pr_number) (\(.task_id)): \(.issues | join(", ")), age \(.pr_age_days)d. Action: \(.suggested_action)"' 2>/dev/null || echo "")
				;;
			blocked_task_audit)
				desc=$(printf '%s' "$finding" | jq -r '"\(.task_id): blocked \(.blocked_hours)h by \(.blocked_by), resolved \(.blockers_resolved)/\(.blockers_total). Action: \(.suggested_action)"' 2>/dev/null || echo "")
				;;
			esac
			if [[ -n "$desc" ]]; then
				output+="- $desc\n"
			fi
		done < <(printf '%s' "$high_findings" | jq -c '.[]' 2>/dev/null || true)
		output+="\n"
	fi

	# Include medium-severity summary (counts only, to save tokens)
	if [[ "$medium" -gt 0 ]]; then
		output+="### Medium Severity ($medium findings)\n\n"
		local med_by_source=""
		med_by_source=$(printf '%s' "$audit_json" | jq -r '
			[.closed_issues[], .stale_issues[], .orphan_prs[], .blocked_tasks[]]
			| map(select(.severity == "medium"))
			| group_by(.source)
			| map({source: .[0].source, count: length})
			| .[]
			| "- \(.source): \(.count)"' 2>/dev/null || echo "")
		if [[ -n "$med_by_source" ]]; then
			output+="$med_by_source\n"
		fi
		output+="\n"
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 10: AI Self-Reflection (t1118)
# Feeds the AI its own recent action execution results so it can
# identify recurring failures, prompt issues, and deployment gaps.
# Sources: action log files + pipeline log
#######################################
build_self_reflection_context() {
	local output="## AI Supervisor Self-Reflection\n\n"
	local log_dir="${AI_REASON_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"

	if [[ ! -d "$log_dir" ]]; then
		output+="*No AI supervisor logs found*\n"
		printf '%b' "$output"
		return 0
	fi

	# Collect recent action logs (last 5 cycles)
	local action_logs
	action_logs=$(find "$log_dir" -maxdepth 1 -name 'actions-*.md' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -5)

	if [[ -z "$action_logs" ]]; then
		output+="*No action execution history yet*\n"
		printf '%b' "$output"
		return 0
	fi

	# Aggregate execution stats across recent cycles
	local total_executed=0 total_failed=0 total_skipped=0 cycle_count=0
	local skip_reasons=""
	local failed_actions=""

	while IFS= read -r log_file; do
		cycle_count=$((cycle_count + 1))

		# Count outcomes from action log headers
		local executed failed skipped
		executed=$(grep -c 'SUCCESS' "$log_file" 2>/dev/null || echo 0)
		failed=$(grep -c 'FAILED' "$log_file" 2>/dev/null || echo 0)
		skipped=$(grep -c 'SKIPPED' "$log_file" 2>/dev/null || echo 0)
		# Ensure clean integers (trim whitespace/newlines)
		executed="${executed//[^0-9]/}"
		failed="${failed//[^0-9]/}"
		skipped="${skipped//[^0-9]/}"
		: "${executed:=0}" "${failed:=0}" "${skipped:=0}"

		total_executed=$((total_executed + executed))
		total_failed=$((total_failed + failed))
		total_skipped=$((total_skipped + skipped))

		# Collect skip reasons (these reveal prompt/code issues)
		local skips
		skips=$(grep -E 'SKIPPED' "$log_file" 2>/dev/null || true)
		if [[ -n "$skips" ]]; then
			while IFS= read -r skip_line; do
				# Extract action type and reason from "## Action N: type — SKIPPED (reason)"
				local skip_type skip_reason
				skip_type=$(printf '%s' "$skip_line" | sed -E 's/.*: ([a-z_]+) — SKIPPED.*/\1/' 2>/dev/null || echo "unknown")
				skip_reason=$(printf '%s' "$skip_line" | sed -E 's/.*SKIPPED \(([^)]+)\).*/\1/' 2>/dev/null || echo "unknown")
				skip_reasons+="$skip_type: $skip_reason\n"
			done <<<"$skips"
		fi

		# Collect failed actions
		local fails
		fails=$(grep -E 'FAILED' "$log_file" 2>/dev/null || true)
		if [[ -n "$fails" ]]; then
			while IFS= read -r fail_line; do
				local fail_type
				fail_type=$(printf '%s' "$fail_line" | sed -E 's/.*: ([a-z_]+) — FAILED.*/\1/' 2>/dev/null || echo "unknown")
				failed_actions+="$fail_type\n"
			done <<<"$fails"
		fi
	done <<<"$action_logs"

	output+="### Execution Summary (last $cycle_count cycles)\n\n"
	output+="| Metric | Count |\n|--------|-------|\n"
	output+="| Executed | $total_executed |\n"
	output+="| Failed | $total_failed |\n"
	output+="| Skipped | $total_skipped |\n"

	local total_actions=$((total_executed + total_failed + total_skipped))
	if [[ "$total_actions" -gt 0 ]]; then
		local exec_rate=$((total_executed * 100 / total_actions))
		local skip_rate=$((total_skipped * 100 / total_actions))
		output+="| Execution rate | ${exec_rate}% |\n"
		output+="| Skip rate | ${skip_rate}% |\n"
	fi
	output+="\n"

	# Deduplicate and count skip reasons
	if [[ -n "$skip_reasons" ]]; then
		output+="### Recurring Skip Reasons\n\n"
		output+="These actions were proposed by the AI but rejected by the executor.\n"
		output+="**Fix these by adjusting your output format or the executor code.**\n\n"

		local deduped_skips
		deduped_skips=$(printf '%b' "$skip_reasons" | sort | uniq -c | sort -rn)
		output+="| Count | Action Type | Reason |\n|-------|-------------|--------|\n"
		while IFS= read -r line; do
			local count type_reason
			count=$(printf '%s' "$line" | awk '{print $1}')
			type_reason=$(printf '%s' "$line" | sed 's/^ *[0-9]* *//')
			local stype sreason
			stype=$(printf '%s' "$type_reason" | cut -d: -f1)
			sreason=$(printf '%s' "$type_reason" | cut -d: -f2- | sed 's/^ //')
			output+="| $count | $stype | $sreason |\n"
		done <<<"$deduped_skips"
		output+="\n"
	fi

	# Deduplicate and count failed actions
	if [[ -n "$failed_actions" ]]; then
		output+="### Recurring Failures\n\n"
		local deduped_fails
		deduped_fails=$(printf '%b' "$failed_actions" | sort | uniq -c | sort -rn)
		while IFS= read -r line; do
			local count ftype
			count=$(printf '%s' "$line" | awk '{print $1}')
			ftype=$(printf '%s' "$line" | sed 's/^ *[0-9]* *//')
			output+="- $ftype: failed $count times\n"
		done <<<"$deduped_fails"
		output+="\n"
	fi

	# Check for repeated identical actions across cycles (dedup detection)
	output+="### Action Repetition Detection\n\n"
	local all_actions=""
	while IFS= read -r log_file; do
		# Extract issue numbers targeted by actions
		local issue_actions
		issue_actions=$(grep -oE '"issue_number":[0-9]+' "$log_file" 2>/dev/null |
			sort -u || true)
		if [[ -n "$issue_actions" ]]; then
			while IFS= read -r ia; do
				local inum
				inum=$(printf '%s' "$ia" | grep -oE '[0-9]+')
				all_actions+="issue:#$inum\n"
			done <<<"$issue_actions"
		fi
		# Extract task IDs targeted by actions
		local task_actions
		task_actions=$(grep -oE '"task_id":"t[0-9]+"' "$log_file" 2>/dev/null |
			sort -u || true)
		if [[ -n "$task_actions" ]]; then
			while IFS= read -r ta; do
				local tid
				tid=$(printf '%s' "$ta" | grep -oE 't[0-9]+')
				all_actions+="task:$tid\n"
			done <<<"$task_actions"
		fi
	done <<<"$action_logs"

	if [[ -n "$all_actions" ]]; then
		local repeated
		repeated=$(printf '%b' "$all_actions" | sort | uniq -c | sort -rn | awk '$1 > 1')
		if [[ -n "$repeated" ]]; then
			output+="The following targets received actions in multiple cycles (possible redundant work):\n\n"
			while IFS= read -r line; do
				local count target
				count=$(printf '%s' "$line" | awk '{print $1}')
				target=$(printf '%s' "$line" | sed 's/^ *[0-9]* *//')
				output+="- $target: acted on $count times across $cycle_count cycles\n"
			done <<<"$repeated"
			output+="\n"
			output+="Consider: are these repeated actions necessary, or should you skip targets already addressed in prior cycles?\n"
		else
			output+="No repeated targets detected — each action targeted a unique resource.\n"
		fi
	else
		output+="No action targets to analyze.\n"
	fi
	output+="\n"

	# Pipeline errors from ai-supervisor.log (last 50 lines)
	local pipeline_log="${HOME}/.aidevops/.agent-workspace/supervisor/logs/ai-supervisor.log"
	if [[ -f "$pipeline_log" ]]; then
		# Extract pipeline errors with surrounding timestamp context (last 500 lines = ~last 2h)
		# Include the === AI Supervisor Run: TIMESTAMP === lines for context
		local recent_errors
		recent_errors=$(tail -500 "$pipeline_log" 2>/dev/null | awk '
			/=== AI Supervisor Run:/ { ts=$0 }
			/AI Actions Pipeline:.*error|AI Actions Pipeline:.*expected array|Result: rc=1/ {
				if (ts) print ts
				print $0
				ts=""
			}
		' | tail -20 || true)
		if [[ -n "$recent_errors" ]]; then
			output+="### Pipeline Errors (recent)\n\n"
			output+="These errors occurred in the action execution pipeline (with timestamps):\n\n"
			output+="\`\`\`\n"
			output+="$recent_errors\n"
			output+="\`\`\`\n\n"
			output+="If these are recurring (same error in multiple recent runs), create a \`create_improvement\` task to fix the root cause. If timestamps show errors are >1h old and recent runs succeeded, they may be already resolved.\n"
		fi
	fi

	printf '%b' "$output"
	return 0
}

#######################################
# Section 11: Auto-dispatch eligibility assessment (t1134)
# Scans open TODO.md tasks across all registered repos and evaluates
# each for auto-dispatch eligibility. Provides the AI reasoning engine
# with pre-computed eligibility data so it can propose #auto-dispatch
# tagging with recommended model tiers.
#
# Eligibility criteria:
#   1. Task has a clear, bounded description (not vague research)
#   2. No blocked-by with unresolved dependencies
#   3. No assignee already set
#   4. Estimated effort within worker capability (~30m to ~4h)
#      Exception (t1241): #bugfix + model:haiku + specific target → ~10m minimum
#   5. Task type matches patterns with >70% autonomous success rate
#
# Arguments:
#   $1 - primary repo path
# Outputs:
#   Markdown section to stdout
#######################################
build_auto_dispatch_eligibility_context() {
	local repo_path="${1:-$REPO_PATH}"
	local output="## Auto-Dispatch Eligibility Assessment (t1134)\n\n"
	output+="Open tasks evaluated for autonomous dispatch eligibility.\n"
	output+="Use \`propose_auto_dispatch\` action to recommend tagging eligible tasks.\n\n"

	# Collect all repos from DB + primary repo
	local all_repos=""
	if [[ -f "$SUPERVISOR_DB" ]]; then
		all_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	fi
	# Ensure primary repo is included
	if [[ -n "$repo_path" && -d "$repo_path" ]]; then
		if [[ -z "$all_repos" ]] || ! echo "$all_repos" | grep -qF "$repo_path"; then
			all_repos="${all_repos:+$all_repos
}$repo_path"
		fi
	fi

	if [[ -z "$all_repos" ]]; then
		output+="No repos found to scan.\n"
		printf '%b' "$output"
		return 0
	fi

	# Query pattern tracker for success rates by task type (if available)
	local pattern_db="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"
	local pattern_data=""
	if [[ -f "$pattern_db" ]]; then
		# Get success rates per task type keyword from pattern data
		# Look at tags containing common task type keywords
		pattern_data=$(sqlite3 "$pattern_db" "
			SELECT
				CASE
					WHEN tags LIKE '%feature%' OR content LIKE '%task:feature%' THEN 'feature'
					WHEN tags LIKE '%bugfix%' OR content LIKE '%task:bugfix%' THEN 'bugfix'
					WHEN tags LIKE '%refactor%' OR content LIKE '%task:refactor%' THEN 'refactor'
					WHEN tags LIKE '%docs%' OR content LIKE '%task:docs%' THEN 'docs'
					WHEN tags LIKE '%testing%' OR content LIKE '%task:testing%' THEN 'testing'
					WHEN tags LIKE '%code-review%' OR content LIKE '%task:code-review%' THEN 'code-review'
					WHEN tags LIKE '%enhancement%' THEN 'enhancement'
					WHEN tags LIKE '%automation%' THEN 'automation'
					ELSE 'other'
				END as task_type,
				SUM(CASE WHEN type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') THEN 1 ELSE 0 END) as successes,
				SUM(CASE WHEN type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') THEN 1 ELSE 0 END) as failures,
				COUNT(*) as total
			FROM learnings
			WHERE type IN ('SUCCESS_PATTERN', 'FAILURE_PATTERN', 'WORKING_SOLUTION', 'FAILED_APPROACH', 'ERROR_FIX')
			GROUP BY task_type
			HAVING total >= 3
			ORDER BY task_type;
		" 2>/dev/null || echo "")
	fi

	if [[ -n "$pattern_data" ]]; then
		output+="### Pattern Tracker Success Rates\n\n"
		output+="| Task Type | Successes | Failures | Total | Rate |\n"
		output+="|-----------|-----------|----------|-------|------|\n"
		while IFS='|' read -r ptype psuccess pfailure ptotal; do
			[[ -z "$ptype" ]] && continue
			local prate=0
			if [[ "$ptotal" -gt 0 ]]; then
				prate=$(((psuccess * 100) / ptotal))
			fi
			local rate_marker=""
			if [[ "$prate" -ge 70 ]]; then
				rate_marker=" (eligible)"
			fi
			output+="| $ptype | $psuccess | $pfailure | $ptotal | ${prate}%${rate_marker} |\n"
		done <<<"$pattern_data"
		output+="\nTask types with >=70% success rate are eligible for auto-dispatch.\n\n"
	else
		output+="### Pattern Tracker Success Rates\n\n"
		output+="No pattern data available yet. Default to allowing auto-dispatch for clear, bounded tasks.\n\n"
	fi

	# Scan each repo's TODO.md for eligible tasks
	local eligible_count=0
	local ineligible_count=0
	local already_tagged=0

	output+="### Task Eligibility\n\n"
	output+="| Repo | Task ID | Description | Estimate | Eligible | Reason | Recommended Model |\n"
	output+="|------|---------|-------------|----------|----------|--------|-------------------|\n"

	while IFS= read -r scan_repo; do
		[[ -z "$scan_repo" || ! -d "$scan_repo" ]] && continue
		local scan_todo="$scan_repo/TODO.md"
		[[ ! -f "$scan_todo" ]] && continue

		local repo_name
		repo_name=$(basename "$scan_repo")

		# Find open tasks without #auto-dispatch
		local open_tasks
		open_tasks=$(grep -E '^[[:space:]]*- \[ \] t[0-9]+' "$scan_todo" 2>/dev/null || true)
		[[ -z "$open_tasks" ]] && continue

		while IFS= read -r task_line; do
			[[ -z "$task_line" ]] && continue

			local tid
			tid=$(echo "$task_line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			[[ -z "$tid" ]] && continue

			# Skip already tagged tasks
			if echo "$task_line" | grep -q '#auto-dispatch'; then
				already_tagged=$((already_tagged + 1))
				continue
			fi

			# Skip tasks already in supervisor DB (already being managed)
			if [[ -f "$SUPERVISOR_DB" ]]; then
				local db_status
				db_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$tid")';" 2>/dev/null || echo "")
				if [[ -n "$db_status" ]]; then
					continue
				fi
			fi

			# Extract description (strip task ID and metadata)
			local desc
			desc=$(echo "$task_line" | sed -E 's/^[[:space:]]*- \[ \] t[0-9]+(\.[0-9]+)* //' | sed -E 's/ (model:|~[0-9]+[mh]|#[a-zA-Z0-9_-]+|ref:|logged:|blocked-by:|assignee:|started:|category:)[^ ]*//g' | head -c 80)

			# Extract estimate
			local estimate
			estimate=$(echo "$task_line" | grep -oE '~[0-9]+[mh]' | head -1 || echo "")

			# === Eligibility checks ===
			local eligible="yes"
			local reason=""
			local recommended_model="sonnet"

			# Check 1: Has assignee already set
			if echo "$task_line" | grep -qE 'assignee:'; then
				eligible="no"
				reason="has assignee"
			fi

			# Check 2: Has unresolved blocked-by dependencies
			if [[ "$eligible" == "yes" ]] && echo "$task_line" | grep -qE 'blocked-by:'; then
				local blocked_by
				blocked_by=$(echo "$task_line" | grep -oE 'blocked-by:t[0-9]+(\.[0-9]+)*' | sed 's/blocked-by://')
				if [[ -n "$blocked_by" ]]; then
					# Check if the blocking task is still open
					local blocker_done=true
					while IFS= read -r blocker_id; do
						[[ -z "$blocker_id" ]] && continue
						if grep -qE "^[[:space:]]*- \[ \] ${blocker_id}( |$)" "$scan_todo" 2>/dev/null; then
							blocker_done=false
							break
						fi
					done <<<"$blocked_by"
					if [[ "$blocker_done" == "false" ]]; then
						eligible="no"
						reason="blocked-by unresolved"
					fi
				fi
			fi

			# Check 3: Estimate within worker capability (~30m to ~4h)
			# Exception (t1241): trivial bugfix bypass — #bugfix + model:haiku + specific
			# file/function target in description → eligible down to ~10m (93% success rate)
			if [[ "$eligible" == "yes" && -n "$estimate" ]]; then
				local est_minutes=0
				if [[ "$estimate" =~ ~([0-9]+)h ]]; then
					est_minutes=$((${BASH_REMATCH[1]} * 60))
				elif [[ "$estimate" =~ ~([0-9]+)m ]]; then
					est_minutes=${BASH_REMATCH[1]}
				fi
				if [[ "$est_minutes" -gt 0 ]]; then
					if [[ "$est_minutes" -lt 30 ]]; then
						# Trivial bugfix bypass (t1241): allow ~10m+ if task meets all three criteria:
						# 1. Has #bugfix tag, 2. Has model:haiku, 3. Description contains a specific
						# file or function target (contains extension, function call, or path reference)
						local is_trivial_bugfix="no"
						if [[ "$est_minutes" -ge 10 ]] &&
							echo "$task_line" | grep -qE '#bugfix' &&
							echo "$task_line" | grep -qE 'model:haiku' &&
							echo "$desc" | grep -qE '(\.[a-z]{1,5}|[a-zA-Z_]+\(\)|\.sh|\.py|\.ts|\.js|in [a-zA-Z_/.-]+)'; then
							is_trivial_bugfix="yes"
						fi
						if [[ "$is_trivial_bugfix" == "yes" ]]; then
							reason="trivial bugfix bypass (t1241): #bugfix+haiku+specific target"
						else
							eligible="no"
							reason="estimate too small (<30m)"
						fi
					elif [[ "$est_minutes" -gt 240 ]]; then
						# Check if subtasks already exist for this task (t1214)
						local has_subtasks_count
						has_subtasks_count=$(grep -c "^[[:space:]]*- \[.\] ${tid}\." "$scan_todo" 2>/dev/null || echo 0)
						if [[ "$has_subtasks_count" -gt 0 ]]; then
							eligible="no"
							reason="has-subtasks: ${has_subtasks_count} subtask(s) exist — dispatch subtasks instead"
						else
							eligible="no"
							reason="estimate too large (>4h) — use create_subtasks to break down"
						fi
					fi
				fi
			fi

			# Check 4: Description clarity — reject vague/research tasks
			if [[ "$eligible" == "yes" ]]; then
				local lower_desc
				lower_desc=$(echo "$desc" | tr '[:upper:]' '[:lower:]')
				if echo "$lower_desc" | grep -qE '^(research|investigate|explore|look into|think about|consider|evaluate options)'; then
					eligible="no"
					reason="vague/research task"
				elif [[ ${#desc} -lt 10 ]]; then
					eligible="no"
					reason="description too short"
				fi
			fi

			# Check 5: Model recommendation based on estimate and task type
			if [[ "$eligible" == "yes" ]]; then
				# Extract model: field if present
				local existing_model
				existing_model=$(echo "$task_line" | grep -oE 'model:[a-z]+' | head -1 | sed 's/model://')
				if [[ -n "$existing_model" ]]; then
					recommended_model="$existing_model"
				else
					# Infer from estimate
					local est_minutes=0
					if [[ "$estimate" =~ ~([0-9]+)h ]]; then
						est_minutes=$((${BASH_REMATCH[1]} * 60))
					elif [[ "$estimate" =~ ~([0-9]+)m ]]; then
						est_minutes=${BASH_REMATCH[1]}
					fi
					if [[ "$est_minutes" -le 60 ]]; then
						recommended_model="sonnet"
					elif [[ "$est_minutes" -le 120 ]]; then
						recommended_model="sonnet"
					else
						recommended_model="opus"
					fi
				fi
				reason="clear spec, bounded scope"
				eligible_count=$((eligible_count + 1))
			else
				ineligible_count=$((ineligible_count + 1))
			fi

			output+="| $repo_name | $tid | ${desc:0:50} | ${estimate:-n/a} | $eligible | $reason | $recommended_model |\n"
		done <<<"$open_tasks"
	done <<<"$all_repos"

	output+="\n**Summary**: $eligible_count eligible, $ineligible_count ineligible, $already_tagged already tagged\n"
	output+="\nFor eligible tasks, use \`propose_auto_dispatch\` action with the task_id and recommended model.\n"
	output+="The executor adds a \`[proposed]\` prefix that requires one pulse cycle confirmation before actual tagging.\n"

	printf '%b' "$output"
	return 0
}

#######################################
# Section 12: Recently Fixed Systemic Issues (t1284)
# Shows improvement/bugfix tasks completed in the last 30 days so the AI
# reasoner doesn't re-create investigation tasks for already-fixed problems.
# The create_improvement dedup only checks 24h; this section provides broader
# awareness of recent fixes to prevent stale-data false positives.
#
# Arguments:
#   $1 - repo path
# Outputs:
#   Markdown section to stdout
#######################################
build_recent_fixes_context() {
	local repo_path="${1:-$REPO_PATH}"
	local dedup_days="${AI_IMPROVEMENT_DEDUP_DAYS:-30}"
	local output="## Recently Fixed Systemic Issues (last ${dedup_days}d)\n\n"
	output+="**IMPORTANT**: Do NOT create \`create_improvement\` tasks for problems listed here — they were already fixed.\n"
	output+="If the same symptom recurs, check whether the fix was effective before proposing new work.\n\n"

	local todo_file="${repo_path}/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		output+="*TODO.md not found*\n"
		printf '%b' "$output"
		return 0
	fi

	# Compute cutoff date (30 days ago)
	local cutoff_date
	cutoff_date=$(date -u -v-"${dedup_days}d" '+%Y-%m-%d' 2>/dev/null || date -u -d "${dedup_days} days ago" '+%Y-%m-%d' 2>/dev/null || echo "")

	if [[ -z "$cutoff_date" ]]; then
		output+="*Could not compute cutoff date*\n"
		printf '%b' "$output"
		return 0
	fi

	# Scan completed tasks with #bugfix, #self-improvement, or improvement-related keywords
	local found_fixes=""
	local fix_count=0
	while IFS= read -r task_line; do
		# Only include if completed: timestamp is within the dedup window
		local completed_date
		completed_date=$(printf '%s' "$task_line" | grep -oE 'completed:[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | sed 's/completed://')
		if [[ -z "$completed_date" || ! "$completed_date" > "$cutoff_date" ]]; then
			continue
		fi

		# Only include bugfix, self-improvement, or automation tasks
		local lower_line
		lower_line=$(printf '%s' "$task_line" | tr '[:upper:]' '[:lower:]')
		if ! printf '%s' "$lower_line" | grep -qE '#bugfix|#self-improvement|#automation|fix|investigate|hang|timeout|worker|supervisor|dispatch'; then
			continue
		fi

		local task_id
		task_id=$(printf '%s' "$task_line" | grep -oE 't[0-9]+(\.[0-9]+)?' | head -1)
		[[ -z "$task_id" ]] && continue

		local pr_ref
		pr_ref=$(printf '%s' "$task_line" | grep -oE 'pr:#[0-9]+' | head -1 || echo "")

		local excerpt
		excerpt=$(printf '%s' "$task_line" | sed -E 's/^[[:space:]]*- \[x\] t[0-9]+(\.[0-9]+)? //' | head -c 120)

		found_fixes+="- **$task_id** (completed: $completed_date${pr_ref:+, $pr_ref}): $excerpt\n"
		fix_count=$((fix_count + 1))
	done < <(grep -E '^\s*- \[x\] t[0-9]' "$todo_file" 2>/dev/null)

	if [[ "$fix_count" -eq 0 ]]; then
		output+="No systemic fixes found in the last ${dedup_days} days.\n"
	else
		output+="$fix_count fix(es) merged in the last ${dedup_days} days:\n\n"
		output+="$(printf '%b' "$found_fixes")"
	fi

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
