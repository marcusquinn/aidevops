#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# State persistence and repository utilities for the lifecycle orchestrator.
# Inherits globals and dependencies from full-loop-helper-state-lifecycle.sh.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_FULL_LOOP_STATE_PERSISTENCE_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_PERSISTENCE_LOADED=1

# --- State Management ---

save_state() {
	local phase="$1" prompt="$2" pr_number="${3:-}" started_at="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	local now
	now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	local tmp_file="${STATE_FILE}.tmp.$$"
	RUN_ID="${RUN_ID:-run-$(date -u '+%Y%m%dT%H%M%SZ')-$$}"
	STATE_REVISION=$((${STATE_REVISION:-0} + 1))
	mkdir -p "$STATE_DIR"
	cat >"$tmp_file" <<EOF
---
schema_version: 2
active: true
run_id: "${RUN_ID}"
state_revision: ${STATE_REVISION}
phase: ${phase}
phase_status: ${PHASE_STATUS:-initialized}
phase_attempt: ${PHASE_ATTEMPT:-0}
phase_started_at: "${PHASE_STARTED_AT:-}"
phase_ended_at: "${PHASE_ENDED_AT:-}"
next_action: "${NEXT_ACTION:-resume}"
terminal_evidence: "${TERMINAL_EVIDENCE:-}"
executor_status: ${EXECUTOR_STATUS:-$_FULL_LOOP_EXECUTOR_INITIALIZED}
executor_pid: "${EXECUTOR_PID:-}"
executor_identity: "${EXECUTOR_IDENTITY:-}"
heartbeat_at: "${HEARTBEAT_AT:-}"
pr_check_status: "${PR_CHECK_STATUS:-}"
pr_check_head: "${PR_CHECK_HEAD:-}"
pr_check_evidence: "${PR_CHECK_EVIDENCE:-}"
manual_resume_count: ${MANUAL_RESUME_COUNT:-0}
reused_subagent_units: ${REUSED_SUBAGENT_UNITS:-0}
duplicate_work_avoided: ${DUPLICATE_WORK_AVOIDED:-0}
started_at: "${started_at}"
updated_at: "${now}"
pr_number: "${pr_number}"
repository: "${REPOSITORY:-}"
max_task_iterations: ${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}
max_preflight_iterations: ${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}
max_pr_iterations: ${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}
skip_preflight: ${SKIP_PREFLIGHT:-false}
skip_postflight: ${SKIP_POSTFLIGHT:-false}
skip_runtime_testing: ${SKIP_RUNTIME_TESTING:-false}
no_auto_pr: ${NO_AUTO_PR:-false}
no_auto_deploy: ${NO_AUTO_DEPLOY:-false}
release_intent: ${RELEASE_INTENT:-false}
release_type: ${RELEASE_TYPE:-patch}
deployment_scope: ${DEPLOYMENT_SCOPE:-incremental}
release_expected_sources: "${RELEASE_EXPECTED_SOURCES:-}"
release_status: ${RELEASE_STATUS:-$_FULL_LOOP_RELEASE_NOT_REQUESTED}
headless: ${HEADLESS:-false}
---

${prompt}
EOF
	mv "$tmp_file" "$STATE_FILE"
	return 0
}

_full_loop_append_event() {
	local event_type="$1"
	local status="$2"
	local event_file="${STATE_DIR}/full-loop-events.jsonl"
	local now
	now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	mkdir -p "$STATE_DIR" || return 0
	if command -v jq >/dev/null 2>&1; then
		jq -cn --arg event_type "$event_type" --arg run_id "${RUN_ID:-unknown}" \
			--arg phase "${CURRENT_PHASE:-${PHASE:-unknown}}" --arg status "$status" \
			--arg timestamp "$now" --argjson attempt "${PHASE_ATTEMPT:-0}" \
			'{event_type:$event_type,run_id:$run_id,phase:$phase,status:$status,attempt:$attempt,timestamp:$timestamp}' \
			>>"$event_file" 2>/dev/null || true
	fi
	return 0
}

load_state() {
	[[ -f "$STATE_FILE" ]] || return 1
	# Pre-initialize all state variables with safe defaults so that set -u does
	# not abort when the state file is incomplete (missing fields are never set
	# by the awk parse loop, leaving variables unbound).
	PHASE=""
	RUN_ID=""
	STATE_REVISION="0"
	PHASE_STATUS="initialized"
	PHASE_ATTEMPT="0"
	PHASE_STARTED_AT=""
	PHASE_ENDED_AT=""
	NEXT_ACTION="resume"
	TERMINAL_EVIDENCE=""
	EXECUTOR_STATUS="$_FULL_LOOP_EXECUTOR_INITIALIZED"
	EXECUTOR_PID=""
	EXECUTOR_IDENTITY=""
	HEARTBEAT_AT=""
	PR_CHECK_STATUS=""
	PR_CHECK_HEAD=""
	PR_CHECK_EVIDENCE=""
	MANUAL_RESUME_COUNT="0"
	REUSED_SUBAGENT_UNITS="0"
	DUPLICATE_WORK_AVOIDED="0"
	ACTIVE=""
	ITERATION=""
	STARTED_AT="unknown"
	UPDATED_AT=""
	PR_NUMBER=""
	REPOSITORY=""
	MAX_TASK_ITERATIONS="$DEFAULT_MAX_TASK_ITERATIONS"
	MAX_PREFLIGHT_ITERATIONS="$DEFAULT_MAX_PREFLIGHT_ITERATIONS"
	MAX_PR_ITERATIONS="$DEFAULT_MAX_PR_ITERATIONS"
	SKIP_PREFLIGHT="$_FULL_LOOP_BOOL_FALSE"
	SKIP_POSTFLIGHT="$_FULL_LOOP_BOOL_FALSE"
	SKIP_RUNTIME_TESTING="$_FULL_LOOP_BOOL_FALSE"
	NO_AUTO_PR="$_FULL_LOOP_BOOL_FALSE"
	NO_AUTO_DEPLOY="$_FULL_LOOP_BOOL_FALSE"
	RELEASE_INTENT="$_FULL_LOOP_BOOL_FALSE"
	RELEASE_TYPE="patch"
	DEPLOYMENT_SCOPE="incremental"
	RELEASE_EXPECTED_SOURCES=""
	RELEASE_STATUS="$_FULL_LOOP_RELEASE_NOT_REQUESTED"
	HEADLESS="${FULL_LOOP_HEADLESS:-false}"
	SAVED_PROMPT=""
	# Single-pass parse of YAML frontmatter — safe variable assignment via printf -v
	local _key _val _line
	while IFS= read -r _line; do
		_key="${_line%%=*}"
		_val="${_line#*=}"
		# Allowlist: only set known state variables
		case "$_key" in
		PHASE | ACTIVE | ITERATION | STARTED_AT | UPDATED_AT | RUN_ID | STATE_REVISION | \
			PHASE_STATUS | PHASE_ATTEMPT | PHASE_STARTED_AT | PHASE_ENDED_AT | NEXT_ACTION | TERMINAL_EVIDENCE | \
			EXECUTOR_STATUS | EXECUTOR_PID | EXECUTOR_IDENTITY | HEARTBEAT_AT | PR_CHECK_STATUS | PR_CHECK_HEAD | PR_CHECK_EVIDENCE | \
			MANUAL_RESUME_COUNT | REUSED_SUBAGENT_UNITS | DUPLICATE_WORK_AVOIDED | \
			MAX_TASK_ITERATIONS | MAX_PREFLIGHT_ITERATIONS | \
			MAX_PR_ITERATIONS | SKIP_PREFLIGHT | SKIP_POSTFLIGHT | SKIP_RUNTIME_TESTING | \
			NO_AUTO_PR | NO_AUTO_DEPLOY | RELEASE_INTENT | RELEASE_TYPE | DEPLOYMENT_SCOPE | RELEASE_EXPECTED_SOURCES | RELEASE_STATUS | HEADLESS | PR_NUMBER | REPOSITORY)
			printf -v "$_key" '%s' "$_val"
			;;
		esac
	done < <(awk -F': ' '/^---$/{n++;next} n==1 && NF>=2{
		gsub(/[" ]/, "", $2); k=$1; gsub(/-/, "_", k)
		print toupper(k) "=" $2
	}' "$STATE_FILE")
	CURRENT_PHASE="${PHASE:-}"
	SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
	return 0
}

is_loop_active() { [[ -f "$STATE_FILE" ]] && grep -q '^active: true' "$STATE_FILE"; }

# --- Utility Functions ---

is_aidevops_repo() {
	local r
	r=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	[[ "$r" == *"/aidevops"* ]] || [[ -f "$r/.aidevops-repo" ]]
}
get_current_branch() { git branch --show-current 2>/dev/null || echo ""; }
is_on_feature_branch() {
	local b
	b=$(get_current_branch)
	[[ -n "$b" && "$b" != "main" && "$b" != "master" ]]
}
