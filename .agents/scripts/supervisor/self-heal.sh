#!/usr/bin/env bash
# self-heal.sh - Self-healing and diagnostic functions
#
# Functions for automatic failure diagnosis, model escalation,
# and diagnostic subtask creation


#######################################
# Self-healing: determine if a failed/blocked task is eligible for
# automatic diagnostic subtask creation (t150)
# Returns 0 if eligible, 1 if not
#######################################
is_self_heal_eligible() {
	local task_id="$1"
	local failure_reason="$2"

	# Check global toggle (env var or default on)
	if [[ "${SUPERVISOR_SELF_HEAL:-true}" == "false" ]]; then
		return 1
	fi

	# Skip failures that require human intervention - no diagnostic can fix these
	# Note (t183): no_log_file removed from exclusion list. With enhanced dispatch
	# error capture, log files now contain diagnostic metadata even when workers
	# fail to start, making self-healing viable for these failures.
	case "$failure_reason" in
	auth_error | merge_conflict | out_of_memory | max_retries)
		return 1
		;;
	esac

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Skip if this task is itself a diagnostic subtask (prevent recursive healing)
	local is_diagnostic
	is_diagnostic=$(db "$SUPERVISOR_DB" "SELECT diagnostic_of FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -n "$is_diagnostic" ]]; then
		return 1
	fi

	# Skip if a diagnostic subtask already exists for this task (max 1 per task)
	local existing_diag
	existing_diag=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE diagnostic_of = '$escaped_id';" 2>/dev/null || echo "0")
	if [[ "$existing_diag" -gt 0 ]]; then
		return 1
	fi

	return 0
}

#######################################
# Self-healing: create a diagnostic subtask for a failed/blocked task (t150)
# The diagnostic task analyzes the failure log and attempts to fix the issue.
# On completion, the original task is re-queued.
#
# Args: task_id, failure_reason, batch_id (optional)
# Returns: diagnostic task ID on stdout, 0 on success, 1 on failure
#######################################
create_diagnostic_subtask() {
	local task_id="$1"
	local failure_reason="$2"
	local batch_id="${3:-}"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get original task details
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, description, log_file, error, model
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local trepo tdesc tlog terror tmodel
	IFS='|' read -r trepo tdesc tlog terror tmodel <<<"$task_row"

	# Generate diagnostic task ID: {parent}-diag-{N}
	local diag_count
	diag_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE id LIKE '$(sql_escape "$task_id")-diag-%';" 2>/dev/null || echo "0")
	local diag_num=$((diag_count + 1))
	local diag_id="${task_id}-diag-${diag_num}"

	# Extract failure context from log (last 100 lines)
	# CRITICAL: Replace newlines with spaces. The description is stored in SQLite
	# and returned by cmd_next as tab-separated output parsed with `read`. Embedded
	# newlines (e.g., EXIT:0 from log tail) would be parsed as separate task rows,
	# causing malformed task IDs like "EXIT:0" or "DIAGNOSTIC_CONTEXT_END".
	local failure_context=""
	if [[ -n "$tlog" && -f "$tlog" ]]; then
		failure_context=$(tail -100 "$tlog" 2>/dev/null | head -c 4000 | tr '\n' ' ' | tr '\t' ' ' || echo "")
	fi

	# Build diagnostic task description (single line - no embedded newlines)
	local diag_desc="Diagnose and fix failure in ${task_id}: ${failure_reason}."
	diag_desc="${diag_desc} Original task: ${tdesc:-unknown}."
	if [[ -n "$terror" ]]; then
		diag_desc="${diag_desc} Error: $(echo "$terror" | tr '\n' ' ' | head -c 200)"
	fi
	diag_desc="${diag_desc} Analyze the failure log, identify root cause, and apply a fix."
	diag_desc="${diag_desc} If the fix requires code changes, make them and create a PR."
	diag_desc="${diag_desc} DIAGNOSTIC_CONTEXT_START"
	if [[ -n "$failure_context" ]]; then
		diag_desc="${diag_desc} LOG_TAIL: ${failure_context}"
	fi
	diag_desc="${diag_desc} DIAGNOSTIC_CONTEXT_END"

	# Add diagnostic task to supervisor
	local escaped_diag_id
	escaped_diag_id=$(sql_escape "$diag_id")
	local escaped_diag_desc
	escaped_diag_desc=$(sql_escape "$diag_desc")
	local escaped_repo
	escaped_repo=$(sql_escape "$trepo")
	local escaped_model
	escaped_model=$(sql_escape "$tmodel")

	db "$SUPERVISOR_DB" "
        INSERT INTO tasks (id, repo, description, model, max_retries, diagnostic_of)
        VALUES ('$escaped_diag_id', '$escaped_repo', '$escaped_diag_desc', '$escaped_model', 2, '$escaped_id');
    "

	# Log the creation
	db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_diag_id', '', 'queued', 'Self-heal diagnostic for $task_id ($failure_reason)');
    "

	# Add to same batch if applicable
	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")
		local max_pos
		max_pos=$(db "$SUPERVISOR_DB" "SELECT COALESCE(MAX(position), 0) + 1 FROM batch_tasks WHERE batch_id = '$escaped_batch';" 2>/dev/null || echo "0")
		db "$SUPERVISOR_DB" "
            INSERT OR IGNORE INTO batch_tasks (batch_id, task_id, position)
            VALUES ('$escaped_batch', '$escaped_diag_id', $max_pos);
        " 2>/dev/null || true
	fi

	log_success "Created diagnostic subtask: $diag_id for $task_id ($failure_reason)"
	echo "$diag_id"
	return 0
}

#######################################
# Self-healing: attempt to create a diagnostic subtask for a failed/blocked task (t150)
# Called from pulse cycle. Checks eligibility before creating.
#
# Args: task_id, outcome_type (blocked/failed), failure_reason, batch_id (optional)
# Returns: 0 if diagnostic created, 1 if skipped
#######################################
attempt_self_heal() {
	local task_id="$1"
	local outcome_type="$2"
	local failure_reason="$3"
	local batch_id="${4:-}"

	if ! is_self_heal_eligible "$task_id" "$failure_reason"; then
		log_info "Self-heal skipped for $task_id ($failure_reason): not eligible"
		return 1
	fi

	local diag_id
	diag_id=$(create_diagnostic_subtask "$task_id" "$failure_reason" "$batch_id") || return 1

	log_info "Self-heal: created $diag_id to investigate $task_id"

	# Store self-heal event in memory
	if [[ -x "$MEMORY_HELPER" ]]; then
		"$MEMORY_HELPER" store \
			--auto \
			--type "ERROR_FIX" \
			--content "Supervisor self-heal: created $diag_id to diagnose $task_id ($failure_reason)" \
			--tags "supervisor,self-heal,$task_id,$diag_id" \
			2>/dev/null || true
	fi

	return 0
}

#######################################
# Auto-escalate task model on failure (t314)
# When a worker fails (hung, crashed, max runtime), escalate the task's model
# to the next tier via get_next_tier() before re-queuing. This ensures retries
# use a more capable model instead of repeating with the same underpowered one.
#
# Args: task_id
# Returns: 0 if escalated, 1 if already at max tier or not applicable
#######################################
escalate_model_on_failure() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get current model and escalation state
	local task_data
	task_data=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT model, escalation_depth, max_escalation
        FROM tasks WHERE id = '$escaped_id';
    " 2>/dev/null || echo "")

	if [[ -z "$task_data" ]]; then
		return 1
	fi

	local current_model current_depth max_depth
	IFS='|' read -r current_model current_depth max_depth <<<"$task_data"

	# Already at max escalation depth
	if [[ "$current_depth" -ge "$max_depth" ]]; then
		log_info "Model escalation: $task_id already at max depth ($current_depth/$max_depth)"
		return 1
	fi

	# Get next tier
	local next_tier
	next_tier=$(get_next_tier "$current_model")

	if [[ -z "$next_tier" ]]; then
		log_info "Model escalation: $task_id already at max tier ($current_model)"
		return 1
	fi

	# Resolve to full model string
	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null || echo "opencode")
	local next_model
	next_model=$(resolve_model "$next_tier" "$ai_cli")

	if [[ -z "$next_model" || "$next_model" == "$current_model" ]]; then
		log_info "Model escalation: no higher model available for $task_id"
		return 1
	fi

	# Update model and escalation depth in DB
	db "$SUPERVISOR_DB" "
        UPDATE tasks SET
            model = '$(sql_escape "$next_model")',
            escalation_depth = $((current_depth + 1))
        WHERE id = '$escaped_id';
    "

	log_warn "Model escalation (t314): $task_id escalated from $current_model to $next_model (depth $((current_depth + 1))/$max_depth)"

	# Record pattern for future routing decisions
	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ -x "$pattern_helper" ]]; then
		"$pattern_helper" record \
			--type "FAILURE_PATTERN" \
			--task "$task_id" \
			--model "$current_model" \
			--detail "Auto-escalated to $next_model after failure" \
			2>/dev/null || true
	fi

	return 0
}

#######################################
# Self-healing: check if a completed diagnostic task should re-queue its parent (t150)
# Called from pulse cycle after a task completes.
#
# Args: task_id (the completed task)
# Returns: 0 if parent was re-queued, 1 if not applicable
#######################################
handle_diagnostic_completion() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Check if this is a diagnostic task
	local parent_id
	parent_id=$(db "$SUPERVISOR_DB" "SELECT diagnostic_of FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	if [[ -z "$parent_id" ]]; then
		return 1
	fi

	# Check parent task status - only re-queue if still blocked/failed
	local parent_status
	parent_status=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$parent_id")';" 2>/dev/null || echo "")

	case "$parent_status" in
	blocked | failed)
		log_info "Diagnostic $task_id completed - re-queuing parent $parent_id"
		cmd_reset "$parent_id" 2>/dev/null || {
			log_warn "Failed to reset parent task $parent_id"
			return 1
		}
		# Log the re-queue
		db "$SUPERVISOR_DB" "
                INSERT INTO state_log (task_id, from_state, to_state, reason)
                VALUES ('$(sql_escape "$parent_id")', '$parent_status', 'queued',
                        'Re-queued after diagnostic $task_id completed');
            " 2>/dev/null || true
		log_success "Re-queued $parent_id after diagnostic $task_id completed"
		return 0
		;;
	*)
		log_info "Diagnostic $task_id completed but parent $parent_id is in '$parent_status' (not re-queueing)"
		return 1
		;;
	esac
}

#######################################
# Command: self-heal - manually create a diagnostic subtask for a task
#######################################
cmd_self_heal() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh self-heal <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, error FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tstatus terror
	IFS='|' read -r tstatus terror <<<"$task_row"

	if [[ "$tstatus" != "blocked" && "$tstatus" != "failed" ]]; then
		log_error "Task $task_id is in '$tstatus' state. Self-heal only works on blocked/failed tasks."
		return 1
	fi

	local failure_reason="${terror:-unknown}"

	# Find batch for this task (if any)
	local batch_id
	batch_id=$(db "$SUPERVISOR_DB" "SELECT batch_id FROM batch_tasks WHERE task_id = '$escaped_id' LIMIT 1;" 2>/dev/null || echo "")

	local diag_id
	diag_id=$(create_diagnostic_subtask "$task_id" "$failure_reason" "$batch_id") || return 1

	echo -e "${BOLD}Created diagnostic subtask:${NC} $diag_id"
	echo "  Parent task: $task_id ($tstatus)"
	echo "  Reason:      $failure_reason"
	echo "  Batch:       ${batch_id:-none}"
	echo ""
	echo "The diagnostic task will be dispatched on the next pulse cycle."
	echo "When it completes, $task_id will be automatically re-queued."
	return 0
}
