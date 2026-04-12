#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-capacity.sh — Worker-slot capacity counters — target workers, runnable candidates, queued count, debug formatting.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - get_max_workers_target
#   - count_runnable_candidates
#   - count_queued_without_worker
#   - pulse_count_debug_log
#   - normalize_count_output
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CAPACITY_LOADED:-}" ]] && return 0
_PULSE_CAPACITY_LOADED=1

#######################################
# Get current max workers from pulse-max-workers file
# Returns: numeric value via stdout (defaults to 1)
#######################################
get_max_workers_target() {
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	local max_workers
	max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "1")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	fi
	echo "$max_workers"
	return 0
}

#######################################
# Count runnable backlog candidates across pulse scope
# Heuristic for t1453 utilization loop:
# - open issues passing default-open candidate filter
#   (non-needs-* and non-management labels)
# - open PRs with failing checks or changes requested
# Returns: count via stdout
#######################################
count_runnable_candidates() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local total=0
	while IFS='|' read -r slug _path; do
		[[ -n "$slug" ]] || continue

		local issue_count
		issue_count=$(list_dispatchable_issue_candidates "$slug" "$PULSE_RUNNABLE_ISSUE_LIMIT" | wc -l | tr -d ' ') || issue_count=0
		[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

		local pr_json pr_rc_err
		pr_rc_err=$(mktemp)
		pr_json=$(gh pr list --repo "$slug" --state open --json reviewDecision,statusCheckRollup --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>"$pr_rc_err") || pr_json="[]"
		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local _pr_rc_err_msg
			_pr_rc_err_msg=$(cat "$pr_rc_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_runnable_candidates: gh pr list FAILED for ${slug}: ${_pr_rc_err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
		rm -f "$pr_rc_err"
		local pr_count
		pr_count=$(echo "$pr_json" | jq '[.[] | select(.reviewDecision == "CHANGES_REQUESTED" or ((.statusCheckRollup // []) | any((.conclusion // .state) == "FAILURE")))] | length' 2>/dev/null) || pr_count=0
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
		pulse_count_debug_log "count_runnable_candidates repo=${slug} issues=${issue_count} prs=${pr_count} total=$((issue_count + pr_count))"

		total=$((total + issue_count + pr_count))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Count queued issues that do not have an active worker process
# This is a launch-validation signal: queued labels imply dispatch,
# but no matching worker indicates startup failure or immediate exit.
# Returns: count via stdout
#######################################
count_queued_without_worker() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

	local total=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local queued_json queued_err
		queued_err=$(mktemp)
		queued_json=$(gh issue list --repo "$slug" --state open --label "status:queued" --json number,assignees --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$queued_err") || queued_json="[]"
		if [[ -z "$queued_json" || "$queued_json" == "null" ]]; then
			local _queued_err_msg
			_queued_err_msg=$(cat "$queued_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_queued_without_worker: gh issue list FAILED for ${slug}: ${_queued_err_msg}" >>"$LOGFILE"
			queued_json="[]"
		fi
		rm -f "$queued_err"

		local queued_count
		queued_count=$(echo "$queued_json" | jq 'length' 2>/dev/null) || queued_count=0
		[[ "$queued_count" =~ ^[0-9]+$ ]] || queued_count=0
		pulse_count_debug_log "count_queued_without_worker repo=${slug} queued=${queued_count}"
		if [[ "$queued_count" -eq 0 ]]; then
			continue
		fi

		while IFS='|' read -r issue_num assigned_to_other; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Cross-runner safety: queued issues assigned to another login are not
			# counted as "without worker" because the worker may be running on that
			# runner's machine and invisible to local process inspection.
			if [[ "$assigned_to_other" == "true" ]]; then
				continue
			fi

			if ! has_worker_for_repo_issue "$issue_num" "$slug"; then
				total=$((total + 1))
				pulse_count_debug_log "count_queued_without_worker repo=${slug} issue=${issue_num} missing_worker=true"
			fi
		done < <(echo "$queued_json" | jq -r --arg self "$self_login" '.[] | .number as $n | ((.assignees | length) > 0 and (([.assignees[].login] | index($self)) == null)) as $assigned_other | "\($n)|\($assigned_other)"' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Emit debug logs for pulse count helpers without polluting stdout.
#
# Debug logs are opt-in via PULSE_DEBUG and always go to stderr so helpers that
# are consumed numerically keep a strict stdout contract.
#
# Arguments:
#   $1 - message to log
# Returns: 0 always
#######################################
pulse_count_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		printf '[pulse-wrapper] DEBUG: %s\n' "$message" >&2
		;;
	esac
	return 0
}

#######################################
# Normalize noisy helper stdout to a numeric count.
#
# Some count helpers may emit diagnostic lines before their final numeric
# result. Accept the last line that is purely an integer; otherwise fail closed
# to 0.
#
# Arguments:
#   $1 - raw helper stdout
# Returns: normalized integer via stdout
#######################################
normalize_count_output() {
	local raw_output="$1"
	local normalized
	normalized=$(printf '%s\n' "$raw_output" | awk '
		/^[[:space:]]*[0-9]+[[:space:]]*$/ {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
			last = $0
		}
		END {
			if (last != "") {
				print last
			}
		}
	')

	if [[ "$normalized" =~ ^[0-9]+$ ]]; then
		echo "$normalized"
		return 0
	fi

	echo "0"
	return 0
}
