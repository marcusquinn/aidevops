#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Sourced by release provenance. No mutable branch reads or writes: callers
# capture a canonical head once and pass immutable range endpoints here.

# Read-only GitHub read with bounded retry of transport failures only (empty
# body, HTTP 5xx, truncated/invalid JSON). Auth, 404 and permission failures and
# wrong response shapes fail on the first attempt. Fail closed after 3 attempts.
# Usage: _release_snapshot_gh_read <purpose> <jq-shape-test> -- gh-args...
_release_snapshot_gh_read() {
	local purpose="$1"
	local shape="$2"
	shift 3
	local attempt=1
	local response=""
	local status=0
	local error_file=""
	local error_text=""
	local cause=""
	error_file=$(mktemp) || return 1
	while [[ "$attempt" -le 3 ]]; do
		status=0
		response=$(gh "$@" 2>"$error_file") || status=$?
		error_text=$(<"$error_file")
		if [[ "$status" -eq 0 && "$response" =~ [^[:space:]] ]]; then
			if jq -e "$shape" <<<"$response" >/dev/null 2>&1; then
				rm -f "$error_file"
				printf '%s\n' "$response"
				return 0
			elif jq -e . <<<"$response" >/dev/null 2>&1; then
				rm -f "$error_file"
				printf 'release-snapshot: %s: unexpected response shape\n' "$purpose" >&2
				return 1
			fi
			cause="invalid JSON response"
		elif [[ "$error_text" =~ HTTP[[:space:]]5[0-9][0-9] ]]; then
			cause="HTTP 5xx"
		elif [[ "$error_text" =~ (unexpected\ end\ of\ JSON\ input|invalid\ character) ]]; then
			cause="JSON decode error"
		elif [[ "$status" -eq 0 && -z "$error_text" ]]; then
			cause="empty response"
		else
			rm -f "$error_file"
			printf 'release-snapshot: %s: GitHub read failed (exit %s, attempt %s; not retryable)\n' "$purpose" "$status" "$attempt" >&2
			return 1
		fi
		[[ "$attempt" -eq 3 ]] && break
		printf 'release-snapshot: %s: %s; retrying after attempt %s/3\n' "$purpose" "$cause" "$attempt" >&2
		sleep $((attempt * ${RELEASE_SNAPSHOT_RETRY_UNIT:-1}))
		attempt=$((attempt + 1))
	done
	rm -f "$error_file"
	printf 'release-snapshot: %s: %s after 3 attempts\n' "$purpose" "$cause" >&2
	return 1
}

release_snapshot_sources() {
	local repo="$1"
	local branch="$2"
	local base="$3"
	local snapshot="$4"
	local commits=""
	local commit=""
	local records=""
	local record=""
	local merge_sha=""
	local pr_number=""
	local pr_json=""
	local sources='[]'
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$base" =~ ^[0-9a-f]{40}$ && "$snapshot" =~ ^[0-9a-f]{40}$ ]] || return 1
	git merge-base --is-ancestor "$base" "$snapshot" || return 1
	commits=$(git rev-list --first-parent --reverse "${base}..${snapshot}") || return 1
	[[ -n "$commits" ]] || return 1
	while IFS= read -r commit; do
		# For commits on the default branch GitHub returns the introducing PR.
		# A rebase merge introduces several commits with one final merge tip;
		# verify that tip independently and bind every introduced commit to it.
		records=$(_release_snapshot_gh_read "pull requests for commit ${commit} in ${repo}" 'type == "array"' -- \
			api --paginate --slurp "repos/${repo}/commits/${commit}/pulls?per_page=100") || return 1
		#aidevops:trust-boundary
		record=$(jq -ce --arg repo "$repo" --arg branch "$branch" '
			flatten | [.[] | select(.merged_at != null and .state == "closed"
				and .base.repo.full_name == $repo and .base.ref == $branch
				and (.merge_commit_sha | type) == "string")]
			| if length == 1 then .[0] else error("ambiguous or unmerged snapshot commit") end
			| {pr:.number,merge:.merge_commit_sha}
			| select((.pr | type) == "number" and .pr > 0 and (.pr | floor) == .pr)
		' <<<"$records") || return 1
		merge_sha=$(jq -er '.merge | select(test("^[0-9a-f]{40}$"))' <<<"$record") || return 1
		pr_number=$(jq -er '.pr' <<<"$record") || return 1
		git merge-base --is-ancestor "$commit" "$merge_sha" || return 1
		git merge-base --is-ancestor "$merge_sha" "$snapshot" || return 1
		if git merge-base --is-ancestor "$merge_sha" "$base"; then
			return 1
		fi
		pr_json=$(_release_snapshot_gh_read "source PR #${pr_number} in ${repo}" 'type == "object"' -- \
			pr view "$pr_number" --repo "$repo" --json state,mergedAt,mergeCommit,baseRefName) || return 1
		jq -e --arg sha "$merge_sha" --arg branch "$branch" '
			.state == "MERGED" and .mergedAt != null and .baseRefName == $branch
			and .mergeCommit.oid == $sha' <<<"$pr_json" >/dev/null || return 1
		sources=$(jq -ce --argjson record "$record" '
			if any(.[]; .pr == $record.pr and .merge != $record.merge) then error("conflicting snapshot PR")
			elif any(.[]; . == $record) then . else . + [$record] end
		' <<<"$sources") || return 1
	done <<<"$commits"
	jq -c 'sort_by(.pr)' <<<"$sources"
	return $?
}
