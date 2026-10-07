#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Start/resume infrastructure, lifecycle commands, and completion reconciliation.
# Inherits globals and dependencies from the lifecycle orchestrator.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_FULL_LOOP_STATE_COMMANDS_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_COMMANDS_LOADED=1

# --- Start/Resume Infrastructure ---

# Initialize option variables with defaults so set -u doesn't crash on
# export when flags are not passed.
_init_start_defaults() {
	MAX_TASK_ITERATIONS="${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}"
	MAX_PREFLIGHT_ITERATIONS="${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}"
	MAX_PR_ITERATIONS="${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}"
	SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
	SKIP_POSTFLIGHT="${SKIP_POSTFLIGHT:-false}"
	SKIP_RUNTIME_TESTING="${SKIP_RUNTIME_TESTING:-false}"
	NO_AUTO_PR="${NO_AUTO_PR:-false}"
	NO_AUTO_DEPLOY="${NO_AUTO_DEPLOY:-false}"
	if [[ "${AIDEVOPS_RELEASE_INTENT_TRUSTED:-}" == "1" ]]; then
		RELEASE_INTENT="$_FULL_LOOP_BOOL_TRUE"
	else
		RELEASE_INTENT="${RELEASE_INTENT:-false}"
	fi
	RELEASE_TYPE="${RELEASE_TYPE:-${AIDEVOPS_RELEASE_TYPE:-patch}}"
	DEPLOYMENT_SCOPE="${DEPLOYMENT_SCOPE:-${AIDEVOPS_RELEASE_DEPLOY_SCOPE:-incremental}}"
	RELEASE_EXPECTED_SOURCES="${RELEASE_EXPECTED_SOURCES:-${AIDEVOPS_RELEASE_EXPECTED_SOURCES:-}}"
	RELEASE_STATUS="${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}"
	DRY_RUN="${DRY_RUN:-false}"
	_BACKGROUND=false
	return 0
}

# Parse start subcommand options. Sets global option variables and _BACKGROUND.
# Arguments: all remaining args after the prompt string.
# Returns: 0 on success, 1 on unknown option.
_parse_start_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-task-iterations)
			MAX_TASK_ITERATIONS="$2"
			shift 2
			;;
		--max-preflight-iterations)
			MAX_PREFLIGHT_ITERATIONS="$2"
			shift 2
			;;
		--max-pr-iterations)
			MAX_PR_ITERATIONS="$2"
			shift 2
			;;
		--skip-preflight)
			SKIP_PREFLIGHT=true
			shift
			;;
		--skip-postflight)
			SKIP_POSTFLIGHT=true
			shift
			;;
		--skip-runtime-testing)
			SKIP_RUNTIME_TESTING=true
			shift
			;;
		--no-auto-pr)
			NO_AUTO_PR=true
			shift
			;;
		--no-auto-deploy)
			NO_AUTO_DEPLOY=true
			shift
			;;
		--release-intent)
			RELEASE_INTENT=true
			RELEASE_STATUS=authorized
			shift
			;;
		--release-type)
			RELEASE_TYPE="${2:-}"
			case "$RELEASE_TYPE" in patch | minor | major) ;; *)
				print_error "Invalid release type: $RELEASE_TYPE"
				return 1
				;;
			esac
			RELEASE_INTENT=true
			RELEASE_STATUS=authorized
			shift 2
			;;
		--deployment-scope)
			DEPLOYMENT_SCOPE="${2:-}"
			case "$DEPLOYMENT_SCOPE" in incremental | full) ;; *)
				print_error "Invalid deployment scope: $DEPLOYMENT_SCOPE"
				return 1
				;;
			esac
			shift 2
			;;
		--release-expected-sources)
			RELEASE_EXPECTED_SOURCES="${2:-}"
			[[ -n "$RELEASE_EXPECTED_SOURCES" ]] || {
				print_error "Release expected sources cannot be empty"
				return 1
			}
			RELEASE_INTENT=true
			RELEASE_STATUS=authorized
			shift 2
			;;
		--headless)
			HEADLESS=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--background | --bg)
			_BACKGROUND=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Launch the loop asynchronously in the local session via nohup.
# Arguments: $1 — prompt string.
_launch_background() {
	local prompt="$1"
	mkdir -p "$STATE_DIR"
	# The shell helper is a lifecycle coordinator, not an AI executor. Unless a
	# runtime adapter explicitly supplies an executor, persist an honest
	# initialized-only checkpoint instead of launching a child that prints one
	# prompt, exits, and is then incorrectly reported as a running loop.
	if [[ -z "${AIDEVOPS_FULL_LOOP_EXECUTOR:-}" ]]; then
		EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
		EXECUTOR_PID=""
		NEXT_ACTION="attach-executor-or-resume"
		PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
		save_state "$_FULL_LOOP_PHASE_TASK" "$prompt" "" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
		_full_loop_append_event "executor.initialized" "$_FULL_LOOP_EXECUTOR_INITIALIZED"
		print_warning "Background loop initialized, but no executor was launched."
		printf 'FULL_LOOP_START_RESULT=initialized-only\n'
		return 0
	fi
	export AIDEVOPS_RELEASE_TYPE="$RELEASE_TYPE" AIDEVOPS_RELEASE_DEPLOY_SCOPE="$DEPLOYMENT_SCOPE"
	export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
	export SKIP_PREFLIGHT SKIP_POSTFLIGHT SKIP_RUNTIME_TESTING NO_AUTO_PR NO_AUTO_DEPLOY RELEASE_INTENT RELEASE_TYPE DEPLOYMENT_SCOPE RELEASE_STATUS FULL_LOOP_HEADLESS="$HEADLESS"
	local heartbeat_file="${STATE_DIR}/full-loop.heartbeat"
	export AIDEVOPS_FULL_LOOP_RUN_ID="$RUN_ID"
	export AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE="$heartbeat_file"
	nohup "$AIDEVOPS_FULL_LOOP_EXECUTOR" "$0" "$prompt" >"${STATE_DIR}/full-loop.log" 2>&1 &
	EXECUTOR_PID="$!"
	EXECUTOR_IDENTITY="${AIDEVOPS_FULL_LOOP_EXECUTOR##*/}"
	echo "$EXECUTOR_PID" >"${STATE_DIR}/full-loop.pid"
	local handshake_attempt=0
	local handshake_limit="${AIDEVOPS_FULL_LOOP_HANDSHAKE_ATTEMPTS:-100}"
	[[ "$handshake_limit" =~ ^[1-9][0-9]*$ ]] || handshake_limit=100
	local heartbeat_run=""
	while [[ "$handshake_attempt" -lt "$handshake_limit" ]]; do
		handshake_attempt=$((handshake_attempt + 1))
		if [[ -f "$heartbeat_file" ]]; then
			read -r heartbeat_run HEARTBEAT_AT <"$heartbeat_file" || true
			[[ "$heartbeat_run" == "$RUN_ID" ]] && break
		fi
		kill -0 "$EXECUTOR_PID" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$EXECUTOR_PID" 2>/dev/null && [[ "$heartbeat_run" == "$RUN_ID" ]]; then
		EXECUTOR_STATUS="$_FULL_LOOP_PHASE_RUNNING"
		HEARTBEAT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		NEXT_ACTION="monitor"
		PHASE_STATUS="$_FULL_LOOP_PHASE_RUNNING"
		save_state "$_FULL_LOOP_PHASE_TASK" "$prompt" "" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
		_full_loop_append_event "executor.started" "$_FULL_LOOP_PHASE_RUNNING"
		print_success "Background executor started (PID: ${EXECUTOR_PID}). Use 'status' or 'logs' to monitor."
		printf 'FULL_LOOP_START_RESULT=running\n'
		return 0
	fi
	kill "$EXECUTOR_PID" 2>/dev/null || true
	EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
	EXECUTOR_PID=""
	NEXT_ACTION="attach-executor-or-resume"
	PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
	save_state "$_FULL_LOOP_PHASE_TASK" "$prompt" "" "${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	_full_loop_append_event "executor.start_failed" "$_FULL_LOOP_EXECUTOR_INITIALIZED"
	print_warning "Background executor exited before liveness could be verified."
	printf 'FULL_LOOP_START_RESULT=initialized-only\n'
	return 0
}

_full_loop_iso_epoch() {
	local timestamp="$1"
	local epoch=""
	epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" '+%s' 2>/dev/null || true)
	if [[ -z "$epoch" ]]; then
		epoch=$(date -u -d "$timestamp" '+%s' 2>/dev/null || true)
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$epoch"
	return 0
}

_full_loop_acquire_transition_lock() {
	local lock_file="${STATE_DIR}/full-loop-transition.lock"
	local reclaim_dir="${lock_file}.reclaim"
	local current_token=""
	if [[ -n "$FULL_LOOP_TRANSITION_LOCK_TOKEN" && -f "$lock_file" ]]; then
		current_token=$(<"$lock_file")
		if [[ "$current_token" == "$FULL_LOOP_TRANSITION_LOCK_TOKEN" ]]; then
			FULL_LOOP_TRANSITION_LOCK_DEPTH=$((FULL_LOOP_TRANSITION_LOCK_DEPTH + 1))
			return 0
		fi
	fi
	mkdir -p "$STATE_DIR" || return 1
	local attempt=0 candidate="" token="" owner_pid=""
	while [[ "$attempt" -lt 2 ]]; do
		attempt=$((attempt + 1))
		candidate=$(mktemp "${STATE_DIR}/.full-loop-transition.XXXXXX") || return 1
		token="$$:$(date +%s):${RANDOM}"
		printf '%s\n' "$token" >"$candidate"
		if ln "$candidate" "$lock_file" 2>/dev/null; then
			rm -f "$candidate"
			FULL_LOOP_TRANSITION_LOCK_TOKEN="$token"
			FULL_LOOP_TRANSITION_LOCK_DEPTH=1
			return 0
		fi
		rm -f "$candidate"
		current_token=$(cat "$lock_file" 2>/dev/null || true)
		owner_pid=${current_token%%:*}
		if [[ "$current_token" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
			print_error "Another lifecycle transition owns the full-loop state lock (PID: ${owner_pid})"
			return 1
		fi
		mkdir "$reclaim_dir" 2>/dev/null || return 1
		if [[ "$(cat "$lock_file" 2>/dev/null || true)" == "$current_token" ]]; then
			rm -f "$lock_file"
		fi
		rmdir "$reclaim_dir" 2>/dev/null || true
	done
	print_error "Could not acquire the full-loop state transition lock"
	return 1
}

_full_loop_release_transition_lock() {
	local lock_file="${STATE_DIR}/full-loop-transition.lock"
	[[ "$FULL_LOOP_TRANSITION_LOCK_DEPTH" -gt 0 ]] || return 0
	FULL_LOOP_TRANSITION_LOCK_DEPTH=$((FULL_LOOP_TRANSITION_LOCK_DEPTH - 1))
	[[ "$FULL_LOOP_TRANSITION_LOCK_DEPTH" -eq 0 ]] || return 0
	local current_token=""
	[[ -f "$lock_file" ]] && current_token=$(<"$lock_file")
	if [[ -n "$FULL_LOOP_TRANSITION_LOCK_TOKEN" && "$current_token" == "$FULL_LOOP_TRANSITION_LOCK_TOKEN" ]]; then
		rm -f "$lock_file"
	fi
	FULL_LOOP_TRANSITION_LOCK_TOKEN=""
	return 0
}

# --- Lifecycle Commands ---

_cmd_start_locked() {
	local prompt="$1"
	shift

	_init_start_defaults
	_parse_start_options "$@" || return 1
	if [[ "$RELEASE_INTENT" == "$_FULL_LOOP_BOOL_TRUE" && "$HEADLESS" != "$_FULL_LOOP_BOOL_TRUE" ]]; then
		export AIDEVOPS_RELEASE_INTENT_TRUSTED=1
	fi
	export AIDEVOPS_RELEASE_TYPE="$RELEASE_TYPE" AIDEVOPS_RELEASE_DEPLOY_SCOPE="$DEPLOYMENT_SCOPE"

	if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" ]] && is_headless; then
		print_error "Interactive issue implementation cannot enter headless/remote worker routing"
		return 1
	fi

	[[ -z "$prompt" ]] && {
		print_error "Usage: full-loop-helper.sh start \"<prompt>\" [options]"
		return 1
	}
	is_loop_active && {
		print_warning "Loop already active. Use 'resume' or 'cancel'."
		return 1
	}
	is_on_feature_branch || {
		print_error "Must be in a safe linked worktree"
		return 1
	}

	# Pre-start maintainer gate check (GH#17810/GH#22854): block if linked issue
	# has needs-maintainer-review label; in headless mode also block missing
	# assignee. Interactive sessions may claim an unassigned maintainer-supplied
	# issue below instead of treating the missing assignment as fatal.
	_check_linked_issue_gate "$prompt" || return 1

	# Interactive claim (t2056 hardening): when not headless, automatically
	# claim the linked issue so the pulse cannot dispatch a parallel worker
	# during the window between start and PR creation. This closes the race
	# that prompt-only enforcement missed (GH#18775 incident).
	_auto_claim_interactive "$prompt"

	printf "\n${BOLD}${BLUE}=== FULL DEVELOPMENT LOOP - STARTING ===${NC}\n  Task: %s\n  Branch: %s | Headless: %s\n\n" \
		"$prompt" "$(get_current_branch)" "$HEADLESS"
	[[ "${DRY_RUN:-$_FULL_LOOP_BOOL_FALSE}" == "$_FULL_LOOP_BOOL_TRUE" ]] && {
		print_info "Dry run - no changes made"
		return 0
	}

	PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
	PHASE_ATTEMPT=1
	PHASE_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	NEXT_ACTION="complete-task-development"
	EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
	save_state "$_FULL_LOOP_PHASE_TASK" "$prompt"
	SAVED_PROMPT="$prompt"
	_full_loop_append_event "phase.started" "$_FULL_LOOP_PHASE_WAITING"

	if [[ "$_BACKGROUND" == "$_FULL_LOOP_BOOL_TRUE" ]]; then
		_launch_background "$prompt"
		return 0
	fi
	emit_task_phase "$prompt"
}

cmd_start() {
	_full_loop_acquire_transition_lock || return 1
	local status=0
	_cmd_start_locked "$@" || status=$?
	_full_loop_release_transition_lock
	return "$status"
}

# Phase transition map: current -> next phase + emit function
_next_phase() {
	case "$1" in
	task) echo "preflight emit_preflight_phase" ;;
	preflight) echo "pr-create emit_pr_create_phase" ;;
	pr-create) echo "pr-review emit_pr_review_phase" ;;
	pr-review) echo "postflight emit_postflight_phase" ;;
	postflight) echo "deploy emit_deploy_phase" ;;
	deploy) echo "complete cmd_complete" ;;
	complete) echo "complete cmd_complete" ;;
	*) return 1 ;;
	esac
}

cmd_resume() {
	is_loop_active || {
		print_error "No active loop to resume"
		return 1
	}
	_full_loop_acquire_transition_lock || return 1
	load_state || {
		_full_loop_release_transition_lock
		return 1
	}
	print_info "Resuming from phase: $CURRENT_PHASE"
	MANUAL_RESUME_COUNT=$((MANUAL_RESUME_COUNT + 1))
	PHASE_STATUS="$_FULL_LOOP_PHASE_COMPLETED"
	PHASE_ENDED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	TERMINAL_EVIDENCE="manual-resume"
	_full_loop_append_event "phase.completed" "$_FULL_LOOP_PHASE_COMPLETED"
	local transition
	transition=$(_next_phase "$CURRENT_PHASE") || {
		print_error "Unknown phase: $CURRENT_PHASE"
		_full_loop_release_transition_lock
		return 1
	}
	local next_phase="${transition%% *}" emit_fn="${transition#* }"
	PHASE_STATUS="$_FULL_LOOP_PHASE_RUNNING"
	PHASE_ATTEMPT=1
	PHASE_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	PHASE_ENDED_AT=""
	NEXT_ACTION="run-${next_phase}"
	TERMINAL_EVIDENCE=""
	save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
	CURRENT_PHASE="$next_phase"
	_full_loop_append_event "phase.started" "$_FULL_LOOP_PHASE_RUNNING"
	if ! "$emit_fn"; then
		PHASE_STATUS="$_FULL_LOOP_PHASE_FAILED"
		NEXT_ACTION="retry-${next_phase}"
		_full_loop_append_event "phase.failed" "$_FULL_LOOP_PHASE_FAILED"
		save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
		_full_loop_release_transition_lock
		return 1
	fi
	PHASE_STATUS="$_FULL_LOOP_PHASE_WAITING"
	NEXT_ACTION="complete-${next_phase}"
	save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
	_full_loop_release_transition_lock
	return 0
}

_full_loop_record_phase() {
	local phase="$1"
	local pr_number="$2"
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ -f "$STATE_FILE" ]] || return 0
	_full_loop_acquire_transition_lock || return 1
	load_state || {
		_full_loop_release_transition_lock
		return 1
	}
	PR_NUMBER="$pr_number"
	if ! save_state "$phase" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"; then
		_full_loop_release_transition_lock
		return 1
	fi
	_full_loop_release_transition_lock
	return 0
}

_full_loop_record_merged_pr() {
	local pr_number="$1"
	_full_loop_record_phase "pr-review" "$pr_number"
	return $?
}

_full_loop_status_receipt_projection() {
	local cleanup_receipt="$1"
	local repo="$2"
	local pr_number="$3"

	[[ -f "$cleanup_receipt" && ! -L "$cleanup_receipt" ]] || return 1
	jq -er --arg repo "$repo" --argjson pr "$pr_number" \
		--arg complete "$_FULL_LOOP_EXECUTOR_COMPLETE" \
		--arg finalization_pending "$_FULL_LOOP_EXECUTOR_FINALIZATION_PENDING" \
		--arg deferred "$_FULL_LOOP_CLEANUP_DEFERRED" \
		--arg leased "$_FULL_LOOP_CLEANUP_LEASED" \
		--arg cleaned "$_FULL_LOOP_CLEANUP_CLEANED" '
		select(
			.schema_version == 1
			and .repository == $repo
			and .pr_number == $pr
			and (.worktree | type == "string" and length > 0)
			and (.executor_completion_state == $complete or .executor_completion_state == $finalization_pending)
			and (.resource_cleanup_state == $deferred or .resource_cleanup_state == $leased or .resource_cleanup_state == $cleaned)
		)
		| [.executor_completion_state, .resource_cleanup_state, .worktree]
		| @tsv
	' "$cleanup_receipt" 2>/dev/null
	return $?
}

cmd_status() {
	is_loop_active || {
		if [[ "${1:-}" == "--json" ]]; then
			printf '{"active":false,"executor_status":"inactive","executor_completion_state":"inactive","resource_cleanup_state":"%s"}\n' "$_FULL_LOOP_RESOURCE_NONE"
			return 0
		fi
		echo "No active full loop"
		return 0
	}
	load_state
	local observed_status="$EXECUTOR_STATUS"
	local executor_completion_state="$_FULL_LOOP_EXECUTOR_IN_PROGRESS"
	local resource_cleanup_state="$_FULL_LOOP_RESOURCE_NONE"
	local cleanup_worktree=""
	local cleanup_receipt=""
	local status_next_action="$NEXT_ACTION"
	local phase_is_historical=false
	local status_repo=""
	local receipt_projection=""
	if [[ "$observed_status" == "$_FULL_LOOP_PHASE_RUNNING" ]]; then
		local observed_command=""
		local heartbeat_file="${STATE_DIR}/full-loop.heartbeat"
		local heartbeat_run="" heartbeat_timestamp=""
		local heartbeat_epoch=0 now_epoch=0 max_heartbeat_age="${AIDEVOPS_FULL_LOOP_HEARTBEAT_MAX_AGE_SECONDS:-120}"
		[[ -f "$heartbeat_file" ]] && read -r heartbeat_run heartbeat_timestamp <"$heartbeat_file" || true
		heartbeat_epoch=$(_full_loop_iso_epoch "$heartbeat_timestamp" 2>/dev/null || printf '0')
		now_epoch=$(date +%s)
		[[ "$max_heartbeat_age" =~ ^[1-9][0-9]*$ ]] || max_heartbeat_age=120
		[[ "$EXECUTOR_PID" =~ ^[0-9]+$ ]] && observed_command=$(ps -p "$EXECUTOR_PID" -o command= 2>/dev/null || true)
		if [[ ! "$EXECUTOR_PID" =~ ^[0-9]+$ ]] || ! kill -0 "$EXECUTOR_PID" 2>/dev/null ||
			[[ -z "$EXECUTOR_IDENTITY" || "$observed_command" != *"$EXECUTOR_IDENTITY"* || "$heartbeat_run" != "$RUN_ID" ]] ||
			[[ "$heartbeat_epoch" -eq 0 || $((now_epoch - heartbeat_epoch)) -gt "$max_heartbeat_age" ]]; then
			observed_status="stale"
		fi
	fi
	if [[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		if [[ -n "${AIDEVOPS_FULL_LOOP_REPO:-}" ]]; then
			status_repo=$(_full_loop_resolve_repo "$AIDEVOPS_FULL_LOOP_REPO" 2>/dev/null || true)
		elif [[ "${REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
			status_repo="$REPOSITORY"
		else
			status_repo=$(_full_loop_resolve_repo "" 2>/dev/null || true)
		fi
		if [[ -n "$status_repo" ]] && declare -F _full_loop_cleanup_receipt_path >/dev/null 2>&1; then
			cleanup_receipt=$(_full_loop_cleanup_receipt_path "$status_repo" "$PR_NUMBER" 2>/dev/null || true)
		fi
	fi
	if [[ -n "$cleanup_receipt" && -n "$status_repo" ]] &&
		receipt_projection=$(_full_loop_status_receipt_projection "$cleanup_receipt" "$status_repo" "$PR_NUMBER"); then
		IFS=$'\t' read -r executor_completion_state resource_cleanup_state cleanup_worktree <<<"$receipt_projection"
		if [[ "$executor_completion_state" == "$_FULL_LOOP_EXECUTOR_COMPLETE" ]]; then
			observed_status="complete"
			phase_is_historical=true
			case "$resource_cleanup_state" in
			"$_FULL_LOOP_CLEANUP_CLEANED") status_next_action="none" ;;
			*) status_next_action="await-resource-cleanup" ;;
			esac
		elif [[ "$executor_completion_state" == "$_FULL_LOOP_EXECUTOR_FINALIZATION_PENDING" ]]; then
			status_next_action="complete"
		fi
	fi
	if [[ "${1:-}" == "--json" ]]; then
		jq -cn --arg run_id "$RUN_ID" --arg phase "$CURRENT_PHASE" --arg phase_status "$PHASE_STATUS" \
			--arg executor_status "$observed_status" --arg next_action "$status_next_action" --arg pr_number "${PR_NUMBER:-}" \
			--arg executor_completion_state "$executor_completion_state" --arg resource_cleanup_state "$resource_cleanup_state" \
			--arg cleanup_worktree "$cleanup_worktree" \
			--arg heartbeat_at "${heartbeat_timestamp:-${HEARTBEAT_AT:-}}" \
			--argjson phase_is_historical "$phase_is_historical" \
			--argjson revision "$STATE_REVISION" --argjson attempts "$PHASE_ATTEMPT" --argjson manual_resumes "$MANUAL_RESUME_COUNT" \
			'{run_id:$run_id,phase:$phase,phase_status:$phase_status,phase_is_historical:$phase_is_historical,executor_status:$executor_status,executor_completion_state:$executor_completion_state,resource_cleanup_state:$resource_cleanup_state,cleanup_worktree:$cleanup_worktree,heartbeat_at:$heartbeat_at,next_action:$next_action,pr_number:$pr_number,state_revision:$revision,phase_attempts:$attempts,manual_resumes:$manual_resumes}'
		return 0
	fi
	local phase_label="Phase"
	[[ "$phase_is_historical" == true ]] && phase_label="Recorded phase"
	printf "\n${BOLD}Full Loop Status${NC}\n%s: ${CYAN}%s${NC} | Started: %s | PR: %s | Headless: %s\nPrompt: %s\n\n" \
		"$phase_label" \
		"$CURRENT_PHASE" "$STARTED_AT" "${PR_NUMBER:-none}" "$HEADLESS" "$(echo "$SAVED_PROMPT" | head -3)"
	printf 'Executor: %s (%s) | Resource cleanup: %s | Phase status: %s | Attempts: %s | Next: %s\n' \
		"$observed_status" "$executor_completion_state" "$resource_cleanup_state" "$PHASE_STATUS" "$PHASE_ATTEMPT" "$status_next_action"
	return 0
}

_cmd_cancel_locked() {
	is_loop_active || {
		print_warning "No active loop to cancel"
		return 0
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && {
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
		}
		rm -f "$pid_file"
	fi
	rm -f "$STATE_FILE" ".agents/loop-state/quality-loop.local.state" 2>/dev/null
	print_success "Full loop cancelled"
	return 0
}

cmd_cancel() {
	_full_loop_acquire_transition_lock || return 1
	local status=0
	_cmd_cancel_locked "$@" || status=$?
	_full_loop_release_transition_lock
	return "$status"
}

cmd_logs() {
	local log_file="${STATE_DIR}/full-loop.log" lines="${1:-50}"
	[[ -f "$log_file" ]] || {
		print_warning "No log file. Start with --background first."
		return 1
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && print_info "Running (PID: $pid)" || print_warning "Not running (was PID: $pid)"
	fi
	printf "\n${BOLD}Full Loop Logs (last %d lines)${NC}\n" "$lines"
	tail -n "$lines" "$log_file"
}

_full_loop_reconcile_published_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	local receipt_status=""
	local previous_status="${RELEASE_STATUS:-}"
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ "$receipt_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]] || return 1
	if [[ "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_verify_superseded_release_receipt "$repo" "$pr_number" || return 1
	fi
	if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$receipt_status" || return 1
	fi
	RELEASE_STATUS="$receipt_status"
	if ! save_state "${CURRENT_PHASE:-${PHASE:-complete}}" "$SAVED_PROMPT" "$pr_number" \
		"${STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"; then
		RELEASE_STATUS="$previous_status"
		return 1
	fi
	return 0
}

_full_loop_reconcile_completion_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	local local_status="$3"
	local receipt_path=""
	local receipt_status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	if [[ ! -f "$receipt_path" ]]; then
		[[ "$local_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]]
		return $?
	fi
	IFS= read -r receipt_status <"$receipt_path" || return 1
	case "$receipt_status" in
	"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED")
		_full_loop_reconcile_published_release_receipt "$repo" "$pr_number"
		return $?
		;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		[[ "$local_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]]
		return $?
		;;
	*) return 1 ;;
	esac
}

_full_loop_reconcile_detached_publication_receipt() {
	local receipt_repo=""
	local receipt_path=""
	local receipt_status=""
	[[ "${PR_NUMBER:-}" =~ ^[0-9]+$ ]] || return 1
	receipt_repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}" 2>/dev/null || true)
	[[ -n "$receipt_repo" ]] || return 1
	receipt_path=$(_full_loop_release_receipt_path "$receipt_repo" "$PR_NUMBER") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r receipt_status <"$receipt_path" || return 1
	[[ "$receipt_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]] || return 1
	_full_loop_reconcile_published_release_receipt "$receipt_repo" "$PR_NUMBER" || return 2
	return 0
}

cmd_complete() {
	load_state 2>/dev/null || {
		print_error "Cannot complete full loop without persisted lifecycle state"
		return 1
	}
	if [[ ! "${PR_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		print_error "Cannot complete full loop without a verified PR number"
		return 1
	fi
	local repo=""
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || {
		print_error "Cannot resolve repository for deferred cleanup handoff"
		return 1
	}
	if [[ "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" == "authorized" || "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]]; then
		_full_loop_reconcile_completion_release_receipt "$repo" "$PR_NUMBER" "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" || {
			print_error "Cleanup blocked: release:${RELEASE_STATUS} is not terminal-success"
			return 1
		}
	fi
	case "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" in
	failed | authorized)
		print_error "Cleanup blocked: release:${RELEASE_STATUS} is not terminal-success"
		return 1
		;;
	"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED" | "$_FULL_LOOP_RELEASE_NOT_REQUESTED") ;;
	*)
		print_error "Cleanup blocked: unknown release status ${RELEASE_STATUS:-missing}"
		return 1
		;;
	esac
	local current_root=""
	current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	local current_branch=""
	local owner_pid=""
	local owner_session="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$_FULL_LOOP_OWNER_SESSION_FALLBACK}}}"
	local receipt_path=""
	current_branch=$(git branch --show-current 2>/dev/null || true)
	owner_pid="${PPID:-}"
	if declare -F _resolve_worktree_owner_pid >/dev/null 2>&1; then
		owner_pid=$(_resolve_worktree_owner_pid "" 2>/dev/null || printf '%s' "${PPID:-}")
	fi
	if [[ -z "$current_root" || -z "$current_branch" ]] || ! declare -F full_loop_write_cleanup_deferred >/dev/null 2>&1; then
		print_error "Cannot persist durable deferred-cleanup handoff without worktree and branch evidence"
		return 1
	fi
	REPOSITORY="$repo"
	if ! save_state "${CURRENT_PHASE:-complete}" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"; then
		print_error "Cannot persist repository identity for deferred cleanup status"
		return 1
	fi
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$PR_NUMBER") || return 1
	if [[ -f "$receipt_path" ]]; then
		# A merged direct-completion receipt can belong to the merge executor rather
		# than this initialized-only executor. Finalize through the same canonical
		# terminal-evidence path as `finalize-receipt` so immutable receipt identity
		# remains preserved instead of requiring the current process identity.
		full_loop_finalize_cleanup_receipt "$repo" "$PR_NUMBER" \
			"${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" || {
			print_error "Cannot finalize durable deferred-cleanup handoff"
			return 1
		}
	elif ! full_loop_write_cleanup_deferred "$repo" "$PR_NUMBER" "$current_root" "$current_branch" \
		"$owner_pid" "$owner_session" "${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" >/dev/null; then
		# A merge process may have created the receipt after the existence check.
		full_loop_finalize_cleanup_receipt "$repo" "$PR_NUMBER" \
			"${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}" || {
			print_error "Cannot persist durable deferred-cleanup handoff"
			return 1
		}
	fi
	print_warning "LIFECYCLE_STATE=CLEANUP_DEFERRED worktree=${current_root}"
	print_info "Executor complete; guarded cleanup supervisor owns the remaining CLEANED transition"
	echo "<promise>FULL_LOOP_CLEANUP_DEFERRED</promise>"
	return 0
}

_full_loop_resolve_repo() {
	local repo_arg="${1:-}"
	if [[ -n "$repo_arg" ]]; then
		[[ "$repo_arg" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
		printf '%s\n' "$repo_arg"
		return 0
	fi
	repo_arg=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
	[[ "$repo_arg" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	printf '%s\n' "$repo_arg"
	return 0
}

_full_loop_verify_merged_pr() {
	local pr_number="$1"
	local repo="$2"
	_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo" >/dev/null
	return $?
}

_full_loop_resolve_remote_release_tag_commit() {
	local repo="$1"
	local tag_name="$2"
	local ref_json=""
	local object_type=""
	local object_sha=""
	local tag_json=""

	[[ "$repo" == */* && "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]] || return 1
	ref_json=$(gh api "repos/${repo}/git/ref/tags/${tag_name}" 2>/dev/null) || return 1
	object_type=$(jq -er 'select(.ref == ("refs/tags/" + $tag_name) and (.object.type == "commit" or .object.type == "tag")) | .object.type' \
		--arg tag_name "$tag_name" <<<"$ref_json") || return 1
	object_sha=$(jq -er '.object.sha' <<<"$ref_json") || return 1
	[[ "$object_sha" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	if [[ "$object_type" == "tag" ]]; then
		tag_json=$(gh api "repos/${repo}/git/tags/${object_sha}" 2>/dev/null) || return 1
		object_sha=$(jq -er 'select((.object | type) == "object") | select(.object.type == "commit") | .object.sha' \
			<<<"$tag_json") || return 1
	fi
	[[ "$object_sha" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	printf '%s\n' "$object_sha"
	return 0
}

_full_loop_verify_published_release() {
	local repo="$1"
	local tag_name="$2"
	local merge_commit="$3"
	local workflow_file="${4:-}"
	local workflow_event="${5:-$_FULL_LOOP_WORKFLOW_EVENT_RELEASE}"
	local generated_catalog="${6:-$_FULL_LOOP_BOOL_FALSE}"
	local tag_commit=""
	local release_json=""
	local workflow_runs_json=""
	local workflow_runs_endpoint=""

	[[ "$repo" == */* && "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX && "$merge_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	if [[ "$workflow_event" != "$_FULL_LOOP_WORKFLOW_EVENT_RELEASE" &&
		"$workflow_event" != "push" && "$workflow_event" != "workflow_dispatch" ]]; then
		return 1
	fi
	if [[ -n "$workflow_file" ]]; then
		if [[ ! "$workflow_file" =~ ^[1-9][0-9]*$ && ! "$workflow_file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ ]]; then
			return 1
		fi
		workflow_runs_endpoint="repos/${repo}/actions/workflows/${workflow_file}/runs?event=${workflow_event}&status=success&per_page=100"
	else
		[[ "$workflow_event" == "$_FULL_LOOP_WORKFLOW_EVENT_RELEASE" ]] || return 1
		workflow_runs_endpoint="repos/${repo}/actions/runs?event=release&status=success&per_page=100"
	fi
	tag_commit=$(_full_loop_resolve_remote_release_tag_commit "$repo" "$tag_name") || return 1
	if [[ "$tag_commit" != "$merge_commit" ]]; then
		#aidevops:trust-boundary — never substitute a generic ancestry check.
		[[ "$generated_catalog" == "$_FULL_LOOP_BOOL_TRUE" && -n "$workflow_file" ]] || return 1
		python3 "${SCRIPT_DIR}/cloudron-release-evidence.py" --repo "$repo" --tag "$tag_name" \
			--source "$merge_commit" --commit "$tag_commit" --workflow "$workflow_file" --event "$workflow_event" || return 1
		[[ "$tag_commit" == "$(_full_loop_resolve_remote_release_tag_commit "$repo" "$tag_name")" ]] || return 1
	fi
	release_json=$(gh api "repos/${repo}/releases/tags/${tag_name}" 2>/dev/null) || return 1
	jq -e --arg tag_name "$tag_name" '.tag_name == $tag_name and .draft == false' <<<"$release_json" >/dev/null || return 1
	workflow_runs_json=$(gh api "$workflow_runs_endpoint" 2>/dev/null) || return 1
	jq -e --arg tag_name "$tag_name" --arg merge_commit "$merge_commit" \
		--arg completed "$_FULL_LOOP_PHASE_COMPLETED" --arg workflow_event "$workflow_event" '
		[.workflow_runs[]? | select(
			.event == $workflow_event and .status == $completed and .conclusion == "success"
			and .head_sha == $merge_commit
			and ($workflow_event != "release" or .head_branch == $tag_name)
		)] | length > 0
	' <<<"$workflow_runs_json" >/dev/null || return 1
	return 0
}

cmd_record_no_release() {
	local pr_number="${1:-}"
	local repo_arg="${2:-}"
	local repo=""
	local receipt_path=""
	local release_status=""
	if [[ $# -lt 1 || $# -gt 2 ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		print_error "Usage: full-loop-helper.sh record-no-release <PR> [REPO]"
		return 1
	fi
	repo=$(_full_loop_resolve_repo "$repo_arg") || {
		print_error "Cannot resolve repository for release evidence"
		return 1
	}
	_full_loop_verify_merged_pr "$pr_number" "$repo" || {
		print_error "Cannot record release:not-requested: PR #${pr_number} lacks merged evidence"
		return 1
	}
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	if [[ -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || true
	fi
	case "$release_status" in
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
			full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || return 1
		fi
		print_info "release:not-requested already recorded for PR #${pr_number}"
		return 0
		;;
	"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED" | "$_FULL_LOOP_PHASE_FAILED")
		print_error "Cannot replace terminal release:${release_status} evidence for PR #${pr_number}"
		return 1
		;;
	"") ;;
	*)
		print_error "Cannot replace unknown release:${release_status} evidence for PR #${pr_number}"
		return 1
		;;
	esac
	_full_loop_write_release_receipt "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || return 1
	if declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_NOT_REQUESTED" || return 1
	fi
	print_success "release:not-requested recorded for merged PR #${pr_number}"
	return 0
}

_full_loop_parse_published_release_options() {
	local -a args=("$@")
	local arg_count="${#args[@]}"
	local arg_index=0
	local option=""
	local option_value=""
	_FULL_LOOP_PARSED_REPO_ARG=""
	_FULL_LOOP_PARSED_WORKFLOW_FILE=""
	_FULL_LOOP_PARSED_WORKFLOW_EVENT="$_FULL_LOOP_WORKFLOW_EVENT_RELEASE"
	_FULL_LOOP_PARSED_GENERATED_CATALOG="$_FULL_LOOP_BOOL_FALSE"
	if [[ "$arg_index" -lt "$arg_count" ]]; then
		option="${args[$arg_index]}"
	fi
	if [[ "$arg_index" -lt "$arg_count" && "$option" != --* ]]; then
		_FULL_LOOP_PARSED_REPO_ARG="$option"
		arg_index=$((arg_index + 1))
	fi
	while [[ "$arg_index" -lt "$arg_count" ]]; do
		option="${args[$arg_index]}"
		case "$option" in
		--generated-cloudron-catalog)
			_FULL_LOOP_PARSED_GENERATED_CATALOG="$_FULL_LOOP_BOOL_TRUE"
			arg_index=$((arg_index + 1))
			;;
		--workflow | --event)
			[[ $((arg_index + 1)) -lt "$arg_count" ]] || {
				print_error "${option} requires a value"
				return 1
			}
			option_value="${args[$((arg_index + 1))]}"
			if [[ "$option" == "--workflow" ]]; then
				_FULL_LOOP_PARSED_WORKFLOW_FILE="$option_value"
			else
				_FULL_LOOP_PARSED_WORKFLOW_EVENT="$option_value"
			fi
			arg_index=$((arg_index + 2))
			;;
		*)
			print_error "Unknown record-published-release option: $option"
			return 1
			;;
		esac
	done
	if [[ -z "$_FULL_LOOP_PARSED_WORKFLOW_FILE" &&
		"$_FULL_LOOP_PARSED_WORKFLOW_EVENT" != "$_FULL_LOOP_WORKFLOW_EVENT_RELEASE" ]]; then
		print_error "--event ${_FULL_LOOP_PARSED_WORKFLOW_EVENT} requires --workflow to bind publication evidence to an exact workflow"
		return 1
	fi
	return 0
}

cmd_record_published_release() {
	local pr_number="${1:-}"
	local tag_name="${2:-}"
	local repo_arg=""
	local repo=""
	local pr_json=""
	local merge_commit=""
	local receipt_path=""
	local release_status=""
	local workflow_file=""
	local workflow_event="$_FULL_LOOP_WORKFLOW_EVENT_RELEASE"
	local status=0
	if [[ $# -lt 2 ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]] || [[ ! "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]]; then
		print_error "Usage: full-loop-helper.sh record-published-release <PR> <TAG> [REPO] [--workflow FILE] [--event release|push|workflow_dispatch]"
		return 1
	fi
	shift 2
	_full_loop_parse_published_release_options "$@" || return 1
	repo_arg="$_FULL_LOOP_PARSED_REPO_ARG"
	workflow_file="$_FULL_LOOP_PARSED_WORKFLOW_FILE"
	workflow_event="$_FULL_LOOP_PARSED_WORKFLOW_EVENT"
	repo=$(_full_loop_resolve_repo "$repo_arg") || {
		print_error "Cannot resolve repository for release evidence"
		return 1
	}
	pr_json=$(_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo") || {
		print_error "Cannot record release:published: PR #${pr_number} lacks merged evidence"
		return 1
	}
	merge_commit=$(jq -er '.mergeCommit.oid' <<<"$pr_json") || return 1
	[[ "$merge_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || {
		print_error "Cannot record release:published: PR #${pr_number} merge commit is invalid"
		return 1
	}
	_full_loop_verify_published_release "$repo" "$tag_name" "$merge_commit" \
		"$workflow_file" "$workflow_event" "$_FULL_LOOP_PARSED_GENERATED_CATALOG" || {
		print_error "Cannot record release:published: release, tag, and successful release workflow evidence do not match PR #${pr_number}"
		return 1
	}
	_full_loop_acquire_transition_lock || return 1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || status=1
	if [[ "$status" -eq 0 && -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || status=1
	fi
	if [[ "$status" -eq 0 ]]; then
		case "$release_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED" | "$_FULL_LOOP_RELEASE_PUBLISHED") ;;
		*)
			print_error "Cannot replace terminal release:${release_status} evidence for PR #${pr_number}"
			status=1
			;;
		esac
	fi
	if [[ "$status" -eq 0 ]]; then
		_full_loop_write_release_receipt "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_PUBLISHED" || status=1
	fi
	if [[ "$status" -eq 0 ]] && declare -F full_loop_update_cleanup_release_status >/dev/null 2>&1; then
		full_loop_update_cleanup_release_status "$repo" "$pr_number" "$_FULL_LOOP_RELEASE_PUBLISHED" || status=1
	fi
	_full_loop_release_transition_lock
	[[ "$status" -eq 0 ]] || return 1
	print_success "release:published recorded for merged PR #${pr_number} (tag=${tag_name})"
	return 0
}

cmd_record_included_release() {
	local pr_number="${1:-}"
	local source_pr="${2:-}"
	local tag_name="${3:-}"
	local repo="" source_json="" feature_json="" source_merge="" feature_merge=""
	local source_receipt="" receipt_path="" release_status="" compare_json=""
	local workflow_file="" workflow_event="" evidence_path="" status=0
	if [[ $# -lt 3 || ! "$pr_number" =~ ^[1-9][0-9]*$ || ! "$source_pr" =~ ^[1-9][0-9]*$ || "$pr_number" == "$source_pr" || ! "$tag_name" =~ $_FULL_LOOP_VERSION_TAG_REGEX ]]; then
		print_error "Usage: record-included-release <PR> <SOURCE_PR> <TAG> [REPO] [--workflow FILE] [--event EVENT]"
		return 1
	fi
	shift 3
	_full_loop_parse_published_release_options "$@" || return 1
	[[ "$_FULL_LOOP_PARSED_GENERATED_CATALOG" == "$_FULL_LOOP_BOOL_FALSE" ]] || return 1
	repo=$(_full_loop_resolve_repo "$_FULL_LOOP_PARSED_REPO_ARG") || return 1
	# Canonical aidevops releases retain their signed aggregation manifest path.
	[[ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" != "marcusquinn/aidevops" ]] || return 1
	workflow_file="$_FULL_LOOP_PARSED_WORKFLOW_FILE"
	workflow_event="$_FULL_LOOP_PARSED_WORKFLOW_EVENT"
	source_receipt=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	[[ -f "$source_receipt" ]] || return 1
	IFS= read -r release_status <"$source_receipt" || return 1
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" ]] || return 1
	source_json=$(_full_loop_read_fresh_merged_pr_json "$source_pr" "$repo") || return 1
	feature_json=$(_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo") || return 1
	source_merge=$(jq -er '.mergeCommit.oid' <<<"$source_json") || return 1
	feature_merge=$(jq -er '.mergeCommit.oid' <<<"$feature_json") || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$feature_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	# aidevops:trust-boundary — ancestry proves inclusion only AFTER independently
	# verifying the published source receipt, exact source tag and successful run.
	_full_loop_verify_published_release "$repo" "$tag_name" "$source_merge" "$workflow_file" "$workflow_event" || return 1
	compare_json=$(gh api "repos/${repo}/compare/${feature_merge}...${source_merge}" 2>/dev/null) || return 1
	jq -e --arg feature "$feature_merge" --arg source "$source_merge" '
		(.status == "ahead" or .status == "identical")
		and .merge_base_commit.sha == $feature and .base_commit.sha == $feature
		and (if .status == "identical" then $source == $feature else true end)
	' <<<"$compare_json" >/dev/null || return 1
	[[ "$source_merge" == "$(_full_loop_resolve_remote_release_tag_commit "$repo" "$tag_name")" ]] || return 1
	_full_loop_acquire_transition_lock || return 1
	# Recheck the linked receipt under the same lock used for destination writes.
	IFS= read -r release_status <"$source_receipt" || status=1
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" ]] || status=1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || status=1
	release_status=""
	if [[ "$status" -eq 0 && -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || status=1
	fi
	case "$release_status" in
	"" | "$_FULL_LOOP_PHASE_FAILED" | "$_FULL_LOOP_RELEASE_NOT_REQUESTED") ;;
	"$_FULL_LOOP_RELEASE_SUPERSEDED")
		evidence_path=$(_full_loop_superseded_release_evidence_path "$repo" "$pr_number") || status=1
		if [[ "$status" -eq 0 ]]; then
			jq -e --argjson source "$source_pr" --arg feature "$feature_merge" --arg merge "$source_merge" --arg tag "$tag_name" '
				.aggregate_pr == $source and .source_merge == $feature and .aggregate_merge == $merge
				and .release_tag == $tag and .release_commit == $merge
			' "$evidence_path" >/dev/null || status=1
		fi
		;;
	*) status=1 ;;
	esac
	if [[ "$status" -eq 0 && "$release_status" != "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_write_superseded_release_receipt "$repo" "$pr_number" "$feature_merge" \
			"$source_pr" "$source_merge" "$tag_name" "$source_merge" || status=1
	elif [[ "$status" -eq 0 ]]; then
		_full_loop_update_superseded_cleanup_receipt "$repo" "$pr_number" || status=1
	fi
	_full_loop_release_transition_lock
	[[ "$status" -eq 0 ]] || return 1
	print_success "release:superseded recorded for PR #${pr_number}, included in source PR #${source_pr} (${tag_name})"
	return 0
}

_full_loop_terminal_release_status() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	local release_status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	IFS= read -r release_status <"$receipt_path" || return 1
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || return 1
	if [[ "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_verify_superseded_release_receipt "$repo" "$pr_number" || return 1
	fi
	printf '%s\n' "$release_status"
	return 0
}

# Retire only the rollout marker for this exact, finalized merged worktree.
# The external receipt remains authoritative for live-owner cleanup protection.
_full_loop_retire_finalized_cleanup_marker() {
	local repo="$1"
	local pr_number="$2"
	local release_status="$3"
	local worktree=""
	local branch=""
	local cleanup_target=""
	local receipt_path=""
	local marker_path=""
	local owner_pid=""
	local owner_identity=""
	local tracked_marker=""
	local owner_session="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$_FULL_LOOP_OWNER_SESSION_FALLBACK}}}"
	worktree=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	marker_path="${worktree}/.agents/.full-loop-cleanup-deferred"
	[[ -e "$marker_path" || -L "$marker_path" ]] || return 0
	[[ -f "$marker_path" && ! -L "$marker_path" && ! -L "${worktree}/.agents" ]] || return 1
	# Never remove a tracked file, or a marker from another PR/head/worktree.
	tracked_marker=$(git -C "$worktree" ls-files -- .agents/.full-loop-cleanup-deferred) || return 1
	[[ -z "$tracked_marker" ]] || return 1
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || return 1
	# Retirement must accept every target merge cleanup records (including a
	# same-repository alias); the locked receipt check below binds it to the
	# exact recorded worktree and branch (GH#33890).
	cleanup_target=$(_merge_fresh_retirement_worktree_cleanup_target "$pr_number" "$repo") || return 1
	IFS=$'\t' read -r worktree branch _ <<<"$cleanup_target"
	[[ "$marker_path" == "${worktree}/.agents/.full-loop-cleanup-deferred" ]] || return 1
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" && ! -L "$receipt_path" ]] || return 1
	_full_loop_receipt_lock_acquire || return 1
	if ! jq -e --arg repo "$repo" --argjson pr "$pr_number" \
		--arg worktree "$worktree" --arg branch "$branch" --arg session "$owner_session" \
		--arg release "$release_status" '
		.schema_version == 1 and .repository == $repo and .pr_number == $pr
		and .worktree == $worktree and .branch == $branch
		and .executor_completion_state == "COMPLETE" and .release_status == $release
		and .resource_cleanup_state == "CLEANUP_DEFERRED"
		and .cleanup_lease == {state:"pending",pid:null,acquired_at:null}
		and (.receipt_disposition // null) == null
		and (.owner.pid | type == "number" and . > 0 and floor == .)
		and (.owner.process_identity | strings | length > 0)
		and .owner.session == $session
	' "$receipt_path" >/dev/null 2>&1; then
		_full_loop_receipt_lock_release
		return 1
	fi
	owner_pid=$(jq -r '.owner.pid' "$receipt_path")
	owner_identity=$(jq -r '.owner.process_identity' "$receipt_path")
	# Match the entire legacy format, not just its first line. A reused live PID
	# cannot inherit a receipt written by a different process generation.
	if ! cmp -s "$marker_path" <(printf '%s\n' "$owner_pid") ||
		{ kill -0 "$owner_pid" 2>/dev/null && [[ "$owner_identity" != "$(_full_loop_process_identity "$owner_pid")" ]]; }; then
		_full_loop_receipt_lock_release
		return 1
	fi
	if ! rm -- "$marker_path"; then
		_full_loop_receipt_lock_release
		return 1
	fi
	_full_loop_receipt_lock_release
	return 0
}

cmd_finalize_receipt() {
	local pr_number="${1:-}"
	local repo=""
	local release_status=""
	[[ $# -ge 1 && $# -le 2 && "$pr_number" =~ ^[0-9]+$ ]] || {
		print_error "Usage: full-loop-helper.sh finalize-receipt <PR> [REPO]"
		return 1
	}
	repo=$(_full_loop_resolve_repo "${2:-}") || return 1
	_full_loop_verify_merged_pr "$pr_number" "$repo" || {
		print_error "Finalization blocked: PR #${pr_number} lacks merged evidence"
		return 1
	}
	release_status=$(_full_loop_terminal_release_status "$repo" "$pr_number") || {
		print_error "Finalization blocked: terminal release evidence is missing"
		return 1
	}
	full_loop_finalize_cleanup_receipt "$repo" "$pr_number" "$release_status" || {
		print_error "Finalization blocked: cleanup receipt is missing or conflicts with terminal evidence"
		return 1
	}
	_full_loop_retire_finalized_cleanup_marker "$repo" "$pr_number" "$release_status" || {
		print_error "Finalization blocked: legacy cleanup marker does not match the exact finalized owner contract"
		return 1
	}
	print_success "Cleanup receipt finalized for merged PR #${pr_number} (release:${release_status})"
	return 0
}

cmd_migrate_repository_receipt() {
	local pr_number="${1:-}"
	local old_repo="${2:-}"
	local new_repo="${3:-}"
	local source_release=""
	local destination_release=""
	local release_status=""
	if [[ $# -ne 3 || ! "$pr_number" =~ ^[0-9]+$ || "$old_repo" != */* || "$new_repo" != */* || "$old_repo" == "$new_repo" ]]; then
		print_error "Usage: full-loop-helper.sh migrate-repository-receipt <PR> <OLD_REPO> <NEW_REPO>"
		return 1
	fi
	_full_loop_verify_merged_pr "$pr_number" "$new_repo" || {
		print_error "Migration blocked: PR #${pr_number} lacks merged evidence in ${new_repo}"
		return 1
	}
	source_release=$(_full_loop_release_receipt_path "$old_repo" "$pr_number") || return 1
	destination_release=$(_full_loop_release_receipt_path "$new_repo" "$pr_number") || return 1
	if [[ -f "$source_release" ]]; then
		IFS= read -r release_status <"$source_release" || true
	elif [[ -f "$destination_release" ]]; then
		IFS= read -r release_status <"$destination_release" || true
	fi
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] || {
		print_error "Migration blocked: terminal release evidence is missing"
		return 1
	}
	full_loop_migrate_cleanup_receipt "$old_repo" "$new_repo" "$pr_number" \
		"$source_release" "$destination_release" "$release_status" || {
		print_error "Migration blocked: source evidence is missing or destination evidence conflicts"
		return 1
	}
	print_success "Migrated full-loop receipts from ${old_repo} to ${new_repo} for PR #${pr_number}"
	return 0
}

_full_loop_verify_aidevops_release_deploy() {
	local repo="$1"
	local pr_number="$2"
	local receipt_path=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$pr_number") || return 1
	local release_status=""
	[[ -f "$receipt_path" ]] && IFS= read -r release_status <"$receipt_path"
	[[ "$repo" == "marcusquinn/aidevops" ]] || return 0
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_NOT_REQUESTED" ]] && return 0
	local repo_root=""
	local version=""
	local tag_name=""
	local expected_release_sha=""
	if [[ "$release_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
		_full_loop_verify_superseded_release_receipt "$repo" "$pr_number" || return 1
		local superseded_evidence=""
		superseded_evidence=$(_full_loop_superseded_release_evidence_path "$repo" "$pr_number") || return 1
		tag_name=$(jq -er '.release_tag' "$superseded_evidence") || return 1
		expected_release_sha=$(jq -er '.release_commit' "$superseded_evidence") || return 1
		version="${tag_name#v}"
	else
		[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" ]] || return 1
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
		[[ -n "$repo_root" && -f "${repo_root}/VERSION" ]] && IFS= read -r version <"${repo_root}/VERSION"
		[[ -n "$version" ]] || return 1
		tag_name="v${version}"
	fi
	local release_sha=""
	release_sha=$(git ls-remote --exit-code --tags origin "refs/tags/${tag_name}^{}" | cut -f1 || true)
	if [[ -z "$release_sha" ]]; then
		release_sha=$(git ls-remote --exit-code --tags origin "refs/tags/${tag_name}" | cut -f1 || true)
	fi
	[[ -n "$release_sha" ]] || return 1
	[[ -z "$expected_release_sha" || "$release_sha" == "$expected_release_sha" ]] || return 1
	gh release view "$tag_name" --repo "$repo" >/dev/null 2>&1 || return 1
	local deployed_version=""
	[[ -f "${HOME}/.aidevops/agents/VERSION" ]] && IFS= read -r deployed_version <"${HOME}/.aidevops/agents/VERSION"
	[[ "$deployed_version" == "$version" ]] || return 1
	local postflight="${SCRIPT_DIR}/postflight-check.sh"
	[[ -f "$postflight" ]] || return 1
	bash "$postflight" --quick --sha "$release_sha" --tag "$tag_name" >/dev/null 2>&1 || return 1
	return 0
}

_full_loop_verify_cleanup_audit() {
	local removed_worktree="$1"
	local cleanup_log="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"
	[[ -f "$cleanup_log" ]] || return 1
	grep -Fq "worktree-removed: ${removed_worktree} —" "$cleanup_log"
	return $?
}

cmd_complete_after_cleanup() {
	local pr_number="${1:-}"
	local removed_worktree="${2:-}"
	local repo=""
	local release_status=""
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$removed_worktree" ]] || {
		print_error "Usage: full-loop-helper.sh complete-after-cleanup <PR> <removed-worktree-path> [REPO]"
		return 1
	}
	repo=$(_full_loop_resolve_repo "${3:-}") || {
		print_error "Cannot resolve repository for completion evidence"
		return 1
	}
	if [[ -e "$removed_worktree" ]] || git worktree list --porcelain 2>/dev/null | grep -Fq "worktree ${removed_worktree}"; then
		print_error "LIFECYCLE_STATE=CLEANUP_PENDING worktree=${removed_worktree}"
		return 1
	fi
	_full_loop_verify_cleanup_audit "$removed_worktree" || {
		print_error "Completion blocked: no removal audit evidence for ${removed_worktree}"
		return 1
	}
	declare -F full_loop_mark_cleanup_cleaned_for_identity >/dev/null 2>&1 || {
		print_error "Completion blocked: exact cleanup-receipt verifier is unavailable"
		return 1
	}
	full_loop_mark_cleanup_cleaned_for_identity "$repo" "$pr_number" "$removed_worktree" || {
		print_error "Completion blocked: durable cleanup receipt identity is not CLEANED for ${repo}#${pr_number} at ${removed_worktree}"
		return 1
	}
	_full_loop_verify_merged_pr "$pr_number" "$repo" || {
		print_error "Completion blocked: PR #${pr_number} lacks merged evidence"
		return 1
	}
	release_status=$(_full_loop_terminal_release_status "$repo" "$pr_number") || {
		print_error "Completion blocked: terminal release evidence is missing"
		return 1
	}
	_full_loop_verify_aidevops_release_deploy "$repo" "$pr_number" || {
		print_error "Completion blocked: release, deployment, or postflight evidence is missing"
		return 1
	}
	full_loop_finalize_cleanup_receipt "$repo" "$pr_number" "$release_status" || {
		print_error "Completion blocked: cleanup receipt conflicts with terminal release evidence"
		return 1
	}
	printf "\n${BOLD}${GREEN}=== FULL DEVELOPMENT LOOP - COMPLETE ===${NC}\n"
	printf "PR: #%s | Lifecycle: CLEANED | release:%s\n\n" "$pr_number" "$release_status"
	echo "<promise>FULL_LOOP_COMPLETE</promise>"
	return 0
}
