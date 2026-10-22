#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by dispatch-claim-helper.sh; revised checkpoints use the same claim
# producer, consensus and lease transitions, never an assignment-guard bypass.

_dch_checkpoint_snapshot() {
	local issue="$1" repo="$2" pr="$3" head="$4" ref="$5" runner="$6" session="$7"
	local lease="${8:-}" pr_json="" issue_json="" comments=""
	pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,body,isDraft,isCrossRepository,labels,headRefName,headRefOid,author,closingIssuesReferences) || return 1
	issue_json=$(gh api "repos/${repo}/issues/${issue}") || return 1
	comments=$(gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate --slurp) || return 1
	jq -e --argjson issue "$issue" '.number == $issue' <<<"$issue_json" >/dev/null || return 1
	jq -e --argjson pr "$pr" --arg head "$head" --arg ref "$ref" \
		'.number == $pr and .headRefOid == $head and .headRefName == $ref' <<<"$pr_json" >/dev/null || return 1
	_pr_checkpoint_revised_target "$repo" "$pr_json" "$issue_json" "$comments" "$runner" "$lease" "$session" true |
		jq --argjson issue "$issue_json" '. + {previous_assignee:($issue.assignees[0].login // ""),
		previous_status:([$issue.labels[].name | select(startswith("status:"))][0] | sub("^status:";""))}'
	return $?
}

#aidevops:trust-boundary — exact approved release replaces only the generic
# assigned-draft predicate. Interactive fences and distributed consensus remain.
cmd_claim_pr_checkpoint() {
	local issue="${1:-}" repo="${2:-}" pr="${3:-}" head="${4:-}" ref="${5:-}" runner="${6:-}" session="${7:-}"
	local approval="" after="" nonce="" comment_id="" claims="" approval_id="" race_output="" expires_at=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40,64}$ &&
		"$runner" =~ ^[A-Za-z0-9._-]+$ && "$session" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
	[[ "$(_resolve_runner "")" == "$runner" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	if declare -F _interactive_claim_fence_blocks_dispatch >/dev/null 2>&1 &&
		_interactive_claim_fence_blocks_dispatch "$issue" "$repo"; then
		return 1
	fi
	approval=$(_dch_checkpoint_snapshot "$issue" "$repo" "$pr" "$head" "$ref" "$runner" "$session") || return 1
	approval_id=$(jq -r '.approval_id' <<<"$approval") || return 1
	nonce=$(_generate_nonce) || return 1
	comment_id=$(_post_claim "$issue" "$repo" "$runner" "$nonce" "$(_now_utc)" \
		"checkpoint_approval=${approval_id}" "$session") || return 1
	sleep "$DISPATCH_CLAIM_WINDOW"
	claims=$(_fetch_claims "$issue" "$repo" "$runner") || return 1
	if ! race_output=$(_resolve_claim_race_result "$issue" "$repo" "$runner" "$nonce" "$comment_id" "$claims"); then
		return 1
	fi
	# Fresh reread after consensus rejects revision/head/owner drift and any newer
	# worker or human event, including a competing claim from this same account.
	if ! after=$(_dch_checkpoint_snapshot "$issue" "$repo" "$pr" "$head" "$ref" "$runner" "$session" "$nonce") ||
		[[ "$after" != "$approval" ]] ||
		{ declare -F _interactive_claim_fence_blocks_dispatch >/dev/null 2>&1 &&
			_interactive_claim_fence_blocks_dispatch "$issue" "$repo"; }; then
		_delete_losing_claim_comment "$repo" "$comment_id"
		return 1
	fi
	# GH#35331: expose the prelaunch deadline so an interactive executor renews
	# (transition prelaunch) before the claim-only orphan grace expires.
	expires_at=$(jq -r --arg n "$nonce" '[.[] | select(.nonce == $n)][0].lease_expires_at // 0' <<<"$claims") || expires_at=0
	[[ "$expires_at" =~ ^[0-9]+$ ]] || expires_at=0
	jq --arg lease "$nonce" --arg session "$session" --argjson expires "$expires_at" \
		'{lease:$lease,session:$session,approval_id,previous_assignee,previous_status,prelaunch_expires_at:$expires}' <<<"$approval"
	return 0
}

# Select the caller's own unedited, never-ready, expired checkpoint claim.
# Prints its comment ID, or one allowlisted `deny:<reason>` token.
_dch_abort_claim_id() {
	local comments="$1" runner="$2" lease="$3" session="$4" device="$5" now="$6"
	jq -r --arg runner "$runner" --arg lease "$lease" --arg session "$session" \
		--arg device "$device" --argjson now "$now" '
		def fields: [scan("(?:^|\\s)([a-z_]+)=([^\\s]+)") | {key: .[0], value: .[1]}] | from_entries;
		def own: .user.login == $runner and (.updated_at // .created_at) == .created_at
			and (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR"));
		def event_lines: .body | split("\n")[] | select(test("^(DISPATCH_CLAIM|DISPATCH_LEASE|CLAIM_RELEASED) "));
		[.[][]] as $all
		| [$all[] | . as $c | event_lines | select(startswith("DISPATCH_CLAIM ")) | fields
			| select(.nonce == $lease) | {c: $c, f: .}] as $claims
		| if ($claims | length) != 1 then "deny:claim_unmatched"
		else $claims[0] as $claim
		| if ($claim.c | own | not) or $claim.f.runner != $runner or $claim.f.lease_token != $lease
			or $claim.f.session != $session or $claim.f.device != $device then "deny:identity_mismatch"
		elif ($claim.f.checkpoint_approval // "") == "" then "deny:not_checkpoint_claim"
		else [$all[] | select(.id > $claim.c.id) | select(.body | contains($lease))] as $later
		| if any($later[]; own | not) then "deny:identity_mismatch"
		elif any($later[]; .body | test("(^|\n)CLAIM_RELEASED ")) then "deny:already_released"
		elif any($later[]; .body | test("(^|\n)Dispatching worker")) then "deny:launched"
		else [$later[] | event_lines | fields] as $leases
		| [$claim.f, $leases[] | .expires_at // ""] as $expiries
		| if ($claim.f.phase // "") != "prelaunch"
			or any($leases[]; .phase != "prelaunch" or .lease_token != $lease or .session != $session)
			then "deny:not_prelaunch"
		# Unknown expiry is never treated as elapsed; the lease predicate keeps it active.
		elif any($expiries[]; test("^[1-9][0-9]*$") | not) then "deny:expiry_unknown"
		elif ($expiries | map(tonumber) | max) >= $now then "deny:lease_live"
		else ($claim.c.id | tostring) end end end end' <<<"$comments"
	return $?
}

#aidevops:trust-boundary — GH#35331: only the authenticated claim owner, on the
# claiming device and session, may close its own expired never-ready checkpoint
# claim. The existing claim-only release grants nothing: continuation still
# requires a fresh approval whose released_successors binds this closed episode.
cmd_abort_pr_checkpoint_claim() {
	local issue="${1:-}" repo="${2:-}" lease="${3:-}" session="${4:-}"
	local runner="" comments="" result="" release=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
		"$lease" =~ ^[A-Za-z0-9._-]+$ && "$session" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
	runner=$(_resolve_runner "") || return 1
	[[ -n "$runner" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	comments=$(gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate --slurp) || return 1
	result=$(_dch_abort_claim_id "$comments" "$runner" "$lease" "$session" \
		"$(_resolve_device_id)" "$(_now_epoch)") || return 1
	if [[ ! "$result" =~ ^[0-9]+$ ]]; then
		printf 'PR_CHECKPOINT_ABORT_DENIED reason=%s\n' "${result#deny:}" >&2
		return 1
	fi
	release=$(jq -nc --argjson id "$result" --arg nonce "$lease" --arg runner "$runner" \
		'[{id: $id, nonce: $nonce, claim_author: $runner}]') || return 1
	_post_orphan_claim_release "$issue" "$repo" "$runner" "$release" || return 1
	printf 'PR_CHECKPOINT_CLAIM_ABORTED claim_id=%s\n' "$result"
	return 0
}
