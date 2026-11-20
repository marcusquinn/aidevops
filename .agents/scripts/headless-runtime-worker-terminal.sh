#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Terminal -- PR-less terminal completion verdicts
# =============================================================================
# Sourced by headless-runtime-worker.sh after its constants and dependencies.
# Function bodies are kept unchanged; callers continue to source the worker
# orchestrator, which supplies claim lifecycle and PR handoff helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_TERMINAL_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_TERMINAL_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback for direct sourcing and test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Return success when GitHub already shows the worker target as terminal.
#
# A worker can be interrupted after it merged a PR and the linked issue closed.
# In that case the local process lacks a completion signal, but redispatching is
# noise. Only confirmed terminal GitHub state returns 0; unknown/API failures
# return 1 so normal failure handling remains conservative.
#
# Args: $1=session_key, $2=work_dir (optional, used to resolve branch)
#######################################
_worker_external_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""

	[[ "$session_key" == issue-* ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	if [[ "$session_key" =~ ([0-9]+)$ ]]; then
		issue_number="${BASH_REMATCH[1]}"
	fi
	[[ -n "$issue_number" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state // empty' 2>/dev/null || true)
	[[ "$issue_state" == "CLOSED" ]] || return 1
	if _hrw_pr_less_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug"; then
		return 0
	fi

	local branch_name="${WORKER_TARGET_BRANCH:-}"
	if [[ -n "$work_dir" && -d "$work_dir" ]]; then
		local live_branch_name=""
		live_branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
		if [[ -n "$live_branch_name" && "$live_branch_name" != "$_HRW_GIT_HEAD" ]]; then
			branch_name="$live_branch_name"
		fi
	fi
	[[ -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" ]] || return 1

	local branch_pr_numbers=""
	branch_pr_numbers=$(gh pr list --repo "$repo_slug" --head "$branch_name" --state merged --json number --jq '.[].number' 2>/dev/null || true)
	[[ -n "$branch_pr_numbers" ]] || return 1

	local issue_pr_numbers=""
	issue_pr_numbers=$(gh pr list --repo "$repo_slug" --state merged --search "$issue_number" --json number --jq '.[].number' 2>/dev/null || true)
	[[ -n "$issue_pr_numbers" ]] || return 1

	local branch_pr_number=""
	local padded_issue_prs=$'\n'"$issue_pr_numbers"$'\n'
	while IFS= read -r branch_pr_number; do
		[[ -n "$branch_pr_number" ]] || continue
		if [[ "$padded_issue_prs" == *$'\n'"$branch_pr_number"$'\n'* ]]; then
			print_info "[lifecycle] worker_external_terminal complete session=${session_key} issue=${issue_number} branch=${branch_name} pr=${branch_pr_number}"
			return 0
		fi
	done <<<"$branch_pr_numbers"

	return 1
}

# GH#35629: own squash merges need exact PR-head proof, not ancestry against
# the default tip. Keep this separate from the stricter PR-less contract.
# A finalized guarded receipt binds delivery to this session and attempt window.
_hrw_own_merged_terminal_complete() {
	local session_key="$1" work_dir="$2"
	_hrw_merged_terminal_complete "$session_key" "$work_dir" own
	return $?
}

# GH#37098: a read-only continuation may finish verification after an earlier
# attempt merged this exact head. This is delivery evidence, not merge ownership.
_hrw_continued_merged_terminal_complete() {
	local session_key="$1" work_dir="$2"
	_hrw_merged_terminal_complete "$session_key" "$work_dir" continuation
	return $?
}

_hrw_merged_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local mode="$3"
	local runtime_session="${discovered_session:-${_HRW_OWN_MERGED_RUNTIME_SESSION:-}}"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local issue_number branch head dirty context started
	[[ -n "$runtime_session" && -n "${AIDEVOPS_ATTEMPT_ID:-}" ]] || return 1
	[[ "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]{19}$ ]] || return 1
	_hrw_is_issue_worker_session "$session_key" || return 1
	issue_number=$(_hrw_issue_number_for_session "$session_key") || return 1
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo_slug" == */* ]] || return 1
	[[ "${WORKER_ISSUE_NUMBER:-}" == "$issue_number" && -d "$work_dir" ]] || return 1
	work_dir=$(cd "$work_dir" && pwd -P) || return 1
	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null) || return 1
	head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || return 1
	dirty=$(_hrw_task_worktree_status "$work_dir") || return 1
	[[ -n "$branch" && "$head" =~ ^[0-9a-f]{40}$ && -z "$dirty" ]] || return 1
	# A clean checkout at the delivered head cannot hide newer remote-only work.
	local remote_branch=""
	remote_branch=$(git -C "$work_dir" ls-remote origin "refs/heads/${branch}" 2>/dev/null) || return 1
	[[ -z "$remote_branch" || "${remote_branch%%[[:space:]]*}" == "$head" ]] || return 1
	context="${mode}|${session_key}|${repo_slug}|${issue_number}|${AIDEVOPS_ATTEMPT_ID}|${AIDEVOPS_ATTEMPT_STARTED_AT}|${runtime_session}|${work_dir}|${branch}|${head}"
	# Reuse only in-process proof for the identical attempt and clean head. A
	# later API outage must not erase verified delivery during finalization.
	[[ "$context" == "${_HRW_OWN_MERGED_VERIFIED_CONTEXT:-}" ]] && return 0
	started="${AIDEVOPS_ATTEMPT_STARTED_AT:0:10}"
	local issue_json handoff pr_number pr_json receipt
	issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 1
	jq -e --arg closed closed --arg completed completed \
		'.state == $closed and .state_reason == $completed and .pull_request == null' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	handoff=$(_pr_handoff_state_for_branch_or_issue "$branch" "$issue_number" \
		"$repo_slug" head-only "$head" 1) || return 1
	[[ "$handoff" =~ ^merged\|[1-9][0-9]*$ ]] || return 1
	pr_number="${handoff#*|}"
	# Bypass cached views and revalidate actual closing references, repository,
	# branch and head rather than trusting a search match or a prose summary.
	pr_json=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,state,mergedAt,mergeCommit,headRefOid,headRefName,headRepository,headRepositoryOwner,closingIssuesReferences 2>/dev/null) || return 1
	jq -e --argjson pr "$pr_number" --argjson issue "$issue_number" \
		--arg repo "$repo_slug" --arg branch "$branch" --arg head "$head" \
		--arg separator / --arg string_type string --argjson started "$started" --arg mode "$mode" '
		.number == $pr and .state == "MERGED"
		and ((.mergedAt | fromdateiso8601) as $merged
			# GitHub timestamps have whole-second precision: equality cannot
			# establish own-attempt ordering, so classify it as continuation.
			| if $mode == "own" then $merged > $started else $merged <= $started end)
		and (.mergeCommit.oid | type == $string_type and test("^[0-9a-f]{40}$"))
		and .headRefOid == $head and .headRefName == $branch
		and ([.headRepositoryOwner.login, .headRepository.name] | join($separator) | ascii_downcase) == ($repo | ascii_downcase)
		and any(.closingIssuesReferences[]?; .number == $issue
			and ([.repository.owner.login, .repository.name] | join($separator) | ascii_downcase) == ($repo | ascii_downcase))
	' <<<"$pr_json" >/dev/null 2>&1 || return 1
	# Own-attempt receipts must be fresh for this attempt. For a continuation,
	# retain the same runtime owner's finalized receipt, fresh for the actual
	# merge; revalidate live issue/PR/head evidence in every new attempt. Never
	# rewrite that historical receipt or attribute its merge to this attempt.
	if [[ "$mode" == continuation ]]; then
		started=$(jq -r '.mergedAt | fromdateiso8601' <<<"$pr_json") || return 1
	fi
	receipt=$(_full_loop_cleanup_receipt_path "$repo_slug" "$pr_number") || return 1
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg repo "$repo_slug" --argjson pr "$pr_number" --arg worktree "$work_dir" \
		--arg branch "$branch" --arg session "$runtime_session" --argjson started "$started" \
		--arg deferred "$_FULL_LOOP_CLEANUP_DEFERRED" --arg leased "$_FULL_LOOP_CLEANUP_LEASED" --arg string_type string '
		.schema_version == 1 and .repository == $repo and .pr_number == $pr
		and .worktree == $worktree and .branch == $branch and .owner.session == $session
		and (.owner.pid | type == "number" and . > 0)
		and (.owner.process_identity | type == $string_type and length > 0)
		# Cleanup receipts use Python ISO timestamps with fractional seconds;
		# jq fromdateiso8601 accepts only whole-second UTC timestamps.
		and (.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $started
		and .executor_completion_state == "COMPLETE"
		and (.resource_cleanup_state == $deferred or .resource_cleanup_state == $leased)
		and (.release_status == "not-requested" or .release_status == "published" or .release_status == "superseded")
	' "$receipt" >/dev/null 2>&1 || return 1
	_HRW_OWN_MERGED_VERIFIED_CONTEXT="$context"
	_HRW_OWN_MERGED_RUNTIME_SESSION="$runtime_session"
	print_info "[lifecycle] worker_merged_${mode} complete session=${session_key} attempt=${AIDEVOPS_ATTEMPT_ID} issue=${issue_number} pr=${pr_number} head=${head}"
	return 0
}

