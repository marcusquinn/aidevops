#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# dependency-supersession-repoint-lib.sh — repoint dependants of a superseded
# issue at its live successor (GH#35130).
#
# GH#34341 keeps dependants blocked at read time by following "Superseded by
# #S". This library makes the graph itself truthful: it adds a native
# blocked_by edge to #S, rewrites "Blocked by:" lines from #orig to #S and posts
# one pointer comment. The old edge stays as history.
#
# Requires dependency-supersession-lib.sh. Writes use gh-write-helper.sh.

[[ -n "${_DEPENDENCY_SUPERSESSION_REPOINT_LOADED:-}" ]] && return 0
_DEPENDENCY_SUPERSESSION_REPOINT_LOADED=1

_dsr_dir="${BASH_SOURCE[0]%/*}"
[[ "$_dsr_dir" == "${BASH_SOURCE[0]}" ]] && _dsr_dir="."
: "${DSR_GH_WRITE_HELPER:=${_dsr_dir}/gh-write-helper.sh}"
unset _dsr_dir
DSR_STATE_OPEN="open"

# Replace #orig with #succ on "Blocked by" lines only (body on stdin).
_dsr_rewrite_body() {
	local orig="$1"
	local succ="$2"
	sed -E "/[Bb]locked[- ][Bb]y/ s/#${orig}([^0-9]|\$)/#${succ}\\1/g"
	return $?
}

# Repoint one dependant from a superseded original to its open successor.
# Args: $1 repo, $2 dependant number, $3 original, $4 successor
# Returns: 0 on success or no-op; 1 on a failed read or write.
dsr_repoint_dependant() {
	local repo="$1"
	local dependant="$2"
	local orig="$3"
	local succ="$4"
	local issue_json="" state="" body="" new_body="" succ_id="" edges="" body_file="" changed=false
	[[ "$repo" == */* && "$dependant" =~ ^[1-9][0-9]*$ && "$orig" =~ ^[1-9][0-9]*$ && "$succ" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$dependant" != "$succ" && "$dependant" != "$orig" ]] || return 0
	# Fresh REST reads: gh issue view can serve stale data right after writes.
	issue_json=$(gh api "repos/${repo}/issues/${dependant}" 2>/dev/null) || return 1
	state=$(printf '%s' "$issue_json" | jq -r '.state // ""') || return 1
	[[ "$state" == "$DSR_STATE_OPEN" ]] || return 0
	body=$(printf '%s' "$issue_json" | jq -r '.body // ""') || return 1
	edges=$(gh api "repos/${repo}/issues/${dependant}/dependencies/blocked_by" --jq '.[].number' 2>/dev/null) || return 1
	if ! printf '%s\n' "$edges" | grep -qx "$succ"; then
		succ_id=$(gh api "repos/${repo}/issues/${succ}" --jq '.id' 2>/dev/null) || return 1
		[[ "$succ_id" =~ ^[0-9]+$ ]] || return 1
		gh api -X POST "repos/${repo}/issues/${dependant}/dependencies/blocked_by" -F "issue_id=${succ_id}" >/dev/null 2>&1 || return 1
		changed=true
	fi
	new_body=$(printf '%s' "$body" | _dsr_rewrite_body "$orig" "$succ") || return 1
	if [[ "$new_body" != "$body" ]]; then
		body_file=$(mktemp) || return 1
		printf '%s' "$new_body" >"$body_file"
		"$DSR_GH_WRITE_HELPER" issue edit "$dependant" --repo "$repo" --body-file "$body_file" >/dev/null 2>&1 || {
			rm -f "$body_file"
			return 1
		}
		rm -f "$body_file"
		changed=true
	fi
	if [[ "$changed" == true ]]; then
		body_file=$(mktemp) || return 1
		printf 'Blocker #%s was superseded by #%s; this issue now lists #%s as its blocker (GH#35130).\n' "$orig" "$succ" "$succ" >"$body_file"
		"$DSR_GH_WRITE_HELPER" issue comment "$dependant" --repo "$repo" --body-file "$body_file" >/dev/null 2>&1 || true
		rm -f "$body_file"
	fi
	return 0
}

# Consolidation path: repoint every open dependant of a just-superseded issue.
# Args: $1 repo, $2 original (closed), $3 successor (must be open)
# Returns: 0 when all dependants were handled; 1 on any failure.
dsr_repoint_dependants_of() {
	local repo="$1"
	local orig="$2"
	local succ="$3"
	local succ_state="" dependants="" dependant="" failed=0
	[[ "$repo" == */* && "$orig" =~ ^[1-9][0-9]*$ && "$succ" =~ ^[1-9][0-9]*$ ]] || return 1
	succ_state=$(gh api "repos/${repo}/issues/${succ}" --jq '.state' 2>/dev/null) || return 1
	[[ "$succ_state" == "$DSR_STATE_OPEN" ]] || return 1
	dependants=$(gh api --paginate "repos/${repo}/issues/${orig}/dependencies/blocking" --jq ".[] | select(.state == \"${DSR_STATE_OPEN}\") | .number" 2>/dev/null) || return 1
	while IFS= read -r dependant; do
		[[ -n "$dependant" ]] || continue
		dsr_repoint_dependant "$repo" "$dependant" "$orig" "$succ" || failed=$((failed + 1))
	done <<<"$dependants"
	[[ "$failed" -eq 0 ]]
	return $?
}

# Sweep path: when every native blocker of a dependant is closed and at least
# one was superseded by an open successor, repoint it. Same-repo blockers only.
# Args: $1 repo, $2 dependant number
# Returns: 0 when nothing failed; 1 on a failed read or write.
dsr_repoint_if_superseded() {
	local repo="$1"
	local dependant="$2"
	local owner="${repo%%/*}" name="${repo#*/}" result="" nodes="" nrepo="" nnum="" nreason="" succ="" failed=0
	[[ "$repo" == */* && "$dependant" =~ ^[1-9][0-9]*$ ]] || return 1
	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
	result=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){blockedBy(first:100){nodes{number state stateReason repository{nameWithOwner}}pageInfo{hasNextPage}}}}}' -F o="$owner" -F r="$name" -F n="$dependant" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -e '.data.repository.issue.blockedBy
		| (.pageInfo.hasNextPage == false) and ((.nodes | length) > 0) and all(.nodes[]; .state == "CLOSED")' >/dev/null 2>&1 || return 0
	nodes=$(printf '%s' "$result" | jq -r '.data.repository.issue.blockedBy.nodes[] | "\(.repository.nameWithOwner) \(.number) \(.stateReason // "")"') || return 1
	while read -r nrepo nnum nreason; do
		[[ "$nrepo" == "$repo" ]] || continue
		succ=$(dep_supersession_open_successor "$repo" "$nnum" "$nreason") || continue
		dsr_repoint_dependant "$repo" "$dependant" "$nnum" "$succ" || failed=$((failed + 1))
	done <<<"$nodes"
	[[ "$failed" -eq 0 ]]
	return $?
}
