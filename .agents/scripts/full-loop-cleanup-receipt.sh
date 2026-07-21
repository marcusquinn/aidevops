#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Durable, external lifecycle receipts for owner-safe full-loop cleanup.
# The receipt survives removal of the linked worktree and lets a later guarded
# cleanup process assume the lease and record the terminal CLEANED transition.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_FULL_LOOP_CLEANUP_RECEIPT_LOADED:-}" ]] && return 0
_FULL_LOOP_CLEANUP_RECEIPT_LOADED=1

_FULL_LOOP_CLEANUP_DEFERRED="CLEANUP_DEFERRED"
_FULL_LOOP_CLEANUP_LEASED="CLEANUP_LEASED"
_FULL_LOOP_CLEANUP_CLEANED="CLEANED"

_full_loop_cleanup_receipt_dir() {
	printf '%s\n' "${AIDEVOPS_FULL_LOOP_CLEANUP_DIR:-${HOME}/.aidevops/state/full-loop-cleanup}"
	return 0
}

_full_loop_cleanup_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	local receipt_dir=""
	local safe_repo="${repo//\//_}"

	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	printf '%s/%s-%s.json\n' "$receipt_dir" "$safe_repo" "$pr_number"
	return 0
}

_full_loop_process_identity() {
	local owner_pid="$1"
	local identity=""

	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	identity=$(ps -p "$owner_pid" -o lstart= 2>/dev/null || true)
	[[ -n "$identity" ]] || return 1
	printf '%s\n' "$identity"
	return 0
}

full_loop_write_cleanup_deferred() {
	local repo="$1"
	local pr_number="$2"
	local worktree="$3"
	local branch="$4"
	local owner_pid="$5"
	local owner_session="$6"
	local release_status="${7:-pending}"
	local executor_completion_state="${8:-COMPLETE}"
	local receipt_path=""
	local owner_identity=""
	local now=""

	[[ -n "$worktree" && -n "$branch" && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ "$executor_completion_state" == "FINALIZATION_PENDING" || "$executor_completion_state" == "COMPLETE" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	owner_identity=$(_full_loop_process_identity "$owner_pid") || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${receipt_path%/*}" || return 1
	jq -cn \
		--arg repo "$repo" --argjson pr_number "$pr_number" \
		--arg worktree "$worktree" --arg branch "$branch" \
		--argjson owner_pid "$owner_pid" --arg owner_identity "$owner_identity" \
		--arg owner_session "$owner_session" --arg release_status "$release_status" \
		--arg executor_completion_state "$executor_completion_state" \
		--arg state "$_FULL_LOOP_CLEANUP_DEFERRED" --arg now "$now" \
		'{schema_version:1,repository:$repo,pr_number:$pr_number,worktree:$worktree,branch:$branch,
		  executor_completion_state:$executor_completion_state,resource_cleanup_state:$state,release_status:$release_status,
		  owner:{pid:$owner_pid,process_identity:$owner_identity,session:$owner_session},
		  cleanup_lease:{state:"pending",pid:null,acquired_at:null},created_at:$now,updated_at:$now,cleaned_at:null}' \
		>"${receipt_path}.tmp.$$" || return 1
	mv "${receipt_path}.tmp.$$" "$receipt_path" || return 1
	printf '%s\n' "$receipt_path"
	return 0
}

full_loop_cleanup_receipt_for_worktree() {
	local worktree="$1"
	local receipt_dir=""
	local receipt_path=""

	[[ -n "$worktree" ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	[[ -d "$receipt_dir" ]] || return 1
	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		if jq -e --arg worktree "$worktree" '.worktree == $worktree' "$receipt_path" >/dev/null 2>&1; then
			printf '%s\n' "$receipt_path"
			return 0
		fi
	done
	return 1
}

full_loop_cleanup_owner_alive() {
	local receipt_path="$1"
	local owner_pid=""
	local expected_identity=""
	local observed_identity=""

	[[ -f "$receipt_path" ]] || return 1
	owner_pid=$(jq -r '.owner.pid // empty' "$receipt_path" 2>/dev/null || true)
	expected_identity=$(jq -r '.owner.process_identity // empty' "$receipt_path" 2>/dev/null || true)
	[[ "$owner_pid" =~ ^[0-9]+$ && -n "$expected_identity" ]] || return 1
	kill -0 "$owner_pid" 2>/dev/null || return 1
	observed_identity=$(_full_loop_process_identity "$owner_pid") || return 1
	[[ "$observed_identity" == "$expected_identity" ]] || return 1
	return 0
}

full_loop_transition_cleanup_receipt() {
	local receipt_path="$1"
	local target_state="$2"
	local lease_pid="${3:-}"
	local current_state=""
	local now=""

	[[ -f "$receipt_path" ]] || return 1
	case "$target_state" in
	"$_FULL_LOOP_CLEANUP_DEFERRED" | "$_FULL_LOOP_CLEANUP_LEASED" | "$_FULL_LOOP_CLEANUP_CLEANED") ;;
	*) return 1 ;;
	esac
	current_state=$(jq -r '.resource_cleanup_state // empty' "$receipt_path" 2>/dev/null || true)
	case "${current_state}:${target_state}" in
	"${_FULL_LOOP_CLEANUP_DEFERRED}:${_FULL_LOOP_CLEANUP_DEFERRED}" | \
		"${_FULL_LOOP_CLEANUP_DEFERRED}:${_FULL_LOOP_CLEANUP_LEASED}" | \
		"${_FULL_LOOP_CLEANUP_DEFERRED}:${_FULL_LOOP_CLEANUP_CLEANED}" | \
		"${_FULL_LOOP_CLEANUP_LEASED}:${_FULL_LOOP_CLEANUP_LEASED}" | \
		"${_FULL_LOOP_CLEANUP_LEASED}:${_FULL_LOOP_CLEANUP_CLEANED}" | \
		"${_FULL_LOOP_CLEANUP_CLEANED}:${_FULL_LOOP_CLEANUP_CLEANED}") ;;
	*) return 1 ;;
	esac
	if [[ "$target_state" == "$_FULL_LOOP_CLEANUP_LEASED" ]]; then
		[[ "$lease_pid" =~ ^[0-9]+$ ]] || return 1
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	jq --arg state "$target_state" --arg now "$now" --arg lease_pid "$lease_pid" '
		.resource_cleanup_state = $state
		| .updated_at = $now
		| if $state == "CLEANUP_LEASED" then
			.cleanup_lease = {state:"acquired",pid:($lease_pid | tonumber),acquired_at:$now}
		  elif $state == "CLEANED" then
			.cleanup_lease.state = "released" | .cleaned_at = $now
		  else . end
	' "$receipt_path" >"${receipt_path}.tmp.$$" || return 1
	mv "${receipt_path}.tmp.$$" "$receipt_path" || return 1
	return 0
}

full_loop_update_cleanup_release_status() {
	local repo="$1"
	local pr_number="$2"
	local release_status="$3"
	local receipt_path=""
	local now=""

	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 0
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	jq --arg release_status "$release_status" --arg now "$now" \
		'.release_status = $release_status | .updated_at = $now' \
		"$receipt_path" >"${receipt_path}.tmp.$$" || return 1
	mv "${receipt_path}.tmp.$$" "$receipt_path" || return 1
	return 0
}

full_loop_mark_cleanup_cleaned_for_worktree() {
	local worktree="$1"
	local cleanup_log="${2:-${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}}"
	local receipt_path=""

	[[ -n "$worktree" && ! -e "$worktree" && -f "$cleanup_log" ]] || return 1
	grep -Fq "worktree-removed: ${worktree} —" "$cleanup_log" || return 1
	receipt_path=$(full_loop_cleanup_receipt_for_worktree "$worktree") || return 1
	full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_CLEANED"
	return $?
}

full_loop_reconcile_cleanup_receipts() {
	local receipt_dir=""
	local receipt_path=""
	local worktree=""
	local state=""
	local cleanup_log="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"

	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 0
	[[ -d "$receipt_dir" && -f "$cleanup_log" ]] || return 0
	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		state=$(jq -r '.resource_cleanup_state // empty' "$receipt_path" 2>/dev/null || true)
		[[ "$state" != "$_FULL_LOOP_CLEANUP_CLEANED" ]] || continue
		worktree=$(jq -r '.worktree // empty' "$receipt_path" 2>/dev/null || true)
		[[ -n "$worktree" && ! -e "$worktree" ]] || continue
		grep -Fq "worktree-removed: ${worktree} —" "$cleanup_log" || continue
		full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_CLEANED" || true
	done
	return 0
}
