#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Output -- Output classification and PR checkpoints
# =============================================================================
# Sourced by headless-runtime-worker.sh after its constants and dependencies.
# Function bodies are kept unchanged; callers continue to source the worker
# orchestrator, which supplies claim lifecycle and PR handoff helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_OUTPUT_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_OUTPUT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback for direct sourcing and test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Worker output classification
# =============================================================================

#######################################
# Resolve the repository default branch for worker-output guards.
#
# Args:
#   $1 - work_dir (worktree root; must be a git repo)
#######################################
_hrw_resolve_default_branch() {
	local work_dir="$1"
	local default_branch=""

	default_branch=$(git -C "$work_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ "$default_branch" == origin/* ]]; then
		default_branch="${default_branch#origin/}"
	fi

	if [[ -z "$default_branch" ]]; then
		for default_branch in main master; do
			if git -C "$work_dir" show-ref --verify --quiet "refs/remotes/origin/${default_branch}" 2>/dev/null || \
				git -C "$work_dir" show-ref --verify --quiet "refs/heads/${default_branch}" 2>/dev/null; then
				printf '%s' "$default_branch"
				return 0
			fi
		done
		default_branch=""
	fi

	if [[ -n "$default_branch" ]]; then
		printf '%s' "$default_branch"
		return 0
	fi

	return 0
}

#######################################
# Resolve the comparison base and count commits beyond it.
# Output: <default-branch>|<count|unknown>
# Args: $1=work_dir
#######################################
_hrw_worker_base_commit_state() {
	local work_dir="$1"
	local default_branch=""
	local commit_count=""

	default_branch=$(_hrw_resolve_default_branch "$work_dir")
	[[ -z "$default_branch" ]] && default_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"
	if commit_count=$(git -C "$work_dir" rev-list --count "origin/${default_branch}..${_HRW_GIT_HEAD}" 2>/dev/null) && \
		[[ "$commit_count" =~ ^[0-9]+$ ]]; then
		printf '%s|%s' "$default_branch" "$commit_count"
	else
		printf '%s|unknown' "$default_branch"
	fi
	return 0
}

#######################################
# Detect whether a worker produced any tangible output.
#
# Checks three independent signals. Returns 0 (true — has output) if ANY
# signal is present; returns 1 (false — zero output) only when ALL are absent.
#
# Args:
#   $1 - session_key (e.g. "issue-20721")
#   $2 - work_dir    (worktree root; must be a git repo)
#
# Signals checked (in order of cheapness):
#   1. Commits on feature branch beyond the resolved remote default branch
#      (git rev-list --count origin/<default>..HEAD > 0)
#   2. Branch pushed to remote
#      (git ls-remote origin refs/heads/<branch> is non-empty)
#   3. PR linked to this issue via gh
#      (gh pr list --search "<issue_number>" returns at least one result)
#
# Design principle — fail-open: every check that errors (no remote, no gh,
# detached HEAD, network failure) returns 0 so false-negatives are impossible.
# Only a confirmed absence of all three signals triggers a noop classification.
#######################################
# _worker_produced_output — classify worker output quality (GH#20819)
#
# Returns a concrete lifecycle/output classification via stdout:
#   "pr_exists"             — PR confirmed, or fail-open (cannot evaluate signals)
#   "branch_orphan"         — branch pushed + commits exist BUT no PR found
#                             (requires DISPATCH_REPO_SLUG + gh to confirm absence)
#   "local_branch_unpushed" — local branch has commits but no remote branch or PR
#   "dirty_worktree"        — uncommitted/untracked edits exist after a crash
#   "draft_checkpoint"      — exact-head worker draft (durable, incomplete)
#   "protected_draft"       — interactive/held/NMR/non-worker draft
#   "closed_unmerged"       — exact-head PR closed without merge
#   "unverified_open_pr"    — issue-search fallback cannot prove exact head
#   "head_mismatch"         — local HEAD is not the open PR head
#   "ready_missing_linkage" — exact-head ready PR lacks a closing issue reference
#   "merged_missing_linkage" — exact-head merged PR lacks a closing issue reference
#   "ready_missing_summary" — exact-head ready PR lacks MERGE_SUMMARY
#   "merged_missing_summary" — exact-head merged PR lacks MERGE_SUMMARY
#   "noop"                  — no commits, no pushed branch, no PR
#
# Fail-open semantics are preserved: any condition that prevents confident
# signal evaluation echoes "pr_exists" so false-negatives (real work
# misclassified as orphan or noop) are impossible.  Only a confirmed
# absence of all signals (noop), a confirmed remote branch-without-PR
# (branch_orphan), or a confirmed local committed branch-without-PR
# (local_branch_unpushed) triggers those classifications.
#
# Always returns 0. Callers capture stdout:
#   local classification
#   classification=$(_worker_produced_output "$session_key" "$work_dir")
#######################################
_hrw_is_issue_worker_session() {
	local session_key="$1"
	local manual_issue_number=""
	[[ "$session_key" == issue-* ]] && return 0
	if [[ "$session_key" =~ ^manual-cli-([1-9][0-9]*)-[0-9]+$ ]]; then
		manual_issue_number="${BASH_REMATCH[1]}"
	fi
	[[ -n "$manual_issue_number" && "${WORKER_ISSUE_NUMBER:-}" == "$manual_issue_number" ]]
}

_hrw_issue_number_for_session() {
	local session_key="$1"
	if [[ "$session_key" =~ ^issue-([1-9][0-9]*)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	_scl_worker_issue_number "$session_key"
}

# GH#33374: a merged checkpoint or reopened issue is not worker completion.
_hrw_merged_pr_output_class() {
	local pr_state="$1" repo_slug="$2" issue_number="$3"
	local issue_state=""
	issue_state=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.state | ascii_downcase' 2>/dev/null) || issue_state=""
	case "${issue_state}:${pr_state}" in
	open:*) printf 'merged_checkpoint' ;;
	closed:merged) printf 'pr_exists' ;;
	*) printf 'merged_missing_linkage' ;;
	esac
	return 0
}

_hrw_pr_output_class() {
	local pr_state="$1" repo_slug="$2" issue_number="$3" has_pushed_branch="$4"
	case "$pr_state" in
	ready) printf 'pr_exists' ;;
	merged | merged_missing_linkage)
		_hrw_merged_pr_output_class "$pr_state" "$repo_slug" "$issue_number"
		;;
	draft_checkpoint | protected_draft | closed_unmerged | unverified_open_pr | head_mismatch | ready_missing_linkage | ready_missing_summary | merged_missing_summary)
		printf '%s' "$pr_state"
		;;
	absent)
		if [[ "$has_pushed_branch" -eq 1 ]]; then
			printf 'branch_orphan'
		else
			printf 'local_branch_unpushed'
		fi
		;;
	*) printf 'pr_exists' ;; # unknown -> fail-open
	esac
	return 0
}

_worker_produced_output() {
	local session_key="$1"
	local work_dir="$2"

	# Manual keys remain issue workers when their contract matches the embedded issue.
	if ! _hrw_is_issue_worker_session "$session_key"; then
		printf 'pr_exists'  # fail-open for non-worker sessions
		return 0
	fi

	# Bail if work_dir is not a valid git repo — fail-open
	if [[ -z "$work_dir" ]] || ! git -C "$work_dir" rev-parse --git-dir >/dev/null 2>&1; then
		printf 'pr_exists'  # fail-open: cannot evaluate signals
		return 0
	fi

	# Compare against the resolved default, not an assumed main/master base.
	local base_commit_state=""
	local default_branch=""
	local commit_count=""
	local has_commits=0
	local commit_comparison_known=0
	base_commit_state=$(_hrw_worker_base_commit_state "$work_dir")
	default_branch="${base_commit_state%%|*}"
	commit_count="${base_commit_state#*|}"
	if [[ "$commit_count" =~ ^[0-9]+$ ]]; then
		commit_comparison_known=1
		[[ "$commit_count" -gt 0 ]] && has_commits=1
	fi

	# Signal 2: a remote feature ref is output evidence only off the resolved
	# default branch (t2899).
	local has_pushed_branch=0
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [[ -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" && "$branch_name" != "$default_branch" ]]; then
		local remote_ref=""
		remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/$branch_name" 2>/dev/null || true)
		[[ -n "$remote_ref" ]] && has_pushed_branch=1
	fi

	# A successful zero-count comparison proves the branch has no PR-able output,
	# even when a same-SHA feature ref already exists remotely. Check for dirty
	# edits first so crash recovery still preserves uncommitted work.
	if [[ "$has_commits" -eq 0 ]]; then
		local task_status=""
		if ! task_status=$(_hrw_worktree_task_status "$work_dir"); then
			printf 'pr_exists' # fail-open: cannot safely classify local state
			return 0
		fi
		if [[ -n "$task_status" ]]; then
			printf 'dirty_worktree'
			return 0
		fi
		if [[ "$commit_comparison_known" -eq 1 ]]; then
			printf 'noop'
			return 0
		fi
		if [[ "$has_pushed_branch" -eq 0 ]]; then
			printf 'pr_exists' # fail-open: resolved base ref could not be compared
			return 0
		fi
	fi
	# t2899: HEAD on default branch with commits ahead but no feature branch pushed.
	# This is "worker landed on main with local commits" — not an orphan branch.
	# Without a feature branch to recover, Signal 1 alone cannot produce a meaningful
	# branch_orphan classification, so collapse to noop.
	if [[ "$has_pushed_branch" -eq 0 && "$branch_name" == "$default_branch" ]]; then
		printf 'noop'
		return 0
	fi

	# Signal 3: exact-head lifecycle first; issue search is inconclusive fallback.
	local issue_number=""
	issue_number=$(_hrw_issue_number_for_session "$session_key")
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local pr_handoff="unknown|"
	local pr_state="unknown"
	local local_head=""
	local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)
	[[ -n "$local_head" ]] || local_head="missing-local-head"
	pr_handoff=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug" \
		"branch-or-issue" "$local_head" 1)
	pr_state="${pr_handoff%%|*}"
	_hrw_pr_output_class "$pr_state" "$repo_slug" "$issue_number" "$has_pushed_branch"
	return 0
}

#######################################
# Preserve an exact-head worker PR for continuation. The issue remains assigned
# and in-review while auto-dispatch is disabled; stale recovery can then route
# the exact existing PR instead of launching a competing branch.
# Failed or invisible transitions retain the claim.
# Args: $1=session key, $2=repo slug, $3=lifecycle state, $4=release reason,
#       $5=transition failure reason
#######################################
_escalate_worker_pr_checkpoint() {
	local session_key="$1"
	local repo_slug="$2"
	local lifecycle_state="$3"
	local release_reason="${4:-$_HRW_REASON_DRAFT_CHECKPOINT}"
	local transition_failure_reason="${5:-$_HRW_REASON_DRAFT_ESCALATION_FAILED}"
	local issue_number=""
	local runner_login=""
	local -a transition_args=(--remove-label "auto-dispatch")

	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		_HRW_RECOVERY_CLASSIFICATION="$transition_failure_reason"
		print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — issue/repo unavailable; retaining claim"
		return 0
	fi
	if declare -F _hrff_resolve_release_runner_login >/dev/null 2>&1; then
		runner_login=$(_hrff_resolve_release_runner_login)
		[[ -n "$runner_login" ]] && transition_args+=(--add-assignee "$runner_login")
	fi
	if declare -F set_issue_status >/dev/null 2>&1; then
		if ! set_issue_status "$issue_number" "$repo_slug" "in-review" "${transition_args[@]}"; then
			_HRW_RECOVERY_CLASSIFICATION="$transition_failure_reason"
			print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — continuation transition failed; retaining claim"
			return 0
		fi
	elif ! gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "status:in-review" \
		--remove-label "status:available,status:queued,status:in-progress" \
		"${transition_args[@]}" >/dev/null 2>&1; then
		_HRW_RECOVERY_CLASSIFICATION="$transition_failure_reason"
		print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — continuation transition failed; retaining claim"
		return 0
	fi
	if ! _worker_pr_checkpoint_block_visible "$issue_number" "$repo_slug" "$runner_login"; then
		_HRW_RECOVERY_CLASSIFICATION="$transition_failure_reason"
		print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — continuation state not visible; retaining claim"
		return 0
	fi

	_hrw_release_dispatch_claim "$session_key" "$release_reason"
	_HRW_RECOVERY_CLASSIFICATION="$release_reason"
	print_warning "[lifecycle] worker_pr_handoff_preserved session=${session_key} state=${lifecycle_state} — exact-head continuation pending"
	return 0
}

_worker_pr_checkpoint_block_visible() {
	local issue_number="$1"
	local repo_slug="$2"
	local expected_runner="${3:-}"
	gh issue view "$issue_number" --repo "$repo_slug" --json state,labels,assignees 2>/dev/null \
		| jq -e --arg runner "$expected_runner" '
			([.labels[]?.name]) as $labels |
			([.assignees[]?.login]) as $assignees |
			.state == "OPEN" and
			($labels | index("status:in-review")) != null and
			(["status:available", "status:queued", "status:in-progress", "auto-dispatch"] - $labels | length) == 4 and
			($runner == "" or ($assignees | index($runner)) != null)
		' >/dev/null 2>&1
	return $?
}
