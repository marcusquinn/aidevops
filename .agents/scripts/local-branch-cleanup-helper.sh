#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Audited local ref cleanup. No canonical Git mutation is performed directly.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worktree-paths.sh
source "${SCRIPT_DIR}/worktree-paths.sh"

REPO_PATH="$PWD"
REMOTE_NAME=origin
ONLY_BRANCH=""
APPLY=0
TRANSPORT=""
FAILURES=0
MAX_LOOKUPS=500
LOOKUPS=0
OPEN_PR_REFS=""
OPEN_PR_STATUS=unavailable
OPEN_PR_LOADED_AT=""
ACTIVE_CACHE=""
ACTIVE_CACHE_SET=""
N_SCANNED=0
N_ACTED=0
N_KEPT=0
N_BUDGET=0

usage() {
	printf '%s\n' 'Usage: local-branch-cleanup-helper.sh [--repo PATH] [--remote NAME] [--branch NAME] [--apply] [--max-lookups N]' \
		'Dry-run by default. --branch limits the scan to one local branch.' \
		'--max-lookups N caps closed-PR lookups per run (default 500); rerun to continue a large backlog.' \
		'AIDEVOPS_LOCAL_BRANCH_CLEANUP_OPEN_TTL_S sets the open-PR listing cache TTL in seconds (default 60).' \
		'AIDEVOPS_LOCAL_BRANCH_CLEANUP_SKIP_GH=1 disables GitHub reads and preserves all branches.'
	return 0
}

parse_args() {
	local arg="" value=""
	while [[ $# -gt 0 ]]; do
		arg="${1:-}"
		value="${2:-}"
		case "$arg" in
		--repo | --remote | --branch | --max-lookups)
			[[ $# -ge 2 && -n "$value" ]] || { usage >&2; return 1; }
			case "$arg" in
			--repo) REPO_PATH="$value" ;;
			--remote) REMOTE_NAME="$value" ;;
			--branch) ONLY_BRANCH="$value" ;;
			--max-lookups)
				[[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || { usage >&2; return 1; }
				MAX_LOOKUPS="$value" ;;
			esac
			shift 2 ;;
		--apply) APPLY=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; return 1 ;;
		esac
	done
	return 0
}

repo_git() {
	git -C "$REPO_PATH" "$@"
	return $?
}

default_branch() {
	local branch=""
	branch=$(repo_git symbolic-ref --quiet --short "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null) || branch=""
	branch="${branch#"${REMOTE_NAME}/"}"
	if [[ -z "$branch" ]]; then
		branch=$(repo_git remote show "$REMOTE_NAME" 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p' | sed -n '1p') || branch=""
	fi
	[[ -n "$branch" ]] || branch=main
	printf '%s\n' "$branch"
	return 0
}

is_protected_branch() {
	local branch="$1" default="$2"
	case "$branch" in
	"$default" | main | master | develop | development | staging | production | release | gh-pages) return 0 ;;
	esac
	return 1
}

repo_slug() {
	local url=""
	url=$(repo_git remote get-url "$REMOTE_NAME" 2>/dev/null) || return 1
	case "$url" in
	git@github.com:*) url="${url#git@github.com:}" ;;
	https://github.com/*) url="${url#https://github.com/}" ;;
	*) return 1 ;;
	esac
	url="${url%.git}"
	[[ "$url" == */* ]] || return 1
	printf '%s\n' "$url"
	return 0
}

# Open PR heads are loop-invariant within a scan: list them once per TTL window.
# A failed or incomplete listing sets OPEN_PR_STATUS=unavailable (keep branches).
load_open_pr_refs() {
	local slug="$1" page=1 data count refs="" now="" ttl="${AIDEVOPS_LOCAL_BRANCH_CLEANUP_OPEN_TTL_S:-60}"
	[[ "$ttl" =~ ^[1-9][0-9]*$ ]] || ttl=60
	now=$(date +%s)
	if [[ -n "$OPEN_PR_LOADED_AT" && $((now - OPEN_PR_LOADED_AT)) -lt "$ttl" ]]; then
		return 0
	fi
	OPEN_PR_REFS=""
	OPEN_PR_STATUS=unavailable
	OPEN_PR_LOADED_AT="$now"
	command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
	# An open PR from a fork can have the same head.ref, so match on ref alone
	# and exhaust bounded open pages before trusting the listing.
	while [[ "$page" -le 10 ]]; do
		data=$(AIDEVOPS_GH_ROUTE_DECISION="local-branch-cleanup-open-prs-rest" gh api "repos/${slug}/pulls?state=open&per_page=100&page=${page}" 2>/dev/null) || return 0
		count=$(printf '%s' "$data" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null) || return 0
		[[ "$count" =~ ^[0-9]+$ ]] || return 0
		refs+=$(printf '%s' "$data" | jq -r '.[].head.ref // empty' 2>/dev/null)$'\n' || return 0
		if [[ "$count" -lt 100 ]]; then
			OPEN_PR_REFS="$refs"
			OPEN_PR_STATUS=ok
			return 0
		fi
		page=$((page + 1))
	done
	return 0
}

# Closed-PR lookups are budgeted by --max-lookups; each request counts.
closed_pr_lookup() {
	local branch="$1" sha="$2" slug="$3" owner="" page=1 data count
	owner="${slug%%/*}"
	PR_STATUS=none
	while [[ "$page" -le 10 ]]; do
		LOOKUPS=$((LOOKUPS + 1))
		data=$(AIDEVOPS_GH_ROUTE_DECISION="local-branch-cleanup-prs-rest" gh api "repos/${slug}/pulls?state=closed&head=${owner}:${branch}&per_page=100&page=${page}" 2>/dev/null) || { PR_STATUS=unavailable; return 0; }
		count=$(printf '%s' "$data" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null) || { PR_STATUS=unavailable; return 0; }
		[[ "$count" =~ ^[0-9]+$ ]] || { PR_STATUS=unavailable; return 0; }
		if printf '%s' "$data" | jq -e --arg b "$branch" --arg sha "$sha" 'any(.[]; .head.ref == $b and .head.sha == $sha and .merged_at != null)' >/dev/null; then
			PR_STATUS=merged
		fi
		[[ "$count" -lt 100 ]] && return 0
		page=$((page + 1))
	done
	PR_STATUS=unavailable
	return 0
}

# A failed or incomplete PR lookup must never authorize a deletion.
# enforce_budget=1 yields PR_STATUS=budget when the closed-PR budget is spent.
pr_evidence() {
	local branch="$1" sha="$2" slug="$3" need_merged="$4" enforce_budget="${5:-0}"
	PR_STATUS=unavailable
	[[ "${AIDEVOPS_LOCAL_BRANCH_CLEANUP_SKIP_GH:-0}" != 1 && -n "$slug" ]] || return 0
	command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
	load_open_pr_refs "$slug"
	[[ "$OPEN_PR_STATUS" == ok ]] || return 0
	if [[ $'\n'"$OPEN_PR_REFS" == *$'\n'"${branch}"$'\n'* ]]; then
		PR_STATUS=open
		return 0
	fi
	PR_STATUS=none
	[[ "$need_merged" -eq 1 ]] || return 0
	if [[ "$enforce_budget" -eq 1 && "$LOOKUPS" -ge "$MAX_LOOKUPS" ]]; then
		PR_STATUS=budget
		return 0
	fi
	closed_pr_lookup "$branch" "$sha" "$slug"
	return 0
}

# fresh=1 bypasses the scan cache (mutation-time guard).
active_branch() {
	local branch="$1" fresh="${2:-0}" active=""
	if [[ "$fresh" -eq 1 || -z "$ACTIVE_CACHE_SET" ]]; then
		active=$(repo_git worktree list --porcelain) || return 0
		if [[ "$fresh" -ne 1 ]]; then
			ACTIVE_CACHE="$active"
			ACTIVE_CACHE_SET=1
		fi
	else
		active="$ACTIVE_CACHE"
	fi
	[[ $'\n'"$active"$'\n' == *$'\n'"branch refs/heads/${branch}"$'\n'* ]]
	return $?
}

cleanup_transport() {
	[[ -n "$TRANSPORT" ]] || return 0
	repo_git worktree remove --force "$TRANSPORT" >/dev/null 2>&1 || return 1
	TRANSPORT=""
	return 0
}

prepare_transport() {
	[[ -z "$TRANSPORT" ]] || return 0
	local path=""
	path=$(aidevops_generate_worktree_path "$REPO_PATH" "local-branch-cleanup-$$") || return 1
	[[ ! -e "$path" && ! -L "$path" ]] || return 1
	repo_git worktree add --detach --no-checkout "$path" HEAD >/dev/null 2>&1 || return 1
	TRANSPORT="$path"
	return 0
}

report() {
	local action="$1" branch="$2" detail="$3"
	printf '%s %s %s\n' "$action" "$branch" "$detail"
	case "$action" in
	would-delete | deleted) N_ACTED=$((N_ACTED + 1)) ;;
	keep) N_KEPT=$((N_KEPT + 1)) ;;
	esac
	if [[ -n "$ONLY_BRANCH" && "$action" == keep || -n "$ONLY_BRANCH" && "$action" == failed ]]; then
		printf 'branch preserved: %s (%s)\n' "$detail" "$branch"
	fi
	return 0
}

delete_branch() {
	local branch="$1" sha="$2" slug="$3" merged_by_ancestry="$4"
	if ! prepare_transport; then
		report failed "$branch" 'isolated deletion transport unavailable'
		FAILURES=$((FAILURES + 1))
		return 0
	fi
	if active_branch "$branch" 1; then
		report keep "$branch" 'checked out after scan'
		return 0
	fi
	# Recheck open PRs immediately before mutation; errors are conservative.
	pr_evidence "$branch" "$sha" "$slug" "$((1 - merged_by_ancestry))"
	if [[ "$PR_STATUS" == open || "$PR_STATUS" == unavailable ]]; then
		report keep "$branch" 'open PR or github evidence unavailable'
		return 0
	fi
	if ! git -C "$TRANSPORT" update-ref -d "refs/heads/${branch}" "$sha" 2>/dev/null; then
		report failed "$branch" 'ref changed after scan or deletion refused'
		FAILURES=$((FAILURES + 1))
		return 0
	fi
	report deleted "$branch" "$sha"
	bash "${SCRIPT_DIR}/audit-log-helper.sh" log local-branch-delete "deleted ${branch} ${sha}" --detail "repository=${REPO_PATH}" >/dev/null || {
		report failed "$branch" 'audit log unavailable; recover from printed SHA'
		FAILURES=$((FAILURES + 1))
	}
	return 0
}

scan_branch() {
	local branch="$1" default="$2" slug="$3" sha="" reason="" merged_by_ancestry=0
	N_SCANNED=$((N_SCANNED + 1))
	sha=$(repo_git rev-parse --verify "refs/heads/${branch}" 2>/dev/null) || sha=""
	if [[ -z "$sha" ]]; then
		report keep "$branch" absent
		return 0
	fi
	if is_protected_branch "$branch" "$default"; then reason='protected/default branch'
	elif active_branch "$branch"; then reason='checked out'
	else
		if repo_git merge-base --is-ancestor "$sha" "refs/remotes/${REMOTE_NAME}/${default}" 2>/dev/null; then
			merged_by_ancestry=1
		fi
		pr_evidence "$branch" "$sha" "$slug" "$((1 - merged_by_ancestry))" 1
		if [[ "$PR_STATUS" == budget ]]; then
			reason='lookup budget exhausted'
			N_BUDGET=$((N_BUDGET + 1))
		elif [[ "$PR_STATUS" == open ]]; then reason='open PR exists'
		elif [[ "$PR_STATUS" == unavailable ]]; then reason='github evidence unavailable'
		elif [[ "$merged_by_ancestry" -eq 1 ]]; then reason='merged by ancestry'
		elif [[ "$PR_STATUS" == merged ]]; then reason='merged PR head SHA'
		else reason='unmerged local commits'
		fi
	fi
	if [[ "$reason" != 'merged by ancestry' && "$reason" != 'merged PR head SHA' ]]; then
		report keep "$branch" "$reason"
	elif [[ "$APPLY" -eq 1 ]]; then
		delete_branch "$branch" "$sha" "$slug" "$merged_by_ancestry"
	else
		report would-delete "$branch" "$reason ($sha)"
	fi
	return 0
}

main() {
	local default="" slug="" branch="" rc=0
	parse_args "$@" || return 1
	repo_git rev-parse --git-dir >/dev/null 2>&1 || return 1
	[[ -z "$ONLY_BRANCH" ]] || repo_git check-ref-format --branch "$ONLY_BRANCH" >/dev/null 2>&1 || return 1
	default=$(default_branch)
	slug=$(repo_slug) || slug=""
	trap 'cleanup_transport || true' EXIT
	if [[ -n "$ONLY_BRANCH" ]]; then
		scan_branch "$ONLY_BRANCH" "$default" "$slug"
	else
		while IFS= read -r branch; do
			[[ -z "$branch" ]] || scan_branch "$branch" "$default" "$slug"
		done < <(repo_git for-each-ref --format='%(refname:lstrip=2)' refs/heads)
	fi
	cleanup_transport || rc=1
	trap - EXIT
	if [[ -z "$ONLY_BRANCH" ]]; then
		printf 'summary scanned=%s %s=%s kept=%s lookups=%s budget_exhausted=%s\n' \
			"$N_SCANNED" "$([[ "$APPLY" -eq 1 ]] && printf deleted || printf would-delete)" "$N_ACTED" "$N_KEPT" "$LOOKUPS" "$N_BUDGET"
	fi
	[[ "$FAILURES" -eq 0 && "$rc" -eq 0 ]] || return 1
	return 0
}

main "$@"
