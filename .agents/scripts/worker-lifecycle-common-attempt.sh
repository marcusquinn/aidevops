#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Common -- Attempt Identity & Runtime Evidence
# =============================================================================
# Worker lineage/attempt identity, objective-reconciliation evidence and
# runtime/supervisor dispatch event emission.
#
# Pure move from worker-lifecycle-common.sh (large-file split, GH#40351):
# function bodies, names and shared variables are unchanged.
#
# Usage: sourced by worker-lifecycle-common.sh; callers keep sourcing that file.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_ATTEMPT_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_ATTEMPT_LOADED=1

_ensure_worker_lineage() {
	local session_key="$1"
	local epoch=""
	epoch=$(date +%s 2>/dev/null || printf '0')
	if [[ -z "${AIDEVOPS_WORKER_ID:-}" ]]; then
		export AIDEVOPS_WORKER_ID="worker:${session_key:-session}:$$:${epoch}:${RANDOM:-0}"
	fi
	if [[ -z "${AIDEVOPS_ROOT_WORKER_ID:-}" ]]; then
		export AIDEVOPS_ROOT_WORKER_ID="${AIDEVOPS_PARENT_WORKER_ID:-$AIDEVOPS_WORKER_ID}"
	fi
	if [[ -z "${AIDEVOPS_CORRELATION_ID:-}" ]]; then
		export AIDEVOPS_CORRELATION_ID="correlation:${AIDEVOPS_ROOT_WORKER_ID}"
	fi
	: "${AIDEVOPS_PARENT_WORKER_ID:=}"
	: "${AIDEVOPS_CAUSATION_ID:=}"
	: "${AIDEVOPS_PARENT_EVENT_ID:=}"
	: "${AIDEVOPS_ROOT_EVENT_ID:=}"
	export AIDEVOPS_WORKER_ID AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_CORRELATION_ID
	export AIDEVOPS_CAUSATION_ID AIDEVOPS_PARENT_EVENT_ID AIDEVOPS_ROOT_EVENT_ID
	return 0
}

_ensure_worker_attempt_identity() {
	if [[ -z "${AIDEVOPS_ATTEMPT_ID:-}" ]]; then
		AIDEVOPS_ATTEMPT_ID=$(aidevops_generate_execution_id "attempt")
	fi
	if [[ ! "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]+$ ]]; then
		AIDEVOPS_ATTEMPT_STARTED_AT=$(_worker_attempt_start_marker)
	fi
	export AIDEVOPS_ATTEMPT_ID AIDEVOPS_ATTEMPT_STARTED_AT
	return 0
}

# Return a high-resolution epoch marker so attempts dispatched within the same
# second retain deterministic chronology. Python is already a framework runtime
# dependency; the seconds fallback preserves a comparable 19-digit shape.
_worker_attempt_start_marker() {
	local marker=""
	marker=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || true)
	if [[ ! "$marker" =~ ^[0-9]{19}$ ]]; then
		marker="$(date +%s 2>/dev/null || printf '0')000000000"
	fi
	printf '%s' "$marker"
	return 0
}

_begin_worker_runtime_run() {
	AIDEVOPS_RUN_ID=$(aidevops_generate_execution_id "run")
	export AIDEVOPS_RUN_ID
	return 0
}

_worker_attempt_id_for_issue() {
	local issue_number="$1"
	local repo_slug="$2"
	local attempt_id="${3:-${AIDEVOPS_ATTEMPT_ID:-}}"
	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local ledger_file="${ledger_dir}/dispatch-ledger.jsonl"

	[[ "$issue_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" ]] || return 1
	if [[ -z "$attempt_id" && -s "$ledger_file" ]]; then
		attempt_id=$(jq -sr --arg issue "$issue_number" --arg repo "$repo_slug" '
			[.[] | select((.issue_number // "") == $issue and (.repo_slug // "") == $repo and (.attempt_id // "") != "")]
			| last | .attempt_id // empty
		' "$ledger_file" 2>/dev/null) || attempt_id=""
	fi
	[[ "$attempt_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || return 1
	printf '%s' "$attempt_id"
	return 0
}

_objective_disposition_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local attempt_id="${3:-}"
	local helper="${BASH_SOURCE[0]%/*}/objective-reconciliation-helper.sh"
	local -a disposition_args=(disposition --repo "$repo_slug" --issue "$issue_number")

	[[ -x "$helper" && "$issue_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" ]] || return 1
	[[ -n "$attempt_id" ]] && disposition_args+=(--attempt-id "$attempt_id")
	"$helper" "${disposition_args[@]}" 2>/dev/null
	return $?
}

_objective_disposition_suppresses() {
	local suppression_field="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local attempt_id="${4:-}"
	local disposition=""

	case "$suppression_field" in
	suppress_fast_fail | suppress_retry | suppress_enrichment | suppress_failure_mining) ;;
	*) return 1 ;;
	esac
	disposition=$(_objective_disposition_json "$issue_number" "$repo_slug" "$attempt_id") || return 1
	printf '%s' "$disposition" | jq -e --arg field "$suppression_field" '.[$field] == true' >/dev/null 2>&1
	return $?
}

_emit_objective_recovery_evidence() {
	local event_type="$1"
	local status="$2"
	local classification="$3"
	local issue_number="${WORKER_ISSUE_NUMBER:-${ISSUE_NUMBER:-}}"
	local repo="${GITHUB_REPOSITORY:-${WORKER_REPO:-}}"
	[[ "$issue_number" =~ ^[0-9]+$ && -n "$repo" ]] || return 0
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_dir=""
	local evidence_timestamp="0"
	local branch_name=""
	local worktree_name=""
	local commit_sha=""
	local log_path="${WORKER_LOG_FILE:-${HEADLESS_RUNTIME_LOG:-}}"
	local next_action="monitor_worker"
	local execution_path_state="running"
	local recovery_attempt="${AIDEVOPS_RECOVERY_ATTEMPT:-0}"
	local attempt_started_at="${AIDEVOPS_ATTEMPT_STARTED_AT:-0}"
	local repair_pr_number="${AIDEVOPS_PR_REPAIR_NUMBER:-}"
	local repair_head_sha="${AIDEVOPS_PR_REPAIR_HEAD_SHA:-}"
	local repair_head_ref="${AIDEVOPS_PR_REPAIR_HEAD_REF:-}"
	local repair_fingerprint="${AIDEVOPS_PR_REPAIR_FINGERPRINT:-}"
	[[ "$recovery_attempt" =~ ^[0-9]+$ ]] || recovery_attempt=0
	[[ "$attempt_started_at" =~ ^[0-9]+$ ]] || attempt_started_at=0
	evidence_dir=$(dirname "$evidence_file")
	mkdir -p "$evidence_dir" 2>/dev/null || return 0
	evidence_timestamp=$(date +%s 2>/dev/null) || evidence_timestamp=0
	branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch_name=""
	commit_sha=$(git rev-parse HEAD 2>/dev/null) || commit_sha=""
	worktree_name=$(basename "${WORKER_WORKTREE_PATH:-$PWD}")
	case "$event_type" in
	worker.completed) next_action="monitor_pr"; execution_path_state="terminal" ;;
	worker.failed) next_action="retry_infrastructure"; execution_path_state="recovery" ;;
	worker.commit_attempted|worker.push_attempted) next_action="resume_session"; execution_path_state="checkpointed" ;;
	esac
	local evidence_record=""
	evidence_record=$(jq -nc \
		--arg event_type "$event_type" \
		--arg status "$status" \
		--arg classification "$classification" \
		--arg repo "$repo" \
		--argjson issue_number "$issue_number" \
		--argjson evidence_timestamp "$evidence_timestamp" \
		--arg worker_id "${AIDEVOPS_WORKER_ID:-}" \
		--arg attempt_id "${AIDEVOPS_ATTEMPT_ID:-}" \
		--arg run_id "${AIDEVOPS_RUN_ID:-}" \
		--argjson attempt_started_at "$attempt_started_at" \
		--arg branch "$branch_name" \
		--arg worktree "$worktree_name" \
		--arg commit "$commit_sha" \
		--arg next_action "$next_action" \
		--arg execution_path_state "$execution_path_state" \
		--argjson recovery_attempt "${recovery_attempt:-0}" \
		--arg repair_pr_number "$repair_pr_number" \
		--arg repair_head_sha "$repair_head_sha" \
		--arg repair_head_ref "$repair_head_ref" \
		--arg repair_fingerprint "$repair_fingerprint" \
		--argjson logs_preserved "$([[ -n "$log_path" && -s "$log_path" ]] && printf true || printf false)" \
		--argjson verification_preserved "$([[ -n "${AIDEVOPS_VERIFICATION_EVIDENCE:-}" ]] && printf true || printf false)" \
		'{event_type:$event_type,status:$status,classification:$classification,repo:$repo,
		issue_number:$issue_number,evidence_timestamp:$evidence_timestamp,worker_id:$worker_id,
		attempt_id:$attempt_id,run_id:$run_id,attempt_started_at:$attempt_started_at,
		branch:$branch,worktree:$worktree,commit:$commit,next_action:$next_action,
		execution_path_state:$execution_path_state,recovery_attempt:$recovery_attempt,
		branch_preserved:($branch != ""),worktree_preserved:($worktree != ""),
		commits_preserved:($commit != ""),logs_preserved:$logs_preserved,
		verification_preserved:$verification_preserved,subsequent_action_at:$evidence_timestamp,
		pr_repair:(if $repair_pr_number == "" then null else {pr_number:($repair_pr_number|tonumber),
		head_sha:$repair_head_sha,head_ref:$repair_head_ref,failure_fingerprint:$repair_fingerprint} end)}') || evidence_record=""
	[[ -n "$evidence_record" ]] || return 0
	_objective_evidence_locked_append "$evidence_file" "$evidence_record"
	return 0
}

# GH#32938: concurrent unlocked `>>` appends of >1KB records tore ledger lines.
# Shares objective-reconciliation-helper.sh's `<file>.lockdir` so both writers
# serialise. Lock contention past ~5s falls back to the previous best-effort append.
_objective_evidence_locked_append() {
	local evidence_file="$1"
	local record="$2"
	local lock_dir="${evidence_file}.lockdir"
	local attempts=0
	local owner_pid=""
	local locked=0
	while [[ "$attempts" -lt 100 ]]; do
		if mkdir "$lock_dir" 2>/dev/null; then
			locked=1
			printf '%s\n' "$$" >"${lock_dir}/owner.pid" 2>/dev/null || true
			break
		fi
		attempts=$((attempts + 1))
		owner_pid=$(tr -d '[:space:]' <"${lock_dir}/owner.pid" 2>/dev/null || true)
		if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 0.05
	done
	printf '%s\n' "$record" >>"$evidence_file" 2>/dev/null || true
	if [[ "$locked" -eq 1 ]]; then
		rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	return 0
}

_emit_worker_runtime_event() {
	local event_type="$1"
	local status="${2:-}"
	local classification="${3:-}"
	local runtime_events="${BASH_SOURCE[0]%/*}/runtime-events.mjs"
	[[ -n "${AIDEVOPS_WORKER_ID:-}" ]] || return 0
	_emit_objective_recovery_evidence "$event_type" "$status" "$classification"
	case "$event_type" in
	worker.completed | worker.failed | worker.deferred)
		if [[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" && "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ && -n "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" ]]; then
			local lease_helper="${BASH_SOURCE[0]%/*}/dispatch-claim-helper.sh"
			# shellcheck source=./terminal-lease-recovery.sh
			source "${BASH_SOURCE[0]%/*}/terminal-lease-recovery.sh"
			_terminal_lease_emit_or_record "$WORKER_ISSUE_NUMBER" \
				"${DISPATCH_REPO_SLUG:-$WORKER_REPO_SLUG}" \
				"${AIDEVOPS_DISPATCH_LEASE_SESSION:-${_invoke_session_key:-issue-${WORKER_ISSUE_NUMBER}}}" "$lease_helper" || true
		fi
		;;
	esac
	[[ -f "$runtime_events" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local -a event_cmd=(node "$runtime_events" emit "$event_type" --source worker_self_reported)
	[[ -n "$status" ]] && event_cmd+=(--status "$status")
	[[ -n "$classification" ]] && event_cmd+=(--classification "$classification")
	"${event_cmd[@]}" >/dev/null 2>&1 || true
	return 0
}

_emit_supervisor_dispatch_event() {
	local worker_id="$1"
	local parent_worker_id="$2"
	local root_worker_id="$3"
	local correlation_id="$4"
	local runtime_events="${BASH_SOURCE[0]%/*}/runtime-events.mjs"
	local event_id=""
	[[ -n "$worker_id" && -f "$runtime_events" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0

	local -a event_cmd=(
		node "$runtime_events" emit worker.dispatched
		--subject "$worker_id"
		--worker "$worker_id"
		--root-worker "$root_worker_id"
		--correlation "$correlation_id"
		--source supervisor_observed
		--root-dispatch
		--print-id
	)
	if [[ -n "$parent_worker_id" ]]; then
		event_cmd+=(--parent-worker "$parent_worker_id")
	fi
	if [[ -n "${AIDEVOPS_ROOT_EVENT_ID:-}" ]]; then
		event_cmd+=(--root-event "$AIDEVOPS_ROOT_EVENT_ID")
	fi
	if [[ -n "${AIDEVOPS_PARENT_EVENT_ID:-}" ]]; then
		event_cmd+=(--parent-event "$AIDEVOPS_PARENT_EVENT_ID" --causation "$AIDEVOPS_PARENT_EVENT_ID")
	elif [[ -n "${AIDEVOPS_CAUSATION_ID:-}" ]]; then
		event_cmd+=(--causation "$AIDEVOPS_CAUSATION_ID")
	fi
	event_id=$("${event_cmd[@]}" 2>/dev/null) || event_id=""
	printf '%s' "$event_id"
	return 0
}
