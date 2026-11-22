#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Require positive body-edit evidence, including when REST timestamps match:
# their second resolution cannot exclude a same-second edit. Missing/partial
# GraphQL evidence never authorizes a coordination write or state projection.
_hrff_release_comment_edits() {
	local raw="$1" ids="" chunk="" id="" response="" clean="[]"
	local pattern="${2:-(?m)^(DISPATCH_CLAIM|DISPATCH_LEASE|CLAIM_RELEASED) }"
	local query="query(\$ids: [ID!]!) { nodes(ids: \$ids) { ... on IssueComment { id lastEditedAt } } }"
	local -a args=()
	ids=$(jq -r --arg pattern "$pattern" '[.[][] | select((.body // "") | test($pattern)) |
		select((.node_id // "") | test("^[A-Za-z0-9_=-]+$")) |
		.node_id] | unique | . as $ids | range(0; length; 50) | $ids[.:.+50] | join(" ")' <<<"$raw" 2>/dev/null) || return 1
	while IFS= read -r chunk; do
		[[ -n "$chunk" ]] || continue
		args=()
		for id in $chunk; do args+=(-f "ids[]=${id}"); done
		response=$(gh api graphql -f query="$query" "${args[@]}" 2>/dev/null) || continue
		clean=$(jq -ec --argjson previous "$clean" '
			select((.errors // []) | length == 0) |
			$previous + [.data.nodes[]? | select(.id != null and has("lastEditedAt") and .lastEditedAt == null) | .id]
		' <<<"$response" 2>/dev/null) || continue
	done <<<"$ids"
	jq -c --argjson clean "$clean" 'map(map(.node_id as $id |
		._release_body_unedited = ($id != null and ($clean | index($id)) != null)
	))' <<<"$raw" 2>/dev/null || return 1
	return 0
}

# Read-only snapshot check; a worker context is not proof of an owned claim.
# projection_line is nonempty only after this invocation persisted that exact
# bound release. A new claim or ambiguous event prevents lifecycle projection.
_hrff_check_release_claim() {
	local issue_number="$1" repo_slug="$2" runner_name="$3" session_key="$4"
	local projection_line="${5:-}"
	local token="${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}"
	local device="${AIDEVOPS_DISPATCH_LEASE_DEVICE:-${AIDEVOPS_DEVICE_ID:-}}"
	local session="${AIDEVOPS_DISPATCH_LEASE_SESSION:-$session_key}"
	local comments="" result="" verdict=""
	local filter="${BASH_SOURCE[0]%/*}/dispatch-release-claim.jq"
	_HRFF_RELEASE_CLAIM_OWNED=0
	_HRFF_RELEASE_CLAIM_ID=""
	if [[ -z "$token" || -z "$device" || -z "$session" ]]; then
		print_info "Skipped coordination release for #${issue_number}: no bound dispatch claim context"
		return 0
	fi
	if ! comments=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" --paginate --slurp 2>/dev/null) ||
		! comments=$(_hrff_release_comment_edits "$comments"); then
		print_warning "Claim evidence unavailable for #${issue_number}; retaining issue lifecycle state"
		return 1
	fi
	if ! result=$(jq -ec --arg token "$token" --arg runner "$runner_name" \
		--arg device "$device" --arg session "$session" --arg projection_line "$projection_line" \
		-f "$filter" <<<"$comments" 2>/dev/null); then
		print_warning "Claim evidence unreadable for #${issue_number}; retaining issue lifecycle state"
		return 1
	fi
	verdict=$(jq -r '.verdict' <<<"$result") || return 1
	case "$verdict" in
	owned)
		_HRFF_RELEASE_CLAIM_ID=$(jq -er '.claim_id | tostring' <<<"$result") || return 1
		_HRFF_RELEASE_CLAIM_OWNED=1
		return 0
		;;
	unowned | released | terminal | superseded)
		print_info "Skipped coordination release for #${issue_number}: no current unreleased matching dispatch claim"
		return 0
		;;
	*)
		print_warning "Claim evidence ambiguous or edited for #${issue_number}; retaining issue lifecycle state"
		return 1
		;;
	esac
}
