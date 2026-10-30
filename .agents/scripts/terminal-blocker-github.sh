#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# REST-first recovery reads; GraphQL has an independent rate-limit budget.
# Callers retain their stage deadlines and treat every failed read as incomplete.

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

terminal_blocker_search_issues() {
	local query="$1" response=""
	if response=$(gh api -X GET search/issues -f q="$query" --jq '.items[].number' 2>/dev/null); then
		printf '%s\n' "$response"
		return 0
	fi
	# shellcheck disable=SC2016
	response=$(gh api graphql --paginate --slurp \
		-f query='query($q:String!,$endCursor:String){search(query:$q,type:ISSUE,first:100,after:$endCursor){nodes{... on Issue{number}}pageInfo{hasNextPage endCursor}}}' \
		-f q="$query" 2>/dev/null) || return 1
	printf '%s' "$response" | jq -er '
		arrays | select(length > 0) |
		select(all(.[]; (.errors // [] | length) == 0 and (.data.search.nodes | type) == "array")) |
		select(.[-1].data.search.pageInfo.hasNextPage == false) |
		[.[].data.search.nodes[].number] | join("\n")' || return 1
	return 0
}
