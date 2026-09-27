#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Synchronise registered private mirrors without touching canonical checkouts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
CONFIG_FILE="${AIDEVOPS_REPOS_FILE:-$HOME/.config/aidevops/repos.json}"
STATE_FILE="${AIDEVOPS_MIRROR_STATE_FILE:-$HOME/.aidevops/cache/mirror-sync-state.json}"
TEMP_ROOT="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"

report() {
	local slug="$1" state="$2" detail="${3:-}"
	printf '%s %s %s\n' "$state" "$slug" "$detail"
	if [[ "$MODE" == sync ]]; then
		jq --arg slug "$slug" --arg state "$state" --arg detail "$detail" \
			'.[$slug] = {state:$state, detail:$detail}' "$STATE_FILE" >"${STATE_FILE}.tmp" &&
			mv "${STATE_FILE}.tmp" "$STATE_FILE"
	fi
}

# gh is only used as a transient credential provider, never for upstream writes.
git_remote() {
	local directory="$1" remote="$2" url="$3"
	shift 3
	local -a args=("$@")
	if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$directory" "${args[@]}" 2>/dev/null; then
		return 0
	fi
	# Retry SSH GitHub remotes through HTTPS only when gh is authenticated.
	if [[ "$url" =~ ^git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(\.git)?$ ]] &&
		command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		local https_url="https://github.com/${BASH_REMATCH[1]}.git"
		git -C "$directory" remote set-url "$remote" "$https_url"
		GIT_TERMINAL_PROMPT=0 git -C "$directory" -c credential.helper= \
			-c 'credential.helper=!gh auth git-credential' "${args[@]}" 2>/dev/null
	elif [[ "$url" == https://github.com/* ]] && command -v gh >/dev/null 2>&1 &&
		gh auth status >/dev/null 2>&1; then
		GIT_TERMINAL_PROMPT=0 git -C "$directory" -c credential.helper= \
			-c 'credential.helper=!gh auth git-credential' "${args[@]}" 2>/dev/null
	else
		return 1
	fi
}

sync_one() (
	local slug="$1" upstream="$2" upstream_url="$3" origin_url="$4"
	local directory branch origin_tip upstream_tip count paths sync_branch
	directory=$(mktemp -d "${TEMP_ROOT}/mirror-sync.XXXXXXXX") || return 1
	trap 'rm -rf "$directory"' EXIT
	git -C "$directory" init -q
	git -C "$directory" remote add origin "$origin_url"
	git -C "$directory" remote add upstream "$upstream_url"
	# Discover the upstream default branch without consulting a mutable canonical ref.
	local remote_head
	remote_head=$(git_remote "$directory" upstream "$upstream_url" ls-remote --symref upstream HEAD) || {
		report "$slug" FAIL 'upstream authentication or discovery failed'
		return 1
	}
	branch=$(printf '%s\n' "$remote_head" | awk '$1 == "ref:" {sub("refs/heads/", "", $2); print $2; exit}')
	if [[ -z "$branch" || ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
		report "$slug" FAIL 'upstream default branch unavailable'
		return 1
	fi
	if ! git_remote "$directory" upstream "$upstream_url" fetch --no-tags upstream "+refs/heads/${branch}:refs/remotes/upstream/${branch}" ||
		! git_remote "$directory" origin "$origin_url" fetch --no-tags origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
		report "$slug" FAIL 'remote fetch failed'
		return 1
	fi
	origin_tip=$(git -C "$directory" rev-parse "refs/remotes/origin/${branch}")
	upstream_tip=$(git -C "$directory" rev-parse "refs/remotes/upstream/${branch}")
	if git -C "$directory" merge-base --is-ancestor "$upstream_tip" "$origin_tip"; then
		report "$slug" OK 'up-to-date'
		return 0
	fi
	if git -C "$directory" merge-base --is-ancestor "$origin_tip" "$upstream_tip"; then
		count=$(git -C "$directory" rev-list --count "${origin_tip}..${upstream_tip}")
		if [[ "$MODE" == check ]]; then
			report "$slug" BEHIND "$count"
			return 0
		fi
		if git_remote "$directory" origin "$origin_url" push origin "${upstream_tip}:refs/heads/${branch}"; then
			report "$slug" OK "fast-forwarded $count commits"
			return 0
		fi
		report "$slug" FAIL 'fast-forward push rejected (origin changed or protected)'
		return 1
	fi
	if [[ "$MODE" == check ]]; then
		report "$slug" DIVERGED 'local commits require merge'
		return 0
	fi
	sync_branch="sync/upstream-$(date +%Y%m%d)"
	git -C "$directory" -c user.name='aidevops mirror sync' -c user.email='mirror-sync@localhost' \
		checkout -q -b "$sync_branch" "$origin_tip"
	if ! git -C "$directory" -c user.name='aidevops mirror sync' -c user.email='mirror-sync@localhost' \
		merge --no-ff --no-edit "$upstream_tip" >/dev/null 2>&1; then
		paths=$(git -C "$directory" diff --name-only --diff-filter=U | paste -sd ',' -)
		git -C "$directory" merge --abort >/dev/null 2>&1 || true
		report "$slug" CONFLICT "${paths:-merge failed}"
		return 1
	fi
	# A pre-existing dated branch must not be overwritten. The merge commit remains
	# reachable only if the branch creation succeeds; never force-update either ref.
	if ! git_remote "$directory" origin "$origin_url" push origin "HEAD:refs/heads/${sync_branch}"; then
		report "$slug" FAIL 'sync branch push rejected'
		return 1
	fi
	if git_remote "$directory" origin "$origin_url" push origin "HEAD:refs/heads/${branch}"; then
		report "$slug" OK "merged on ${sync_branch}"
	else
		report "$slug" FAIL 'default branch fast-forward rejected'
		return 1
	fi
)

MODE="${1:-}"
case "$MODE" in check | sync | status) shift ;; *) printf 'Usage: %s check|sync|status [--repo owner/name]\n' "$0" >&2; exit 2 ;; esac
FILTER=""
if [[ "${1:-}" == --repo && $# -eq 2 ]]; then
	shift
	FILTER="${1:-}"
elif [[ $# -ne 0 ]]; then
	exit 2
fi
if [[ "$MODE" == status ]]; then
	if [[ -f "$STATE_FILE" ]]; then jq -r 'to_entries[] | "\(.value.state) \(.key) \(.value.detail)"' "$STATE_FILE"; fi
	exit 0
fi
[[ -f "$CONFIG_FILE" ]] || { printf 'FAIL config unavailable\n' >&2; exit 1; }
mkdir -p "$TEMP_ROOT"
if [[ "$MODE" == sync ]]; then
	mkdir -p "$(dirname "$STATE_FILE")"
	printf '{}\n' >"$STATE_FILE"
fi
fail=0
while IFS= read -r entry; do
	slug=$(jq -r '.slug // empty' <<<"$entry")
	upstream=$(jq -r '.mirror_upstream | if type == "string" then . else "" end' <<<"$entry")
	[[ -z "$FILTER" || "$FILTER" == "$slug" ]] || continue
	if [[ -z "$upstream" ]]; then
		[[ "$(jq -r 'has("mirror_upstream")' <<<"$entry")" == true ]] && printf 'INFO privacy-only mirror marker skipped\n'
		continue
	fi
	[[ "$(jq -r '.mirror_sync // true' <<<"$entry")" == true ]] || continue
	if [[ ! "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$upstream" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		report "$slug" FAIL 'invalid mirror or upstream slug'; fail=1; continue
	fi
	upstream_url=$(jq -r '.mirror_upstream_url // empty' <<<"$entry")
	[[ -n "$upstream_url" ]] || upstream_url="https://github.com/${upstream}.git"
	origin_url="https://github.com/${slug}.git"
	if [[ -z "$origin_url" ]] || ! sync_one "$slug" "$upstream" "$upstream_url" "$origin_url"; then fail=1; fi
done < <(jq -c '.initialized_repos[]?' "$CONFIG_FILE")
exit "$fail"
