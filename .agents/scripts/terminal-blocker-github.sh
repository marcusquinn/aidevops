#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# REST-first recovery reads; GraphQL has an independent rate-limit budget.
# Callers retain their stage deadlines and treat every failed read as incomplete.

# Read a small queue window in one round trip. No search index, comments or
# persistent cache: any partial/error response rejects the entire window.
terminal_blocker_fetch_issue_batch() {
	local query="query {" response="" index=0
	while [[ "$#" -ge 2 ]]; do
		local repo="$1" issue="$2"
		shift 2
		[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
		query+="r${index}:repository(owner:\"${repo%%/*}\",name:\"${repo#*/}\"){nameWithOwner i:issue(number:${issue}){number title body state updatedAt labels(first:100){nodes{name}pageInfo{hasNextPage}}}}"
		index=$((index + 1))
	done
	[[ "$#" -eq 0 && "$index" -gt 0 && "$index" -le 4 ]] || return 1
	response=$(gh api graphql -f query="${query}}" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -ce --argjson expected "$index" '
		select((.errors // [] | length) == 0) | .data | objects |
		select(length == $expected) |
		select(all(.[]; . != null and (.i | type) == "object" and
			(.i.labels.pageInfo.hasNextPage == false))) |
		[.[] | {key:((.nameWithOwner | ascii_downcase | sub("/"; "--")) + "--" + (.i.number | tostring)),
			value:(.i | {number,title,body,state:(.state | ascii_downcase),updated_at:.updatedAt,labels:.labels.nodes})}] |
		from_entries' || return 1
	return 0
}

# Only the supervisor supplies a same-window snapshot; releases and rearm
# continue to call the fresh-read helper without a batch.
terminal_blocker_fetch_queue_issue() {
	local repo="$1" issue="$2" batch_file="$3" response=""
	if [[ -n "$batch_file" ]]; then
		response=$(jq -ce --arg key "${repo//\//--}--${issue}" '.[$key | ascii_downcase] | objects' "$batch_file" 2>/dev/null) || response=""
	fi
	if [[ -n "$response" ]]; then
		printf '%s\n' "$response"
		return 0
	fi
	terminal_blocker_fetch_issue "$repo" "$issue" || return 1
	return 0
}

terminal_blocker_fetch_issue() {
	local repo="$1" issue="$2" response=""
	if response=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null); then
		printf '%s\n' "$response"
		return 0
	fi
	# shellcheck disable=SC2016
	response=$(gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){number title body state updatedAt labels(first:100){nodes{name}pageInfo{hasNextPage}}}}}' \
		-F owner="${repo%%/*}" -F name="${repo#*/}" -F number="$issue" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -ce '
		select((.errors // [] | length) == 0) | .data.repository.issue |
		select(. != null and (.labels.pageInfo.hasNextPage == false)) |
		{number,title,body,state:(.state | ascii_downcase),updated_at:.updatedAt,labels:.labels.nodes}' || return 1
	return 0
}

terminal_blocker_fetch_comments() {
	local repo="$1" issue="$2" response=""
	if response=$(gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate --slurp 2>/dev/null); then
		printf '%s\n' "$response"
		return 0
	fi
	# gh follows endCursor until the entire connection has been read. Buffer all
	# pages: an error on a later page must never look like absent hold evidence.
	# shellcheck disable=SC2016
	response=$(gh api graphql --paginate --slurp \
		-f query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){issue(number:$number){comments(first:100,after:$endCursor){nodes{fullDatabaseId author{login} authorAssociation body createdAt}pageInfo{hasNextPage endCursor}}}}}' \
		-F owner="${repo%%/*}" -F name="${repo#*/}" -F number="$issue" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -ce '
		# Validate BigInt text before conversion can round an unsafe integer.
		# Abort the whole read rather than silently dropping ordering evidence.
		def comment_id:
			(if type == "string" or type == "number" then tostring else "" end) |
			if test("^[1-9][0-9]*$") and
				(length < 16 or (length == 16 and . <= "9007199254740991"))
			then tonumber else error("invalid comment fullDatabaseId") end;
		arrays | select(length > 0) |
		select(all(.[]; (.errors // [] | length) == 0 and
			(.data.repository.issue.comments.nodes | type) == "array")) |
		select(.[-1].data.repository.issue.comments.pageInfo.hasNextPage == false) |
		[.[].data.repository.issue.comments.nodes[] |
			{id:(.fullDatabaseId | comment_id),user:{login:(.author.login // "")},author_association:.authorAssociation,
			 body,created_at:.createdAt}]' || return 1
	return 0
}

# GH#36114: search returns 30 items per page by default. Read every page and
# treat GitHub's incomplete_results flag as a failed read, never as absence.
# Args: query, jq formatter for one item.
_terminal_blocker_rest_search() {
	local query="$1" format="$2"
	gh api -X GET search/issues --paginate -f q="$query" -f per_page=100 \
		--jq 'if .incomplete_results then error("incomplete search results") else .items[] | '"$format"' end' \
		2>/dev/null || return 1
	return 0
}

# GraphQL fallback: buffer every page; an error or truncation on any page fails
# the whole read. Args: query, Issue node fields, jq formatter for one node.
_terminal_blocker_graphql_search() {
	local query="$1" fields="$2" format="$3" response=""
	# shellcheck disable=SC2016
	response=$(gh api graphql --paginate --slurp \
		-f query='query($q:String!,$endCursor:String){search(query:$q,type:ISSUE,first:100,after:$endCursor){nodes{... on Issue{'"$fields"'}}pageInfo{hasNextPage endCursor}}}' \
		-f q="$query" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -er '
		arrays | select(length > 0) |
		select(all(.[]; (.errors // [] | length) == 0 and (.data.search.nodes | type) == "array")) |
		select(.[-1].data.search.pageInfo.hasNextPage == false) |
		[.[].data.search.nodes[] | select(.number != null) | '"$format"'] | join("\n")' || return 1
	return 0
}

terminal_blocker_search_issues() {
	local query="$1" response=""
	if response=$(_terminal_blocker_rest_search "$query" '.number'); then
		printf '%s\n' "$response"
		return 0
	fi
	_terminal_blocker_graphql_search "$query" number '.number' || return 1
	return 0
}

# Cross-repository form for owner-scoped intake (GH#36114). Prints one
# "owner/repo<TAB>number<TAB>updated_at" line per issue.
terminal_blocker_search_issue_refs() {
	local query="$1" response=""
	if response=$(_terminal_blocker_rest_search "$query" \
		'"\(.repository_url | sub("^.*/repos/"; ""))\t\(.number)\t\(.updated_at)"'); then
		printf '%s\n' "$response"
		return 0
	fi
	_terminal_blocker_graphql_search "$query" 'number updatedAt repository{nameWithOwner}' \
		'"\(.repository.nameWithOwner)\t\(.number)\t\(.updatedAt)"' || return 1
	return 0
}
