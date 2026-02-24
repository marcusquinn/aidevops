#!/usr/bin/env bash
# self-heal.sh - AI-powered self-healing and failure recovery (t1316)
#
# Replaces hardcoded failure classification and recovery decisions with AI
# reasoning. Instead of a static case statement deciding which failures are
# healable and a fixed escalation pattern list, the AI analyzes the failure
# context and decides the best recovery strategy.
#
# The AI can:
#   - Distinguish infrastructure failures from capability failures (no hardcoded patterns)
#   - Decide whether to escalate, retry at same tier, or create a diagnostic subtask
#   - Generate better diagnostic task descriptions by understanding the failure context
#   - Adapt to new failure patterns without code changes
#
# Functions for automatic failure diagnosis, model escalation,
# and diagnostic subtask creation.
#
# Sourced by: supervisor-helper.sh (set -euo pipefail inherited)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SCRIPT_DIR, REPO_PATH
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   cmd_reset(), cmd_transition()
#   resolve_ai_cli(), resolve_model(), get_next_tier() (from dispatch.sh)
#   portable_timeout() (from _common.sh)

# Self-heal AI toggle (default: enabled)
SUPERVISOR_SELF_HEAL_AI="${SUPERVISOR_SELF_HEAL_AI:-true}"

# AI timeout for self-heal reasoning (seconds)
SUPERVISOR_SELF_HEAL_AI_TIMEOUT="${SUPERVISOR_SELF_HEAL_AI_TIMEOUT:-60}"

# Log directory for self-heal AI reasoning
SELF_HEAL_AI_LOG_DIR="${SELF_HEAL_AI_LOG_DIR:-$HOME/.aidevops/logs/ai-supervisor}"

#######################################
# Self-healing: determine if a failed/blocked task is eligible for
# automatic recovery (diagnostic subtask, model escalation, or retry).
#
# Replaces the hardcoded case statement with AI reasoning that analyzes
# the failure context and decides the best recovery strategy.
#
# Args:
#   $1 - task_id
#   $2 - failure_reason
# Returns:
#   0 if eligible for self-healing, 1 if not
#######################################
is_self_heal_eligible() {
	local task_id="$1"
	local failure_reason="$2"

	# Check global toggle (env var or default on)
	if [[ "${SUPERVISOR_SELF_HEAL:-true}" == "false" ]]; then
		return 1
	fi

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

	# AI-powered eligibility: ask the AI whether this failure is self-healable
	if [[ "$SUPERVISOR_SELF_HEAL_AI" == "true" ]]; then
		local ai_decision
		ai_decision=$(_ai_assess_heal_eligibility "$task_id" "$failure_reason")
		if [[ "$ai_decision" == "eligible" ]]; then
			return 0
		elif [[ "$ai_decision" == "ineligible" ]]; then
			return 1
		fi
		# AI unavailable or inconclusive — fall through to fast heuristic
	fi

	# Fast heuristic fallback: failures requiring human intervention are not healable
	case "$failure_reason" in
	auth_error | merge_conflict | out_of_memory | max_retries)
		return 1
		;;
	esac

	return 0
}

#######################################
# AI assessment of self-heal eligibility
# Asks the AI whether a failure is self-healable or requires human intervention.
#
# Args:
#   $1 - task_id
#   $2 - failure_reason
# Returns:
#   "eligible", "ineligible", or "unknown" on stdout
#######################################
_ai_assess_heal_eligibility() {
	local task_id="$1"
	local failure_reason="$2"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		echo "unknown"
		return 0
	}

	local ai_model
	ai_model=$(resolve_model "haiku" "$ai_cli" 2>/dev/null) || {
		echo "unknown"
		return 0
	}

	# Get task context from DB
	local task_data
	task_data=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT COALESCE(description,''), COALESCE(error,''), COALESCE(model,''),
		       COALESCE(retries,0), COALESCE(max_retries,3), COALESCE(log_file,'')
		FROM tasks WHERE id = '$(sql_escape "$task_id")';
	" 2>/dev/null || echo "")

	local tdesc terror tmodel tretries tmax tlog
	IFS='|' read -r tdesc terror tmodel tretries tmax tlog <<<"$task_data"

	# Get last 50 lines of log for context (if available)
	local log_tail=""
	if [[ -n "$tlog" && -f "$tlog" ]]; then
		log_tail=$(tail -50 "$tlog" 2>/dev/null | tr '\n' ' ' | head -c 2000 || echo "")
	fi

	local prompt
	prompt="You are a failure triage system. Decide if this task failure can be automatically recovered (retry, model escalation, or diagnostic subtask) or requires human intervention.

Task: $task_id
Description: ${tdesc:0:200}
Failure reason: $failure_reason
Error: ${terror:0:200}
Model: $tmodel
Retries: $tretries/$tmax
Log tail: ${log_tail:0:500}

Respond with ONLY one word:
- \"eligible\" if the failure can be automatically recovered (code errors, timeouts, model capability issues, transient failures)
- \"ineligible\" if it requires human intervention (auth errors, merge conflicts, out of memory, missing credentials, missing infrastructure, manual approval needed)

One word only:"

	local ai_timeout="${SUPERVISOR_SELF_HEAL_AI_TIMEOUT:-60}"
	local ai_result=""

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "heal-eligibility-$$" \
			"$prompt" 2>/dev/null || echo "")
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Parse the response — extract the first word
	local decision
	decision=$(printf '%s' "$ai_result" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | grep -oE '^(eligible|ineligible)' | head -1 || echo "")

	if [[ -n "$decision" ]]; then
		log_info "Self-heal AI: $task_id eligibility=$decision (reason: $failure_reason)"
		echo "$decision"
		return 0
	fi

	echo "unknown"
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
	# newlines would be parsed as separate task rows.
	local failure_context=""
	if [[ -n "$tlog" && -f "$tlog" ]]; then
		failure_context=$(tail -100 "$tlog" 2>/dev/null | head -c 4000 | tr '\n' ' ' | tr '\t' ' ' || echo "")
	fi

	# AI-powered diagnostic description (if available)
	local diag_desc
	diag_desc=$(_ai_build_diagnostic_description "$task_id" "$failure_reason" "$tdesc" "$terror" "$failure_context")

	if [[ -z "$diag_desc" ]]; then
		# Fallback: static diagnostic description
		diag_desc="Diagnose and fix failure in ${task_id}: ${failure_reason}."
		diag_desc="${diag_desc} Original task: ${tdesc:-unknown}."
		if [[ -n "$terror" ]]; then
			diag_desc="${diag_desc} Error: $(echo "$terror" | tr '\n' ' ' | head -c 200)"
		fi
		diag_desc="${diag_desc} Analyze the failure log, identify root cause, and apply a fix."
		diag_desc="${diag_desc} If the fix requires code changes, make them and create a PR."
	fi

	# Append diagnostic context markers (single line)
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
# AI-powered diagnostic description builder
# Asks the AI to analyze the failure and produce a focused diagnostic prompt
# that will guide the diagnostic worker more effectively than a static template.
#
# Args:
#   $1 - task_id
#   $2 - failure_reason
#   $3 - original task description
#   $4 - error message
#   $5 - failure context (log tail)
# Returns:
#   Diagnostic description on stdout (single line, no newlines)
#   Empty string if AI unavailable
#######################################
_ai_build_diagnostic_description() {
	local task_id="$1"
	local failure_reason="$2"
	local orig_desc="$3"
	local error_msg="$4"
	local log_context="$5"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || return 0

	local ai_model
	ai_model=$(resolve_model "haiku" "$ai_cli" 2>/dev/null) || return 0

	local prompt
	prompt="You are writing a diagnostic task description for an automated worker. The worker will read this description and attempt to fix the failure. Be specific and actionable.

Failed task: $task_id
Failure reason: $failure_reason
Original task: ${orig_desc:0:300}
Error: ${error_msg:0:300}
Log context: ${log_context:0:1000}

Write a single-paragraph diagnostic task description (no newlines) that:
1. States the specific failure to investigate
2. Identifies the most likely root cause based on the error/log context
3. Gives the worker a concrete first step to fix it
4. Mentions if code changes and a PR are needed

Respond with ONLY the description paragraph, no quotes, no markdown:"

	local ai_timeout="${SUPERVISOR_SELF_HEAL_AI_TIMEOUT:-60}"
	local ai_result=""

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "diag-desc-$$" \
			"$prompt" 2>/dev/null || echo "")
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Clean up: single line, no tabs, truncate
	if [[ -n "$ai_result" ]]; then
		local clean_result
		clean_result=$(printf '%s' "$ai_result" | tr '\n' ' ' | tr '\t' ' ' | head -c 4000)
		# Verify it's not empty after cleaning
		local trimmed
		trimmed=$(printf '%s' "$clean_result" | tr -d '[:space:]')
		if [[ -n "$trimmed" ]]; then
			printf '%s' "$clean_result"
			return 0
		fi
	fi

	# Return empty — caller will use static fallback
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
	local _outcome_type="$2" # kept for API compatibility (blocked/failed)
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
	local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
	if [[ ! -x "$memory_helper" ]]; then
		memory_helper="$HOME/.aidevops/agents/scripts/memory-helper.sh"
	fi
	if [[ -x "$memory_helper" ]]; then
		"$memory_helper" store \
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
# Uses AI reasoning to decide whether to escalate the model tier.
# The AI distinguishes infrastructure failures (don't escalate — retry at
# same tier) from capability failures (escalate to stronger model).
#
# Args: task_id
# Returns: 0 if escalated, 1 if already at max tier or not applicable
#######################################
escalate_model_on_failure() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Get current model, escalation state, and error reason
	local task_data
	task_data=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT model, escalation_depth, max_escalation, error
		FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null || echo "")

	if [[ -z "$task_data" ]]; then
		return 1
	fi

	local current_model current_depth max_depth task_error
	IFS='|' read -r current_model current_depth max_depth task_error <<<"$task_data"

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

	# AI-powered escalation decision
	local should_escalate="true"
	if [[ "$SUPERVISOR_SELF_HEAL_AI" == "true" ]]; then
		should_escalate=$(_ai_assess_escalation "$task_id" "$current_model" "$next_tier" "$task_error")
	fi

	if [[ "$should_escalate" != "true" ]]; then
		log_info "Model escalation: $task_id skipped — AI determined not a capability failure (error: ${task_error:0:80})"
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
# AI assessment of whether to escalate model tier
# Distinguishes infrastructure failures (retry at same tier) from
# capability failures (escalate to stronger model).
#
# Args:
#   $1 - task_id
#   $2 - current_model
#   $3 - next_tier
#   $4 - task_error
# Returns:
#   "true" if should escalate, "false" if should not, on stdout
#######################################
_ai_assess_escalation() {
	local task_id="$1"
	local current_model="$2"
	local next_tier="$3"
	local task_error="$4"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		echo "true"
		return 0
	}

	local ai_model
	ai_model=$(resolve_model "haiku" "$ai_cli" 2>/dev/null) || {
		echo "true"
		return 0
	}

	local prompt
	prompt="You are a model escalation decision system. A task failed and we need to decide whether to escalate to a stronger AI model or retry at the same tier.

Task: $task_id
Current model: $current_model
Proposed escalation: $next_tier
Error: ${task_error:0:500}

ESCALATE (respond \"true\") when the failure is a CAPABILITY issue:
- Task too complex for the current model tier
- Code reasoning errors, incomplete implementations
- Worker ran out of context or produced wrong output
- Repeated failures at this tier on similar tasks

DO NOT ESCALATE (respond \"false\") when the failure is INFRASTRUCTURE:
- Stale state recovery, dead evaluator, supervisor crash/respawn
- No live worker, DB orphan, Phase 0.7 recovery
- Manual recovery, evaluation process died
- Network timeouts, rate limits, API errors
- These should retry at the SAME tier — escalating wastes budget

Respond with ONLY \"true\" or \"false\":"

	local ai_timeout="${SUPERVISOR_SELF_HEAL_AI_TIMEOUT:-60}"
	local ai_result=""

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$ai_timeout" opencode run \
			-m "$ai_model" \
			--format default \
			--title "escalation-$$" \
			"$prompt" 2>/dev/null || echo "")
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$ai_timeout" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	local decision
	decision=$(printf '%s' "$ai_result" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | grep -oE '^(true|false)' | head -1 || echo "")

	if [[ -n "$decision" ]]; then
		log_info "Model escalation AI: $task_id decision=$decision (error: ${task_error:0:80})"
		echo "$decision"
		return 0
	fi

	# AI inconclusive — default to escalate (safer: avoids infinite retry loops)
	echo "true"
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

	echo -e "${BOLD:-}Created diagnostic subtask:${NC:-} $diag_id"
	echo "  Parent task: $task_id ($tstatus)"
	echo "  Reason:      $failure_reason"
	echo "  Batch:       ${batch_id:-none}"
	echo ""
	echo "The diagnostic task will be dispatched on the next pulse cycle."
	echo "When it completes, $task_id will be automatically re-queued."
	return 0
}
