#!/usr/bin/env bash
# sanity-check.sh - AI-powered adversarial state verification for the supervisor
#
# Replaces the previous deterministic sanity checks (t1316) with AI reasoning.
# Instead of 4 hardcoded contradiction checks, the AI analyzes the full state
# snapshot (TODO.md, DB, system) and decides what's stuck and how to fix it.
#
# The AI can detect novel stall patterns that hardcoded checks would miss,
# and can reason about ambiguous cases (e.g., "is this task really stuck or
# just slow?") instead of applying rigid time thresholds.
#
# Invoked by: pulse.sh Phase 0.9 (after all deterministic phases, before dispatch)
# Frequency: every pulse when zero tasks are dispatchable
# Cost: AI reasoning gated behind SUPERVISOR_SANITY_AI (default: true)
#        Rate-limited via cooldown (SUPERVISOR_SANITY_AI_COOLDOWN, default 300s)
#
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   cmd_unclaim(), cmd_transition(), cmd_reset()
#   resolve_ai_cli(), resolve_model() (from dispatch.sh)
#   portable_timeout() (from _common.sh)
#   commit_and_push_todo() (from todo-sync.sh)

# Sanity check AI toggle (default: enabled)
SUPERVISOR_SANITY_AI="${SUPERVISOR_SANITY_AI:-true}"

# Cooldown between AI sanity checks (seconds, default 5 min)
SUPERVISOR_SANITY_AI_COOLDOWN="${SUPERVISOR_SANITY_AI_COOLDOWN:-300}"

# AI timeout for sanity check reasoning (seconds)
SUPERVISOR_SANITY_AI_TIMEOUT="${SUPERVISOR_SANITY_AI_TIMEOUT:-120}"

# Log directory for sanity check AI reasoning
SANITY_AI_LOG_DIR="${SANITY_AI_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"

#######################################
# Phase 0.9: Sanity check — AI-powered stall diagnosis
#
# Called when the pulse finds zero dispatchable tasks but open tasks exist.
# Gathers state data and asks the AI to identify contradictions and fixes.
#
# Args:
#   $1 - repo path
# Returns:
#   Number of issues found and fixed (via stdout)
#   0 on success
#######################################
run_sanity_check() {
	local repo_path="${1:-$REPO_PATH}"
	local todo_file="$repo_path/TODO.md"
	local fixed=0

	if [[ ! -f "$todo_file" ]]; then
		echo "$fixed"
		return 0
	fi

	ensure_db

	log_info "Phase 0.9: Sanity check — AI-powered stall diagnosis"

	# Gate: check if AI sanity is enabled and cooldown has elapsed
	if [[ "$SUPERVISOR_SANITY_AI" != "true" ]]; then
		log_info "Phase 0.9: AI sanity check disabled (SUPERVISOR_SANITY_AI=false)"
		_log_queue_stall_reasons "$repo_path"
		echo "$fixed"
		return 0
	fi

	if ! _sanity_ai_cooldown_elapsed; then
		log_info "Phase 0.9: AI sanity check cooldown not elapsed, skipping"
		_log_queue_stall_reasons "$repo_path"
		echo "$fixed"
		return 0
	fi

	# Gather state snapshot for AI reasoning
	local state_snapshot
	state_snapshot=$(_build_sanity_state_snapshot "$repo_path")

	# Resolve AI CLI
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "Phase 0.9: No AI CLI available, falling back to stall logging"
		_log_queue_stall_reasons "$repo_path"
		echo "$fixed"
		return 0
	}

	local ai_model
	ai_model=$(resolve_model "sonnet" "$ai_cli" 2>/dev/null) || {
		log_warn "Phase 0.9: No model available, falling back to stall logging"
		_log_queue_stall_reasons "$repo_path"
		echo "$fixed"
		return 0
	}

	# Build the reasoning prompt
	local prompt
	prompt=$(_build_sanity_prompt "$state_snapshot")

	# Log the prompt for auditability
	mkdir -p "$SANITY_AI_LOG_DIR"
	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	local reason_log="$SANITY_AI_LOG_DIR/sanity-${timestamp}.md"
	{
		echo "# Sanity Check AI Reasoning Log"
		echo ""
		echo "Timestamp: $timestamp"
		echo "Repo: $repo_path"
		echo "Model: $ai_model"
		echo ""
		echo "## State Snapshot"
		echo ""
		echo "$state_snapshot"
		echo ""
		echo "## Prompt"
		echo ""
		echo "$prompt"
		echo ""
	} >"$reason_log"

	# Spawn AI reasoning
	log_info "Phase 0.9: Spawning AI reasoning ($ai_model)"
	local ai_result=""
	local ai_timeout="${SUPERVISOR_SANITY_AI_TIMEOUT:-120}"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "sanity-check-${timestamp}" \
			"$prompt" 2>/dev/null || echo "")
		# Strip ANSI escape codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Log the AI response
	{
		echo "## AI Response"
		echo ""
		echo "Response length: $(printf '%s' "$ai_result" | wc -c | tr -d ' ') bytes"
		echo ""
		echo '```'
		echo "$ai_result"
		echo '```'
		echo ""
	} >>"$reason_log"

	# Parse the JSON action plan
	local action_plan
	action_plan=$(_extract_sanity_actions "$ai_result")

	if [[ -z "$action_plan" || "$action_plan" == "null" || "$action_plan" == "[]" ]]; then
		log_info "Phase 0.9: AI found no fixable issues"
		_log_queue_stall_reasons "$repo_path"
		_record_sanity_ai_run
		echo "$fixed"
		return 0
	fi

	# Execute the actions
	local action_count
	action_count=$(printf '%s' "$action_plan" | jq 'length' 2>/dev/null || echo 0)
	log_info "Phase 0.9: AI proposed $action_count fix(es)"

	local i
	for ((i = 0; i < action_count; i++)); do
		local action
		action=$(printf '%s' "$action_plan" | jq ".[$i]")
		local action_type
		action_type=$(printf '%s' "$action" | jq -r '.action // "unknown"')

		local exec_result
		exec_result=$(_execute_sanity_action "$action" "$action_type" "$repo_path")
		local exec_rc=$?

		if [[ $exec_rc -eq 0 ]]; then
			fixed=$((fixed + 1))
			log_success "  Phase 0.9: executed $action_type — $exec_result"
		else
			log_warn "  Phase 0.9: $action_type failed — $exec_result"
		fi

		{
			echo "## Action $((i + 1)): $action_type — $([ $exec_rc -eq 0 ] && echo "SUCCESS" || echo "FAILED")"
			echo "Result: $exec_result"
			echo ""
		} >>"$reason_log"
	done

	# Record the run for cooldown tracking
	_record_sanity_ai_run

	# Summary
	if [[ "$fixed" -gt 0 ]]; then
		log_success "Phase 0.9: Sanity check fixed $fixed issue(s)"

		# Record pattern for observability
		local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
		if [[ -x "$pattern_helper" ]]; then
			"$pattern_helper" record \
				--type "SELF_HEAL_PATTERN" \
				--task "supervisor" \
				--model "$ai_model" \
				--detail "Phase 0.9 AI sanity check: fixed $fixed issue(s) on stalled queue" \
				2>/dev/null || true
		fi
	else
		log_info "Phase 0.9: Sanity check found no fixable issues"
		_log_queue_stall_reasons "$repo_path"
	fi

	echo "$fixed"
	return 0
}

#######################################
# Build a state snapshot for the AI to reason about
# Gathers: TODO.md open tasks, DB state, system state (worktrees, PIDs)
# Args:
#   $1 - repo path
# Returns:
#   Structured text on stdout
#######################################
_build_sanity_state_snapshot() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"
	local snapshot=""

	# 1. Open tasks from TODO.md with metadata
	snapshot+="### Open Tasks (TODO.md)\n"
	local open_tasks
	open_tasks=$(grep -E '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || echo "")
	if [[ -n "$open_tasks" ]]; then
		snapshot+="$open_tasks\n"
	else
		snapshot+="(none)\n"
	fi
	snapshot+="\n"

	# 2. DB task states (non-terminal)
	snapshot+="### Active DB Tasks\n"
	local db_tasks
	db_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, COALESCE(error,''), COALESCE(retries,0), COALESCE(max_retries,3),
		       COALESCE(model,''), COALESCE(pr_url,''),
		       CAST((julianday('now') - julianday(COALESCE(updated_at, created_at))) * 24 * 60 AS INTEGER) as mins_stale
		FROM tasks
		WHERE repo = '$(sql_escape "$repo_path")'
		AND status NOT IN ('complete', 'verified', 'deployed', 'cancelled')
		ORDER BY status, id;
	" 2>/dev/null || echo "")
	if [[ -n "$db_tasks" ]]; then
		snapshot+="id|status|error|retries|max_retries|model|pr_url|mins_stale\n"
		snapshot+="$db_tasks\n"
	else
		snapshot+="(none)\n"
	fi
	snapshot+="\n"

	# 3. Failed/blocked tasks in DB (potential stall causes)
	snapshot+="### Failed/Blocked DB Tasks\n"
	local failed_tasks
	failed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, COALESCE(error,''), COALESCE(retries,0), COALESCE(max_retries,3)
		FROM tasks
		WHERE repo = '$(sql_escape "$repo_path")'
		AND status IN ('failed', 'blocked')
		ORDER BY updated_at DESC
		LIMIT 20;
	" 2>/dev/null || echo "")
	if [[ -n "$failed_tasks" ]]; then
		snapshot+="id|status|error|retries|max_retries\n"
		snapshot+="$failed_tasks\n"
	else
		snapshot+="(none)\n"
	fi
	snapshot+="\n"

	# 4. Active PID files (running workers)
	snapshot+="### Active Worker PIDs\n"
	local supervisor_dir
	supervisor_dir=$(dirname "$SUPERVISOR_DB")
	if [[ -d "$supervisor_dir/pids" ]]; then
		local pid_file
		for pid_file in "$supervisor_dir/pids"/*.pid; do
			[[ -f "$pid_file" ]] || continue
			local pid_task
			pid_task=$(basename "$pid_file" .pid)
			local pid_val
			pid_val=$(cat "$pid_file" 2>/dev/null || echo "")
			local pid_alive="dead"
			if [[ -n "$pid_val" ]] && kill -0 "$pid_val" 2>/dev/null; then
				pid_alive="alive"
			fi
			snapshot+="$pid_task: PID=$pid_val ($pid_alive)\n"
		done
	fi
	snapshot+="\n"

	# 5. DB orphans (tasks in DB not in TODO.md)
	snapshot+="### Potential DB Orphans\n"
	local orphans
	orphans=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status FROM tasks
		WHERE repo = '$(sql_escape "$repo_path")'
		AND status IN ('queued', 'dispatched', 'running')
		ORDER BY id;
	" 2>/dev/null || echo "")
	if [[ -n "$orphans" ]]; then
		while IFS='|' read -r oid ostatus; do
			[[ -z "$oid" ]] && continue
			local escaped_oid
			escaped_oid=$(printf '%s' "$oid" | sed 's/\./\\./g')
			if ! grep -qE "^[[:space:]]*- \[.\] ${escaped_oid}( |$)" "$todo_file" 2>/dev/null; then
				snapshot+="$oid ($ostatus): IN DB but NOT in TODO.md\n"
			fi
		done <<<"$orphans"
	fi
	snapshot+="\n"

	# 6. Pipeline phase health (t1336)
	# Check if critical pipeline phases are actually working by examining
	# recent log output. Phase 3 (ai-lifecycle) was silently broken for days
	# because gather_task_state referenced a non-existent column — every task
	# failed with "could not gather state" but nothing flagged it.
	snapshot+="### Pipeline Phase Health\n"
	local log_file="${SUPERVISOR_LOG:-$HOME/.aidevops/logs/supervisor.log}"
	if [[ -f "$log_file" ]]; then
		# Phase 3: check last ai-lifecycle summary line
		local last_lifecycle
		last_lifecycle=$(grep 'ai-lifecycle.*evaluated.*actioned' "$log_file" 2>/dev/null | tail -1 || echo "")
		if [[ -n "$last_lifecycle" ]]; then
			local eval_count action_count
			eval_count=$(echo "$last_lifecycle" | grep -oE 'evaluated [0-9]+' | grep -oE '[0-9]+' || echo "0")
			action_count=$(echo "$last_lifecycle" | grep -oE 'actioned [0-9]+' | grep -oE '[0-9]+' || echo "0")
			snapshot+="Phase 3 (ai-lifecycle): last run evaluated=$eval_count actioned=$action_count\n"
			if [[ "$eval_count" == "0" ]]; then
				# Count how many consecutive 0-evaluated runs
				local zero_streak
				zero_streak=$(grep -c 'ai-lifecycle.*evaluated 0' "$log_file" 2>/dev/null || echo "0")
				snapshot+="WARNING: Phase 3 evaluated 0 tasks ($zero_streak consecutive zero-runs in log)\n"
			fi
		else
			snapshot+="Phase 3 (ai-lifecycle): no recent runs found in log\n"
		fi

		# Check for repeated "could not gather state" errors
		local gather_failures
		gather_failures=$(grep -c 'could not gather state' "$log_file" 2>/dev/null || echo "0")
		if [[ "$gather_failures" -gt 10 ]]; then
			snapshot+="WARNING: $gather_failures 'could not gather state' errors in log — possible schema drift or query bug\n"
		fi

		# Phase 2b: check for stall/underutilisation entries
		local stall_count underutil_count
		stall_count=$(grep -c 'Dispatch stall detected' "$log_file" 2>/dev/null || echo "0")
		underutil_count=$(grep -c 'Concurrency underutilised' "$log_file" 2>/dev/null || echo "0")
		if [[ "$stall_count" -gt 5 ]]; then
			snapshot+="WARNING: $stall_count dispatch stalls in log\n"
		fi
		if [[ "$underutil_count" -gt 5 ]]; then
			snapshot+="WARNING: $underutil_count concurrency underutilisation events in log\n"
		fi
	else
		snapshot+="(log file not found)\n"
	fi
	snapshot+="\n"

	# 7. Schema validation (t1336)
	# Verify that key queries used by supervisor modules reference columns
	# that actually exist in the tasks table. This catches the exact bug where
	# gather_task_state referenced worker_pid after it was removed.
	snapshot+="### Schema Validation\n"
	local actual_columns
	actual_columns=$(sqlite3 "$SUPERVISOR_DB" "PRAGMA table_info(tasks);" 2>/dev/null | cut -d'|' -f2 | tr '\n' ',' || echo "")
	if [[ -n "$actual_columns" ]]; then
		# Check for known query columns that must exist
		local required_cols="id status pr_url repo branch worktree error rebase_attempts retries max_retries model session_id"
		local missing_cols=""
		for col in $required_cols; do
			if ! echo ",$actual_columns" | grep -q ",$col,"; then
				missing_cols="${missing_cols}${col} "
			fi
		done
		if [[ -n "$missing_cols" ]]; then
			snapshot+="CRITICAL: Missing columns in tasks table: $missing_cols\n"
			snapshot+="Queries referencing these columns will silently fail!\n"
		else
			snapshot+="All required columns present in tasks table\n"
		fi
	else
		snapshot+="Could not read tasks schema\n"
	fi
	snapshot+="\n"

	# 8. Cross-repo issue tag truthfulness (t1336)
	# Compare GitHub issue labels (status:*) against actual DB state.
	# Catches drift where GH says "status:in-review" but DB says "queued".
	snapshot+="### Cross-Repo Issue Tag Truthfulness\n"
	local all_repos
	all_repos=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks WHERE repo IS NOT NULL AND repo != '';" 2>/dev/null || echo "")
	if [[ -n "$all_repos" ]]; then
		while IFS= read -r check_repo; do
			[[ -z "$check_repo" || ! -d "$check_repo" ]] && continue
			local check_slug
			check_slug=$(detect_repo_slug "$check_repo" 2>/dev/null || echo "")
			[[ -z "$check_slug" ]] && continue
			local repo_name
			repo_name=$(basename "$check_repo")

			# Get tasks with both DB status and GH issue
			local db_tasks_with_issues
			db_tasks_with_issues=$(db -separator '|' "$SUPERVISOR_DB" "
				SELECT id, status, issue_url FROM tasks
				WHERE repo = '$(sql_escape "$check_repo")'
				AND issue_url IS NOT NULL AND issue_url != ''
				AND status NOT IN ('cancelled')
				ORDER BY id;
			" 2>/dev/null || echo "")

			if [[ -z "$db_tasks_with_issues" ]]; then
				continue
			fi

			local drift_count=0
			while IFS='|' read -r dtid dtstatus dtissue; do
				[[ -z "$dtid" || -z "$dtissue" ]] && continue
				# Extract issue number
				local issue_num
				issue_num=$(echo "$dtissue" | grep -oE '[0-9]+$' || echo "")
				[[ -z "$issue_num" ]] && continue

				# Get GH labels for this issue (cached per-pulse is fine)
				local gh_labels
				gh_labels=$(gh issue view "$issue_num" --repo "$check_slug" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

				# Map DB status to expected GH label
				local expected_label=""
				case "$dtstatus" in
				queued) expected_label="status:queued" ;;
				running | dispatched) expected_label="status:claimed" ;;
				pr_review | review_triage) expected_label="status:in-review" ;;
				blocked) expected_label="status:blocked" ;;
				complete | verified | deployed) expected_label="status:in-review" ;; # PR submitted
				esac

				if [[ -n "$expected_label" ]] && ! echo "$gh_labels" | grep -q "$expected_label"; then
					snapshot+="DRIFT ($repo_name): $dtid DB=$dtstatus but GH#$issue_num labels=[$gh_labels] (expected $expected_label)\n"
					drift_count=$((drift_count + 1))
				fi
			done <<<"$db_tasks_with_issues"

			if [[ "$drift_count" -eq 0 ]]; then
				snapshot+="$repo_name: all issue tags match DB state\n"
			else
				snapshot+="$repo_name: $drift_count tag drift(s) found\n"
			fi
		done <<<"$all_repos"
	else
		snapshot+="(no repos in DB)\n"
	fi
	snapshot+="\n"

	# 9. Identity context
	local identity
	identity=$(get_aidevops_identity 2>/dev/null || whoami)
	snapshot+="### Context\n"
	snapshot+="Local identity: $identity\n"
	snapshot+="Repo: $repo_path\n"

	printf '%b' "$snapshot"
	return 0
}

#######################################
# Build the AI prompt for sanity check reasoning
# Args:
#   $1 - state snapshot text
# Returns:
#   Full prompt on stdout
#######################################
_build_sanity_prompt() {
	local state_snapshot="$1"

	cat <<PROMPT
You are a supervisor sanity checker for an automated task dispatch system. The queue is stalled — there are open tasks but none are dispatchable. Your job is to find contradictions between the TODO.md state, the database state, and the system state, then propose specific fixes.

## State Snapshot

$state_snapshot

## What to Look For

1. **DB-failed tasks with TODO.md claims**: If the DB says a task failed/blocked but TODO.md still has assignee:/started: fields, the claim is stale. Strip it so the task can be re-assessed.

2. **Failed blockers holding up chains**: If a task's blocked-by: dependency has permanently failed (retries exhausted), the dependent will wait forever. Either reset the blocker for retry or remove the blocked-by field.

3. **Tasks eligible for dispatch but missing #auto-dispatch**: If a task has model:, an estimate (~Xh), no blockers, no assignee, and no blocked-by, it's probably dispatchable. Recommend adding #auto-dispatch.

4. **DB orphans**: Tasks in the DB with non-terminal status (queued/dispatched/running) that don't exist in TODO.md. These consume batch slots. Cancel them.

5. **Stale claims**: Tasks with assignee:/started: but no corresponding running worker in the DB or PID files. The claim may be from a dead session.

6. **Pipeline phase failures**: Check the "Pipeline Phase Health" section. If Phase 3 evaluated 0 tasks for multiple consecutive runs, or there are many "could not gather state" errors, the pipeline is broken — likely a schema drift or query bug. Recommend "log_only" with a clear diagnosis so a human can investigate.

7. **Schema drift**: Check the "Schema Validation" section. If any required columns are missing, this is CRITICAL — queries referencing those columns silently return empty results. Recommend "log_only" with urgency.

8. **Issue tag drift**: Check the "Cross-Repo Issue Tag Truthfulness" section. If GitHub issue labels don't match DB state, recommend "log_only" with the specific drifts so the label sync can be triggered.

9. **Any other contradiction** you can identify between the state sources.

## Output Format

Respond with ONLY a JSON array of fix actions. No markdown fencing, no explanation.

Each action object must have:
- "action": one of "unclaim", "reset", "cancel_orphan", "remove_blocker", "add_auto_dispatch", "log_only"
- "task_id": the task ID to act on
- "reasoning": why this fix is needed (one sentence)
- For "remove_blocker": include "blocker_id" (the failed blocker to remove)
- For "log_only": include "message" (what to log for human review)

Example:
[
  {"action": "unclaim", "task_id": "t123", "reasoning": "DB says failed but TODO.md has active claim"},
  {"action": "cancel_orphan", "task_id": "t456", "reasoning": "In DB as queued but missing from TODO.md"},
  {"action": "remove_blocker", "task_id": "t789", "blocker_id": "t456", "reasoning": "Blocker t456 permanently failed (3/3 retries)"},
  {"action": "add_auto_dispatch", "task_id": "t101", "reasoning": "Has model:sonnet, ~2h estimate, no blockers — eligible for dispatch"},
  {"action": "log_only", "task_id": "pipeline", "message": "Phase 3 evaluated 0 tasks for 5 consecutive runs — possible schema drift in gather_task_state query"}
]

If nothing needs fixing, return: []

Respond with ONLY the JSON array.
PROMPT
	return 0
}

#######################################
# Extract JSON action plan from AI response
# Reuses the same extraction logic as ai-reason.sh
# Args:
#   $1 - raw AI response
# Returns:
#   JSON array on stdout, or empty string
#######################################
_extract_sanity_actions() {
	local response="$1"

	if [[ -z "$response" ]]; then
		echo ""
		return 0
	fi

	# Try direct JSON parse
	local parsed
	parsed=$(printf '%s' "$response" | jq '.' 2>/dev/null)
	if [[ $? -eq 0 && -n "$parsed" ]]; then
		local is_array
		is_array=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
		if [[ "$is_array" == '"array"' ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try extracting from ```json block
	local json_block
	json_block=$(printf '%s' "$response" | awk '
		/^```json/ { capture=1; block=""; next }
		/^```$/ && capture { capture=0; last_block=block; next }
		capture { block = block (block ? "\n" : "") $0 }
		END { if (capture && block) print block; else if (last_block) print last_block }
	')
	if [[ -n "$json_block" ]]; then
		parsed=$(printf '%s' "$json_block" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			printf '%s' "$parsed"
			return 0
		fi
	fi

	# Try finding a JSON array in the response
	local bracket_json
	bracket_json=$(printf '%s' "$response" | awk '
		/^[[:space:]]*\[/ { capture=1; block="" }
		capture { block = block (block ? "\n" : "") $0 }
		/^[[:space:]]*\]/ && capture { capture=0; last_block=block }
		END { if (last_block) print last_block }
	')
	if [[ -n "$bracket_json" ]]; then
		parsed=$(printf '%s' "$bracket_json" | jq '.' 2>/dev/null)
		if [[ $? -eq 0 && -n "$parsed" ]]; then
			local arr_type
			arr_type=$(printf '%s' "$parsed" | jq 'type' 2>/dev/null || echo "")
			if [[ "$arr_type" == '"array"' ]]; then
				printf '%s' "$parsed"
				return 0
			fi
		fi
	fi

	echo ""
	return 0
}

#######################################
# Execute a single sanity check action
# Args:
#   $1 - JSON action object
#   $2 - action type
#   $3 - repo path
# Returns:
#   Result description on stdout, 0 on success, 1 on failure
#######################################
_execute_sanity_action() {
	local action="$1"
	local action_type="$2"
	local repo_path="$3"
	local todo_file="$repo_path/TODO.md"

	local task_id
	task_id=$(printf '%s' "$action" | jq -r '.task_id // ""')
	local reasoning
	reasoning=$(printf '%s' "$action" | jq -r '.reasoning // ""')

	if [[ -z "$task_id" ]]; then
		echo "missing task_id"
		return 1
	fi

	log_verbose "  Sanity AI action: $action_type on $task_id — $reasoning"

	case "$action_type" in
	unclaim)
		# Strip assignee:/started: from the task in TODO.md
		if cmd_unclaim "$task_id" "$repo_path" --force >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1; then
			# If task has retries available, reset to queued
			local retries max_retries
			retries=$(db "$SUPERVISOR_DB" "SELECT COALESCE(retries, 0) FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "0")
			max_retries=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_retries, 3) FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "3")
			retries="${retries:-0}"
			max_retries="${max_retries:-3}"
			if [[ "$retries" -lt "$max_retries" ]]; then
				cmd_reset "$task_id" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1 || true
				echo "claim stripped, reset to queued ($retries/$max_retries retries)"
			else
				echo "claim stripped (retries exhausted $retries/$max_retries)"
			fi
			return 0
		fi
		echo "unclaim failed"
		return 1
		;;

	reset)
		# Reset a failed/blocked task to queued for retry
		if cmd_reset "$task_id" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1; then
			echo "reset to queued"
			return 0
		fi
		echo "reset failed"
		return 1
		;;

	cancel_orphan)
		# Cancel a DB orphan that has no TODO.md entry
		if cmd_transition "$task_id" "cancelled" --error "Sanity check AI: DB orphan with no TODO.md entry" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1; then
			echo "cancelled (DB orphan)"
			return 0
		fi
		echo "cancel failed"
		return 1
		;;

	remove_blocker)
		# Remove a specific blocker from a task's blocked-by field
		local blocker_id
		blocker_id=$(printf '%s' "$action" | jq -r '.blocker_id // ""')
		if [[ -z "$blocker_id" ]]; then
			echo "missing blocker_id"
			return 1
		fi

		local escaped_task_id
		escaped_task_id=$(printf '%s' "$task_id" | sed 's/\./\\./g')

		local line_num
		line_num=$(grep -nE "^[[:space:]]*- \[ \] ${escaped_task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1 || echo "")
		if [[ -z "$line_num" ]]; then
			echo "task not found in TODO.md"
			return 1
		fi

		# Get current blocked-by value
		local current_line
		current_line=$(sed -n "${line_num}p" "$todo_file")
		local blocked_by
		blocked_by=$(printf '%s' "$current_line" | grep -oE 'blocked-by:t[0-9][^ ]*' | head -1 | sed 's/blocked-by://' || echo "")

		if [[ -z "$blocked_by" ]]; then
			echo "no blocked-by field found"
			return 1
		fi

		local escaped_blocker
		escaped_blocker=$(printf '%s' "$blocker_id" | sed 's/\./\\./g')

		if [[ "$blocked_by" == "$blocker_id" ]]; then
			# Only blocker — remove the whole field
			sed_inplace "${line_num}s/ blocked-by:${escaped_blocker}//" "$todo_file"
		else
			# Multiple blockers — rebuild without this one
			local new_blockers
			new_blockers=$(printf '%s' ",$blocked_by," | sed "s/,${escaped_blocker},/,/" | sed 's/^,//;s/,$//')
			local escaped_blocked_by
			escaped_blocked_by=$(printf '%s' "$blocked_by" | sed 's/\./\\./g')
			if [[ -n "$new_blockers" ]]; then
				sed_inplace "${line_num}s/blocked-by:${escaped_blocked_by}/blocked-by:${new_blockers}/" "$todo_file"
			else
				sed_inplace "${line_num}s/ blocked-by:${escaped_blocked_by}//" "$todo_file"
			fi
		fi
		sed_inplace "${line_num}s/[[:space:]]*$//" "$todo_file"

		commit_and_push_todo "$repo_path" "chore: sanity check AI — unblock $task_id (removed failed blocker $blocker_id)" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1 || true
		echo "removed blocker $blocker_id"
		return 0
		;;

	add_auto_dispatch)
		# Add #auto-dispatch tag to an eligible task
		local escaped_task_id
		escaped_task_id=$(printf '%s' "$task_id" | sed 's/\./\\./g')

		local line_num
		line_num=$(grep -nE "^[[:space:]]*- \[ \] ${escaped_task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1 || echo "")
		if [[ -z "$line_num" ]]; then
			echo "task not found in TODO.md"
			return 1
		fi

		# Check if already tagged
		if grep -q "^[[:space:]]*- \[ \] ${escaped_task_id}.*#auto-dispatch" "$todo_file"; then
			echo "already has #auto-dispatch"
			return 0
		fi

		# Insert #auto-dispatch after the last #tag before any —
		sed_inplace "${line_num}s/\(#[a-zA-Z][a-zA-Z0-9_-]*\)\([[:space:]]\)/\1 #auto-dispatch\2/" "$todo_file"

		# Verify it was added
		if grep -q "^[[:space:]]*- \[ \] ${escaped_task_id}.*#auto-dispatch" "$todo_file"; then
			commit_and_push_todo "$repo_path" "chore: sanity check AI — auto-tag $task_id as #auto-dispatch" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1 || true
			echo "tagged #auto-dispatch"
			return 0
		fi

		# Fallback: append before the description separator
		sed_inplace "${line_num}s/ — / #auto-dispatch — /" "$todo_file"
		if grep -q "^[[:space:]]*- \[ \] ${escaped_task_id}.*#auto-dispatch" "$todo_file"; then
			commit_and_push_todo "$repo_path" "chore: sanity check AI — auto-tag $task_id as #auto-dispatch" >>"${SUPERVISOR_LOG:-/dev/null}" 2>&1 || true
			echo "tagged #auto-dispatch (fallback)"
			return 0
		fi

		echo "could not insert #auto-dispatch tag"
		return 1
		;;

	log_only)
		# Just log a message for human review
		local message
		message=$(printf '%s' "$action" | jq -r '.message // "no message"')
		log_warn "  Phase 0.9 AI: $task_id — $message"
		echo "logged: $message"
		return 0
		;;

	*)
		echo "unknown action type: $action_type"
		return 1
		;;
	esac
}

#######################################
# Check if the AI sanity check cooldown has elapsed
# Returns:
#   0 if cooldown elapsed (should run), 1 if still cooling down
#######################################
_sanity_ai_cooldown_elapsed() {
	local cooldown="${SUPERVISOR_SANITY_AI_COOLDOWN:-300}"

	local last_run
	last_run=$(db "$SUPERVISOR_DB" "
		SELECT MAX(timestamp) FROM state_log
		WHERE task_id = 'sanity-check-ai'
		  AND to_state = 'complete';
	" 2>/dev/null || echo "")

	if [[ -z "$last_run" || "$last_run" == "null" ]]; then
		return 0
	fi

	local last_epoch now_epoch
	last_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_run" "+%s" 2>/dev/null || date -d "$last_run" "+%s" 2>/dev/null || echo 0)
	now_epoch=$(date "+%s")
	local elapsed=$((now_epoch - last_epoch))

	if [[ "$elapsed" -lt "$cooldown" ]]; then
		log_verbose "Phase 0.9: AI cooldown (${elapsed}s / ${cooldown}s)"
		return 1
	fi

	return 0
}

#######################################
# Record that an AI sanity check ran (for cooldown tracking)
#######################################
_record_sanity_ai_run() {
	db "$SUPERVISOR_DB" "
		INSERT INTO state_log (task_id, from_state, to_state, reason)
		VALUES ('sanity-check-ai', 'reasoning', 'complete',
				'AI sanity check completed');
	" 2>/dev/null || true
	return 0
}

#######################################
# Log structured skip reasons when the queue is stalled
# Makes the stall visible instead of silently saying "No new tasks"
#######################################
_log_queue_stall_reasons() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	local open_count claimed_count blocked_count no_tag_count db_failed_count
	open_count=$(grep -cE '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null || echo "0")
	claimed_count=$(grep -cE '^\s*- \[ \] t[0-9]+.*(assignee:|started:)' "$todo_file" 2>/dev/null || echo "0")
	blocked_count=$(grep -cE '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" 2>/dev/null || echo "0")
	no_tag_count=$(grep -E '^\s*- \[ \] t[0-9]+' "$todo_file" 2>/dev/null | grep -cv '#auto-dispatch' || echo "0")
	db_failed_count=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM tasks
		WHERE repo = '$(sql_escape "$repo_path")'
		AND status IN ('failed', 'blocked');
	" 2>/dev/null || echo "0")

	log_warn "  Queue stall breakdown:"
	log_warn "    Open tasks in TODO.md: $open_count"
	log_warn "    Claimed (assignee/started): $claimed_count"
	log_warn "    Blocked (blocked-by): $blocked_count"
	log_warn "    Missing #auto-dispatch: $no_tag_count"
	log_warn "    Failed/blocked in DB: $db_failed_count"
	log_warn "    Dispatchable: 0"

	return 0
}
