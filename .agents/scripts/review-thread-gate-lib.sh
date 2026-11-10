#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Review-thread gate -- unresolved review-bot thread count (GH#27137)
# =============================================================================
# Sourced by full-loop-helper-readiness.sh so `full-loop-helper.sh merge`
# enforces the same unresolved review-bot thread rule as the deterministic
# pulse merge pass (pulse-merge-required-checks.sh
# _pmrc_snapshot_review_threads_clear). Keep the bot pattern in sync.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_REVIEW_THREAD_GATE_LIB_LOADED:-}" ]] && return 0
_REVIEW_THREAD_GATE_LIB_LOADED=1

# Same bot set as the pulse snapshot (gemini-code-assist retained for history).
_RTG_BOT_RE="coderabbitai|gemini-code-assist|augment-code|augmentcode|copilot"

#######################################
# Count unresolved review threads opened by review bots.
# Args: $1=repo slug (owner/name), $2=PR number
# Stdout: integer count
# Returns: 0=count produced, 1=query/parse error or truncated page (fail closed)
#######################################
review_thread_gate_unresolved_bot_count() {
	local repo_slug="$1"
	local pr_number="$2"
	local owner="${repo_slug%%/*}" name="${repo_slug##*/}" response="" has_next="" count=""

	[[ -n "$owner" && -n "$name" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	# shellcheck disable=SC2016 # GraphQL query, not shell interpolation.
	response=$(gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) {
					reviewThreads(first: 100) {
						pageInfo { hasNextPage }
						nodes { isResolved comments(first: 1) { nodes { author { login } } } }
					}
				}
			}
		}
	' 2>/dev/null) || return 1
	[[ -n "$response" ]] || return 1
	printf '%s' "$response" | jq -e 'try (.data.repository.pullRequest != null) catch false' >/dev/null 2>&1 || return 1
	has_next=$(printf '%s' "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false') || return 1
	[[ "$has_next" == "false" ]] || return 1
	printf '%s' "$response" | jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array" and all(.[]; type == "object")' >/dev/null 2>&1 || return 1
	count=$(printf '%s' "$response" | jq -r --arg bots "$_RTG_BOT_RE" '
		[.data.repository.pullRequest.reviewThreads.nodes[]?
		| select((.isResolved // false) == false)
		| select((.comments.nodes[0].author.login // "") | test($bots; "i"))
		] | length
	') || return 1
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
	return 0
}
