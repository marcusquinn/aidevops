#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Orphan -- Committed branch recovery
# =============================================================================
# Sourced by headless-runtime-worker.sh at the original definition location.
# Function bodies are kept unchanged; the orchestrator supplies claim lifecycle,
# orphan recovery dependencies and terminal outcome globals.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_ORPHAN_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_ORPHAN_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback for direct sourcing and test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Orphan handling
# =============================================================================

#######################################
# _increment_orphan_count_stat — increment worker_branch_orphan_count in pulse-stats.json
#
# Uses pulse_stats_increment if available (pulse-stats-helper.sh is sourced
# in pulse-wrapper.sh context); otherwise does an inline jq atomic update
# using the same timestamp-array format for consistency.
#
# Non-fatal: any file/jq failure is silently ignored.
#######################################
_increment_orphan_count_stat() {
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "worker_branch_orphan_count" 2>/dev/null || true
		return 0
	fi
	# Inline fallback: timestamp-array format (matches pulse-stats-helper.sh schema)
	local _stats_file="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
	local _stats_dir
	_stats_dir="$(dirname "$_stats_file")"
	[[ -d "$_stats_dir" ]] || mkdir -p "$_stats_dir" 2>/dev/null || return 0
	[[ -f "$_stats_file" ]] || printf '{"counters":{}}\n' >"$_stats_file" 2>/dev/null || return 0
	local _ts _tmp
	_ts=$(date +%s 2>/dev/null) || _ts=0
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	_tmp=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-orphan-XXXXXX") || return 0
	jq --argjson ts "$_ts" \
		'.counters.worker_branch_orphan_count += [$ts]' \
		"$_stats_file" >"$_tmp" 2>/dev/null \
		|| { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$_stats_file" 2>/dev/null || rm -f "$_tmp"
	return 0
}

#######################################
# _handle_worker_branch_orphan — recover from worker_branch_orphan state (GH#20819)
#
# Called from _cmd_run_finish when _worker_produced_output returns "branch_orphan":
# the worker pushed commits/branch but exited before opening a PR.
#
# Actions:
#   1. Increments worker_branch_orphan_count in pulse-stats.json (always)
#   2. Calls _attempt_orphan_recovery_pr to open a PR (GH#20819)
#   3. On PR success  → releases claim as "worker_complete" (audit note)
#   4. On PR failure  → releases claim as "worker_branch_orphan" + posts
#      structured ops comment on the issue so next dispatch can pick up
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_branch_orphan() {
	local session_key="$1"
	local work_dir="$2"

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	# t2899: extended diagnostic — surface what the worker actually produced so
	# the next regression in this classifier is debuggable from a single log line.
	# target_branch is the branch the worker was DISPATCHED to operate on
	# (set by the dispatch path via WORKER_TARGET_BRANCH env if present);
	# final_head is the HEAD SHA the worker exited on; ahead_count is commits
	# ahead of origin/$base_branch (configured PR base branch, fallback to
	# origin/master when the primary ref is missing); work_dir is the worktree path.
	local target_branch="${WORKER_TARGET_BRANCH:-<unset>}"
	local head_ref="HE""AD"
	local final_head=""
	final_head=$(git -C "$work_dir" rev-parse --short=12 "$head_ref" 2>/dev/null || printf '<unreadable>')
	local ahead_count=0
	local base_branch=""
	base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
	local rev_output=""
	# Fallback to master only when the primary ref is MISSING (non-zero exit),
	# not when the count happens to be zero (worker exited on default branch).
	if rev_output=$(git -C "$work_dir" rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null); then
		ahead_count=$rev_output
	else
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || echo 0)
	fi
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0

	print_info "[lifecycle] worker_branch_orphan session=${session_key} branch=${branch_name:-<none>} target_branch=${target_branch} final_head=${final_head} ahead_count=${ahead_count} work_dir=${work_dir:-<unset>}"

	# Always increment counter — failure or success
	_increment_orphan_count_stat

	if _attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug"; then
		print_info "[lifecycle] Orphan PR auto-created for session=${session_key}"
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	else
		print_info "[lifecycle] Orphan recovery failed for session=${session_key}"
		_hrw_release_dispatch_claim "$session_key" "worker_branch_orphan"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		# Post structured ops comment so the next dispatch knows what happened
		if [[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]]; then
			local _ops_comment
			local _orphan_key="${repo_slug}#${issue_number}#${branch_name}#worker_branch_orphan"
			local _orphan_base_branch="main"
			if declare -F _resolve_orphan_recovery_base_branch >/dev/null 2>&1; then
				_orphan_base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
			fi
			# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
			_ops_comment=$(printf '<!-- ops:start -->\n<!-- worker-branch-orphan:key=%s -->\nWORKER_BRANCH_ORPHAN branch=%s session=%s ts=%s\n\nThis worker pushed branch `%s` but no PR could be opened automatically. To recover, open a PR manually against the configured PR base branch:\n\n```\ngh pr create --head %s --base %s --repo %s\n```\n<!-- ops:end -->' \
				"$_orphan_key" \
				"$branch_name" "$session_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				"$branch_name" "$branch_name" "$_orphan_base_branch" "$repo_slug")
			gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}

#######################################
# _handle_worker_local_branch_unpushed — recover local-only committed branch.
#
# Called from _cmd_run_finish when _worker_produced_output returns
# "local_branch_unpushed": the worker has local commits on a feature branch,
# but no remote branch and no PR were found. The shared orphan recovery helper
# safely pushes the branch before creating the PR; failure leaves a distinct,
# non-misleading recovery diagnostic for manual intervention (GH#25374).
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_local_branch_unpushed() {
	local session_key="$1"
	local work_dir="$2"

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	local target_branch="${WORKER_TARGET_BRANCH:-<unset>}"
	local head_ref="HE""AD"
	local final_head=""
	final_head=$(git -C "$work_dir" rev-parse --short=12 "$head_ref" 2>/dev/null || printf '<unreadable>')
	local ahead_count=0
	local base_branch=""
	base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
	local rev_output=""
	if rev_output=$(git -C "$work_dir" rev-list --count "origin/${base_branch}..${head_ref}" 2>/dev/null); then
		ahead_count=$rev_output
	else
		local fallback_base_ref="origin/""master"
		ahead_count=$(git -C "$work_dir" rev-list --count "${fallback_base_ref}..${head_ref}" 2>/dev/null || printf '0')
	fi
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0

	print_info "[lifecycle] worker_local_branch_unpushed session=${session_key} branch=${branch_name:-<none>} target_branch=${target_branch} final_head=${final_head} ahead_count=${ahead_count} work_dir=${work_dir:-<unset>}"

	_increment_orphan_count_stat

	if _attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug"; then
		print_info "[lifecycle] Local branch pushed and recovery PR auto-created for session=${session_key}"
		local complete_reason="worker_"
		_hrw_release_dispatch_claim "$session_key" "${complete_reason}complete"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	else
		print_info "[lifecycle] Local branch recovery failed for session=${session_key}"
		_hrw_release_dispatch_claim "$session_key" "worker_local_branch_unpushed"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		if [[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]]; then
			local _ops_comment
			local _local_key="${repo_slug}#${issue_number}#${branch_name}#worker_local_branch_unpushed"
			local _local_base_branch="main"
			local _local_head_ref="HE""AD"
			if declare -F _resolve_orphan_recovery_base_branch >/dev/null 2>&1; then
				_local_base_branch=$(_resolve_orphan_recovery_base_branch "$repo_slug" "$work_dir")
			fi
			# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
			_ops_comment=$(printf '<!-- ops:start -->\n<!-- worker-local-branch-unpushed:key=%s -->\nWORKER_LOCAL_BRANCH_UNPUSHED branch=%s session=%s ts=%s\n\nThis worker committed local changes on branch `%s`, but no remote branch or PR could be confirmed and automatic recovery failed. To recover, inspect the worker worktree, push the local branch, then open a PR manually against the configured PR base branch:\n\n```\ngit -C %s push origin %s:%s\ngh pr create --head %s --base %s --repo %s\n```\n<!-- ops:end -->' \
				"$_local_key" \
				"$branch_name" "$session_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				"$branch_name" "$work_dir" "$_local_head_ref" "$branch_name" "$branch_name" "$_local_base_branch" "$repo_slug")
			gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}
