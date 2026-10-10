#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# seed-pr-helper.sh — seed draft PRs (GH#34233).
#
# An issue that needs companion files (brief, research notes, fixtures,
# scaffolding) before a worker can start gets a *seed*: a same-repository
# draft PR labelled `seed-pr` whose body carries
# `<!-- aidevops:seed-pr issue=N -->` and a non-closing `For #N`. Dispatch
# does not treat the seed as an implementation checkpoint; the worker branch
# starts from the trusted seed head, and the worker's implementation PR closes
# the superseded seed. No default-branch merge is needed before dispatch.
#
# Usage:
#   seed-pr-helper.sh open <issue> [--repo owner/repo] [--title TEXT] [--notes FILE] [--dispatch]
#   seed-pr-helper.sh find <issue> [--repo owner/repo]
#   seed-pr-helper.sh proof <issue> [--repo owner/repo]
#   seed-pr-helper.sh supersede <issue> <pr> --seed-oid SHA [--repo owner/repo]
#
# find/proof print `<seed-pr>\t<head-ref>\t<head-oid>`.
# Exit codes: 0 found/done, 1 lookup or validation failure, 2 usage,
#             3 no seed, 4 seed rejected (untrusted, fork, ambiguous).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
trap '_run_cleanups' EXIT
trap '_run_cleanups; exit 130' HUP INT TERM

SEED_PR_LABEL="seed-pr"
SEED_PR_LABEL_COLOR="C5DEF5"
SEED_PR_LABEL_DESC="Seed draft PR: companion files a worker starts from (not an implementation checkpoint)"
SEED_PR_RC_NONE=3
SEED_PR_RC_REJECTED=4
SEED_PR_SCAN_LIMIT=100

usage() {
	printf 'Usage: seed-pr-helper.sh open <issue> [--repo owner/repo] [--title TEXT] [--notes FILE] [--dispatch]\n'
	printf '       seed-pr-helper.sh find <issue> [--repo owner/repo]\n'
	printf '       seed-pr-helper.sh proof <issue> [--repo owner/repo]\n'
	printf '       seed-pr-helper.sh supersede <issue> <pr> --seed-oid SHA [--repo owner/repo]\n'
	printf 'Seed workflow: workflows/brief.md "Seed mechanics".\n'
	return 0
}

seed_pr_marker() {
	local issue="$1"
	printf '<!-- aidevops:seed-pr issue=%s -->' "$issue"
	return 0
}

_seed_err() {
	local message="$1"
	printf '[seed-pr] %s\n' "$message" >&2
	return 0
}

_seed_resolve_repo() {
	local repo="${1:-}"
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || repo=""
	fi
	[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	printf '%s\n' "$repo"
	return 0
}

#aidevops:trust-boundary -- GH#34233: a seed head becomes the worker's base
# commit. Only OWNER/MEMBER/COLLABORATOR PR authors qualify; any lookup failure
# rejects the seed (fail closed).
_seed_author_trusted() {
	local repo="$1" pr="$2" association=""
	association=$(gh api "repos/${repo}/pulls/${pr}" --jq '.author_association // empty' 2>/dev/null) || return 1
	case "$association" in
	OWNER | MEMBER | COLLABORATOR) return 0 ;;
	esac
	return 1
}

# Print the single trusted seed for an issue. Drafts only, same-repository
# heads only, exact marker only. Several candidates are ambiguous: reject all.
seed_pr_find() {
	local issue="$1" repo="$2"
	local marker="" prs_json="" count="" matches="" match_count="" row="" pr=""
	marker=$(seed_pr_marker "$issue")
	prs_json=$(gh pr list --repo "$repo" --state open --label "$SEED_PR_LABEL" \
		--limit "$SEED_PR_SCAN_LIMIT" \
		--json number,isDraft,isCrossRepository,headRefName,headRefOid,body 2>/dev/null) || return 1
	count=$(printf '%s' "$prs_json" | jq -er 'if type == "array" then length else error("not array") end' 2>/dev/null) || return 1
	# A full page may hide the real seed; fail closed instead of guessing.
	[[ "$count" -lt "$SEED_PR_SCAN_LIMIT" ]] || return 1
	matches=$(printf '%s' "$prs_json" | jq -c --arg marker "$marker" \
		'[.[] | select(((.body // "") | contains($marker)))]' 2>/dev/null) || return 1
	match_count=$(printf '%s' "$matches" | jq -r 'length' 2>/dev/null) || return 1
	[[ "$match_count" -gt 0 ]] || return "$SEED_PR_RC_NONE"
	if [[ "$match_count" -gt 1 ]]; then
		_seed_err "issue #${issue}: ${match_count} seed PRs carry the marker; ignoring all (ambiguous)"
		return "$SEED_PR_RC_REJECTED"
	fi
	row=$(printf '%s' "$matches" | jq -r '.[0] |
		select(.isDraft == true and .isCrossRepository == false) |
		"\(.number)\t\(.headRefName)\t\(.headRefOid)"' 2>/dev/null) || row=""
	if [[ -z "$row" ]]; then
		_seed_err "issue #${issue}: seed PR is not a same-repository draft; ignoring it"
		return "$SEED_PR_RC_REJECTED"
	fi
	pr="${row%%$'\t'*}"
	if ! _seed_author_trusted "$repo" "$pr"; then
		_seed_err "issue #${issue}: seed PR #${pr} author is not a trusted collaborator; ignoring it"
		return "$SEED_PR_RC_REJECTED"
	fi
	local ref="" oid=""
	IFS=$'\t' read -r _ ref oid <<<"$row"
	if ! git check-ref-format --branch "$ref" >/dev/null 2>&1 || [[ ! "$oid" =~ ^[0-9a-f]{40}$ ]]; then
		_seed_err "issue #${issue}: seed PR #${pr} has an invalid head ref or SHA; ignoring it"
		return "$SEED_PR_RC_REJECTED"
	fi
	printf '%s\n' "$row"
	return 0
}

# Print the seed row when HEAD already contains the seed head. Callers capture
# this before any history rewrite (WIP finalization squashes seed commits).
seed_pr_proof() {
	local issue="$1" repo="$2" row="" rc=0 oid=""
	row=$(seed_pr_find "$issue" "$repo") || rc=$?
	[[ "$rc" -eq 0 ]] || return "$rc"
	oid="${row##*$'\t'}"
	git merge-base --is-ancestor "$oid" HEAD 2>/dev/null || return "$SEED_PR_RC_NONE"
	printf '%s\n' "$row"
	return 0
}

_seed_ensure_label() {
	local repo="$1"
	gh label create "$SEED_PR_LABEL" --repo "$repo" --color "$SEED_PR_LABEL_COLOR" \
		--description "$SEED_PR_LABEL_DESC" >/dev/null 2>&1 || true
	return 0
}

_seed_write_body() {
	local issue="$1" body_file="$2" notes_file="$3"
	{
		seed_pr_marker "$issue"
		printf '\n## Seed for #%s\n\n' "$issue"
		printf 'Companion files for the issue. This draft is **not** an implementation checkpoint:\n'
		printf 'dispatch starts the worker branch from this head, and the implementation PR closes\n'
		printf 'this seed once it contains the seed head. Do not mark it ready or merge it.\n\n'
		if [[ -n "$notes_file" ]]; then
			cat "$notes_file"
			printf '\n\n'
		fi
		printf 'For #%s\n' "$issue"
	} >"$body_file"
	return 0
}

cmd_open() {
	local issue="$1" repo="$2" title="$3" dispatch="$4" notes_file="$5"
	if [[ -n "$notes_file" && ! -r "$notes_file" ]]; then
		_seed_err "notes file is not readable: ${notes_file}"
		return 2
	fi
	local git_dir="" common_dir="" branch="" default_branch="" ahead="" row="" rc=0
	git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || {
		_seed_err "not inside a git worktree"
		return 1
	}
	common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
	if [[ "$(cd "$git_dir" && pwd -P)" == "$common_dir" ]]; then
		_seed_err "run from a linked worktree, not the canonical checkout"
		return 1
	fi
	branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
		_seed_err "HEAD is detached; check out the seed branch"
		return 1
	}
	default_branch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || default_branch=""
	[[ -n "$default_branch" ]] || default_branch="main"
	if [[ "$branch" == "$default_branch" ]]; then
		_seed_err "refusing to seed from the default branch"
		return 1
	fi
	if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
		_seed_err "commit the companion files first (worktree has uncommitted changes)"
		return 1
	fi
	git fetch -q origin "$default_branch" 2>/dev/null || true
	ahead=$(git rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null) || ahead=0
	if [[ "$ahead" -eq 0 ]]; then
		_seed_err "no commits ahead of origin/${default_branch}; nothing to seed"
		return 1
	fi

	git push -q -u origin HEAD || return 1
	row=$(seed_pr_find "$issue" "$repo") || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		printf 'Seed PR #%s already open for #%s; pushed updated head.\n' "${row%%$'\t'*}" "$issue"
	elif [[ "$rc" -eq "$SEED_PR_RC_NONE" ]]; then
		local body_file="" pr_url=""
		body_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/seed-pr.XXXXXX") || return 1
		_seed_write_body "$issue" "$body_file" "$notes_file"
		_seed_ensure_label "$repo"
		[[ -n "$title" ]] || title="GH#${issue}: seed companion files"
		pr_url=$(gh_create_pr --repo "$repo" --draft --base "$default_branch" --head "$branch" \
			--title "$title" --label "$SEED_PR_LABEL" --body-file "$body_file") || pr_url=""
		rm -f "$body_file"
		if [[ -z "$pr_url" ]]; then
			_seed_err "seed PR creation failed for #${issue}"
			return 1
		fi
		printf 'Seed PR opened for #%s: %s\n' "$issue" "$pr_url"
	else
		_seed_err "existing seed state for #${issue} is unusable (rc=${rc}); resolve it before seeding"
		return 1
	fi

	# The issue label lets dispatch skip seed lookups for unseeded issues.
	local -a edit_args=(--add-label "$SEED_PR_LABEL")
	[[ "$dispatch" -eq 1 ]] && edit_args+=(--add-label "auto-dispatch")
	gh_issue_edit_safe "$issue" --repo "$repo" "${edit_args[@]}" >/dev/null || {
		_seed_err "seed opened but labelling issue #${issue} failed; add '${edit_args[*]}' manually"
		return 1
	}
	[[ "$dispatch" -eq 1 ]] && printf 'Issue #%s armed for dispatch from the seed head.\n' "$issue"
	return 0
}

# Close the seed once a PR containing its head exists. The caller supplies the
# seed SHA it proved before rewriting history; a moved seed is left open.
cmd_supersede() {
	local issue="$1" new_pr="$2" seed_oid="$3" repo="$4"
	local row="" rc=0 seed_pr="" current_oid="" comment_file=""
	[[ "$seed_oid" =~ ^[0-9a-f]{40}$ ]] || {
		_seed_err "supersede requires --seed-oid <40-hex SHA>"
		return 2
	}
	row=$(seed_pr_find "$issue" "$repo") || rc=$?
	[[ "$rc" -eq 0 ]] || return 0
	seed_pr="${row%%$'\t'*}"
	current_oid="${row##*$'\t'}"
	[[ "$seed_pr" != "$new_pr" ]] || return 0
	if [[ "$current_oid" != "$seed_oid" ]]; then
		_seed_err "seed PR #${seed_pr} moved since it was proven (${seed_oid:0:12} -> ${current_oid:0:12}); leaving it open"
		return 0
	fi
	comment_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/seed-pr-close.XXXXXX") || return 1
	# shellcheck disable=SC2016 # Backticks in the Markdown comment are literal.
	printf 'Superseded by #%s, whose branch was built on this seed head (`%s`). The seed branch is kept; reopen this draft if #%s closes without merging.\n' \
		"$new_pr" "${seed_oid:0:12}" "$new_pr" >"$comment_file"
	gh_pr_comment "$seed_pr" --repo "$repo" --body-file "$comment_file" >/dev/null 2>&1 || true
	rm -f "$comment_file"
	if ! gh pr close "$seed_pr" --repo "$repo" >/dev/null 2>&1; then
		_seed_err "could not close superseded seed PR #${seed_pr}"
		return 1
	fi
	gh_issue_edit_safe "$issue" --repo "$repo" --remove-label "$SEED_PR_LABEL" >/dev/null 2>&1 || true
	printf 'Closed superseded seed PR #%s (implementation PR #%s).\n' "$seed_pr" "$new_pr"
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	help | --help | -h)
		usage
		return 0
		;;
	esac
	local issue="${1:-}" new_pr="" repo="" title="" seed_oid="" notes_file="" dispatch=0
	[[ "$issue" =~ ^[1-9][0-9]*$ ]] || {
		usage >&2
		return 2
	}
	shift
	if [[ "$command" == "supersede" ]]; then
		new_pr="${1:-}"
		[[ "$new_pr" =~ ^[1-9][0-9]*$ ]] || {
			usage >&2
			return 2
		}
		shift
	fi
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		case "$flag" in
		--repo | --title | --seed-oid | --notes)
			if [[ $# -lt 2 ]]; then
				usage >&2
				return 2
			fi
			case "$flag" in
			--repo) repo="$2" ;;
			--title) title="$2" ;;
			--seed-oid) seed_oid="$2" ;;
			--notes) notes_file="$2" ;;
			esac
			shift 2
			;;
		--dispatch)
			dispatch=1
			shift
			;;
		*)
			usage >&2
			return 2
			;;
		esac
	done
	repo=$(_seed_resolve_repo "$repo") || {
		_seed_err "cannot resolve repository slug; pass --repo owner/repo"
		return 1
	}
	case "$command" in
	open) cmd_open "$issue" "$repo" "$title" "$dispatch" "$notes_file" ;;
	find) seed_pr_find "$issue" "$repo" ;;
	proof) seed_pr_proof "$issue" "$repo" ;;
	supersede) cmd_supersede "$issue" "$new_pr" "$seed_oid" "$repo" ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
