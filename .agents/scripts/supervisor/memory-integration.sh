#!/usr/bin/env bash
# memory-integration.sh - Memory and pattern tracking functions
#
# Functions for task memory recall, failure/success pattern storage,
# batch retrospectives, and session reviews


#######################################
# Recall relevant memories for a task before dispatch
# Returns memory context as text (empty string if none found)
# Used to inject prior learnings into the worker prompt
#######################################
recall_task_memories() {
	local task_id="$1"
	local description="${2:-}"

	if [[ ! -x "$MEMORY_HELPER" ]]; then
		return 0
	fi

	# Build search query from task ID and description
	local query="$task_id"
	if [[ -n "$description" ]]; then
		query="$description"
	fi

	# Recall memories relevant to this task (limit 5, auto-captured preferred)
	local memories=""
	memories=$("$MEMORY_HELPER" recall --query "$query" --limit 5 --format text 2>/dev/null || echo "")

	# Also check for failure patterns from previous attempts of this specific task
	local task_memories=""
	task_memories=$("$MEMORY_HELPER" recall --query "supervisor $task_id failure" --limit 3 --auto-only --format text 2>/dev/null || echo "")

	local result=""
	if [[ -n "$memories" && "$memories" != *"No memories found"* ]]; then
		result="## Relevant Memories (from prior sessions)
$memories"
	fi

	if [[ -n "$task_memories" && "$task_memories" != *"No memories found"* ]]; then
		if [[ -n "$result" ]]; then
			result="$result

## Prior Failure Patterns for $task_id
$task_memories"
		else
			result="## Prior Failure Patterns for $task_id
$task_memories"
		fi
	fi

	echo "$result"
	return 0
}

#######################################
# Store a failure pattern in memory after evaluation
# Called when a task fails, is blocked, or retries
# Tags with supervisor context for future recall
# Uses FAILURE_PATTERN type for pattern-tracker integration (t102.3)
#######################################
store_failure_pattern() {
	local task_id="$1"
	local outcome_type="$2"
	local outcome_detail="$3"
	local description="${4:-}"

	if [[ ! -x "$MEMORY_HELPER" ]]; then
		return 0
	fi

	# Only store meaningful failure patterns (not transient retries)
	case "$outcome_type" in
	blocked | failed)
		true # Always store these
		;;
	retry)
		# Only store retry patterns if they indicate a recurring issue
		# Skip transient ones like rate_limited, timeout, interrupted
		# Skip clean_exit_no_signal retries — infrastructure noise (t230)
		# The blocked/failed outcomes above still capture the final state
		case "$outcome_detail" in
		rate_limited | timeout | interrupted_sigint | killed_sigkill | terminated_sigterm | clean_exit_no_signal)
			return 0
			;;
		esac
		;;
	*)
		return 0
		;;
	esac

	# Rate-limit: skip if 3+ entries with the same outcome_detail exist in last 24h (t230)
	# Prevents memory pollution from repetitive infrastructure failures
	local recent_count=0
	local escaped_detail
	escaped_detail="$(sql_escape "$outcome_detail")"
	if [[ -r "$MEMORY_DB" ]]; then
		recent_count=$(sqlite3 "$MEMORY_DB" \
			"SELECT COUNT(*) FROM learnings WHERE type = 'FAILURE_PATTERN' AND content LIKE '%${escaped_detail}%' AND created_at > datetime('now', '-1 day');" \
			2>/dev/null || echo "0")
	fi
	if [[ "$recent_count" -ge 3 ]]; then
		log_info "Skipping failure pattern storage: $outcome_detail already has $recent_count entries in last 24h (t230)"
		return 0
	fi

	# Look up model tier from task record for pattern routing (t102.3, t1010)
	local model_tier=""
	local task_model
	task_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
	if [[ -n "$task_model" ]]; then
		model_tier=$(model_to_tier "$task_model")
	fi

	# Build structured content for pattern-tracker compatibility
	local content="Supervisor task $task_id ($outcome_type): $outcome_detail"
	if [[ -n "$description" ]]; then
		content="[task:feature] $content | Task: $description"
	fi
	[[ -n "$model_tier" ]] && content="$content [model:$model_tier]"

	# Build tags with model info for pattern-tracker queries
	local tags="supervisor,pattern,$task_id,$outcome_type,$outcome_detail"
	[[ -n "$model_tier" ]] && tags="$tags,model:$model_tier"

	"$MEMORY_HELPER" store \
		--auto \
		--type "FAILURE_PATTERN" \
		--content "$content" \
		--tags "$tags" \
		2>/dev/null || true

	log_info "Stored failure pattern in memory: $task_id ($outcome_type: $outcome_detail)"
	return 0
}

#######################################
# Store a success pattern in memory after task completion
# Records what worked for future reference
# Uses SUCCESS_PATTERN type for pattern-tracker integration (t102.3)
#######################################
store_success_pattern() {
	local task_id="$1"
	local detail="${2:-}"
	local description="${3:-}"

	if [[ ! -x "$MEMORY_HELPER" ]]; then
		return 0
	fi

	# Look up model tier and timing from task record (t102.3)
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local model_tier=""
	local task_model duration_info retries
	task_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	retries=$(db "$SUPERVISOR_DB" "SELECT retries FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "0")

	# Calculate duration if timestamps available
	local started completed duration_secs=""
	started=$(db "$SUPERVISOR_DB" "SELECT started_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	completed=$(db "$SUPERVISOR_DB" "SELECT completed_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -n "$started" && -n "$completed" ]]; then
		local start_epoch end_epoch
		start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" "+%s" 2>/dev/null || date -d "$started" "+%s" 2>/dev/null || echo "")
		end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$completed" "+%s" 2>/dev/null || date -d "$completed" "+%s" 2>/dev/null || echo "")
		if [[ -n "$start_epoch" && -n "$end_epoch" ]]; then
			duration_secs=$((end_epoch - start_epoch))
		fi
	fi

	# Extract tier name from model string (t1010: use shared model_to_tier)
	if [[ -n "$task_model" ]]; then
		model_tier=$(model_to_tier "$task_model")
	fi

	# Build structured content for pattern-tracker compatibility
	local content="Supervisor task $task_id completed successfully"
	if [[ -n "$detail" && "$detail" != "no_pr" ]]; then
		content="$content | PR: $detail"
	fi
	if [[ -n "$description" ]]; then
		content="[task:feature] $content | Task: $description"
	fi
	[[ -n "$model_tier" ]] && content="$content [model:$model_tier]"
	[[ -n "$duration_secs" ]] && content="$content [duration:${duration_secs}s]"
	if [[ "$retries" -gt 0 ]]; then
		content="$content [retries:$retries]"
	fi

	# Task tool parallelism tracking (t217): check if worker used Task tool
	# for sub-agent parallelism. Logged as a quality signal for pattern analysis.
	local log_file task_tool_count=0
	log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -n "$log_file" && -f "$log_file" ]]; then
		task_tool_count=$(grep -c 'mcp_task\|"tool_name":"task"\|"name":"task"' "$log_file" 2>/dev/null || true)
		task_tool_count="${task_tool_count//[^0-9]/}"
		task_tool_count="${task_tool_count:-0}"
	fi
	if [[ "$task_tool_count" -gt 0 ]]; then
		content="$content [task_tool:$task_tool_count]"
	fi

	# Build tags with model and duration info for pattern-tracker queries
	local tags="supervisor,pattern,$task_id,complete"
	[[ -n "$model_tier" ]] && tags="$tags,model:$model_tier"
	[[ -n "$duration_secs" ]] && tags="$tags,duration:$duration_secs"
	[[ "$retries" -gt 0 ]] && tags="$tags,retries:$retries"
	[[ "$task_tool_count" -gt 0 ]] && tags="$tags,task_tool:$task_tool_count"

	"$MEMORY_HELPER" store \
		--auto \
		--type "SUCCESS_PATTERN" \
		--content "$content" \
		--tags "$tags" \
		2>/dev/null || true

	log_info "Stored success pattern in memory: $task_id"
	return 0
}

#######################################
# Run a retrospective after batch completion
# Analyzes outcomes across all tasks in a batch and stores insights
#######################################
run_batch_retrospective() {
	local batch_id="$1"

	if [[ ! -x "$MEMORY_HELPER" ]]; then
		log_warn "Memory helper not available, skipping retrospective"
		return 0
	fi

	ensure_db

	local escaped_batch
	escaped_batch=$(sql_escape "$batch_id")

	# Get batch info
	local batch_name
	batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")

	# Gather statistics
	local total_tasks complete_count failed_count blocked_count cancelled_count
	total_tasks=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks WHERE batch_id = '$escaped_batch';
    ")
	complete_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'complete';
    ")
	failed_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'failed';
    ")
	blocked_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'blocked';
    ")
	cancelled_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status = 'cancelled';
    ")

	# Gather common error patterns
	local error_patterns
	error_patterns=$(db "$SUPERVISOR_DB" "
        SELECT error, count(*) as cnt FROM tasks t
        JOIN batch_tasks bt ON t.id = bt.task_id
        WHERE bt.batch_id = '$escaped_batch'
        AND t.error IS NOT NULL AND t.error != ''
        GROUP BY error ORDER BY cnt DESC LIMIT 5;
    " 2>/dev/null || echo "")

	# Calculate total retries
	local total_retries
	total_retries=$(db "$SUPERVISOR_DB" "
        SELECT COALESCE(SUM(t.retries), 0) FROM tasks t
        JOIN batch_tasks bt ON t.id = bt.task_id
        WHERE bt.batch_id = '$escaped_batch';
    ")

	# Build retrospective summary
	local success_rate=0
	if [[ "$total_tasks" -gt 0 ]]; then
		success_rate=$(((complete_count * 100) / total_tasks))
	fi

	local retro_content="Batch retrospective: $batch_name ($batch_id) | "
	retro_content+="$complete_count/$total_tasks completed (${success_rate}%) | "
	retro_content+="Failed: $failed_count, Blocked: $blocked_count, Cancelled: $cancelled_count | "
	retro_content+="Total retries: $total_retries"

	if [[ -n "$error_patterns" ]]; then
		retro_content+=" | Common errors: $(echo "$error_patterns" | tr '\n' '; ' | head -c 200)"
	fi

	# Store the retrospective
	"$MEMORY_HELPER" store \
		--auto \
		--type "CODEBASE_PATTERN" \
		--content "$retro_content" \
		--tags "supervisor,retrospective,$batch_name,batch" \
		2>/dev/null || true

	# Store individual failure patterns if there are recurring errors
	if [[ -n "$error_patterns" ]]; then
		while IFS='|' read -r error_msg error_count; do
			if [[ "$error_count" -gt 1 && -n "$error_msg" ]]; then
				"$MEMORY_HELPER" store \
					--auto \
					--type "FAILED_APPROACH" \
					--content "Recurring error in batch $batch_name ($error_count occurrences): $error_msg" \
					--tags "supervisor,retrospective,$batch_name,recurring_error" \
					2>/dev/null || true
			fi
		done <<<"$error_patterns"
	fi

	log_success "Batch retrospective stored for $batch_name"
	echo ""
	echo -e "${BOLD}=== Batch Retrospective: $batch_name ===${NC}"
	echo "  Total tasks:  $total_tasks"
	echo "  Completed:    $complete_count (${success_rate}%)"
	echo "  Failed:       $failed_count"
	echo "  Blocked:      $blocked_count"
	echo "  Cancelled:    $cancelled_count"
	echo "  Total retries: $total_retries"
	if [[ -n "$error_patterns" ]]; then
		echo ""
		echo "  Common errors:"
		echo "$error_patterns" | while IFS='|' read -r emsg ecnt; do
			echo "    [$ecnt] $emsg"
		done
	fi

	return 0
}

#######################################
# Run session review and distillation after batch completion (t128.9)
# Gathers session context via session-review-helper.sh and extracts
# learnings via session-distill-helper.sh for cross-session memory.
# Also suggests agent-review for post-batch improvement opportunities.
#######################################
run_session_review() {
	local batch_id="$1"

	ensure_db

	local escaped_batch
	escaped_batch=$(sql_escape "$batch_id")
	local batch_name
	batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")

	# Phase 1: Session review - gather context snapshot
	if [[ -x "$SESSION_REVIEW_HELPER" ]]; then
		log_info "Running session review for batch $batch_name..."
		local review_output=""

		# Get repo from first task in batch (session-review runs in repo context)
		local batch_repo
		batch_repo=$(db "$SUPERVISOR_DB" "
            SELECT t.repo FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            ORDER BY bt.position LIMIT 1;
        " 2>/dev/null || echo "")

		if [[ -n "$batch_repo" && -d "$batch_repo" ]]; then
			review_output=$(cd "$batch_repo" && "$SESSION_REVIEW_HELPER" json 2>>"$SUPERVISOR_LOG") || true
		else
			review_output=$("$SESSION_REVIEW_HELPER" json 2>>"$SUPERVISOR_LOG") || true
		fi

		if [[ -n "$review_output" ]]; then
			# Store session review snapshot in memory
			if [[ -x "$MEMORY_HELPER" ]]; then
				local review_summary
				review_summary=$(echo "$review_output" | jq -r '
                    "Session review for batch '"$batch_name"': branch=" + .branch +
                    " todo=" + (.todo | tostring) +
                    " changes=" + (.changes | tostring)
                ' 2>/dev/null || echo "Session review completed for batch $batch_name")

				"$MEMORY_HELPER" store \
					--auto \
					--type "CONTEXT" \
					--content "$review_summary" \
					--tags "supervisor,session-review,$batch_name,batch" \
					2>/dev/null || true
			fi
			log_success "Session review captured for batch $batch_name"
		else
			log_warn "Session review produced no output for batch $batch_name"
		fi
	else
		log_warn "session-review-helper.sh not found, skipping session review"
	fi

	# Phase 2: Session distillation - extract and store learnings
	if [[ -x "$SESSION_DISTILL_HELPER" ]]; then
		log_info "Running session distillation for batch $batch_name..."

		local batch_repo
		# Re-resolve in case it wasn't set above (defensive)
		batch_repo=$(db "$SUPERVISOR_DB" "
            SELECT t.repo FROM batch_tasks bt
            JOIN tasks t ON bt.task_id = t.id
            WHERE bt.batch_id = '$escaped_batch'
            ORDER BY bt.position LIMIT 1;
        " 2>/dev/null || echo "")

		if [[ -n "$batch_repo" && -d "$batch_repo" ]]; then
			(cd "$batch_repo" && "$SESSION_DISTILL_HELPER" auto 2>>"$SUPERVISOR_LOG") || true
		else
			"$SESSION_DISTILL_HELPER" auto 2>>"$SUPERVISOR_LOG" || true
		fi

		log_success "Session distillation complete for batch $batch_name"
	else
		log_warn "session-distill-helper.sh not found, skipping distillation"
	fi

	# Phase 3: Suggest agent-review (non-blocking recommendation)
	echo ""
	echo -e "${BOLD}=== Post-Batch Recommendations ===${NC}"
	echo "  Batch '$batch_name' is complete. Consider running:"
	echo "    @agent-review  - Review and improve agents used in this batch"
	echo "    /session-review - Full interactive session review"
	echo ""

	return 0
}

#######################################
# Command: retrospective - run batch retrospective
#######################################
cmd_retrospective() {
	local batch_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		batch_id="$1"
		shift
	fi

	if [[ -z "$batch_id" ]]; then
		# Find the most recently completed batch
		ensure_db
		batch_id=$(db "$SUPERVISOR_DB" "
            SELECT id FROM batches WHERE status = 'complete'
            ORDER BY updated_at DESC LIMIT 1;
        " 2>/dev/null || echo "")

		if [[ -z "$batch_id" ]]; then
			log_error "No completed batches found. Usage: supervisor-helper.sh retrospective [batch_id]"
			return 1
		fi
		log_info "Using most recently completed batch: $batch_id"
	fi

	run_batch_retrospective "$batch_id"
	return 0
}

#######################################
# Command: recall - recall memories relevant to a task
#######################################
cmd_recall() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh recall <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local tdesc
	tdesc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	if [[ -z "$tdesc" ]]; then
		# Try looking up from TODO.md in current repo
		tdesc=$(grep -E "^[[:space:]]*- \[( |x|-)\] $task_id " TODO.md 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*- \[( |x|-)\] [^ ]* //' || true)
	fi

	local memories
	memories=$(recall_task_memories "$task_id" "$tdesc")

	if [[ -n "$memories" ]]; then
		echo "$memories"
	else
		log_info "No relevant memories found for $task_id"
	fi

	return 0
}
