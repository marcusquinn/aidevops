#!/usr/bin/env bash
# ai-pulse-decisions.sh - AI judgment for pulse.sh phase 0-4 decision logic (t1315)
#
# Replaces four categories of deterministic heuristic trees with AI judgment:
#   1. Stale-state detection    → ai_diagnose_stale_root_cause()
#   2. Stale recovery routing   → ai_decide_stale_recovery()
#   3. Dispatch gating          → ai_decide_dispatch_gate()
#   4. Phase orchestration      → ai_decide_phase_orchestration()
#
# Architecture: GATHER (shell) → JUDGE (AI) → RETURN (shell)
# - Shell gathers all data (DB, PID files, logs, timestamps)
# - AI receives structured data and makes the judgment call
# - Shell parses AI response and returns in the same format as the original
# - Falls back to deterministic logic if AI is unavailable or returns garbage
#
# Phase sequencing and coordination remain 100% shell — AI only makes decisions.
#
# Cost: ~$0.001 per call with haiku. Pulse runs every 2-5 minutes.
# Budget: ~$0.005 per pulse cycle (5 decisions max).
#
# Sourced by: supervisor-helper.sh (after pulse.sh and dispatch.sh)
# Depends on: pulse.sh (original functions as fallback)
#             dispatch.sh (resolve_ai_cli, resolve_model)
#             _common.sh (portable_timeout, log_*)

# Globals expected from supervisor-helper.sh:
#   SUPERVISOR_DB, SUPERVISOR_LOG, SUPERVISOR_DIR, SCRIPT_DIR
#   db(), log_info(), log_warn(), log_error(), log_success(), sql_escape()
#   resolve_ai_cli(), resolve_model(), portable_timeout()

# Feature flag: enable/disable AI pulse decisions (default: enabled)
# Set to "false" to use deterministic logic exclusively.
AI_PULSE_DECISIONS_ENABLED="${AI_PULSE_DECISIONS_ENABLED:-true}"

# Model tier for pulse decisions — haiku is fast and cheap enough for
# structured classification tasks. These are pattern-matching decisions,
# not open-ended reasoning.
AI_PULSE_DECISIONS_MODEL="${AI_PULSE_DECISIONS_MODEL:-haiku}"

# Timeout for AI judgment calls (seconds) — these are quick classification
# tasks, not open-ended reasoning. 20s is generous for haiku.
AI_PULSE_DECISIONS_TIMEOUT="${AI_PULSE_DECISIONS_TIMEOUT:-20}"

# Log directory for decision audit trail
AI_PULSE_DECISIONS_LOG_DIR="${AI_PULSE_DECISIONS_LOG_DIR:-$HOME/.aidevops/logs/ai-pulse-decisions}"

# Counter: track AI calls per pulse to enforce budget
_AI_PULSE_CALL_COUNT=0
_AI_PULSE_MAX_CALLS="${AI_PULSE_MAX_CALLS_PER_CYCLE:-10}"

#######################################
# Internal: Call AI CLI with a prompt and return the raw response.
# Handles both opencode and claude CLIs, strips ANSI codes.
# Enforces per-pulse call budget.
#
# Args:
#   $1 - prompt text
#   $2 - title suffix for session naming
# Outputs:
#   Raw AI response on stdout (ANSI-stripped)
# Returns:
#   0 on success, 1 on failure (empty response, CLI unavailable, or budget exceeded)
#######################################
_ai_pulse_call() {
	local prompt="$1"
	local title_suffix="$2"

	# Budget guard: prevent runaway AI calls in a single pulse
	if [[ "$_AI_PULSE_CALL_COUNT" -ge "$_AI_PULSE_MAX_CALLS" ]]; then
		log_warn "ai-pulse-decisions: budget exceeded ($_AI_PULSE_CALL_COUNT/$_AI_PULSE_MAX_CALLS calls)"
		return 1
	fi
	_AI_PULSE_CALL_COUNT=$((_AI_PULSE_CALL_COUNT + 1))

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || {
		log_warn "ai-pulse-decisions: no AI CLI available"
		return 1
	}

	local ai_model
	ai_model=$(resolve_model "$AI_PULSE_DECISIONS_MODEL" "$ai_cli" 2>/dev/null) || {
		log_warn "ai-pulse-decisions: model $AI_PULSE_DECISIONS_MODEL unavailable"
		return 1
	}

	local ai_result=""
	local timeout_secs="$AI_PULSE_DECISIONS_TIMEOUT"

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(portable_timeout "$timeout_secs" opencode run \
			-m "$ai_model" \
			--format default \
			--title "pulse-${title_suffix}-$$" \
			"$prompt" </dev/null 2>/dev/null || echo "")
		# Strip ANSI escape codes
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		local claude_model="${ai_model#*/}"
		ai_result=$(portable_timeout "$timeout_secs" claude \
			-p "$prompt" \
			--model "$claude_model" \
			--output-format text </dev/null 2>/dev/null || echo "")
	fi

	if [[ -z "$ai_result" ]]; then
		return 1
	fi

	# Log for audit trail
	mkdir -p "$AI_PULSE_DECISIONS_LOG_DIR" 2>/dev/null || true
	local timestamp
	timestamp=$(date -u '+%Y%m%d-%H%M%S')
	{
		echo "# Pulse Decision: $title_suffix @ $timestamp"
		echo "Model: $ai_model | CLI: $ai_cli | Call: $_AI_PULSE_CALL_COUNT/$_AI_PULSE_MAX_CALLS"
		echo ""
		echo "## Prompt"
		echo "$prompt"
		echo ""
		echo "## Response"
		echo "$ai_result"
	} >"$AI_PULSE_DECISIONS_LOG_DIR/pulse-${title_suffix}-${timestamp}.md" 2>/dev/null || true

	printf '%s' "$ai_result"
	return 0
}

#######################################
# Internal: Extract a single-line verdict from AI response.
# Looks for lines matching a pattern like "key:value".
#
# Args:
#   $1 - raw AI response
#   $2 - regex pattern to match (e.g., '^(root_cause):(.+)')
# Outputs:
#   Matched line on stdout
# Returns:
#   0 if found, 1 if not
#######################################
_ai_pulse_extract_verdict() {
	local response="$1"
	local pattern="$2"

	local verdict
	verdict=$(printf '%s' "$response" | grep -oE "$pattern" | head -1 || echo "")

	if [[ -z "$verdict" ]]; then
		return 1
	fi

	printf '%s' "$verdict"
	return 0
}

#######################################
# Reset per-pulse AI call counter.
# Called at the start of each pulse cycle.
#######################################
ai_pulse_reset_budget() {
	_AI_PULSE_CALL_COUNT=0
	return 0
}

# =====================================================================
# 1. STALE-STATE DETECTION — replaces _diagnose_stale_root_cause()
# =====================================================================

#######################################
# Gather evidence about a stale task for AI diagnosis.
# Pure data collection — no decisions.
#
# Args:
#   $1 - task_id
#   $2 - stale_status (running|dispatched|evaluating)
# Outputs:
#   Structured evidence text on stdout
# Returns:
#   0 on success
#######################################
_gather_stale_evidence() {
	local task_id="$1"
	local stale_status="$2"
	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# DB state
	local log_file updated_at completed_at eval_started_at pr_url
	log_file=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	updated_at=$(db "$SUPERVISOR_DB" "SELECT updated_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	completed_at=$(db "$SUPERVISOR_DB" "SELECT completed_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	eval_started_at=$(db "$SUPERVISOR_DB" "SELECT evaluating_started_at FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	pr_url=$(db "$SUPERVISOR_DB" "SELECT pr_url FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	# Log file state
	local log_exists="false" log_size=0 log_tail_errors="" log_has_completion=""
	if [[ -n "$log_file" && -f "$log_file" ]]; then
		log_exists="true"
		log_size=$(wc -c <"$log_file" 2>/dev/null | tr -d ' ')
		if [[ "$log_size" -gt 0 ]]; then
			log_tail_errors=$(tail -20 "$log_file" 2>/dev/null | grep -oE 'WORKER_FAILED|DISPATCH_ERROR|command not found|Killed|OOM|out of memory|Cannot allocate|rate.limit|429|Too Many Requests' | head -5 | tr '\n' ',' || echo "none")
			log_has_completion=$(grep -c 'FULL_LOOP_COMPLETE\|TASK_COMPLETE' "$log_file" 2>/dev/null || echo "0")
		fi
	fi

	# Heartbeat state (for evaluating tasks)
	local secs_since_update="unknown"
	if [[ -n "$updated_at" ]]; then
		local updated_epoch now_epoch
		updated_epoch=$(_iso_to_epoch "$updated_at")
		now_epoch=$(date +%s 2>/dev/null || echo 0)
		if [[ "$updated_epoch" -gt 0 && "$now_epoch" -gt 0 ]]; then
			secs_since_update=$((now_epoch - updated_epoch))
		fi
	fi

	# Eval lag (for evaluating tasks)
	local eval_lag="unknown"
	if [[ -n "$completed_at" && -n "$eval_started_at" ]]; then
		local c_epoch e_epoch
		c_epoch=$(_iso_to_epoch "$completed_at")
		e_epoch=$(_iso_to_epoch "$eval_started_at")
		if [[ "$c_epoch" -gt 0 && "$e_epoch" -gt 0 ]]; then
			eval_lag=$((e_epoch - c_epoch))
		fi
	fi

	# Eval checkpoint file
	local eval_checkpoint_exists="false"
	local eval_checkpoint_file="${SUPERVISOR_DIR}/eval-checkpoints/${task_id}.eval"
	if [[ -f "$eval_checkpoint_file" ]]; then
		eval_checkpoint_exists="true"
	fi

	# Supervisor log evidence (for evaluating tasks)
	local supervisor_log_has_eval="false"
	if [[ -n "${SUPERVISOR_LOG:-}" && -f "$SUPERVISOR_LOG" ]]; then
		if tail -100 "$SUPERVISOR_LOG" 2>/dev/null | grep -q "evaluate_with_ai.*${task_id}\|AI eval.*${task_id}"; then
			supervisor_log_has_eval="true"
		fi
	fi

	# Eval timeout config
	local eval_timeout_cfg="${SUPERVISOR_EVAL_TIMEOUT:-90}"
	local heartbeat_window=$((eval_timeout_cfg * 2 + 60))

	cat <<EVIDENCE
task_id: $task_id
stale_status: $stale_status
log_file_exists: $log_exists
log_file_size: $log_size
log_tail_errors: ${log_tail_errors:-none}
log_has_completion_signal: $log_has_completion
updated_at: ${updated_at:-unknown}
secs_since_update: $secs_since_update
heartbeat_window: $heartbeat_window
completed_at: ${completed_at:-unknown}
eval_started_at: ${eval_started_at:-unknown}
eval_lag_secs: $eval_lag
eval_checkpoint_exists: $eval_checkpoint_exists
supervisor_log_has_eval_activity: $supervisor_log_has_eval
pr_url: ${pr_url:-none}
EVIDENCE
	return 0
}

#######################################
# AI-powered stale root cause diagnosis.
# Replaces the ~170-line _diagnose_stale_root_cause() heuristic tree.
#
# Args:
#   $1 - task_id
#   $2 - stale_status (running|dispatched|evaluating)
# Outputs:
#   Root cause string on stdout (same format as original)
# Side-effects:
#   Sets _DIAG_WORKER_COMPLETED_AT, _DIAG_EVAL_STARTED_AT,
#   _DIAG_EVAL_LAG_SECS for the caller (same as original)
# Returns:
#   0 always
#######################################
ai_diagnose_stale_root_cause() {
	local task_id="$1"
	local stale_status="$2"

	# Reset timing globals (same as original)
	_DIAG_WORKER_COMPLETED_AT=""
	_DIAG_EVAL_STARTED_AT=""
	_DIAG_EVAL_LAG_SECS="NULL"

	# Gather evidence
	local evidence
	evidence=$(_gather_stale_evidence "$task_id" "$stale_status")

	# Populate timing globals from evidence (for caller compatibility)
	_DIAG_WORKER_COMPLETED_AT=$(printf '%s' "$evidence" | grep '^completed_at:' | sed 's/^completed_at: *//' | sed 's/unknown//')
	_DIAG_EVAL_STARTED_AT=$(printf '%s' "$evidence" | grep '^eval_started_at:' | sed 's/^eval_started_at: *//' | sed 's/unknown//')
	local _lag
	_lag=$(printf '%s' "$evidence" | grep '^eval_lag_secs:' | sed 's/^eval_lag_secs: *//')
	if [[ "$_lag" != "unknown" && -n "$_lag" ]]; then
		_DIAG_EVAL_LAG_SECS="$_lag"
	fi

	# Feature flag check
	if [[ "${AI_PULSE_DECISIONS_ENABLED:-true}" != "true" ]]; then
		_diagnose_stale_root_cause "$task_id" "$stale_status"
		return 0
	fi

	local prompt
	prompt="You are a DevOps supervisor diagnosing why a task is stuck in a stale state.

EVIDENCE:
$evidence

POSSIBLE ROOT CAUSES (respond with EXACTLY ONE of these):
For evaluating tasks:
- eval_in_progress_heartbeat_Ns (if secs_since_update < heartbeat_window — task is actively evaluating, N = secs_since_update)
- eval_race_condition_negative_lag (if eval_lag is negative)
- eval_delayed_pickup_lag_Ns (if eval_lag > 30, N = eval_lag)
- worker_failed_before_eval (if log_tail_errors has WORKER_FAILED/DISPATCH_ERROR and secs_since_update >= heartbeat_window)
- pulse_killed_after_pr_persist (if pr_url is a real URL, not no_pr/task_only)
- pulse_killed_mid_eval (if eval_checkpoint_exists is true)
- ai_eval_timeout (if supervisor_log_has_eval_activity is true)
- eval_process_died (default for evaluating with no other match)

For running tasks:
- worker_oom_killed (if log_tail_errors has Killed/OOM/out of memory/Cannot allocate)
- worker_rate_limited (if log_tail_errors has rate.limit/429/Too Many Requests)
- worker_died_unknown (default for running)

For dispatched tasks:
- dispatch_never_started (always for dispatched)

General:
- no_log_file (if log_file_exists is false or log_file is empty path)
- empty_log_file (if log_file_exists is true but log_file_size is 0)
- unknown (if nothing matches)

CRITICAL: For eval_in_progress_heartbeat, replace N with the actual secs_since_update value.
For eval_delayed_pickup_lag, replace N with the actual eval_lag value.

Respond with EXACTLY ONE LINE: the root cause string. No explanation."

	local ai_result
	ai_result=$(_ai_pulse_call "$prompt" "stale-diag-${task_id}") || {
		# Fallback to deterministic logic
		log_info "ai-pulse-decisions: stale diagnosis fallback for $task_id"
		_diagnose_stale_root_cause "$task_id" "$stale_status"
		return 0
	}

	# Parse the verdict — find a line matching known root cause patterns
	local verdict
	verdict=$(printf '%s' "$ai_result" | tr -d '[:space:]' | head -c 200)
	# More lenient: extract the first word that looks like a root cause
	verdict=$(printf '%s' "$ai_result" | grep -oE '(eval_in_progress_heartbeat_[0-9]+s|eval_race_condition_negative_lag|eval_delayed_pickup_lag_[0-9]+s|worker_failed_before_eval|pulse_killed_after_pr_persist|pulse_killed_mid_eval|ai_eval_timeout|eval_process_died|worker_oom_killed|worker_rate_limited|worker_died_unknown|dispatch_never_started|no_log_file|empty_log_file|unknown)' | head -1 || echo "")

	if [[ -z "$verdict" ]]; then
		# AI returned unparseable response — fallback
		log_warn "ai-pulse-decisions: unparseable stale diagnosis for $task_id, falling back"
		_diagnose_stale_root_cause "$task_id" "$stale_status"
		return 0
	fi

	log_info "ai-pulse-decisions: stale diagnosis $task_id → $verdict (AI)"
	echo "$verdict"
	return 0
}

# =====================================================================
# 2. STALE RECOVERY ROUTING — replaces the if/elif/else tree in Phase 0.7
# =====================================================================

#######################################
# Gather evidence for stale recovery routing decision.
#
# Args:
#   $1 - task_id
#   $2 - stale_status
#   $3 - root_cause
#   $4 - retries
#   $5 - max_retries
#   $6 - pr_url
#   $7 - stale_secs
# Outputs:
#   Structured evidence text on stdout
#######################################
_gather_recovery_evidence() {
	local task_id="$1"
	local stale_status="$2"
	local root_cause="$3"
	local retries="$4"
	local max_retries="$5"
	local pr_url="$6"
	local stale_secs="$7"

	local has_pr="false"
	if [[ -n "$pr_url" && "$pr_url" != "no_pr" && "$pr_url" != "task_only" && "$pr_url" != "task_obsolete" ]]; then
		has_pr="true"
	fi

	cat <<EVIDENCE
task_id: $task_id
stale_status: $stale_status
root_cause: $root_cause
retries: $retries
max_retries: $max_retries
has_pr: $has_pr
pr_url: ${pr_url:-none}
stale_seconds: $stale_secs
is_rate_limited: $([ "$root_cause" = "worker_rate_limited" ] && echo "true" || echo "false")
EVIDENCE
	return 0
}

#######################################
# AI-powered stale recovery routing decision.
# Replaces the if/elif/else tree in Phase 0.7 that decides:
#   - pr_review (has PR, process died)
#   - queued (retries remaining, re-queue)
#   - failed (retries exhausted)
#
# Args:
#   $1 - task_id
#   $2 - stale_status
#   $3 - root_cause
#   $4 - retries
#   $5 - max_retries
#   $6 - pr_url
#   $7 - stale_secs
# Outputs:
#   Recovery action: "pr_review" or "queued" or "failed"
# Returns:
#   0 always
#######################################
ai_decide_stale_recovery() {
	local task_id="$1"
	local stale_status="$2"
	local root_cause="$3"
	local retries="$4"
	local max_retries="$5"
	local pr_url="$6"
	local stale_secs="$7"

	# Feature flag check
	if [[ "${AI_PULSE_DECISIONS_ENABLED:-true}" != "true" ]]; then
		_deterministic_stale_recovery "$task_id" "$stale_status" "$root_cause" "$retries" "$max_retries" "$pr_url"
		return 0
	fi

	local evidence
	evidence=$(_gather_recovery_evidence "$task_id" "$stale_status" "$root_cause" "$retries" "$max_retries" "$pr_url" "$stale_secs")

	local prompt
	prompt="You are a DevOps supervisor deciding how to recover a stale task.

EVIDENCE:
$evidence

DECISION RULES:
- If has_pr is true → pr_review (the work is done, only evaluation died)
- If retries < max_retries → queued (re-queue for another attempt)
- If retries >= max_retries → failed (retries exhausted, give up)
- If root_cause is eval_in_progress_heartbeat_* → skip (task is actively evaluating)

Respond with EXACTLY ONE WORD: pr_review, queued, failed, or skip"

	local ai_result
	ai_result=$(_ai_pulse_call "$prompt" "recovery-${task_id}") || {
		_deterministic_stale_recovery "$task_id" "$stale_status" "$root_cause" "$retries" "$max_retries" "$pr_url"
		return 0
	}

	local verdict
	verdict=$(printf '%s' "$ai_result" | grep -oE '(pr_review|queued|failed|skip)' | head -1 || echo "")

	if [[ -z "$verdict" ]]; then
		log_warn "ai-pulse-decisions: unparseable recovery decision for $task_id, falling back"
		_deterministic_stale_recovery "$task_id" "$stale_status" "$root_cause" "$retries" "$max_retries" "$pr_url"
		return 0
	fi

	log_info "ai-pulse-decisions: recovery $task_id → $verdict (AI)"
	echo "$verdict"
	return 0
}

#######################################
# Deterministic fallback for stale recovery routing.
# Preserves the original Phase 0.7 logic exactly.
#######################################
_deterministic_stale_recovery() {
	local task_id="$1"
	local stale_status="$2"
	local root_cause="$3"
	local retries="$4"
	local max_retries="$5"
	local pr_url="$6"

	local has_pr="false"
	if [[ -n "$pr_url" && "$pr_url" != "no_pr" && "$pr_url" != "task_only" && "$pr_url" != "task_obsolete" ]]; then
		has_pr="true"
	fi

	if [[ "$root_cause" == eval_in_progress_heartbeat_* ]]; then
		echo "skip"
	elif [[ "$has_pr" == "true" ]]; then
		echo "pr_review"
	elif [[ "$retries" -lt "$max_retries" ]]; then
		echo "queued"
	else
		echo "failed"
	fi
	return 0
}

# =====================================================================
# 3. DISPATCH GATING — replaces dispatch stall detection in Phase 2b
# =====================================================================

#######################################
# Gather evidence for dispatch gating decision.
#
# Args:
#   $1 - dispatched_count (this pulse)
#   $2 - batch_id (optional)
# Outputs:
#   Structured evidence text on stdout
#######################################
_gather_dispatch_evidence() {
	local dispatched_count="$1"
	local batch_id="${2:-}"

	local queued_count running_count active_batch_count
	queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
	running_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo 0)
	active_batch_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM batches WHERE status IN ('active', 'running');" 2>/dev/null || echo 0)

	local batch_info=""
	if [[ "$active_batch_count" -gt 0 ]]; then
		batch_info=$(db -separator '|' "$SUPERVISOR_DB" "
			SELECT id, concurrency, status FROM batches
			WHERE status IN ('active', 'running')
			LIMIT 1;" 2>/dev/null || echo "")
	fi

	# Recent dispatch stall count (last 24h)
	local recent_stalls
	recent_stalls=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM state_log
		WHERE task_id = 'supervisor' AND to_state = 'stalled'
		AND timestamp > datetime('now', '-24 hours');
	" 2>/dev/null || echo 0)

	cat <<EVIDENCE
dispatched_this_pulse: $dispatched_count
queued_count: $queued_count
running_count: $running_count
active_batch_count: $active_batch_count
batch_info: ${batch_info:-none}
batch_id_filter: ${batch_id:-none}
recent_stalls_24h: $recent_stalls
EVIDENCE
	return 0
}

#######################################
# AI-powered dispatch stall diagnosis.
# Replaces the Phase 2b heuristic that detects and recovers from
# dispatch stalls (queued tasks but nothing dispatched/running).
#
# Args:
#   $1 - dispatched_count (this pulse)
#   $2 - batch_id (optional)
# Outputs:
#   JSON: {"stalled":true/false,"action":"none|create_batch|log_diagnostic","reason":"..."}
# Returns:
#   0 always
#######################################
ai_decide_dispatch_gate() {
	local dispatched_count="$1"
	local batch_id="${2:-}"

	# Feature flag check
	if [[ "${AI_PULSE_DECISIONS_ENABLED:-true}" != "true" ]]; then
		_deterministic_dispatch_gate "$dispatched_count" "$batch_id"
		return 0
	fi

	local evidence
	evidence=$(_gather_dispatch_evidence "$dispatched_count" "$batch_id")

	local prompt
	prompt="You are a DevOps supervisor checking if the dispatch pipeline is stalled.

EVIDENCE:
$evidence

DECISION RULES:
- If dispatched_this_pulse > 0 → not stalled (dispatch is working)
- If queued_count == 0 → not stalled (nothing to dispatch)
- If running_count > 0 → not stalled (workers are active)
- If queued_count > 0 AND running_count == 0 AND dispatched_this_pulse == 0 → STALLED
  - If active_batch_count == 0 → action: create_batch (no batch to dispatch from)
  - If active_batch_count > 0 → action: log_diagnostic (batch exists but dispatch failed)

Respond with EXACTLY ONE LINE in this format:
stalled:false
OR
stalled:true action:create_batch reason:no active batch
OR
stalled:true action:log_diagnostic reason:batch exists but dispatch produced 0"

	local ai_result
	ai_result=$(_ai_pulse_call "$prompt" "dispatch-gate") || {
		_deterministic_dispatch_gate "$dispatched_count" "$batch_id"
		return 0
	}

	# Parse: look for stalled:true/false
	local is_stalled
	is_stalled=$(printf '%s' "$ai_result" | grep -oE 'stalled:(true|false)' | head -1 | cut -d: -f2 || echo "")

	if [[ -z "$is_stalled" ]]; then
		log_warn "ai-pulse-decisions: unparseable dispatch gate decision, falling back"
		_deterministic_dispatch_gate "$dispatched_count" "$batch_id"
		return 0
	fi

	local action="none"
	local reason=""
	if [[ "$is_stalled" == "true" ]]; then
		action=$(printf '%s' "$ai_result" | grep -oE 'action:(create_batch|log_diagnostic)' | head -1 | cut -d: -f2 || echo "log_diagnostic")
		reason=$(printf '%s' "$ai_result" | sed -n 's/.*reason:\(.*\)/\1/p' | head -1 || echo "dispatch stall detected")
	fi

	log_info "ai-pulse-decisions: dispatch gate → stalled:$is_stalled action:$action (AI)"
	printf '{"stalled":%s,"action":"%s","reason":"%s"}' "$is_stalled" "$action" "$reason"
	return 0
}

#######################################
# Deterministic fallback for dispatch gating.
# Preserves the original Phase 2b logic exactly.
#######################################
_deterministic_dispatch_gate() {
	local dispatched_count="$1"
	local batch_id="${2:-}"

	if [[ "$dispatched_count" -gt 0 ]]; then
		printf '{"stalled":false,"action":"none","reason":"dispatched this pulse"}'
		return 0
	fi

	local queued_count running_count
	queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
	running_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo 0)

	if [[ "$queued_count" -gt 0 && "$running_count" -eq 0 ]]; then
		local active_batch_count
		active_batch_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM batches WHERE status IN ('active', 'running');" 2>/dev/null || echo 0)
		if [[ "$active_batch_count" -eq 0 ]]; then
			printf '{"stalled":true,"action":"create_batch","reason":"no active batch"}'
		else
			printf '{"stalled":true,"action":"log_diagnostic","reason":"batch exists but dispatch produced 0"}'
		fi
	else
		printf '{"stalled":false,"action":"none","reason":"pipeline healthy"}'
	fi
	return 0
}

# =====================================================================
# 4. PHASE ORCHESTRATION — replaces Phase 0.9 sanity check gating
# =====================================================================

#######################################
# Gather evidence for phase orchestration decision.
#
# Args:
#   $1 - phase name (e.g., "sanity_check", "reconcile")
#   $2 - repo_path
# Outputs:
#   Structured evidence text on stdout
#######################################
_gather_orchestration_evidence() {
	local phase_name="$1"
	local repo_path="$2"

	local queued_count running_count total_tasks
	queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
	running_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo 0)
	total_tasks=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks;" 2>/dev/null || echo 0)

	local open_todo_count=0
	if [[ -f "$repo_path/TODO.md" ]]; then
		open_todo_count=$(grep -cE '^\s*- \[ \] t[0-9]+' "$repo_path/TODO.md" 2>/dev/null || echo 0)
	fi

	# Recent sanity check results
	local recent_sanity_fixes
	recent_sanity_fixes=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM state_log
		WHERE reason LIKE '%sanity%'
		AND timestamp > datetime('now', '-1 hour');
	" 2>/dev/null || echo 0)

	cat <<EVIDENCE
phase: $phase_name
queued_count: $queued_count
running_count: $running_count
total_tasks: $total_tasks
open_todo_count: $open_todo_count
recent_sanity_fixes_1h: $recent_sanity_fixes
EVIDENCE
	return 0
}

#######################################
# AI-powered phase orchestration decision.
# Decides whether to run optional phases like sanity check, reconciliation.
#
# Args:
#   $1 - phase name
#   $2 - repo_path
# Outputs:
#   "run" or "skip" with optional reason
# Returns:
#   0 always
#######################################
ai_decide_phase_orchestration() {
	local phase_name="$1"
	local repo_path="$2"

	# Feature flag check
	if [[ "${AI_PULSE_DECISIONS_ENABLED:-true}" != "true" ]]; then
		_deterministic_phase_orchestration "$phase_name" "$repo_path"
		return 0
	fi

	local evidence
	evidence=$(_gather_orchestration_evidence "$phase_name" "$repo_path")

	local prompt
	prompt="You are a DevOps supervisor deciding whether to run an optional maintenance phase.

EVIDENCE:
$evidence

DECISION RULES for sanity_check:
- Run if queued_count == 0 AND open_todo_count > 0 (queue empty but tasks exist — something may be stuck)
- Skip if queued_count > 0 (queue has work, no need to question assumptions)
- Skip if open_todo_count == 0 (no open tasks to check)

DECISION RULES for reconcile:
- Run if running_count == 0 AND queued_count == 0 (idle — good time to reconcile)
- Skip if running_count > 0 OR queued_count > 0 (active work — don't interfere)

Respond with EXACTLY ONE WORD: run or skip"

	local ai_result
	ai_result=$(_ai_pulse_call "$prompt" "orchestration-${phase_name}") || {
		_deterministic_phase_orchestration "$phase_name" "$repo_path"
		return 0
	}

	local verdict
	verdict=$(printf '%s' "$ai_result" | grep -oE '(run|skip)' | head -1 || echo "")

	if [[ -z "$verdict" ]]; then
		log_warn "ai-pulse-decisions: unparseable orchestration decision for $phase_name, falling back"
		_deterministic_phase_orchestration "$phase_name" "$repo_path"
		return 0
	fi

	log_info "ai-pulse-decisions: orchestration $phase_name → $verdict (AI)"
	echo "$verdict"
	return 0
}

#######################################
# Deterministic fallback for phase orchestration.
#######################################
_deterministic_phase_orchestration() {
	local phase_name="$1"
	local repo_path="$2"

	case "$phase_name" in
	sanity_check)
		local queued_count
		queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
		if [[ "$queued_count" -eq 0 ]]; then
			echo "run"
		else
			echo "skip"
		fi
		;;
	reconcile)
		local running_count queued_count
		running_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'dispatched');" 2>/dev/null || echo 0)
		queued_count=$(db "$SUPERVISOR_DB" "SELECT COUNT(*) FROM tasks WHERE status = 'queued';" 2>/dev/null || echo 0)
		if [[ "$running_count" -eq 0 && "$queued_count" -eq 0 ]]; then
			echo "run"
		else
			echo "skip"
		fi
		;;
	*)
		echo "run"
		;;
	esac
	return 0
}
