#!/usr/bin/env bash
# ai-actions.sh - AI Supervisor action executor (t1085.3)
#
# Executes validated actions from the AI reasoning engine's action plan.
# Each action type is validated before execution to prevent unintended changes.
#
# Used by: pulse.sh Phase 14 (AI Action Execution) — wired in t1085.5
# Depends on: ai-reason.sh (run_ai_reasoning), todo-sync.sh, issue-sync.sh
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), sql_escape()
#   commit_and_push_todo() (from todo-sync.sh)
#   find_task_issue_number() (from issue-sync.sh)
#   detect_repo_slug() (from supervisor-helper.sh)

# Action execution log directory (shares with ai-reason)
AI_ACTIONS_LOG_DIR="${AI_ACTIONS_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"

# Valid action types — any action not in this list is rejected
readonly AI_VALID_ACTION_TYPES="comment_on_issue create_task create_subtasks flag_for_review adjust_priority close_verified request_info create_improvement escalate_model"

# Maximum actions per execution cycle (safety limit)
AI_MAX_ACTIONS_PER_CYCLE="${AI_MAX_ACTIONS_PER_CYCLE:-10}"

# Dry-run mode — validate but don't execute (set via --dry-run flag or env)
AI_ACTIONS_DRY_RUN="${AI_ACTIONS_DRY_RUN:-false}"

#######################################
# Execute a validated action plan from the AI reasoning engine
# Arguments:
#   $1 - JSON action plan (array of action objects)
#   $2 - repo path
#   $3 - (optional) mode: "execute" (default), "dry-run", "validate-only"
# Outputs:
#   JSON execution report to stdout
# Returns:
#   0 on success (even if some actions failed), 1 on invalid input
#######################################
execute_action_plan() {
	local action_plan="$1"
	local repo_path="${2:-$REPO_PATH}"
	local mode="${3:-execute}"

	# Ensure log directory exists
	mkdir -p "$AI_ACTIONS_LOG_DIR"

	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	local action_log="$AI_ACTIONS_LOG_DIR/actions-${timestamp}.md"

	# Validate input is a JSON array
	local action_count
	action_count=$(printf '%s' "$action_plan" | jq 'length' 2>/dev/null || echo -1)

	if [[ "$action_count" -eq -1 ]]; then
		log_error "AI Actions: invalid JSON input"
		echo '{"error":"invalid_json","executed":0,"failed":0}'
		return 1
	fi

	if [[ "$action_count" -eq 0 ]]; then
		log_info "AI Actions: empty action plan — nothing to execute"
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	# Safety limit
	if [[ "$action_count" -gt "$AI_MAX_ACTIONS_PER_CYCLE" ]]; then
		log_warn "AI Actions: plan has $action_count actions, capping at $AI_MAX_ACTIONS_PER_CYCLE"
		action_plan=$(printf '%s' "$action_plan" | jq ".[0:$AI_MAX_ACTIONS_PER_CYCLE]")
		action_count="$AI_MAX_ACTIONS_PER_CYCLE"
	fi

	log_info "AI Actions: processing $action_count actions ($mode mode)"

	# Start log
	{
		echo "# AI Supervisor Action Execution Log"
		echo ""
		echo "Timestamp: $timestamp"
		echo "Mode: $mode"
		echo "Actions: $action_count"
		echo "Repo: $repo_path"
		echo ""
	} >"$action_log"

	# Resolve repo slug for GitHub operations
	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")

	# Process each action
	local executed=0
	local failed=0
	local skipped=0
	local results="[]"
	local i

	for ((i = 0; i < action_count; i++)); do
		local action
		action=$(printf '%s' "$action_plan" | jq ".[$i]")

		local action_type
		action_type=$(printf '%s' "$action" | jq -r '.type // "unknown"')

		local reasoning
		reasoning=$(printf '%s' "$action" | jq -r '.reasoning // "no reasoning provided"')

		# Step 1: Validate action type
		if ! validate_action_type "$action_type"; then
			log_warn "AI Actions: skipping invalid action type '$action_type'"
			skipped=$((skipped + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				'. + [{"index": $idx, "type": $type, "status": "skipped", "reason": "invalid_action_type"}]')
			{
				echo "## Action $((i + 1)): $action_type — SKIPPED (invalid type)"
				echo ""
			} >>"$action_log"
			continue
		fi

		# Step 2: Validate action-specific fields
		local validation_error
		validation_error=$(validate_action_fields "$action" "$action_type")
		if [[ -n "$validation_error" ]]; then
			log_warn "AI Actions: skipping $action_type — $validation_error"
			skipped=$((skipped + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				--arg reason "$validation_error" \
				'. + [{"index": $idx, "type": $type, "status": "skipped", "reason": $reason}]')
			{
				echo "## Action $((i + 1)): $action_type — SKIPPED ($validation_error)"
				echo ""
			} >>"$action_log"
			continue
		fi

		# Step 3: Execute (or simulate in dry-run/validate-only mode)
		if [[ "$mode" == "validate-only" ]]; then
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type — validated"
			skipped=$((skipped + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				'. + [{"index": $idx, "type": $type, "status": "validated"}]')
			{
				echo "## Action $((i + 1)): $action_type — VALIDATED"
				echo "Reasoning: $reasoning"
				echo ""
			} >>"$action_log"
			continue
		fi

		if [[ "$mode" == "dry-run" || "$AI_ACTIONS_DRY_RUN" == "true" ]]; then
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type — dry-run"
			executed=$((executed + 1))
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				'. + [{"index": $idx, "type": $type, "status": "dry_run"}]')
			{
				echo "## Action $((i + 1)): $action_type — DRY RUN"
				echo "Reasoning: $reasoning"
				echo ""
				echo '```json'
				printf '%s' "$action" | jq '.'
				echo '```'
				echo ""
			} >>"$action_log"
			continue
		fi

		# Execute the action
		local exec_result
		exec_result=$(execute_single_action "$action" "$action_type" "$repo_path" "$repo_slug" 2>>"$SUPERVISOR_LOG")
		local exec_rc=$?

		# Extract only the JSON portion from exec_result — git operations
		# (commit_and_push_todo) can leak stdout noise (e.g. "Updating ...",
		# "Fast-forward", "Created autostash") before the final JSON line.
		local exec_result_json
		exec_result_json=$(printf '%s' "$exec_result" | grep -E '^\{' | tail -1)
		if [[ -z "$exec_result_json" ]] || ! printf '%s' "$exec_result_json" | jq '.' &>/dev/null; then
			# Not valid JSON — wrap the entire result as a JSON string value
			exec_result_json=$(jq -Rn --arg v "$exec_result" '$v')
		fi

		if [[ $exec_rc -eq 0 ]]; then
			executed=$((executed + 1))
			log_info "AI Actions: [$((i + 1))/$action_count] $action_type — success"
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				--argjson r "$exec_result_json" \
				'. + [{"index": $idx, "type": $type, "status": "executed", "result": $r}]')
		else
			failed=$((failed + 1))
			log_warn "AI Actions: [$((i + 1))/$action_count] $action_type — failed"
			results=$(printf '%s' "$results" | jq \
				--argjson idx "$i" \
				--arg type "$action_type" \
				--arg error "$exec_result" \
				'. + [{"index": $idx, "type": $type, "status": "failed", "error": $error}]')
		fi

		{
			echo "## Action $((i + 1)): $action_type — $([ $exec_rc -eq 0 ] && echo "SUCCESS" || echo "FAILED")"
			echo "Reasoning: $reasoning"
			echo "Result: $exec_result"
			echo ""
		} >>"$action_log"
	done

	# Summary
	local summary
	summary=$(jq -n \
		--argjson executed "$executed" \
		--argjson failed "$failed" \
		--argjson skipped "$skipped" \
		--argjson actions "$results" \
		'{executed: $executed, failed: $failed, skipped: $skipped, actions: $actions}')

	{
		echo "## Summary"
		echo ""
		echo "- Executed: $executed"
		echo "- Failed: $failed"
		echo "- Skipped: $skipped"
		echo ""
	} >>"$action_log"

	log_info "AI Actions: complete (executed=$executed failed=$failed skipped=$skipped log=$action_log)"

	# Store execution event in DB
	db "$SUPERVISOR_DB" "
		INSERT INTO state_log (task_id, from_state, to_state, reason)
		VALUES ('ai-supervisor', 'actions', 'complete',
				'$(sql_escape "AI actions: $executed executed, $failed failed, $skipped skipped")');
	" 2>/dev/null || true

	printf '%s' "$summary"
	return 0
}

#######################################
# Validate that an action type is in the allowed list
# Arguments:
#   $1 - action type string
# Returns:
#   0 if valid, 1 if invalid
#######################################
validate_action_type() {
	local action_type="$1"
	local valid_type

	for valid_type in $AI_VALID_ACTION_TYPES; do
		if [[ "$action_type" == "$valid_type" ]]; then
			return 0
		fi
	done

	return 1
}

#######################################
# Validate action-specific required fields
# Arguments:
#   $1 - JSON action object
#   $2 - action type
# Returns:
#   Empty string if valid, error message if invalid
#######################################
validate_action_fields() {
	local action="$1"
	local action_type="$2"

	case "$action_type" in
	comment_on_issue)
		local issue_number body
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		body=$(printf '%s' "$action" | jq -r '.body // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$body" ]]; then
			echo "missing required field: body"
			return 0
		fi
		# Validate issue_number is a positive integer
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		;;
	create_task)
		local title
		title=$(printf '%s' "$action" | jq -r '.title // empty')
		if [[ -z "$title" ]]; then
			echo "missing required field: title"
			return 0
		fi
		;;
	create_subtasks)
		local parent_task_id subtasks
		parent_task_id=$(printf '%s' "$action" | jq -r '.parent_task_id // empty')
		subtasks=$(printf '%s' "$action" | jq -r '.subtasks // empty')
		if [[ -z "$parent_task_id" ]]; then
			echo "missing required field: parent_task_id"
			return 0
		fi
		if [[ -z "$subtasks" || "$subtasks" == "null" ]]; then
			echo "missing required field: subtasks (array)"
			return 0
		fi
		local subtask_count
		subtask_count=$(printf '%s' "$action" | jq '.subtasks | length' 2>/dev/null || echo 0)
		if [[ "$subtask_count" -eq 0 ]]; then
			echo "subtasks array is empty"
			return 0
		fi
		;;
	flag_for_review)
		local issue_number reason
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		reason=$(printf '%s' "$action" | jq -r '.reason // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$reason" ]]; then
			echo "missing required field: reason"
			return 0
		fi
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		;;
	adjust_priority)
		local task_id new_priority
		task_id=$(printf '%s' "$action" | jq -r '.task_id // empty')
		new_priority=$(printf '%s' "$action" | jq -r '.new_priority // empty')
		if [[ -z "$task_id" ]]; then
			echo "missing required field: task_id"
			return 0
		fi
		# new_priority is no longer strictly required — the executor infers it
		# from reasoning text if missing (see _exec_adjust_priority)
		;;
	close_verified)
		local issue_number pr_number
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		pr_number=$(printf '%s' "$action" | jq -r '.pr_number // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$pr_number" ]]; then
			echo "missing required field: pr_number (must prove merged PR exists)"
			return 0
		fi
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		if ! [[ "$pr_number" =~ ^[0-9]+$ ]] || [[ "$pr_number" -eq 0 ]]; then
			echo "pr_number must be a positive integer, got: $pr_number"
			return 0
		fi
		;;
	request_info)
		local issue_number questions
		issue_number=$(printf '%s' "$action" | jq -r '.issue_number // empty')
		questions=$(printf '%s' "$action" | jq -r '.questions // empty')
		if [[ -z "$issue_number" ]]; then
			echo "missing required field: issue_number"
			return 0
		fi
		if [[ -z "$questions" || "$questions" == "null" ]]; then
			echo "missing required field: questions (array)"
			return 0
		fi
		if ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [[ "$issue_number" -eq 0 ]]; then
			echo "issue_number must be a positive integer, got: $issue_number"
			return 0
		fi
		;;
	create_improvement)
		local title
		title=$(printf '%s' "$action" | jq -r '.title // empty')
		if [[ -z "$title" ]]; then
			echo "missing required field: title"
			return 0
		fi
		;;
	escalate_model)
		local task_id from_tier to_tier
		task_id=$(printf '%s' "$action" | jq -r '.task_id // empty')
		from_tier=$(printf '%s' "$action" | jq -r '.from_tier // empty')
		to_tier=$(printf '%s' "$action" | jq -r '.to_tier // empty')
		if [[ -z "$task_id" ]]; then
			echo "missing required field: task_id"
			return 0
		fi
		if [[ -z "$to_tier" ]]; then
			echo "missing required field: to_tier"
			return 0
		fi
		;;
	*)
		echo "unhandled action type: $action_type"
		return 0
		;;
	esac

	# Valid — return empty string
	echo ""
	return 0
}

#######################################
# Execute a single validated action
# Arguments:
#   $1 - JSON action object
#   $2 - action type
#   $3 - repo path
#   $4 - repo slug (owner/repo)
# Outputs:
#   JSON result to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
execute_single_action() {
	local action="$1"
	local action_type="$2"
	local repo_path="$3"
	local repo_slug="$4"

	case "$action_type" in
	comment_on_issue) _exec_comment_on_issue "$action" "$repo_slug" ;;
	create_task) _exec_create_task "$action" "$repo_path" ;;
	create_subtasks) _exec_create_subtasks "$action" "$repo_path" ;;
	flag_for_review) _exec_flag_for_review "$action" "$repo_slug" ;;
	adjust_priority) _exec_adjust_priority "$action" "$repo_path" ;;
	close_verified) _exec_close_verified "$action" "$repo_slug" ;;
	request_info) _exec_request_info "$action" "$repo_slug" ;;
	create_improvement) _exec_create_improvement "$action" "$repo_path" ;;
	escalate_model) _exec_escalate_model "$action" "$repo_path" ;;
	*)
		echo '{"error":"unhandled_action_type"}'
		return 1
		;;
	esac
}

#######################################
# Action: comment_on_issue
# Posts a comment on a GitHub issue
#######################################
_exec_comment_on_issue() {
	local action="$1"
	local repo_slug="$2"

	local issue_number body
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')
	body=$(printf '%s' "$action" | jq -r '.body')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# Verify issue exists before commenting
	if ! gh issue view "$issue_number" --repo "$repo_slug" --json number &>/dev/null; then
		echo "{\"error\":\"issue_not_found\",\"issue_number\":$issue_number}"
		return 1
	fi

	# Add AI supervisor attribution footer
	local full_body
	full_body="${body}

---
*Posted by AI Supervisor (automated reasoning cycle)*"

	if gh issue comment "$issue_number" --repo "$repo_slug" --body "$full_body" &>/dev/null; then
		echo "{\"commented\":true,\"issue_number\":$issue_number}"
		return 0
	else
		echo "{\"error\":\"comment_failed\",\"issue_number\":$issue_number}"
		return 1
	fi
}

#######################################
# Action: create_task
# Adds a new task to TODO.md via claim-task-id.sh
#######################################
_exec_create_task() {
	local action="$1"
	local repo_path="$2"

	local title description tags estimate model
	title=$(printf '%s' "$action" | jq -r '.title')
	description=$(printf '%s' "$action" | jq -r '.description // ""')
	tags=$(printf '%s' "$action" | jq -r '(.tags // []) | join(" ")')
	estimate=$(printf '%s' "$action" | jq -r '.estimate // "~1h"')
	model=$(printf '%s' "$action" | jq -r '.model // "sonnet"')

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		echo '{"error":"todo_file_not_found"}'
		return 1
	fi

	# Allocate task ID via claim-task-id.sh
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	local task_id=""

	if [[ -x "$claim_script" ]]; then
		local claim_output
		claim_output=$("$claim_script" --title "$title" --repo-path "$repo_path" 2>/dev/null || echo "")
		task_id=$(printf '%s' "$claim_output" | grep -oE 'task_id=t[0-9]+' | head -1 | sed 's/task_id=//')
	fi

	if [[ -z "$task_id" ]]; then
		# Fallback: use timestamp-based ID (will be reconciled later)
		task_id="t$(date +%s | tail -c 5)"
		log_warn "AI Actions: claim-task-id.sh unavailable, using fallback ID $task_id"
	fi

	# Build the task line
	local task_line="- [ ] $task_id $title"
	if [[ -n "$tags" ]]; then
		task_line="$task_line $tags"
	fi
	task_line="$task_line $estimate model:$model"
	if [[ -n "$description" ]]; then
		task_line="$task_line — $description"
	fi

	# Append to TODO.md (before the first blank line after the last task)
	# Find the "Backlog" or last task section and append there
	printf '\n%s\n' "$task_line" >>"$todo_file"

	# Commit and push (redirect stdout to log — git operations leak noise)
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$repo_path" "chore: AI supervisor created task $task_id" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	jq -n --arg task_id "$task_id" --arg title "$title" \
		'{"created": true, "task_id": $task_id, "title": $title}'
	return 0
}

#######################################
# Action: create_subtasks
# Breaks down an existing task into subtasks in TODO.md
#######################################
_exec_create_subtasks() {
	local action="$1"
	local repo_path="$2"

	local parent_task_id
	parent_task_id=$(printf '%s' "$action" | jq -r '.parent_task_id')

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		echo '{"error":"todo_file_not_found"}'
		return 1
	fi

	# Verify parent task exists in TODO.md
	if ! grep -q "^\s*- \[.\] $parent_task_id " "$todo_file" 2>/dev/null; then
		echo "{\"error\":\"parent_task_not_found\",\"parent_task_id\":\"$parent_task_id\"}"
		return 1
	fi

	# Count existing subtasks to determine next index
	local existing_subtask_count
	existing_subtask_count=$(grep -c "^\s*- \[.\] ${parent_task_id}\." "$todo_file" 2>/dev/null || echo 0)

	local subtask_count
	subtask_count=$(printf '%s' "$action" | jq '.subtasks | length')

	local created_ids=""
	local next_index=$((existing_subtask_count + 1))

	# Find the line number of the parent task to insert subtasks after it
	local parent_line_num
	parent_line_num=$(grep -n "^\s*- \[.\] $parent_task_id " "$todo_file" | head -1 | cut -d: -f1)

	if [[ -z "$parent_line_num" ]]; then
		echo "{\"error\":\"parent_task_line_not_found\"}"
		return 1
	fi

	# Build subtask lines
	local subtask_lines=""
	local j
	for ((j = 0; j < subtask_count; j++)); do
		local subtask
		subtask=$(printf '%s' "$action" | jq ".subtasks[$j]")

		local sub_title sub_tags sub_estimate sub_model
		sub_title=$(printf '%s' "$subtask" | jq -r '.title // "Untitled subtask"')
		sub_tags=$(printf '%s' "$subtask" | jq -r '(.tags // []) | join(" ")')
		sub_estimate=$(printf '%s' "$subtask" | jq -r '.estimate // "~30m"')
		sub_model=$(printf '%s' "$subtask" | jq -r '.model // "sonnet"')

		local sub_id="${parent_task_id}.${next_index}"
		local sub_line="  - [ ] $sub_id $sub_title"
		if [[ -n "$sub_tags" ]]; then
			sub_line="$sub_line $sub_tags"
		fi
		sub_line="$sub_line $sub_estimate model:$sub_model"

		subtask_lines="${subtask_lines}${sub_line}\n"
		created_ids="${created_ids}${sub_id},"
		next_index=$((next_index + 1))
	done

	# Find the insertion point: after the parent task and any existing subtasks
	local insert_after=$parent_line_num
	# Skip existing subtasks (indented lines starting with the parent ID pattern)
	local total_lines
	total_lines=$(wc -l <"$todo_file" | tr -d ' ')
	local check_line=$((parent_line_num + 1))
	while [[ $check_line -le $total_lines ]]; do
		local line_content
		line_content=$(sed -n "${check_line}p" "$todo_file")
		if [[ "$line_content" =~ ^[[:space:]]+- ]]; then
			insert_after=$check_line
			check_line=$((check_line + 1))
		else
			break
		fi
	done

	# Insert subtask lines after the insertion point
	local temp_file
	temp_file=$(mktemp)
	{
		head -n "$insert_after" "$todo_file"
		printf '%b' "$subtask_lines"
		tail -n "+$((insert_after + 1))" "$todo_file"
	} >"$temp_file"
	mv "$temp_file" "$todo_file"

	# Commit and push (redirect stdout to log — git operations leak noise)
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$repo_path" "chore: AI supervisor created subtasks for $parent_task_id" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	# Remove trailing comma from created_ids
	created_ids="${created_ids%,}"

	echo "{\"created\":true,\"parent_task_id\":\"$parent_task_id\",\"subtask_ids\":\"$created_ids\",\"count\":$subtask_count}"
	return 0
}

#######################################
# Action: flag_for_review
# Labels an issue for human review and posts a comment explaining why
#######################################
_exec_flag_for_review() {
	local action="$1"
	local repo_slug="$2"

	local issue_number reason
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')
	reason=$(printf '%s' "$action" | jq -r '.reason')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# Verify issue exists
	if ! gh issue view "$issue_number" --repo "$repo_slug" --json number &>/dev/null; then
		echo "{\"error\":\"issue_not_found\",\"issue_number\":$issue_number}"
		return 1
	fi

	# Add "needs-review" label (create if it doesn't exist)
	gh label create "needs-review" --repo "$repo_slug" --description "Flagged for human review by AI supervisor" --color "D93F0B" 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-review" 2>/dev/null || true

	# Post comment explaining why
	local comment_body
	comment_body="## Flagged for Human Review

**Reason:** $reason

This issue has been flagged by the AI supervisor for human review. Please assess and take appropriate action.

---
*Flagged by AI Supervisor (automated reasoning cycle)*"

	gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null || true

	echo "{\"flagged\":true,\"issue_number\":$issue_number}"
	return 0
}

#######################################
# Action: adjust_priority
# Logs a priority adjustment recommendation
# NOTE: Does not reorder TODO.md (too risky for automated changes).
# Instead, posts the recommendation as a comment on the task's GitHub issue.
#######################################
_exec_adjust_priority() {
	local action="$1"
	local repo_path="$2"

	local task_id new_priority reasoning
	task_id=$(printf '%s' "$action" | jq -r '.task_id')
	new_priority=$(printf '%s' "$action" | jq -r '.new_priority // empty')
	reasoning=$(printf '%s' "$action" | jq -r '.reasoning // "No reasoning provided"')

	# Infer priority from reasoning if the AI omitted the field (common pattern —
	# the AI has omitted new_priority in 13+ actions across 5+ cycles)
	if [[ -z "$new_priority" || "$new_priority" == "null" ]]; then
		if printf '%s' "$reasoning" | grep -qi 'critical\|urgent\|blocker\|blocking'; then
			new_priority="critical"
		elif printf '%s' "$reasoning" | grep -qi 'high\|important\|prioriti'; then
			new_priority="high"
		elif printf '%s' "$reasoning" | grep -qi 'low\|minor\|defer'; then
			new_priority="low"
		else
			# Default to high — the AI is recommending a change, usually an escalation
			new_priority="high"
		fi
		log_warn "AI Actions: adjust_priority inferred new_priority='$new_priority' from reasoning (field was missing)"
	fi

	# Find the task's GitHub issue number
	local issue_number=""
	if declare -f find_task_issue_number &>/dev/null; then
		issue_number=$(find_task_issue_number "$task_id" "$repo_path" 2>/dev/null || echo "")
	fi

	local repo_slug=""
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")

	if [[ -n "$issue_number" && -n "$repo_slug" ]] && command -v gh &>/dev/null; then
		local comment_body
		comment_body="## Priority Adjustment Recommendation

**Task:** $task_id
**Recommended priority:** $new_priority
**Reasoning:** $reasoning

This is a recommendation from the AI supervisor. A human should review and decide whether to act on it.

---
*Recommended by AI Supervisor (automated reasoning cycle)*"

		gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null || true
	fi

	# Log to DB for tracking
	db "$SUPERVISOR_DB" "
		INSERT INTO state_log (task_id, from_state, to_state, reason)
		VALUES ('$(sql_escape "$task_id")', 'priority', '$(sql_escape "$new_priority")',
				'$(sql_escape "AI priority recommendation: $reasoning")');
	" 2>/dev/null || true

	echo "{\"recommended\":true,\"task_id\":\"$task_id\",\"new_priority\":\"$new_priority\"}"
	return 0
}

#######################################
# Action: close_verified
# Closes a GitHub issue ONLY if a merged PR is verified
# This is the most safety-critical action — requires proof of merged PR
#######################################
_exec_close_verified() {
	local action="$1"
	local repo_slug="$2"

	local issue_number pr_number
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')
	pr_number=$(printf '%s' "$action" | jq -r '.pr_number')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# CRITICAL: Verify the PR is actually merged
	local pr_state
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")

	if [[ "$pr_state" != "MERGED" ]]; then
		echo "{\"error\":\"pr_not_merged\",\"pr_number\":$pr_number,\"pr_state\":\"$pr_state\"}"
		return 1
	fi

	# Verify the PR has actual file changes (not empty)
	local changed_files
	changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json changedFiles --jq '.changedFiles' 2>/dev/null || echo 0)

	if [[ "$changed_files" -eq 0 ]]; then
		echo "{\"error\":\"pr_has_no_changes\",\"pr_number\":$pr_number}"
		return 1
	fi

	# Verify the issue exists and is open
	local issue_state
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")

	if [[ "$issue_state" != "OPEN" ]]; then
		echo "{\"error\":\"issue_not_open\",\"issue_number\":$issue_number,\"issue_state\":\"$issue_state\"}"
		return 1
	fi

	# Close with a comment explaining the verification
	local close_comment
	close_comment="## Verified Complete

This issue has been verified as complete:
- **PR:** #$pr_number (merged, $changed_files files changed)
- **Verification:** Automated check confirmed PR is merged with real deliverables

---
*Closed by AI Supervisor (automated verification)*"

	gh issue comment "$issue_number" --repo "$repo_slug" --body "$close_comment" &>/dev/null || true
	gh issue close "$issue_number" --repo "$repo_slug" --reason completed &>/dev/null || {
		echo "{\"error\":\"close_failed\",\"issue_number\":$issue_number}"
		return 1
	}

	echo "{\"closed\":true,\"issue_number\":$issue_number,\"pr_number\":$pr_number,\"changed_files\":$changed_files}"
	return 0
}

#######################################
# Action: request_info
# Posts a structured information request on a GitHub issue
#######################################
_exec_request_info() {
	local action="$1"
	local repo_slug="$2"

	local issue_number
	issue_number=$(printf '%s' "$action" | jq -r '.issue_number')

	if [[ -z "$repo_slug" ]]; then
		echo '{"error":"no_repo_slug"}'
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		echo '{"error":"gh_cli_not_available"}'
		return 1
	fi

	# Verify issue exists
	if ! gh issue view "$issue_number" --repo "$repo_slug" --json number &>/dev/null; then
		echo "{\"error\":\"issue_not_found\",\"issue_number\":$issue_number}"
		return 1
	fi

	# Build questions list
	local questions_md=""
	local q_count
	q_count=$(printf '%s' "$action" | jq '.questions | length')
	local q
	for ((q = 0; q < q_count; q++)); do
		local question
		question=$(printf '%s' "$action" | jq -r ".questions[$q]")
		questions_md="${questions_md}$((q + 1)). ${question}\n"
	done

	# Add "needs-info" label
	gh label create "needs-info" --repo "$repo_slug" --description "Additional information requested" --color "0075CA" 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-info" 2>/dev/null || true

	local comment_body
	comment_body="## Information Requested

To make progress on this issue, we need some additional information:

$(printf '%b' "$questions_md")
Please provide the requested details so we can proceed.

---
*Requested by AI Supervisor (automated reasoning cycle)*"

	if gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null; then
		echo "{\"requested\":true,\"issue_number\":$issue_number,\"questions\":$q_count}"
		return 0
	else
		echo "{\"error\":\"comment_failed\",\"issue_number\":$issue_number}"
		return 1
	fi
}

#######################################
# Action: create_improvement
# Creates a self-improvement task in TODO.md (like create_task but
# ensures #self-improvement tag and category metadata)
#######################################
_exec_create_improvement() {
	local action="$1"
	local repo_path="$2"

	local title description tags estimate model category
	title=$(printf '%s' "$action" | jq -r '.title')
	description=$(printf '%s' "$action" | jq -r '.description // ""')
	tags=$(printf '%s' "$action" | jq -r '(.tags // []) | join(" ")')
	estimate=$(printf '%s' "$action" | jq -r '.estimate // "~1h"')
	model=$(printf '%s' "$action" | jq -r '.model // "sonnet"')
	category=$(printf '%s' "$action" | jq -r '.category // "general"')

	# Ensure #self-improvement and #auto-dispatch tags are present
	if [[ "$tags" != *"#self-improvement"* ]]; then
		tags="$tags #self-improvement"
	fi
	if [[ "$tags" != *"#auto-dispatch"* ]]; then
		tags="$tags #auto-dispatch"
	fi

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		echo '{"error":"todo_file_not_found"}'
		return 1
	fi

	# Allocate task ID via claim-task-id.sh
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	local task_id=""

	if [[ -x "$claim_script" ]]; then
		local claim_output
		claim_output=$("$claim_script" --title "$title" --repo-path "$repo_path" 2>/dev/null || echo "")
		task_id=$(printf '%s' "$claim_output" | grep -oE 'task_id=t[0-9]+' | head -1 | sed 's/task_id=//')
	fi

	if [[ -z "$task_id" ]]; then
		task_id="t$(date +%s | tail -c 5)"
		log_warn "AI Actions: claim-task-id.sh unavailable, using fallback ID $task_id"
	fi

	# Build the task line with category metadata
	local task_line="- [ ] $task_id $title $tags $estimate model:$model"
	if [[ -n "$category" && "$category" != "general" ]]; then
		task_line="$task_line category:$category"
	fi
	if [[ -n "$description" ]]; then
		task_line="$task_line — $description"
	fi

	printf '\n%s\n' "$task_line" >>"$todo_file"

	# Redirect stdout to log — git operations leak noise into function output
	if declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo "$repo_path" "chore: AI supervisor created improvement task $task_id" >>"$SUPERVISOR_LOG" 2>&1 || true
	fi

	jq -n --arg task_id "$task_id" --arg title "$title" --arg category "$category" \
		'{"created": true, "task_id": $task_id, "title": $title, "category": $category}'
	return 0
}

#######################################
# Action: escalate_model
# Updates a task's model tier in the supervisor DB and TODO.md
#######################################
_exec_escalate_model() {
	local action="$1"
	local repo_path="$2"

	local task_id from_tier to_tier reasoning
	task_id=$(printf '%s' "$action" | jq -r '.task_id')
	from_tier=$(printf '%s' "$action" | jq -r '.from_tier // "unknown"')
	to_tier=$(printf '%s' "$action" | jq -r '.to_tier')
	reasoning=$(printf '%s' "$action" | jq -r '.reasoning // ""')

	# Update model tier in supervisor DB if task exists there
	if [[ -n "$SUPERVISOR_DB" && -f "$SUPERVISOR_DB" ]]; then
		local db_task_exists
		db_task_exists=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE task_id = '$task_id';" 2>/dev/null || echo 0)
		if [[ "$db_task_exists" -gt 0 ]]; then
			db "$SUPERVISOR_DB" "UPDATE tasks SET model = '$to_tier' WHERE task_id = '$task_id';" 2>/dev/null || true
			log_info "AI Actions: escalated $task_id model in DB: $from_tier -> $to_tier"
		fi
	fi

	# Update model:X in TODO.md if present
	local todo_file="$repo_path/TODO.md"
	if [[ -f "$todo_file" ]]; then
		if grep -q "^\s*- \[.\] $task_id " "$todo_file" 2>/dev/null; then
			# Replace model:old with model:new on the task line
			if grep "^\s*- \[.\] $task_id " "$todo_file" | grep -q "model:"; then
				sed -i.bak "s/\(- \[.\] $task_id .*\)model:[a-z]*/\1model:$to_tier/" "$todo_file"
				rm -f "${todo_file}.bak"
			else
				# No model: field — append it
				sed -i.bak "s/\(- \[.\] $task_id .*\)/\1 model:$to_tier/" "$todo_file"
				rm -f "${todo_file}.bak"
			fi

			# Redirect stdout to log — git operations leak noise into function output
			if declare -f commit_and_push_todo &>/dev/null; then
				commit_and_push_todo "$repo_path" "chore: AI supervisor escalated $task_id model $from_tier -> $to_tier" >>"$SUPERVISOR_LOG" 2>&1 || true
			fi
		fi
	fi

	# Log the escalation event in state_log
	if [[ -n "$SUPERVISOR_DB" && -f "$SUPERVISOR_DB" ]]; then
		db "$SUPERVISOR_DB" "
			INSERT INTO state_log (task_id, from_state, to_state, reason)
			VALUES ('$task_id', 'model:$from_tier', 'model:$to_tier',
					'AI escalation: $reasoning');
		" 2>/dev/null || true
	fi

	echo "{\"escalated\":true,\"task_id\":\"$task_id\",\"from_tier\":\"$from_tier\",\"to_tier\":\"$to_tier\"}"
	return 0
}

#######################################
# Run the full AI reasoning + action execution pipeline
# Convenience function that chains ai-reason.sh → ai-actions.sh
# Arguments:
#   $1 - repo path
#   $2 - (optional) mode: "full" (default), "dry-run"
# Returns:
#   0 on success, 1 on failure
#######################################
run_ai_actions_pipeline() {
	local repo_path="${1:-$REPO_PATH}"
	local mode="${2:-full}"

	# Step 1: Run reasoning to get action plan
	local action_plan
	action_plan=$(run_ai_reasoning "$repo_path" "$mode" 2>/dev/null)
	local reason_rc=$?

	if [[ $reason_rc -ne 0 ]]; then
		log_warn "AI Actions Pipeline: reasoning failed (rc=$reason_rc)"
		echo '{"error":"reasoning_failed","actions":[]}'
		return 1
	fi

	# Handle empty output — concurrency guard or other silent skip
	if [[ -z "$action_plan" ]]; then
		log_info "AI Actions Pipeline: reasoning returned empty output (skipped)"
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	# Check if the result is a skip/error object rather than an action array
	local plan_obj_type
	plan_obj_type=$(printf '%s' "$action_plan" | jq 'type' 2>/dev/null || echo "")
	if [[ "$plan_obj_type" == '"object"' ]]; then
		local is_skipped is_error
		is_skipped=$(printf '%s' "$action_plan" | jq 'has("skipped")' 2>/dev/null || echo "false")
		is_error=$(printf '%s' "$action_plan" | jq 'has("error")' 2>/dev/null || echo "false")
		if [[ "$is_skipped" == "true" ]]; then
			local skip_reason
			skip_reason=$(printf '%s' "$action_plan" | jq -r '.skipped // "unknown"')
			log_info "AI Actions Pipeline: reasoning skipped ($skip_reason)"
			echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
			return 0
		fi
		if [[ "$is_error" == "true" ]]; then
			local error_msg
			error_msg=$(printf '%s' "$action_plan" | jq -r '.error // "unknown"')
			log_warn "AI Actions Pipeline: reasoning returned error: $error_msg"
			echo "$action_plan"
			return 1
		fi
	fi

	# Verify we got an array
	local plan_type
	plan_type=$(printf '%s' "$action_plan" | jq 'type' 2>/dev/null || echo "")
	if [[ "$plan_type" != '"array"' ]]; then
		log_warn "AI Actions Pipeline: expected array, got $plan_type"
		echo '{"error":"invalid_plan_type","actions":[]}'
		return 1
	fi

	local plan_count
	plan_count=$(printf '%s' "$action_plan" | jq 'length' 2>/dev/null || echo 0)

	if [[ "$plan_count" -eq 0 ]]; then
		log_info "AI Actions Pipeline: no actions proposed"
		echo '{"executed":0,"failed":0,"skipped":0,"actions":[]}'
		return 0
	fi

	# Step 2: Execute the action plan
	local exec_mode="execute"
	if [[ "$mode" == "dry-run" ]]; then
		exec_mode="dry-run"
	fi

	execute_action_plan "$action_plan" "$repo_path" "$exec_mode"
	return $?
}

#######################################
# CLI entry point for standalone testing
# Usage: ai-actions.sh [--mode execute|dry-run|validate-only] [--repo /path] [--plan <json>]
#        ai-actions.sh pipeline [--mode full|dry-run] [--repo /path]
#######################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# Source dependencies
	# shellcheck source=_common.sh
	source "$SCRIPT_DIR/_common.sh"
	# shellcheck source=ai-context.sh
	source "$SCRIPT_DIR/ai-context.sh"
	# shellcheck source=ai-reason.sh
	source "$SCRIPT_DIR/ai-reason.sh"

	# Colour codes
	BLUE="${BLUE:-\033[0;34m}"
	GREEN="${GREEN:-\033[0;32m}"
	YELLOW="${YELLOW:-\033[1;33m}"
	RED="${RED:-\033[0;31m}"
	NC="${NC:-\033[0m}"

	# Default paths
	SUPERVISOR_DB="${SUPERVISOR_DB:-$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db}"
	SUPERVISOR_LOG="${SUPERVISOR_LOG:-$HOME/.aidevops/.agent-workspace/supervisor/cron.log}"
	REPO_PATH="${REPO_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	# Stub functions if not available from sourced modules
	if ! declare -f detect_repo_slug &>/dev/null; then
		detect_repo_slug() {
			local repo_path="${1:-.}"
			git -C "$repo_path" remote get-url origin 2>/dev/null |
				sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#' || echo ""
			return 0
		}
	fi

	if ! declare -f commit_and_push_todo &>/dev/null; then
		commit_and_push_todo() {
			log_warn "commit_and_push_todo stub — skipping commit"
			return 0
		}
	fi

	if ! declare -f find_task_issue_number &>/dev/null; then
		find_task_issue_number() {
			local task_id="${1:-}"
			local project_root="${2:-.}"
			local todo_file="$project_root/TODO.md"
			if [[ -f "$todo_file" ]]; then
				grep -oE "ref:GH#[0-9]+" "$todo_file" |
					head -1 | sed 's/ref:GH#//' || echo ""
			fi
			return 0
		}
	fi

	# Parse args
	mode="execute"
	repo_path="$REPO_PATH"
	plan=""
	subcommand=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		pipeline)
			subcommand="pipeline"
			shift
			;;
		--mode)
			mode="$2"
			shift 2
			;;
		--repo)
			repo_path="$2"
			shift 2
			;;
		--plan)
			plan="$2"
			shift 2
			;;
		--dry-run)
			mode="dry-run"
			shift
			;;
		--help | -h)
			echo "Usage: ai-actions.sh [--mode execute|dry-run|validate-only] [--repo /path] [--plan <json>]"
			echo "       ai-actions.sh pipeline [--mode full|dry-run] [--repo /path]"
			echo ""
			echo "Execute AI supervisor action plans."
			echo ""
			echo "Options:"
			echo "  --mode execute|dry-run|validate-only   Execution mode (default: execute)"
			echo "  --repo /path                           Repository path (default: git root)"
			echo "  --plan <json>                          JSON action plan (required unless pipeline)"
			echo "  --dry-run                              Shorthand for --mode dry-run"
			echo "  --help                                 Show this help"
			echo ""
			echo "Subcommands:"
			echo "  pipeline                               Run full reasoning + execution pipeline"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		esac
	done

	if [[ "$subcommand" == "pipeline" ]]; then
		run_ai_actions_pipeline "$repo_path" "$mode"
	elif [[ -n "$plan" ]]; then
		execute_action_plan "$plan" "$repo_path" "$mode"
	else
		echo "Error: --plan <json> is required (or use 'pipeline' subcommand)" >&2
		exit 1
	fi
fi
