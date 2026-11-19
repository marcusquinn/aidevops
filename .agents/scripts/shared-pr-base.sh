#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared PR base-branch resolution (GH#39167)
# =============================================================================
# One resolver for the branch a managed PR should target, shared by
# commit-and-pr, orphan recovery and the pulse merge pass. It never falls back
# to a hard-coded `main`: repositories whose default branch is `dev` (with a
# release-only `main`) otherwise received worker PRs against `main`.
#
# Resolution order (first non-empty wins):
#   1. env      WORKER_PR_BASE_BRANCH / DISPATCH_REPO_PR_BASE_BRANCH /
#               AIDEVOPS_PR_BASE_BRANCH (explicit dispatch base)
#   2. config   .aidevops.json then repos.json: pr_base_branch //
#               pr_target_branch // base_branch
#   3. remote   GitHub REST default_branch (authoritative remote default)
#   4. origin   refs/remotes/origin/HEAD of the work dir (API unavailable)
#   5. config   legacy `default_branch` alias (last resort only, because a
#               stale value must never override the live remote default)
#
# Public API:
#   aidevops_pr_base_resolve <repo_slug> [work_dir]   -> "<branch> <source>"
#   aidevops_pr_base_branch <repo_slug> [work_dir]    -> "<branch>"
#   aidevops_pr_base_is_stacked_parent <repo_slug> <branch>
#       0 = an open PR in the repo has <branch> as its head (real stacked
#       parent), 1 = none, 2 = lookup failed
#   aidevops_pr_base_merge_guard <pr> <repo_slug> <base> <head_oid> <labels>
#       Pulse merge-pass backstop for worker PRs on the wrong base.
#       0 = proceed, 1 = skip this cycle (retargeted, held, or unverifiable)
#
# Usage: source "${SCRIPT_DIR}/shared-pr-base.sh"
# =============================================================================

[[ -n "${_SHARED_PR_BASE_LOADED:-}" ]] && return 0
_SHARED_PR_BASE_LOADED=1

_AIDEVOPS_PR_BASE_CONFIG_FILTER='.pr_base_branch // .pr_target_branch // .base_branch // empty'
_AIDEVOPS_PR_BASE_MISMATCH_MARKER="aidevops:pr-base-mismatch"

_aidevops_pr_base_repos_json() {
	printf '%s\n' "${AIDEVOPS_REPOS_JSON:-${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"
	return 0
}

# Print one repos.json field for a slug (empty when absent).
# Args: $1=repo_slug $2=jq filter applied to the matching entry
_aidevops_pr_base_repos_json_field() {
	local repo_slug="$1"
	local filter="$2"
	local repos_json=""
	repos_json=$(_aidevops_pr_base_repos_json)
	[[ -n "$repo_slug" && -f "$repos_json" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r --arg slug "$repo_slug" \
		".initialized_repos[]? | select(.slug == \$slug) | ${filter}" \
		"$repos_json" 2>/dev/null | sed -n '1p'
	return 0
}

# Resolve the local checkout for a slug from repos.json when the caller has no
# work dir (pulse merge pass), so committed .aidevops.json config still applies.
_aidevops_pr_base_work_dir() {
	local repo_slug="$1"
	local work_dir="${2:-}"
	if [[ -z "$work_dir" ]]; then
		work_dir=$(_aidevops_pr_base_repos_json_field "$repo_slug" '.path // empty')
		case "$work_dir" in
		\~/*) work_dir="${HOME}/${work_dir#\~/}" ;;
		esac
	fi
	[[ -n "$work_dir" && -d "$work_dir" ]] || return 0
	printf '%s\n' "$work_dir"
	return 0
}

# Args: $1=work_dir $2=jq filter
_aidevops_pr_base_repo_config_field() {
	local work_dir="$1"
	local filter="$2"
	[[ -n "$work_dir" && -f "${work_dir}/.aidevops.json" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "$filter" "${work_dir}/.aidevops.json" 2>/dev/null | sed -n '1p'
	return 0
}

#######################################
# Resolve the PR base branch and the source that selected it.
# Args: $1=repo_slug (owner/repo) $2=work_dir (optional)
# Outputs: "<branch> <source>" (branch names cannot contain spaces)
# Returns: 0 resolved, 1 no source available (never guesses `main`)
#######################################
aidevops_pr_base_resolve() {
	local repo_slug="${1:-}"
	local work_dir=""
	work_dir=$(_aidevops_pr_base_work_dir "$repo_slug" "${2:-}")
	local base_branch="" source=""

	base_branch="${WORKER_PR_BASE_BRANCH:-${DISPATCH_REPO_PR_BASE_BRANCH:-${AIDEVOPS_PR_BASE_BRANCH:-}}}"
	[[ -n "$base_branch" ]] && source="env"

	if [[ -z "$base_branch" ]]; then
		base_branch=$(_aidevops_pr_base_repo_config_field "$work_dir" "$_AIDEVOPS_PR_BASE_CONFIG_FILTER")
		[[ -n "$base_branch" ]] && source="repo-config"
	fi
	if [[ -z "$base_branch" ]]; then
		base_branch=$(_aidevops_pr_base_repos_json_field "$repo_slug" "$_AIDEVOPS_PR_BASE_CONFIG_FILTER")
		[[ -n "$base_branch" ]] && source="repos-json"
	fi
	if [[ -z "$base_branch" && -n "$repo_slug" ]]; then
		base_branch=$(gh api "repos/${repo_slug}" --jq '.default_branch // empty' 2>/dev/null) || base_branch=""
		[[ -n "$base_branch" ]] && source="remote-default"
	fi
	if [[ -z "$base_branch" && -n "$work_dir" ]]; then
		base_branch=$(git -C "$work_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || base_branch=""
		base_branch="${base_branch#origin/}"
		[[ -n "$base_branch" ]] && source="origin-head"
	fi
	if [[ -z "$base_branch" ]]; then
		base_branch=$(_aidevops_pr_base_repo_config_field "$work_dir" '.default_branch // empty')
		[[ -z "$base_branch" ]] && base_branch=$(_aidevops_pr_base_repos_json_field "$repo_slug" '.default_branch // empty')
		[[ -n "$base_branch" ]] && source="config-default-branch"
	fi

	[[ -n "$base_branch" ]] || return 1
	git check-ref-format --branch "$base_branch" >/dev/null 2>&1 || return 1
	printf '%s %s\n' "$base_branch" "$source"
	return 0
}

# Per-process cache for the pulse merge pass, which checks many PRs per repo.
# Entries: "<slug>|<branch> <source>" lines (Bash 3.2: no associative arrays).
# Call directly (not in $(...)) so the cache survives; the result is left in
# _AIDEVOPS_PR_BASE_RESOLVED.
_AIDEVOPS_PR_BASE_CACHE=""
_AIDEVOPS_PR_BASE_RESOLVED=""
_aidevops_pr_base_resolve_cached() {
	local repo_slug="$1"
	local line=""
	_AIDEVOPS_PR_BASE_RESOLVED=""
	while IFS= read -r line; do
		[[ -n "$line" && "${line%%|*}" == "$repo_slug" ]] || continue
		_AIDEVOPS_PR_BASE_RESOLVED="${line#*|}"
		return 0
	done <<<"$_AIDEVOPS_PR_BASE_CACHE"
	local resolved=""
	resolved=$(aidevops_pr_base_resolve "$repo_slug" "") || return 1
	_AIDEVOPS_PR_BASE_CACHE="${_AIDEVOPS_PR_BASE_CACHE}${repo_slug}|${resolved}"$'\n'
	_AIDEVOPS_PR_BASE_RESOLVED="$resolved"
	return 0
}

# Args: $1=repo_slug $2=work_dir (optional). Outputs the branch only.
aidevops_pr_base_branch() {
	local resolved=""
	resolved=$(aidevops_pr_base_resolve "$@") || return 1
	printf '%s\n' "${resolved%% *}"
	return 0
}

#######################################
# Is <branch> the head of an open same-repository PR (a stacked parent)?
# Args: $1=repo_slug $2=branch
# Returns: 0 yes, 1 no, 2 lookup failed
#######################################
aidevops_pr_base_is_stacked_parent() {
	local repo_slug="$1"
	local branch="$2"
	[[ "$repo_slug" == */* && -n "$branch" ]] || return 2
	local count=""
	count=$(gh api "repos/${repo_slug}/pulls?state=open&head=${repo_slug%%/*}:${branch}&per_page=1" \
		--jq 'length' 2>/dev/null) || return 2
	[[ "$count" =~ ^[0-9]+$ ]] || return 2
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

# Args: $1=repo_slug $2=pr_number $3=marker. Returns 0 when a comment has it.
_aidevops_pr_base_comment_exists() {
	local repo_slug="$1"
	local pr_number="$2"
	local marker="$3"
	local bodies=""
	bodies=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
		--jq '.[].body' 2>/dev/null) || return 0
	[[ "$bodies" == *"$marker"* ]] && return 0
	return 1
}

# Args: $1=pr_number $2=repo_slug $3=body
_aidevops_pr_base_comment() {
	local pr_number="$1"
	local repo_slug="$2"
	local body="$3"
	declare -F gh_pr_comment >/dev/null 2>&1 || return 0
	gh_pr_comment "$pr_number" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Merge-pass backstop: a worker PR whose base is neither the resolved PR base
# nor an open parent PR head is never merged into that base. When the head is
# built on the resolved base (diff shrinks), retarget once with an audit
# comment; otherwise post one diagnosis and hold. Either way, skip this cycle
# so required checks re-evaluate and no CI fix-worker is routed for failures
# caused by the base divergence.
# #aidevops:trust-boundary — the only mutation moves a PR to the configured
# or remote-default base, so a spoofed origin label gains no authority.
# Args: $1=pr_number $2=repo_slug $3=pr_base_ref $4=head_oid $5=labels (",a,b,")
# Returns: 0 proceed, 1 skip this merge cycle
#######################################
aidevops_pr_base_merge_guard() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_base="$3"
	local head_oid="$4"
	local labels="$5"
	local log_file="${LOGFILE:-/dev/null}"
	local tag="[pulse-merge] PR #${pr_number} in ${repo_slug}"

	case "$labels" in
	*",origin:worker,"* | *",origin:worker-takeover,"*) ;;
	*) return 0 ;;
	esac
	[[ -n "$pr_base" && "$head_oid" =~ ^[0-9a-f]{7,40}$ ]] || return 0

	local resolved="" expected="" source=""
	if ! _aidevops_pr_base_resolve_cached "$repo_slug"; then
		echo "${tag}: PR base unresolvable; base check skipped (GH#39167)" >>"$log_file"
		return 0
	fi
	resolved="$_AIDEVOPS_PR_BASE_RESOLVED"
	expected="${resolved%% *}"
	source="${resolved#* }"
	[[ "$pr_base" == "$expected" ]] && return 0

	local parent_rc=0
	aidevops_pr_base_is_stacked_parent "$repo_slug" "$pr_base" || parent_rc=$?
	case "$parent_rc" in
	0) return 0 ;;
	1) ;;
	*)
		echo "${tag}: base '${pr_base}' differs from PR base '${expected}' and the stacked-parent lookup failed; skipping this pass (GH#39167)" >>"$log_file"
		return 1
		;;
	esac

	local expected_ahead="" current_ahead=""
	expected_ahead=$(gh api "repos/${repo_slug}/compare/${expected}...${head_oid}" --jq '.ahead_by' 2>/dev/null) || expected_ahead=""
	current_ahead=$(gh api "repos/${repo_slug}/compare/${pr_base}...${head_oid}" --jq '.ahead_by' 2>/dev/null) || current_ahead=""
	if [[ "$expected_ahead" =~ ^[0-9]+$ && "$current_ahead" =~ ^[0-9]+$ ]] &&
		[[ "$expected_ahead" -gt 0 && "$expected_ahead" -le "$current_ahead" ]]; then
		if gh api -X PATCH "repos/${repo_slug}/pulls/${pr_number}" -f "base=${expected}" >/dev/null 2>&1; then
			echo "${tag}: retargeted worker PR base '${pr_base}' -> '${expected}' (source: ${source}; ahead ${current_ahead} -> ${expected_ahead}); merge deferred to next cycle (GH#39167)" >>"$log_file"
			_aidevops_pr_base_comment "$pr_number" "$repo_slug" "<!-- ${_AIDEVOPS_PR_BASE_MISMATCH_MARKER} retargeted base=${pr_base} expected=${expected} -->
Retargeted this worker PR from \`${pr_base}\` to \`${expected}\`, the repository PR base (source: ${source}). \`${pr_base}\` is not the head branch of an open parent PR, and the head is built on \`${expected}\` (${expected_ahead} commits ahead of \`${expected}\`, ${current_ahead} ahead of \`${pr_base}\`). Required checks re-evaluate against the new base before the next merge attempt (GH#39167)."
			return 1
		fi
		echo "${tag}: retarget '${pr_base}' -> '${expected}' failed; skipping this pass (GH#39167)" >>"$log_file"
		return 1
	fi

	local hold_marker="<!-- ${_AIDEVOPS_PR_BASE_MISMATCH_MARKER} held base=${pr_base} expected=${expected} -->"
	if ! _aidevops_pr_base_comment_exists "$repo_slug" "$pr_number" "$hold_marker"; then
		_aidevops_pr_base_comment "$pr_number" "$repo_slug" "${hold_marker}
This worker PR targets \`${pr_base}\`, but the repository PR base is \`${expected}\` (source: ${source}) and \`${pr_base}\` is not the head branch of an open parent PR. The merge pass will not merge it into \`${pr_base}\` or route CI fix-workers for failures caused by that divergence. It was not retargeted automatically because the head is not built on \`${expected}\` (ahead of \`${expected}\`: ${expected_ahead:-unknown}, ahead of \`${pr_base}\`: ${current_ahead:-unknown}). Rebase the branch onto \`${expected}\` and run \`gh pr edit ${pr_number} --base ${expected}\`, or set \`pr_base_branch\` if this repository integrates on \`${pr_base}\` (GH#39167)."
	fi
	echo "${tag}: holding worker PR on base '${pr_base}' (PR base '${expected}', source: ${source}; ahead expected=${expected_ahead:-?} current=${current_ahead:-?}) (GH#39167)" >>"$log_file"
	_PMP_HUMAN_GATED=1
	return 1
}
