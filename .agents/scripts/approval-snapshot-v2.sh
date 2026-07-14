#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# approval-snapshot-v2.sh — deterministic content/head snapshots for approvals.

[[ -n "${_APPROVAL_SNAPSHOT_V2_LOADED:-}" ]] && return 0
_APPROVAL_SNAPSHOT_V2_LOADED=1

_approval_snapshot_v2_fetch_pages() {
	local endpoint="$1"
	local pages=""

	pages=$(gh api "$endpoint" --paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$pages" | jq -e 'type == "array" and all(.[]; type == "array")' >/dev/null 2>&1 || return 1
	printf '%s\n' "$pages"
	return 0
}

_approval_snapshot_v2_comments_json() {
	local pages_json="$1"
	local excluded_comment_id="${2:-}"
	local source_name="${3:-conversation}"

	# #aidevops:trust-boundary — exclude the exact approval comment whose
	# signature is being verified plus the strict trusted-association lifecycle
	# audit written after verification. Marker text is attacker-controlled:
	# excluding arbitrary marker comments would let an external contributor hide
	# later drift by copying the marker into an unsigned comment.
	jq -cS --arg excluded "$excluded_comment_id" --arg source "$source_name" '
		[.[][]?
		| select((.id | tostring) != $excluded)
		| select((.user.type // "") != "Bot")
		| select((
			((.author_association // "") == "OWNER" or (.author_association // "") == "MEMBER" or (.author_association // "") == "COLLABORATOR")
			and ((.body // "") | startswith("<!-- aidevops-signed-approval -->\n<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — "))
			and ((.body // "") | contains(") -->\nAuto-approved: "))
			and ((.body // "") | contains(". Stale recovery tick reset."))
		) | not)
		| {
			source: $source,
			id: .id,
			node_id: (.node_id // ""),
			author: {
				id: (.user.id // null),
				node_id: (.user.node_id // ""),
				login: (.user.login // ""),
				type: (.user.type // "")
			},
			author_association: (.author_association // ""),
			created_at: (.created_at // ""),
			updated_at: (.updated_at // .created_at // ""),
			body: (.body // ""),
			path: (.path // null),
			line: (.line // null),
			side: (.side // null),
			commit_id: (.commit_id // null),
			original_commit_id: (.original_commit_id // null)
		}
		] | sort_by(.source, .id)
	' <<<"$pages_json"
	return $?
}

_approval_snapshot_v2_linked_references_json() {
	local pages_json="$1"

	# GitHub timeline cross-reference events are the authoritative read-only
	# projection of issue/PR links. Keep external text and URLs as opaque bytes;
	# this helper never follows or executes them.
	jq -cS '
		[.[][]?
		| select((.event // "") == "cross-referenced" or (.event // "") == "connected" or (.event // "") == "disconnected" or (.event // "") == "referenced")
		| {
			event: (.event // ""),
			id: (.id // null),
			node_id: (.node_id // ""),
			created_at: (.created_at // ""),
			updated_at: (.updated_at // .created_at // ""),
			actor: {
				id: (.actor.id // null),
				node_id: (.actor.node_id // ""),
				login: (.actor.login // ""),
				type: (.actor.type // "")
			},
			commit_id: (.commit_id // ""),
			commit_url: (.commit_url // ""),
			source: (if (.source.issue // null) == null then null else {
				kind: (if (.source.issue.pull_request // null) == null then "issue" else "pr" end),
				repository: ((.source.issue.repository.full_name // "") | ascii_downcase),
				number: (.source.issue.number // null),
				id: (.source.issue.id // null),
				node_id: (.source.issue.node_id // ""),
				title: (.source.issue.title // ""),
				body: (.source.issue.body // ""),
				state: (.source.issue.state // ""),
				updated_at: (.source.issue.updated_at // ""),
				author: {
					id: (.source.issue.user.id // null),
					node_id: (.source.issue.user.node_id // ""),
					login: (.source.issue.user.login // ""),
					type: (.source.issue.user.type // "")
				}
			} end)
		}
		] | sort_by(.created_at, .event, .id)
	' <<<"$pages_json"
	return $?
}

_approval_snapshot_v2_reviews_json() {
	local pages_json="$1"

	jq -cS '
		[.[][]?
		| select((.user.type // "") != "Bot")
		| {
			id: .id,
			node_id: (.node_id // ""),
			author: {
				id: (.user.id // null),
				node_id: (.user.node_id // ""),
				login: (.user.login // ""),
				type: (.user.type // "")
			},
			author_association: (.author_association // ""),
			state: (.state // ""),
			commit_id: (.commit_id // ""),
			submitted_at: (.submitted_at // ""),
			body: (.body // "")
		}
		] | sort_by(.id)
	' <<<"$pages_json"
	return $?
}

approval_snapshot_v2_build() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local excluded_comment_id="${4:-}"
	local issue_json="" comments_pages="" comments_json="" timeline_pages="" linked_references_json="" normalized_slug=""

	[[ "$target_type" == "issue" || "$target_type" == "pr" ]] || return 1
	[[ "$target_number" =~ ^[0-9]+$ && "$slug" == */* ]] || return 1
	normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')

	issue_json=$(gh api "repos/${slug}/issues/${target_number}" 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -e 'type == "object" and (.id != null) and (.node_id != null)' >/dev/null 2>&1 || return 1
	if [[ "$target_type" == "pr" ]]; then
		printf '%s' "$issue_json" | jq -e 'has("pull_request")' >/dev/null 2>&1 || return 1
	else
		printf '%s' "$issue_json" | jq -e 'has("pull_request") | not' >/dev/null 2>&1 || return 1
	fi

	comments_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/comments?per_page=100") || return 1
	comments_json=$(_approval_snapshot_v2_comments_json "$comments_pages" "$excluded_comment_id" "conversation") || return 1
	timeline_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/timeline?per_page=100") || return 1
	linked_references_json=$(_approval_snapshot_v2_linked_references_json "$timeline_pages") || return 1

	if [[ "$target_type" == "issue" ]]; then
		jq -cS -n --arg repo "$normalized_slug" --argjson number "$target_number" \
			--argjson issue "$issue_json" --argjson comments "$comments_json" \
			--argjson linked_references "$linked_references_json" '
			{
				schema: "aidevops-approval-snapshot/v2",
				target: {kind: "issue", repository: $repo, number: $number, id: $issue.id, node_id: $issue.node_id},
				author: {
					id: ($issue.user.id // null), node_id: ($issue.user.node_id // ""),
					login: ($issue.user.login // ""), type: ($issue.user.type // ""),
					association: ($issue.author_association // "")
				},
				created_at: ($issue.created_at // ""),
				title: ($issue.title // ""),
				body: ($issue.body // ""),
				comments: $comments,
				linked_references: $linked_references
			}
		'
		return $?
	fi

	local pr_json="" review_comment_pages="" review_comments_json="" review_pages="" reviews_json=""
	pr_json=$(gh api "repos/${slug}/pulls/${target_number}" 2>/dev/null) || return 1
	printf '%s' "$pr_json" | jq -e 'type == "object" and (.id != null) and (.node_id != null) and ((.head.sha // "") != "") and ((.base.ref // "") != "")' >/dev/null 2>&1 || return 1
	review_comment_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/pulls/${target_number}/comments?per_page=100") || return 1
	review_comments_json=$(_approval_snapshot_v2_comments_json "$review_comment_pages" "" "review") || return 1
	review_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/pulls/${target_number}/reviews?per_page=100") || return 1
	reviews_json=$(_approval_snapshot_v2_reviews_json "$review_pages") || return 1

	jq -cS -n --arg repo "$normalized_slug" --argjson number "$target_number" \
		--argjson issue "$issue_json" --argjson pr "$pr_json" \
		--argjson comments "$comments_json" --argjson review_comments "$review_comments_json" \
		--argjson reviews "$reviews_json" --argjson linked_references "$linked_references_json" '
		{
			schema: "aidevops-approval-snapshot/v2",
			target: {kind: "pr", repository: $repo, number: $number, id: $pr.id, node_id: $pr.node_id, issue_id: $issue.id},
			author: {
				id: ($pr.user.id // null), node_id: ($pr.user.node_id // ""),
				login: ($pr.user.login // ""), type: ($pr.user.type // ""),
				association: ($pr.author_association // "")
			},
			created_at: ($pr.created_at // ""),
			title: ($pr.title // ""),
			body: ($pr.body // ""),
			head: {
				sha: $pr.head.sha, ref: ($pr.head.ref // ""),
				repository_id: ($pr.head.repo.id // null), repository: (($pr.head.repo.full_name // "") | ascii_downcase)
			},
			base: {
				ref: $pr.base.ref,
				repository_id: ($pr.base.repo.id // null), repository: (($pr.base.repo.full_name // $repo) | ascii_downcase)
			},
			comments: $comments,
			review_comments: $review_comments,
			reviews: $reviews,
			linked_references: $linked_references
		}
	'
	return $?
}

approval_snapshot_v2_digest() {
	local snapshot_json="$1"
	local digest=""

	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$snapshot_json" | sha256sum | awk '{print $1}') || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$snapshot_json" | shasum -a 256 | awk '{print $1}') || return 1
	else
		return 1
	fi
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

approval_snapshot_v2_payload() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local issued_at="$4"
	local excluded_comment_id="${5:-}"
	local snapshot_json="" digest="" normalized_slug=""

	snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$excluded_comment_id") || return 1
	digest=$(approval_snapshot_v2_digest "$snapshot_json") || return 1
	normalized_slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	jq -cS -n --arg type "$target_type" --arg repo "$normalized_slug" --argjson number "$target_number" \
		--arg issued "$issued_at" --arg digest "$digest" --argjson snapshot "$snapshot_json" '
		{
			schema: "aidevops-approval/v2",
			authority: (if $type == "pr" then "merge" else "development" end),
			issued_at: $issued,
			target: {kind: $type, repository: $repo, number: $number},
			snapshot_sha256: $digest,
			pr: (if $type == "pr" then {
				head_sha: $snapshot.head.sha,
				head_ref: $snapshot.head.ref,
				head_repository: $snapshot.head.repository,
				base_ref: $snapshot.base.ref,
				base_repository: $snapshot.base.repository
			} else null end)
		}
	'
	return $?
}
