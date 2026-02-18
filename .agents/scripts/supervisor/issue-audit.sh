#!/usr/bin/env bash
# issue-audit.sh - Issue audit capabilities for AI Supervisor (t1085.6)
#
# Provides four audit functions that the AI reasoning engine can invoke:
#   1. Closed issue audit (48h) — verify PR linkage + evidence
#   2. Stale issue detection (7d no activity)
#   3. Orphan PR detection — PRs with no matching TODO.md task
#   4. Blocked task analysis (48h) — tasks blocked longer than threshold
#
# Output: structured JSON findings for the AI reasoning engine to act on.
# Each function returns a JSON array of findings with severity, description,
# and suggested actions.
#
# Used by: ai-reason.sh (provides audit data for AI reasoning context)
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), log_verbose(), sql_escape()
#   detect_repo_slug(), find_project_root()
#   find_task_issue_number(), task_has_completion_evidence()
#   find_closing_pr(), check_gh_auth()

# Configurable thresholds (override via environment)
AUDIT_CLOSED_ISSUE_HOURS="${AUDIT_CLOSED_ISSUE_HOURS:-48}"
AUDIT_STALE_ISSUE_DAYS="${AUDIT_STALE_ISSUE_DAYS:-7}"
AUDIT_BLOCKED_TASK_HOURS="${AUDIT_BLOCKED_TASK_HOURS:-48}"
AUDIT_MAX_ISSUES="${AUDIT_MAX_ISSUES:-200}"

#######################################
# Audit 1: Closed Issue Audit
# Checks issues closed in the last N hours for:
#   - Missing PR linkage (no closing PR referenced)
#   - Missing completion evidence (no verified: or pr:# in TODO.md)
#   - Closed without merged PR (closed manually or by bot without real work)
#
# Arguments:
#   $1 - repo path (optional, defaults to REPO_PATH)
#   $2 - hours threshold (optional, defaults to AUDIT_CLOSED_ISSUE_HOURS)
# Outputs:
#   JSON array of findings to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
audit_closed_issues() {
	local repo_path="${1:-$REPO_PATH}"
	local hours="${2:-$AUDIT_CLOSED_ISSUE_HOURS}"

	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		log_error "audit_closed_issues: cannot detect repo slug"
		echo '[]'
		return 1
	fi

	# Skip if gh CLI not available
	if ! command -v gh &>/dev/null; then
		log_warn "audit_closed_issues: gh CLI not available"
		echo '[]'
		return 0
	fi
	check_gh_auth 2>/dev/null || {
		echo '[]'
		return 0
	}

	local todo_file="$repo_path/TODO.md"
	local since_date=""
	# macOS date -v for relative dates
	since_date=$(date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

	if [[ -z "$since_date" ]]; then
		log_warn "audit_closed_issues: cannot compute date threshold"
		echo '[]'
		return 0
	fi

	log_verbose "audit_closed_issues: checking issues closed since $since_date ($hours hours)"

	# Fetch recently closed issues with closing context
	local closed_json=""
	closed_json=$(gh issue list --repo "$repo_slug" --state closed \
		--limit "$AUDIT_MAX_ISSUES" \
		--json number,title,closedAt,stateReason,labels \
		--jq "[.[] | select(.closedAt >= \"$since_date\")]" 2>/dev/null || echo "[]")

	local issue_count=""
	issue_count=$(printf '%s' "$closed_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$issue_count" -eq 0 ]]; then
		log_verbose "audit_closed_issues: no issues closed in last ${hours}h"
		echo '[]'
		return 0
	fi

	log_verbose "audit_closed_issues: examining $issue_count recently closed issues"

	local findings="[]"

	while IFS= read -r issue_line; do
		local issue_number=""
		issue_number=$(printf '%s' "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
		local issue_title=""
		issue_title=$(printf '%s' "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
		local closed_at=""
		closed_at=$(printf '%s' "$issue_line" | jq -r '.closedAt' 2>/dev/null || echo "")
		local state_reason=""
		state_reason=$(printf '%s' "$issue_line" | jq -r '.stateReason // "COMPLETED"' 2>/dev/null || echo "COMPLETED")

		[[ -z "$issue_number" ]] && continue

		# Extract task ID from issue title
		local task_id=""
		task_id=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")

		# Skip non-task issues (supervisor health, etc.)
		if [[ -z "$task_id" ]]; then
			continue
		fi

		# Check 1: Does the closed issue have a linked/closing PR?
		local linked_prs=""
		linked_prs=$(gh api "repos/${repo_slug}/issues/${issue_number}/timeline" \
			--jq '[.[] | select(.event == "cross-referenced" or .event == "connected") | .source.issue.number // empty] | unique' \
			2>/dev/null || echo "[]")

		local linked_pr_count=""
		linked_pr_count=$(printf '%s' "$linked_prs" | jq 'length' 2>/dev/null || echo "0")

		# Check 2: Does TODO.md have completion evidence for this task?
		local has_evidence=false
		if [[ -f "$todo_file" && -n "$task_id" ]]; then
			local task_line=""
			task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
			if [[ -n "$task_line" ]]; then
				if task_has_completion_evidence "$task_line" "$task_id" "$repo_slug" 2>/dev/null; then
					has_evidence=true
				fi
			fi
		fi

		# Check 3: Was there a merged PR for this task?
		local merged_pr=""
		if [[ -n "$task_id" ]]; then
			local pr_info=""
			pr_info=$(find_closing_pr "" "$task_id" "$repo_slug" 2>/dev/null || echo "")
			if [[ -n "$pr_info" ]]; then
				merged_pr="${pr_info%%|*}"
			fi
		fi

		# Generate findings based on checks
		local severity="low"
		local issues_found=()

		if [[ "$linked_pr_count" -eq 0 && -z "$merged_pr" ]]; then
			issues_found+=("no_pr_linkage")
			severity="high"
		fi

		if [[ "$has_evidence" == "false" ]]; then
			issues_found+=("no_completion_evidence")
			if [[ "$severity" != "high" ]]; then
				severity="medium"
			fi
		fi

		if [[ "$state_reason" == "NOT_PLANNED" ]]; then
			issues_found+=("closed_not_planned")
			severity="medium"
		fi

		# Only report if there are actual issues
		if [[ ${#issues_found[@]} -gt 0 ]]; then
			local issues_json=""
			issues_json=$(printf '%s\n' "${issues_found[@]}" | jq -R . | jq -s .)
			local finding=""
			finding=$(jq -n \
				--arg source "closed_issue_audit" \
				--arg severity "$severity" \
				--argjson issue_number "$issue_number" \
				--arg task_id "$task_id" \
				--arg title "$issue_title" \
				--arg closed_at "$closed_at" \
				--arg state_reason "$state_reason" \
				--argjson linked_pr_count "$linked_pr_count" \
				--arg merged_pr "${merged_pr:-none}" \
				--argjson has_evidence "$has_evidence" \
				--argjson issues "$issues_json" \
				'{
					source: $source,
					severity: $severity,
					issue_number: $issue_number,
					task_id: $task_id,
					title: $title,
					closed_at: $closed_at,
					state_reason: $state_reason,
					linked_pr_count: $linked_pr_count,
					merged_pr: $merged_pr,
					has_evidence: $has_evidence,
					issues: $issues,
					suggested_action: (
						if ($severity == "high") then "reopen_and_investigate"
						elif ($state_reason == "NOT_PLANNED") then "verify_cancellation_reason"
						else "add_completion_evidence"
						end
					)
				}')
			findings=$(printf '%s' "$findings" | jq --argjson f "$finding" '. + [$f]')
		fi
	done < <(printf '%s' "$closed_json" | jq -c '.[]' 2>/dev/null || true)

	local finding_count=""
	finding_count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")
	log_info "audit_closed_issues: $finding_count findings from $issue_count issues (${hours}h window)"

	printf '%s' "$findings"
	return 0
}

#######################################
# Audit 2: Stale Issue Detection
# Finds open issues with no activity (comments, label changes, etc.)
# for longer than the configured threshold.
#
# Arguments:
#   $1 - repo path (optional, defaults to REPO_PATH)
#   $2 - days threshold (optional, defaults to AUDIT_STALE_ISSUE_DAYS)
# Outputs:
#   JSON array of findings to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
audit_stale_issues() {
	local repo_path="${1:-$REPO_PATH}"
	local days="${2:-$AUDIT_STALE_ISSUE_DAYS}"

	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		log_error "audit_stale_issues: cannot detect repo slug"
		echo '[]'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		log_warn "audit_stale_issues: gh CLI not available"
		echo '[]'
		return 0
	fi
	check_gh_auth 2>/dev/null || {
		echo '[]'
		return 0
	}

	local stale_date=""
	stale_date=$(date -u -v-"${days}"d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

	if [[ -z "$stale_date" ]]; then
		log_warn "audit_stale_issues: cannot compute date threshold"
		echo '[]'
		return 0
	fi

	log_verbose "audit_stale_issues: checking for issues with no activity since $stale_date (${days}d)"

	# Fetch open issues with updatedAt
	local open_json=""
	open_json=$(gh issue list --repo "$repo_slug" --state open \
		--limit "$AUDIT_MAX_ISSUES" \
		--json number,title,updatedAt,createdAt,labels,assignees,comments \
		--jq "[.[] | select(.updatedAt < \"$stale_date\")]" 2>/dev/null || echo "[]")

	local stale_count=""
	stale_count=$(printf '%s' "$open_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$stale_count" -eq 0 ]]; then
		log_verbose "audit_stale_issues: no stale issues found (${days}d threshold)"
		echo '[]'
		return 0
	fi

	log_verbose "audit_stale_issues: found $stale_count stale issues"

	local findings="[]"
	local todo_file="$repo_path/TODO.md"

	while IFS= read -r issue_line; do
		local issue_number=""
		issue_number=$(printf '%s' "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
		local issue_title=""
		issue_title=$(printf '%s' "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
		local updated_at=""
		updated_at=$(printf '%s' "$issue_line" | jq -r '.updatedAt' 2>/dev/null || echo "")
		local created_at=""
		created_at=$(printf '%s' "$issue_line" | jq -r '.createdAt' 2>/dev/null || echo "")
		local comment_count=""
		comment_count=$(printf '%s' "$issue_line" | jq -r '.comments | length' 2>/dev/null || echo "0")
		local assignee=""
		assignee=$(printf '%s' "$issue_line" | jq -r '.assignees[0].login // "unassigned"' 2>/dev/null || echo "unassigned")
		local labels_str=""
		labels_str=$(printf '%s' "$issue_line" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")

		[[ -z "$issue_number" ]] && continue

		# Skip supervisor health issues and pinned monitoring issues
		if printf '%s' "$issue_title" | grep -qiE '^\[(Supervisor|Auditor|Auto-|Cron)'; then
			continue
		fi

		# Extract task ID
		local task_id=""
		task_id=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")

		# Calculate staleness in days
		local stale_days=0
		local updated_epoch=""
		local now_epoch=""
		updated_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${updated_at%%Z*}" +%s 2>/dev/null ||
			date -d "$updated_at" +%s 2>/dev/null || echo "0")
		now_epoch=$(date +%s)
		if [[ "$updated_epoch" -gt 0 ]]; then
			stale_days=$(((now_epoch - updated_epoch) / 86400))
		fi

		# Determine severity based on staleness
		local severity="low"
		if [[ "$stale_days" -ge 30 ]]; then
			severity="high"
		elif [[ "$stale_days" -ge 14 ]]; then
			severity="medium"
		fi

		# Check if task exists and is still open in TODO.md
		local todo_status="unknown"
		if [[ -f "$todo_file" && -n "$task_id" ]]; then
			if grep -qE "^\s*- \[x\] ${task_id} " "$todo_file" 2>/dev/null; then
				todo_status="completed"
				severity="high" # Completed task with open stale issue = drift
			elif grep -qE "^\s*- \[ \] ${task_id} " "$todo_file" 2>/dev/null; then
				todo_status="open"
			else
				todo_status="not_found"
			fi
		fi

		# Check if task is blocked
		local is_blocked=false
		if [[ -f "$todo_file" && -n "$task_id" ]]; then
			if grep -qE "^\s*- \[ \] ${task_id} .*blocked-by:" "$todo_file" 2>/dev/null; then
				is_blocked=true
			fi
		fi

		local suggested_action="request_status_update"
		if [[ "$todo_status" == "completed" ]]; then
			suggested_action="close_stale_issue"
		elif [[ "$is_blocked" == "true" ]]; then
			suggested_action="check_blockers"
		elif [[ "$stale_days" -ge 30 ]]; then
			suggested_action="consider_closing_or_reprioritizing"
		fi

		local finding=""
		finding=$(jq -n \
			--arg source "stale_issue_audit" \
			--arg severity "$severity" \
			--argjson issue_number "$issue_number" \
			--arg task_id "${task_id:-none}" \
			--arg title "$issue_title" \
			--arg updated_at "$updated_at" \
			--argjson stale_days "$stale_days" \
			--argjson comment_count "$comment_count" \
			--arg assignee "$assignee" \
			--arg labels "$labels_str" \
			--arg todo_status "$todo_status" \
			--argjson is_blocked "$is_blocked" \
			--arg suggested_action "$suggested_action" \
			'{
				source: $source,
				severity: $severity,
				issue_number: $issue_number,
				task_id: $task_id,
				title: $title,
				updated_at: $updated_at,
				stale_days: $stale_days,
				comment_count: $comment_count,
				assignee: $assignee,
				labels: $labels,
				todo_status: $todo_status,
				is_blocked: $is_blocked,
				suggested_action: $suggested_action
			}')
		findings=$(printf '%s' "$findings" | jq --argjson f "$finding" '. + [$f]')
	done < <(printf '%s' "$open_json" | jq -c '.[]' 2>/dev/null || true)

	local finding_count=""
	finding_count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")
	log_info "audit_stale_issues: $finding_count stale issues found (${days}d threshold)"

	printf '%s' "$findings"
	return 0
}

#######################################
# Audit 3: Orphan PR Detection
# Finds open PRs that don't have a matching task in TODO.md.
# Also detects PRs whose linked task is already completed or cancelled.
#
# Arguments:
#   $1 - repo path (optional, defaults to REPO_PATH)
# Outputs:
#   JSON array of findings to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
audit_orphan_prs() {
	local repo_path="${1:-$REPO_PATH}"

	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		log_error "audit_orphan_prs: cannot detect repo slug"
		echo '[]'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		log_warn "audit_orphan_prs: gh CLI not available"
		echo '[]'
		return 0
	fi
	check_gh_auth 2>/dev/null || {
		echo '[]'
		return 0
	}

	log_verbose "audit_orphan_prs: scanning open PRs for orphans"

	# Fetch all open PRs
	local prs_json=""
	prs_json=$(gh pr list --repo "$repo_slug" --state open \
		--limit "$AUDIT_MAX_ISSUES" \
		--json number,title,headRefName,createdAt,updatedAt,author,isDraft,reviewDecision \
		2>/dev/null || echo "[]")

	local pr_count=""
	pr_count=$(printf '%s' "$prs_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$pr_count" -eq 0 ]]; then
		log_verbose "audit_orphan_prs: no open PRs found"
		echo '[]'
		return 0
	fi

	log_verbose "audit_orphan_prs: examining $pr_count open PRs"

	local findings="[]"
	local todo_file="$repo_path/TODO.md"

	while IFS= read -r pr_line; do
		local pr_number=""
		pr_number=$(printf '%s' "$pr_line" | jq -r '.number' 2>/dev/null || echo "")
		local pr_title=""
		pr_title=$(printf '%s' "$pr_line" | jq -r '.title' 2>/dev/null || echo "")
		local branch=""
		branch=$(printf '%s' "$pr_line" | jq -r '.headRefName' 2>/dev/null || echo "")
		local created_at=""
		created_at=$(printf '%s' "$pr_line" | jq -r '.createdAt' 2>/dev/null || echo "")
		local updated_at=""
		updated_at=$(printf '%s' "$pr_line" | jq -r '.updatedAt' 2>/dev/null || echo "")
		local author=""
		author=$(printf '%s' "$pr_line" | jq -r '.author.login' 2>/dev/null || echo "unknown")
		local is_draft=""
		is_draft=$(printf '%s' "$pr_line" | jq -r '.isDraft' 2>/dev/null || echo "false")
		local review_decision=""
		review_decision=$(printf '%s' "$pr_line" | jq -r '.reviewDecision // "NONE"' 2>/dev/null || echo "NONE")

		[[ -z "$pr_number" ]] && continue

		# Extract task ID from PR title (format: "tNNN: description" or "tNNN.N: description")
		local task_id=""
		task_id=$(printf '%s' "$pr_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")

		# Also try extracting from branch name (format: feature/tNNN or feature/tNNN.N)
		if [[ -z "$task_id" ]]; then
			task_id=$(printf '%s' "$branch" | grep -oE 't[0-9]+(\.[0-9]+)*' || echo "")
		fi

		local issues_found=()
		local severity="low"
		local todo_status="unknown"

		if [[ -z "$task_id" ]]; then
			# No task ID found in title or branch — true orphan
			issues_found+=("no_task_id")
			severity="medium"
			todo_status="no_task_id"
		elif [[ -f "$todo_file" ]]; then
			# Check task status in TODO.md
			if grep -qE "^\s*- \[x\] ${task_id} " "$todo_file" 2>/dev/null; then
				todo_status="completed"
				issues_found+=("task_already_completed")
				severity="medium"
			elif grep -qE "^\s*- \[-\] ${task_id} " "$todo_file" 2>/dev/null; then
				todo_status="declined"
				issues_found+=("task_declined")
				severity="medium"
			elif grep -qE "^\s*- \[ \] ${task_id} " "$todo_file" 2>/dev/null; then
				todo_status="open"
				# Task exists and is open — not an orphan, skip
				continue
			else
				todo_status="not_found"
				issues_found+=("task_not_in_todo")
				severity="medium"
			fi
		fi

		# Calculate PR age in days
		local pr_age_days=0
		local created_epoch=""
		local now_epoch=""
		created_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${created_at%%Z*}" +%s 2>/dev/null ||
			date -d "$created_at" +%s 2>/dev/null || echo "0")
		now_epoch=$(date +%s)
		if [[ "$created_epoch" -gt 0 ]]; then
			pr_age_days=$(((now_epoch - created_epoch) / 86400))
		fi

		# Increase severity for old orphan PRs
		if [[ "$pr_age_days" -ge 14 && "$severity" != "high" ]]; then
			severity="high"
		fi

		# Only report if there are actual issues
		if [[ ${#issues_found[@]} -gt 0 ]]; then
			local issues_json=""
			issues_json=$(printf '%s\n' "${issues_found[@]}" | jq -R . | jq -s .)

			local suggested_action="investigate_and_close_or_link"
			if [[ "$todo_status" == "completed" ]]; then
				suggested_action="close_pr_task_done"
			elif [[ "$todo_status" == "declined" ]]; then
				suggested_action="close_pr_task_declined"
			elif [[ "$todo_status" == "no_task_id" ]]; then
				suggested_action="add_task_id_to_pr_title"
			fi

			local finding=""
			finding=$(jq -n \
				--arg source "orphan_pr_audit" \
				--arg severity "$severity" \
				--argjson pr_number "$pr_number" \
				--arg task_id "${task_id:-none}" \
				--arg title "$pr_title" \
				--arg branch "$branch" \
				--arg created_at "$created_at" \
				--arg updated_at "$updated_at" \
				--arg author "$author" \
				--argjson is_draft "$is_draft" \
				--arg review_decision "$review_decision" \
				--argjson pr_age_days "$pr_age_days" \
				--arg todo_status "$todo_status" \
				--argjson issues "$issues_json" \
				--arg suggested_action "$suggested_action" \
				'{
					source: $source,
					severity: $severity,
					pr_number: $pr_number,
					task_id: $task_id,
					title: $title,
					branch: $branch,
					created_at: $created_at,
					updated_at: $updated_at,
					author: $author,
					is_draft: $is_draft,
					review_decision: $review_decision,
					pr_age_days: $pr_age_days,
					todo_status: $todo_status,
					issues: $issues,
					suggested_action: $suggested_action
				}')
			findings=$(printf '%s' "$findings" | jq --argjson f "$finding" '. + [$f]')
		fi
	done < <(printf '%s' "$prs_json" | jq -c '.[]' 2>/dev/null || true)

	local finding_count=""
	finding_count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")
	log_info "audit_orphan_prs: $finding_count orphan PRs found from $pr_count open PRs"

	printf '%s' "$findings"
	return 0
}

#######################################
# Audit 4: Blocked Task Analysis
# Finds tasks that have been blocked for longer than the threshold.
# Checks whether blockers are resolved, identifies circular dependencies,
# and suggests unblocking actions.
#
# Arguments:
#   $1 - repo path (optional, defaults to REPO_PATH)
#   $2 - hours threshold (optional, defaults to AUDIT_BLOCKED_TASK_HOURS)
# Outputs:
#   JSON array of findings to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
audit_blocked_tasks() {
	local repo_path="${1:-$REPO_PATH}"
	local hours="${2:-$AUDIT_BLOCKED_TASK_HOURS}"

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		log_warn "audit_blocked_tasks: TODO.md not found at $todo_file"
		echo '[]'
		return 0
	fi

	log_verbose "audit_blocked_tasks: scanning for tasks blocked > ${hours}h"

	local findings="[]"
	local now_epoch=""
	now_epoch=$(date +%s)
	local threshold_seconds=$((hours * 3600))

	# Find all open tasks with blocked-by: field
	while IFS= read -r line; do
		local task_id=""
		task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		# Extract blocked-by dependencies
		local blocked_by=""
		blocked_by=$(printf '%s' "$line" | grep -oE 'blocked-by:[A-Za-z0-9.,]+' | head -1 | sed 's/blocked-by://' || echo "")
		[[ -z "$blocked_by" ]] && continue

		# Extract started timestamp (if available) to calculate block duration
		local started=""
		started=$(printf '%s' "$line" | grep -oE 'started:[0-9T:Z-]+' | head -1 | sed 's/started://' || echo "")

		# Extract logged date as fallback for duration calculation
		local logged=""
		logged=$(printf '%s' "$line" | grep -oE 'logged:[0-9-]+' | head -1 | sed 's/logged://' || echo "")

		# Calculate how long the task has been blocked
		local blocked_hours=0
		local reference_time=""
		if [[ -n "$started" ]]; then
			reference_time="$started"
		elif [[ -n "$logged" ]]; then
			reference_time="${logged}T00:00:00Z"
		fi

		if [[ -n "$reference_time" ]]; then
			local ref_epoch=""
			ref_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${reference_time%%Z*}" +%s 2>/dev/null ||
				date -d "$reference_time" +%s 2>/dev/null || echo "0")
			if [[ "$ref_epoch" -gt 0 ]]; then
				blocked_hours=$(((now_epoch - ref_epoch) / 3600))
			fi
		fi

		# Skip if not blocked long enough (unless we can't determine duration)
		if [[ "$blocked_hours" -gt 0 && "$blocked_hours" -lt "$hours" ]]; then
			continue
		fi

		# Analyze each blocker
		local blockers_resolved=0
		local blockers_total=0
		local blocker_details="[]"
		local _saved_ifs="$IFS"
		IFS=','
		for blocker_id in $blocked_by; do
			[[ -z "$blocker_id" ]] && continue
			blockers_total=$((blockers_total + 1))

			local blocker_status="unknown"
			local blocker_has_pr=false

			# Check blocker status in TODO.md
			if grep -qE "^\s*- \[x\] ${blocker_id} " "$todo_file" 2>/dev/null; then
				blocker_status="completed"
				blockers_resolved=$((blockers_resolved + 1))
			elif grep -qE "^\s*- \[-\] ${blocker_id} " "$todo_file" 2>/dev/null; then
				blocker_status="declined"
				blockers_resolved=$((blockers_resolved + 1))
			elif grep -qE "^\s*- \[ \] ${blocker_id} " "$todo_file" 2>/dev/null; then
				blocker_status="open"
				# Check if blocker has a PR in progress
				local blocker_line=""
				blocker_line=$(grep -E "^\s*- \[ \] ${blocker_id} " "$todo_file" | head -1 || echo "")
				if printf '%s' "$blocker_line" | grep -qE 'pr:#[0-9]+'; then
					blocker_has_pr=true
				fi
			else
				blocker_status="not_found"
				blockers_resolved=$((blockers_resolved + 1)) # Non-existent blocker = resolved
			fi

			# Check if blocker is itself blocked (chain detection)
			local blocker_is_blocked=false
			if grep -qE "^\s*- \[ \] ${blocker_id} .*blocked-by:" "$todo_file" 2>/dev/null; then
				blocker_is_blocked=true
			fi

			local detail=""
			detail=$(jq -n \
				--arg id "$blocker_id" \
				--arg status "$blocker_status" \
				--argjson has_pr "$blocker_has_pr" \
				--argjson is_blocked "$blocker_is_blocked" \
				'{id: $id, status: $status, has_pr: $has_pr, is_blocked: $is_blocked}')
			blocker_details=$(printf '%s' "$blocker_details" | jq --argjson d "$detail" '. + [$d]')
		done
		IFS="$_saved_ifs"

		# Determine severity
		local severity="low"
		if [[ "$blockers_resolved" -eq "$blockers_total" ]]; then
			severity="high"                          # All blockers resolved but task still marked blocked
		elif [[ "$blocked_hours" -ge 168 ]]; then # 7+ days
			severity="high"
		elif [[ "$blocked_hours" -ge "$hours" ]]; then
			severity="medium"
		fi

		# Determine suggested action
		local suggested_action="monitor"
		if [[ "$blockers_resolved" -eq "$blockers_total" ]]; then
			suggested_action="unblock_task"
		elif [[ "$blocked_hours" -ge 168 ]]; then
			suggested_action="escalate_or_decompose"
		else
			suggested_action="check_blocker_progress"
		fi

		# Extract description for context
		local description=""
		description=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[.\] t[0-9]+(\.[0-9]+)* //' |
			sed -E 's/ (#[a-z]|~[0-9]|→ |logged:|started:|completed:|ref:|actual:|blocked-by:|blocks:|assignee:|verified:).*//' ||
			echo "")

		local finding=""
		finding=$(jq -n \
			--arg source "blocked_task_audit" \
			--arg severity "$severity" \
			--arg task_id "$task_id" \
			--arg description "$description" \
			--arg blocked_by "$blocked_by" \
			--argjson blocked_hours "$blocked_hours" \
			--argjson blockers_total "$blockers_total" \
			--argjson blockers_resolved "$blockers_resolved" \
			--argjson blocker_details "$blocker_details" \
			--arg suggested_action "$suggested_action" \
			'{
				source: $source,
				severity: $severity,
				task_id: $task_id,
				description: $description,
				blocked_by: $blocked_by,
				blocked_hours: $blocked_hours,
				blockers_total: $blockers_total,
				blockers_resolved: $blockers_resolved,
				blocker_details: $blocker_details,
				suggested_action: $suggested_action
			}')
		findings=$(printf '%s' "$findings" | jq --argjson f "$finding" '. + [$f]')
	done < <(grep -E '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" || true)

	local finding_count=""
	finding_count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")
	log_info "audit_blocked_tasks: $finding_count blocked tasks found (${hours}h threshold)"

	printf '%s' "$findings"
	return 0
}

#######################################
# Run all audits and produce a combined report
# Arguments:
#   $1 - repo path (optional, defaults to REPO_PATH)
# Outputs:
#   JSON object with all audit results to stdout
# Returns:
#   0 on success
#######################################
run_full_audit() {
	local repo_path="${1:-$REPO_PATH}"

	log_info "issue-audit: running full audit suite"

	local closed_findings=""
	closed_findings=$(audit_closed_issues "$repo_path")

	local stale_findings=""
	stale_findings=$(audit_stale_issues "$repo_path")

	local orphan_findings=""
	orphan_findings=$(audit_orphan_prs "$repo_path")

	local blocked_findings=""
	blocked_findings=$(audit_blocked_tasks "$repo_path")

	# Count totals
	local closed_count=""
	closed_count=$(printf '%s' "$closed_findings" | jq 'length' 2>/dev/null || echo "0")
	local stale_count=""
	stale_count=$(printf '%s' "$stale_findings" | jq 'length' 2>/dev/null || echo "0")
	local orphan_count=""
	orphan_count=$(printf '%s' "$orphan_findings" | jq 'length' 2>/dev/null || echo "0")
	local blocked_count=""
	blocked_count=$(printf '%s' "$blocked_findings" | jq 'length' 2>/dev/null || echo "0")
	local total_count=$((closed_count + stale_count + orphan_count + blocked_count))

	# Count by severity across all findings
	local all_findings=""
	all_findings=$(printf '%s' "$closed_findings" | jq ". + $(printf '%s' "$stale_findings") + $(printf '%s' "$orphan_findings") + $(printf '%s' "$blocked_findings")")
	local high_count=""
	high_count=$(printf '%s' "$all_findings" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
	local medium_count=""
	medium_count=$(printf '%s' "$all_findings" | jq '[.[] | select(.severity == "medium")] | length' 2>/dev/null || echo "0")
	local low_count=""
	low_count=$(printf '%s' "$all_findings" | jq '[.[] | select(.severity == "low")] | length' 2>/dev/null || echo "0")

	local report=""
	report=$(jq -n \
		--arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--argjson total "$total_count" \
		--argjson high "$high_count" \
		--argjson medium "$medium_count" \
		--argjson low "$low_count" \
		--argjson closed_issues "$closed_findings" \
		--argjson stale_issues "$stale_findings" \
		--argjson orphan_prs "$orphan_findings" \
		--argjson blocked_tasks "$blocked_findings" \
		'{
			timestamp: $timestamp,
			summary: {
				total_findings: $total,
				by_severity: { high: $high, medium: $medium, low: $low },
				by_audit: {
					closed_issues: ($closed_issues | length),
					stale_issues: ($stale_issues | length),
					orphan_prs: ($orphan_prs | length),
					blocked_tasks: ($blocked_tasks | length)
				}
			},
			closed_issues: $closed_issues,
			stale_issues: $stale_issues,
			orphan_prs: $orphan_prs,
			blocked_tasks: $blocked_tasks
		}')

	log_info "issue-audit: complete — $total_count findings (high:$high_count medium:$medium_count low:$low_count)"

	printf '%s' "$report"
	return 0
}

#######################################
# Format audit findings as human-readable markdown
# Arguments:
#   $1 - JSON audit report (from run_full_audit)
# Outputs:
#   Markdown-formatted report to stdout
#######################################
format_audit_report() {
	local report="$1"

	local timestamp=""
	timestamp=$(printf '%s' "$report" | jq -r '.timestamp' 2>/dev/null || echo "unknown")
	local total=""
	total=$(printf '%s' "$report" | jq -r '.summary.total_findings' 2>/dev/null || echo "0")
	local high=""
	high=$(printf '%s' "$report" | jq -r '.summary.by_severity.high' 2>/dev/null || echo "0")
	local medium=""
	medium=$(printf '%s' "$report" | jq -r '.summary.by_severity.medium' 2>/dev/null || echo "0")
	local low=""
	low=$(printf '%s' "$report" | jq -r '.summary.by_severity.low' 2>/dev/null || echo "0")

	printf '## Issue Audit Report\n\n'
	printf '**Generated**: %s\n' "$timestamp"
	printf '**Total findings**: %s (high: %s, medium: %s, low: %s)\n\n' "$total" "$high" "$medium" "$low"

	# Closed issue findings
	local closed_count=""
	closed_count=$(printf '%s' "$report" | jq '.closed_issues | length' 2>/dev/null || echo "0")
	printf '### Closed Issue Audit (%s findings)\n\n' "$closed_count"
	if [[ "$closed_count" -gt 0 ]]; then
		printf '| Issue | Task | Severity | Issues | Action |\n'
		printf '| --- | --- | --- | --- | --- |\n'
		printf '%s' "$report" | jq -r '.closed_issues[] | "| #\(.issue_number) | \(.task_id) | \(.severity) | \(.issues | join(", ")) | \(.suggested_action) |"' 2>/dev/null || true
		printf '\n'
	else
		printf '_No issues found_\n\n'
	fi

	# Stale issue findings
	local stale_count=""
	stale_count=$(printf '%s' "$report" | jq '.stale_issues | length' 2>/dev/null || echo "0")
	printf '### Stale Issue Detection (%s findings)\n\n' "$stale_count"
	if [[ "$stale_count" -gt 0 ]]; then
		printf '| Issue | Task | Stale Days | Assignee | Action |\n'
		printf '| --- | --- | --- | --- | --- |\n'
		printf '%s' "$report" | jq -r '.stale_issues[] | "| #\(.issue_number) | \(.task_id) | \(.stale_days)d | \(.assignee) | \(.suggested_action) |"' 2>/dev/null || true
		printf '\n'
	else
		printf '_No stale issues found_\n\n'
	fi

	# Orphan PR findings
	local orphan_count=""
	orphan_count=$(printf '%s' "$report" | jq '.orphan_prs | length' 2>/dev/null || echo "0")
	printf '### Orphan PR Detection (%s findings)\n\n' "$orphan_count"
	if [[ "$orphan_count" -gt 0 ]]; then
		printf '| PR | Task | Age | Author | Status | Action |\n'
		printf '| --- | --- | --- | --- | --- | --- |\n'
		printf '%s' "$report" | jq -r '.orphan_prs[] | "| #\(.pr_number) | \(.task_id) | \(.pr_age_days)d | \(.author) | \(.todo_status) | \(.suggested_action) |"' 2>/dev/null || true
		printf '\n'
	else
		printf '_No orphan PRs found_\n\n'
	fi

	# Blocked task findings
	local blocked_count=""
	blocked_count=$(printf '%s' "$report" | jq '.blocked_tasks | length' 2>/dev/null || echo "0")
	printf '### Blocked Task Analysis (%s findings)\n\n' "$blocked_count"
	if [[ "$blocked_count" -gt 0 ]]; then
		printf '| Task | Blocked By | Hours | Resolved | Action |\n'
		printf '| --- | --- | --- | --- | --- |\n'
		printf '%s' "$report" | jq -r '.blocked_tasks[] | "| \(.task_id) | \(.blocked_by) | \(.blocked_hours)h | \(.blockers_resolved)/\(.blockers_total) | \(.suggested_action) |"' 2>/dev/null || true
		printf '\n'
	else
		printf '_No blocked tasks exceeding threshold_\n\n'
	fi

	return 0
}
