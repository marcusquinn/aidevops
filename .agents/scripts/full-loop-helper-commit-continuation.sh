#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit Continuation -- squash-merged head recovery (GH#39862)
# =============================================================================
# Focused sub-library for full-loop-helper-commit.sh. A squash merge lands a
# PR's content on the base under a different SHA, so more commits on that same
# head would republish the merged commits and a later base change (for example
# a shared coverage ledger) makes the continuation PR DIRTY. Before WIP
# finalization, validators, rebase or push, commit-and-pr replays only the
# post-merge unit onto the refreshed base and publishes it on a fresh
# "<branch>-sN" branch. The merged remote ref is never pushed to.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit-continuation.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning)
#   - full-loop-helper-commit.sh (_pr_head_ref_for_repo, _resolve_pr_base_branch,
#     _ensure_no_in_progress_integration)
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_CONTINUATION_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_CONTINUATION_LIB_LOADED=1

# Set by _recover_squash_merged_continuation: the fresh branch and the audit
# note recorded in the PR's merge-summary decisions (empty = no recovery).
FULL_LOOP_CONTINUATION_BRANCH=""
FULL_LOOP_CONTINUATION_NOTE=""

# Pick the first "<stem>-sN" name free locally and on origin; a "-sN" input
# advances its own suffix. Args: $1=branch. Returns 1 when none is free.
_continuation_branch_name() {
	local branch="$1"
	local stem="$branch" n=2 limit=0 candidate="" candidate_ref="" remote_hit=""
	if [[ "$branch" =~ ^(.+)-s([0-9]+)$ ]]; then
		stem="${BASH_REMATCH[1]}"
		n=$((10#${BASH_REMATCH[2]} + 1))
	fi
	limit=$((n + 20))
	while [[ "$n" -le "$limit" ]]; do
		candidate="${stem}-s${n}"
		printf -v candidate_ref 'refs/heads/%s' "$candidate"
		if ! git show-ref --verify --quiet "$candidate_ref"; then
			remote_hit=$(git ls-remote --heads origin "$candidate_ref" 2>/dev/null || printf 'error')
			if [[ -z "$remote_hit" ]]; then
				printf '%s\n' "$candidate"
				return 0
			fi
		fi
		n=$((n + 1))
	done
	return 1
}

# List open and merged PRs whose head is this branch via REST (survives
# GraphQL exhaustion). Output lines: "<open|merged>\t<number>\t<head sha>\t<merge sha>".
# Args: $1=repo slug $2=branch
_list_head_ref_prs() {
	local repo="$1" branch="$2"
	local head_ref=""
	head_ref=$(_pr_head_ref_for_repo "$repo" "$branch")
	[[ "$head_ref" == *:* ]] || head_ref="${repo%%/*}:${branch}"
	gh api -X GET "repos/${repo}/pulls" -f state=all -f head="$head_ref" -f per_page=100 \
		--jq '.[] | select(.state == "open" or .merged_at != null) | [(if .merged_at != null then "merged" else .state end), (.number | tostring), .head.sha, (.merge_commit_sha // "")] | @tsv'
	return $?
}

# Choose the newest merged head that HEAD contains and whose merge commit is in
# the refreshed base. Args: $1=PR list (from _list_head_ref_prs) $2=base ref.
# Output: "<pr>\t<head sha>\t<commits after it>" or nothing.
_select_merged_head_boundary() {
	local prs="$1" base_ref="$2"
	local state="" number="" head_sha="" merge_sha="" ahead="" best="" best_ahead=""
	while IFS=$'\t' read -r state number head_sha merge_sha; do
		[[ "$state" == merged && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || continue
		git cat-file -e "${head_sha}^{commit}" 2>/dev/null ||
			git fetch --quiet origin "refs/pull/${number}/head" 2>/dev/null || true
		git merge-base --is-ancestor "$head_sha" HEAD 2>/dev/null || continue
		if [[ ! "$merge_sha" =~ ^[0-9a-f]{40}$ ]] || ! git merge-base --is-ancestor "$merge_sha" "$base_ref" 2>/dev/null; then
			print_warning "Merged PR #${number}'s merge commit is not in ${base_ref}; its commits are not treated as already merged."
			continue
		fi
		ahead=$(git rev-list --count "${head_sha}..HEAD" 2>/dev/null) || continue
		if [[ -z "$best" || "$ahead" -lt "$best_ahead" ]]; then
			best=$(printf '%s\t%s\t%s' "$number" "$head_sha" "$ahead")
			best_ahead="$ahead"
		fi
	done <<<"$prs"
	[[ -n "$best" ]] && printf '%s\n' "$best"
	return 0
}

# Detect a continuation of a merged PR's head and publish it on a fresh branch.
# When a merged head is in HEAD's ancestry, replay only the commits after it onto
# the refreshed base (rebase --onto). The merged remote ref is never pushed to.
# Args: $1=repo slug $2=branch $3=skip rebase (optional, default 0)
# Returns 0 when no recovery is needed or it succeeded (FULL_LOOP_CONTINUATION_BRANCH
# names the new branch); 1 when publishing would be unsafe, with HEAD restored.
_recover_squash_merged_continuation() {
	local repo="$1" branch="$2"
	local skip_rebase="${3:-0}"
	FULL_LOOP_CONTINUATION_BRANCH=""
	FULL_LOOP_CONTINUATION_NOTE=""
	local prs=""
	if ! prs=$(_list_head_ref_prs "$repo" "$branch" 2>/dev/null); then
		print_warning "Cannot list PRs for head '${branch}'; squash-merged continuation check skipped (GH#39862)."
		return 0
	fi
	[[ $'\n'"$prs" == *$'\n'merged$'\t'* ]] || return 0
	if [[ $'\n'"$prs" == *$'\n'open$'\t'* ]]; then
		print_warning "Head '${branch}' has a merged PR and backs an open PR; continuing that PR unchanged. To exclude already-merged commits, close it and rerun commit-and-pr (GH#39862)."
		return 0
	fi

	local base_branch base_ref
	local boundary="" boundary_pr="" boundary_sha="" boundary_ahead=""
	base_branch=$(_resolve_pr_base_branch origin) || return 1
	printf -v base_ref 'origin/%s' "$base_branch"
	if ! git fetch origin "refs/heads/${base_branch}:refs/remotes/origin/${base_branch}" --quiet 2>/dev/null; then
		print_error "Cannot refresh ${base_ref} to recover the continuation of a merged head; nothing was pushed."
		return 1
	fi
	boundary=$(_select_merged_head_boundary "$prs" "$base_ref")
	IFS=$'\t' read -r boundary_pr boundary_sha boundary_ahead <<<"$boundary"
	if [[ -n "$boundary_sha" && "$boundary_ahead" == 0 ]]; then
		print_error "HEAD has no commits beyond squash-merged PR #${boundary_pr}; nothing new to publish from '${branch}'."
		return 1
	fi
	if [[ -n "$boundary_sha" && "$skip_rebase" == 1 ]]; then
		print_error "Cannot recover the continuation of merged PR #${boundary_pr} with --no-rebase; replay is required, HEAD and branch unchanged, nothing was pushed."
		return 1
	fi

	local original_head="" fresh=""
	original_head=$(git rev-parse HEAD 2>/dev/null) || return 1
	fresh=$(_continuation_branch_name "$branch") || {
		print_error "No free '-sN' continuation branch name for '${branch}'; nothing was pushed."
		return 1
	}
	local note="Head '${branch}' already backs a merged PR; this work is published as '${fresh}' without touching that ref."
	if [[ -n "$boundary_sha" ]]; then
		_ensure_no_in_progress_integration || return 1
		print_info "Replaying ${boundary_ahead} commit(s) after merged PR #${boundary_pr} (${boundary_sha:0:12}) onto ${base_ref}..."
		if ! git rebase --onto "$base_ref" "$boundary_sha" >&2 2>/dev/null; then
			git rebase --abort 2>/dev/null || true
			print_error "Replaying the continuation after merged PR #${boundary_pr} onto ${base_ref} conflicted; HEAD restored at ${original_head:0:12}, nothing was pushed."
			print_error "Resolve: git rebase --onto ${base_ref} ${boundary_sha}, then retry commit-and-pr."
			return 1
		fi
		if [[ "$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo 0)" == 0 ]]; then
			print_error "Continuation after merged PR #${boundary_pr} has no changes beyond ${base_ref}; HEAD restored, nothing was pushed."
			git reset -q --keep "$original_head" 2>/dev/null || true
			return 1
		fi
		note="Continues squash-merged PR #${boundary_pr} from '${branch}' on fresh branch '${fresh}'; only post-merge commits were replayed onto ${base_ref} (original tip ${original_head:0:12})."
	fi
	if ! git branch -m "$branch" "$fresh"; then
		git reset -q --keep "$original_head" 2>/dev/null || true
		print_error "Could not rename '${branch}' to continuation branch '${fresh}'; HEAD restored, nothing was pushed."
		return 1
	fi
	FULL_LOOP_CONTINUATION_BRANCH="$fresh"
	FULL_LOOP_CONTINUATION_NOTE="${note} (GH#39862)"
	print_warning "$note"
	return 0
}
