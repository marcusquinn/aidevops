#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Relationships — Scope, Outcome, and Resume State
# =============================================================================
# Invocation-scoped state management for issue-sync-relationships.sh: sync
# scope begin/end, outcome/diagnostic recording, resume-state persistence,
# summary/progress printing, and the shared sync deadline helpers.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-relationships-state.sh"
#
# Dependencies (all available when sourced from issue-sync-relationships.sh):
#   - shared-constants.sh (print_error, print_info, print_warning)
#   - issue-sync-relationships.sh globals (_RELATIONSHIP_* state variables)
#   - issue-sync-relationship-batch.sh (_init_relationship_batch_state,
#     _cleanup_relationship_batch_state, _register_relationship_batch_cleanup,
#     _relationship_backend_call_count_for, _relationship_operation_seconds)
#
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_RELATIONSHIPS_STATE_LIB_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIPS_STATE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_init_relationship_sync_state() {
	_init_node_id_cache
	_init_relationship_batch_state || return 1
	if [[ -z "$_RELATIONSHIP_EDGE_SEEN_FILE" ]]; then
		_RELATIONSHIP_EDGE_SEEN_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-edges.XXXXXX") || return 1
	fi
	if [[ -z "$_RELATIONSHIP_RESULT_FILE" ]]; then
		_RELATIONSHIP_RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-results.XXXXXX") || return 1
	fi
	if [[ -z "$_RELATIONSHIP_DIAGNOSTIC_FILE" ]]; then
		_RELATIONSHIP_DIAGNOSTIC_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-diagnostics.XXXXXX") || return 1
	fi
	if [[ -z "$_RELATIONSHIP_BACKEND_CALL_FILE" ]]; then
		_RELATIONSHIP_BACKEND_CALL_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-calls.XXXXXX") || return 1
	fi
	: >"$_RELATIONSHIP_EDGE_SEEN_FILE"
	: >"$_RELATIONSHIP_RESULT_FILE"
	: >"$_RELATIONSHIP_DIAGNOSTIC_FILE"
	: >"$_RELATIONSHIP_BACKEND_CALL_FILE"
	_AIDEVOPS_GH_CALL_COUNT_FILE="$_RELATIONSHIP_BACKEND_CALL_FILE"
	return 0
}

_cleanup_relationship_sync_state() {
	if [[ -n "$_RELATIONSHIP_EDGE_SEEN_FILE" ]]; then
		rm -f "$_RELATIONSHIP_EDGE_SEEN_FILE"
		_RELATIONSHIP_EDGE_SEEN_FILE=""
	fi
	if [[ -n "$_RELATIONSHIP_RESULT_FILE" ]]; then
		rm -f "$_RELATIONSHIP_RESULT_FILE"
		_RELATIONSHIP_RESULT_FILE=""
	fi
	if [[ -n "$_RELATIONSHIP_DIAGNOSTIC_FILE" ]]; then
		rm -f "$_RELATIONSHIP_DIAGNOSTIC_FILE"
		_RELATIONSHIP_DIAGNOSTIC_FILE=""
	fi
	if [[ -n "$_RELATIONSHIP_BACKEND_CALL_FILE" ]]; then
		rm -f "$_RELATIONSHIP_BACKEND_CALL_FILE"
		_RELATIONSHIP_BACKEND_CALL_FILE=""
	fi
	_cleanup_relationship_batch_state
	_AIDEVOPS_GH_CALL_COUNT_FILE=""
	return 0
}

_begin_relationship_sync_scope() {
	[[ "$_RELATIONSHIP_SYNC_SCOPE_ACTIVE" -eq 1 ]] && return 0
	_init_relationship_sync_state || return 1
	_RELATIONSHIP_SYNC_DEADLINE_EPOCH=
	_RELATIONSHIP_SYNC_SCOPE_ACTIVE=1
	return 0
}

_ensure_relationship_sync_deadline() {
	if [[ ! "$_RELATIONSHIP_SYNC_DEADLINE_EPOCH" =~ ^[1-9][0-9]*$ ]]; then
		_RELATIONSHIP_SYNC_DEADLINE_EPOCH=$(_relationship_sync_deadline_epoch) || return 1
	fi
	return 0
}

_end_relationship_sync_scope() {
	_cleanup_relationship_sync_state
	_RELATIONSHIP_SYNC_SCOPE_ACTIVE=0
	_RELATIONSHIP_SYNC_DEADLINE_EPOCH=
	return 0
}

_register_relationship_sync_cleanup() {
	push_cleanup "rm -f '${_RELATIONSHIP_EDGE_SEEN_FILE}'"
	push_cleanup "rm -f '${_RELATIONSHIP_RESULT_FILE}'"
	push_cleanup "rm -f '${_RELATIONSHIP_DIAGNOSTIC_FILE}'"
	push_cleanup "rm -f '${_RELATIONSHIP_BACKEND_CALL_FILE}'"
	_register_relationship_batch_cleanup
	return 0
}

_relationship_record_outcome() {
	local outcome="$1"
	case "$outcome" in
	"$_REL_OUTCOME_CREATED" | "$_REL_OUTCOME_ALREADY_PRESENT" | failed:auth | failed:graphql | "$_REL_OUTCOME_FAILED_RESOLUTION" | failed:timeout-uncertain | failed:transport | "$_REL_OUTCOME_FAILED_UNKNOWN" | deferred:cooldown | "$_REL_OUTCOME_DEFERRED_DEADLINE") ;;
	*) return 1 ;;
	esac
	[[ -f "${_RELATIONSHIP_RESULT_FILE:-}" ]] || return 0
	printf '%s\n' "$outcome" >>"$_RELATIONSHIP_RESULT_FILE"
	return 0
}

# Shared pulse logs may be retained. Keep diagnostics limited to normalized
# TODO identifiers and reason classes rather than raw API or filesystem output.
_relationship_record_diagnostic() {
	local task_id="$1" edge="$2" reason="$3" edge_pattern='^[A-Za-z0-9._#>/-]+$'
	[[ "$task_id" =~ ^t[0-9]+(\.[0-9]+)*$ ]] || return 1
	[[ "$edge" =~ $edge_pattern ]] || return 1
	[[ "$reason" =~ ^[a-z0-9-]+$ ]] || return 1
	[[ -f "${_RELATIONSHIP_DIAGNOSTIC_FILE:-}" ]] || return 0
	printf 'task=%s edge=%s reason=%s\n' "$task_id" "$edge" "$reason" >>"$_RELATIONSHIP_DIAGNOSTIC_FILE"
	return 0
}

_relationship_record_mutation_failure() {
	local mutation_rc="$1"
	local result="$2"
	if [[ "$mutation_rc" -eq 75 ]] || printf '%s' "$result" | grep -qiE 'secondary rate limit|abuse detection|retry-after|cooldown'; then
		_relationship_record_outcome "deferred:cooldown"
	elif [[ "$mutation_rc" -eq 124 ]] || printf '%s' "$result" | grep -qiE 'timed out|timeout'; then
		_relationship_record_outcome "failed:timeout-uncertain"
	elif printf '%s' "$result" | grep -qiE 'HTTP (401|403)|authentication|bad credentials'; then
		_relationship_record_outcome "failed:auth"
	elif printf '%s' "$result" | grep -qiE 'connection|network|TLS|unexpected EOF'; then
		_relationship_record_outcome "failed:transport"
	elif printf '%s' "$result" | grep -qiE 'graphql|"errors"|could not resolve'; then
		_relationship_record_outcome "failed:graphql"
	else
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_UNKNOWN"
	fi
	return 0
}

_relationship_outcome_count() {
	local outcome_prefix="$1"
	local count="0"
	[[ -f "${_RELATIONSHIP_RESULT_FILE:-}" ]] || { printf '0\n'; return 0; }
	count=$(grep -cE "^${outcome_prefix}(:|$)" "$_RELATIONSHIP_RESULT_FILE" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s\n' "$count"
	return 0
}

_relationship_first_incomplete_outcome() {
	local outcome=""
	[[ -f "${_RELATIONSHIP_RESULT_FILE:-}" ]] || { printf 'none\n'; return 0; }
	outcome=$(grep -E '^(failed|deferred):' "$_RELATIONSHIP_RESULT_FILE" 2>/dev/null | head -1 || true)
	printf '%s\n' "${outcome:-none}"
	return 0
}

_relationship_backend_call_count() {
	local count="0"
	[[ -f "${_RELATIONSHIP_BACKEND_CALL_FILE:-}" ]] || { printf '0\n'; return 0; }
	count=$(wc -l <"$_RELATIONSHIP_BACKEND_CALL_FILE" 2>/dev/null | tr -d '[:space:]' || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s\n' "$count"
	return 0
}

_relationship_hash_stdin() {
	if command -v git >/dev/null 2>&1; then
		git hash-object --stdin 2>/dev/null
		return $?
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 2>/dev/null | cut -d' ' -f1
		return $?
	fi
	cksum | tr ' ' ':'
	return $?
}

_relationship_resume_state_file() {
	local repo="$1"
	local state_dir="${AIDEVOPS_RELATIONSHIP_STATE_DIR:-${HOME}/.aidevops/state/issue-sync-relationships}"
	local safe_repo=""
	safe_repo=$(printf '%s' "$repo" | tr -c '[:alnum:]._-' '_') || return 1
	printf '%s/%s.state\n' "$state_dir" "$safe_repo"
	return 0
}

_relationship_load_resume_state() {
	local state_file="$1"
	local expected_revision="$2"
	local line="" state_revision="" state_version="" valid=1 pending_task="" suppressed_task=""
	_RELATIONSHIP_RESUME_TASKS=()
	_RELATIONSHIP_RESUME_SUPPRESSED_TASKS=()
	_RELATIONSHIP_RESUME_STATUS="$_RELATIONSHIP_RESUME_FRESH"
	[[ -f "$state_file" ]] || return 0
	while IFS= read -r line; do
		case "$line" in
		version=*) state_version="${line#version=}" ;;
		revision=*) state_revision="${line#revision=}" ;;
		pending=*)
			pending_task="${line#pending=}"
			if [[ "$pending_task" =~ ^t[0-9]+(\.[0-9]+)*$ ]]; then
				_RELATIONSHIP_RESUME_TASKS+=("$pending_task")
			else
				valid=0
			fi
			;;
		suppressed=*)
			suppressed_task="${line#suppressed=}"
			if [[ "$suppressed_task" =~ ^t[0-9]+(\.[0-9]+)*$ ]]; then
				_RELATIONSHIP_RESUME_SUPPRESSED_TASKS+=("$suppressed_task")
			else
				valid=0
			fi
			;;
		*) valid=0 ;;
		esac
	done <"$state_file"
	if [[ "$valid" -ne 1 || "$state_version" != "2" || "$state_revision" != "$expected_revision" ]]; then
		_RELATIONSHIP_RESUME_TASKS=()
		_RELATIONSHIP_RESUME_SUPPRESSED_TASKS=()
		_RELATIONSHIP_RESUME_STATUS="invalidated"
		rm -f "$state_file"
		return 0
	fi
	if [[ ${#_RELATIONSHIP_RESUME_TASKS[@]} -gt 0 ]]; then
		_RELATIONSHIP_RESUME_STATUS="resumed"
	else
		rm -f "$state_file"
	fi
	return 0
}

_relationship_write_resume_state() {
	local state_file="$1"
	local revision="$2"
	shift 2
	local state_dir="" temp_file="" task_id="" previous_umask=""
	state_dir=$(dirname "$state_file") || return 1
	mkdir -p "$state_dir" || return 1
	previous_umask=$(umask)
	umask 077
	temp_file=$(mktemp "${state_dir}/.relationships.XXXXXX")
	local mktemp_rc=$?
	umask "$previous_umask"
	[[ "$mktemp_rc" -eq 0 && -n "$temp_file" ]] || return 1
	{
		printf 'version=2\nrevision=%s\n' "$revision"
		for task_id in "$@"; do
			printf 'pending=%s\n' "$task_id"
		done
		for task_id in "${_RELATIONSHIP_RESUME_SUPPRESSED_TASKS[@]}"; do
			printf 'suppressed=%s\n' "$task_id"
		done
	} >"$temp_file" || { rm -f "$temp_file"; return 1; }
	mv "$temp_file" "$state_file" || { rm -f "$temp_file"; return 1; }
	return 0
}

_relationship_print_summary() {
	local attempted="$1" complete="$2" total="$3" retryable_total="$4" deadline_exhausted="$5"
	local candidate_total="${6:-$total}" remaining="${7:-0}" resume_status="${8:-fresh}"
	local parse_seconds="${9:-0}" mutation_seconds="${10:-0}" backend_calls="${11:-0}"
	local created already_present failed deferred first_incomplete diagnostic=""
	local mapping_calls snapshot_calls mutation_calls verify_calls status_calls other_calls
	local mapping_seconds snapshot_seconds mutation_class_seconds verify_seconds status_seconds
	local timed_seconds unaccounted_seconds
	created=$(_relationship_outcome_count "$_REL_OUTCOME_CREATED")
	already_present=$(_relationship_outcome_count "$_REL_OUTCOME_ALREADY_PRESENT")
	failed=$(_relationship_outcome_count "failed")
	deferred=$(_relationship_outcome_count "deferred")
	first_incomplete=$(_relationship_first_incomplete_outcome)
	mapping_calls=$(_relationship_backend_call_count_for mapping)
	snapshot_calls=$(_relationship_backend_call_count_for snapshot)
	mutation_calls=$(_relationship_backend_call_count_for mutation)
	verify_calls=$(_relationship_backend_call_count_for verify)
	status_calls=$(_relationship_backend_call_count_for status)
	other_calls=$(_relationship_backend_call_count_for other)
	mapping_seconds=$(_relationship_operation_seconds mapping)
	snapshot_seconds=$(_relationship_operation_seconds snapshot)
	mutation_class_seconds=$(_relationship_operation_seconds mutation)
	verify_seconds=$(_relationship_operation_seconds verify)
	status_seconds=$(_relationship_operation_seconds status)
	timed_seconds=$((mapping_seconds + snapshot_seconds + mutation_class_seconds + verify_seconds + status_seconds))
	unaccounted_seconds=$((mutation_seconds - timed_seconds))
	[[ "$unaccounted_seconds" -ge 0 ]] || unaccounted_seconds=0
	printf '\n=== Relationships Sync ===\nEdges: created=%d already-present=%d failed=%d deferred=%d\n' \
		"$created" "$already_present" "$failed" "$deferred"
	printf 'Tasks: attempted=%d complete=%d/%d | Retryable: %d | Deadline exhausted: %s\n' \
		"$attempted" "$complete" "$total" "$retryable_total" "$deadline_exhausted"
	printf 'Workset: candidates=%d resume=%s pending_before=%d remaining=%d\n' \
		"$candidate_total" "$resume_status" "$total" "$remaining"
	printf 'Timing: parse=%ss mutation=%ss | Backend calls: %d\n' \
		"$parse_seconds" "$mutation_seconds" "$backend_calls"
	printf 'Backend classes: mapping=%d snapshot=%d mutation=%d verify=%d status=%d other=%d\n' \
		"$mapping_calls" "$snapshot_calls" "$mutation_calls" "$verify_calls" "$status_calls" "$other_calls"
	printf 'Operation timing: mapping=%ss snapshot=%ss mutation=%ss verify=%ss status=%ss\n' \
		"$mapping_seconds" "$snapshot_seconds" "$mutation_class_seconds" "$verify_seconds" "$status_seconds"
	printf 'Timing coverage: operations=%ss unaccounted=%ss\n' \
		"$timed_seconds" "$unaccounted_seconds"
	printf 'Failure: %s\n' "$first_incomplete"
	if [[ -f "${_RELATIONSHIP_DIAGNOSTIC_FILE:-}" ]]; then
		while IFS= read -r diagnostic; do
			[[ -n "$diagnostic" ]] || continue
			printf 'Unresolved relationship: %s\n' "$diagnostic"
		done <"$_RELATIONSHIP_DIAGNOSTIC_FILE"
	fi
	[[ "$retryable_total" -eq 0 ]] || printf 'Recovery: rerun .agents/scripts/issue-sync-helper.sh relationships\n'
	return 0
}

_relationship_print_progress() {
	local attempted="$1"
	local total="$2"
	if [[ $((attempted % 25)) -eq 0 || "$attempted" -eq "$total" ]]; then
		printf "\r  Progress: %d/%d tasks..." "$attempted" "$total" >&2
	fi
	return 0
}

run_relationship_scoped_command() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	_begin_relationship_sync_scope || return 1
	_register_relationship_sync_cleanup
	local rc=0
	"$@" || rc=$?
	_end_relationship_sync_scope
	return "$rc"
}

_relationship_sync_deadline_epoch() {
	# Keep automatic post-create work below common 120-second outer worker
	# ceilings. Callers may override this documented aggregate budget.
	local budget="${AIDEVOPS_RELATIONSHIP_SYNC_TIMEOUT:-90}"
	local now_epoch=""
	[[ "$budget" =~ ^[1-9][0-9]*$ ]] || budget=90
	now_epoch=$(date +%s 2>/dev/null) || return 1
	printf '%s\n' "$((now_epoch + budget))"
	return 0
}

_relationship_deadline_expired() {
	local deadline_epoch="${AIDEVOPS_GH_DEADLINE_EPOCH:-0}"
	local now_epoch=""
	[[ "$deadline_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
	now_epoch=$(date +%s 2>/dev/null) || return 0
	[[ "$now_epoch" -ge "$deadline_epoch" ]]
	return $?
}

_relationship_edge_should_attempt() {
	local blocked_num="$1"
	local blocker_num="$2"
	local edge_key="${blocked_num}|${blocker_num}"
	[[ -f "${_RELATIONSHIP_EDGE_SEEN_FILE:-}" ]] || return 1
	if grep -Fxq -- "$edge_key" "$_RELATIONSHIP_EDGE_SEEN_FILE"; then
		return 1
	fi
	printf '%s\n' "$edge_key" >>"$_RELATIONSHIP_EDGE_SEEN_FILE"
	return 0
}
