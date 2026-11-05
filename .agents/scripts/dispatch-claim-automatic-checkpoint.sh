#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Automatic checkpoint eligibility plus the existing distributed claim protocol.

_dch_automatic_checkpoint_snapshot() {
	local issue="$1" repo="$2" pr="$3" head="$4" ref="$5" runner="$6" session="$7"
	local owner="$8" author="$9" released="${10}" lease="${11:-}"
	local pr_json="" issue_json="" comments=""
	pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,body,isDraft,isCrossRepository,labels,headRefName,headRefOid,author,closingIssuesReferences) || return 1
	issue_json=$(gh api "repos/${repo}/issues/${issue}") || return 1
	comments=$(_dch_issue_comments "$issue" "$repo") || return 1
	jq -e --argjson issue "$issue" --arg owner "$owner" '
		.number == $issue and [.assignees[].login] == (if $owner == "" then [] else [$owner] end)' \
		<<<"$issue_json" >/dev/null || return 1
	_pr_checkpoint_pr_metadata_is_eligible "$pr_json" "$repo" "$pr" "$issue" "$head" "$ref" "$author" || return 1
	_pr_checkpoint_automatic_target "$repo" "$pr_json" "$issue_json" "$comments" "$runner" \
		"$session" "$lease" true "$owner" "$released"
	return $?
}

cmd_claim_automatic_pr_checkpoint() {
	local issue="${1:-}" repo="${2:-}" pr="${3:-}" head="${4:-}" ref="${5:-}" runner="${6:-}" session="${7:-}"
	local owner="${8:-}" author="${9:-}" released="${10:-false}"
	local before="" after="" nonce="" comment_id="" claims="" snapshot="" status="" expires=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40,64}$ &&
		-n "$ref" && "$runner" =~ ^[A-Za-z0-9._-]+$ && "$session" =~ ^[A-Za-z0-9._-]+$ &&
		"$author" =~ ^[A-Za-z0-9._-]+$ && "$released" =~ ^(true|false)$ ]] || return 2
	[[ "$(_resolve_runner "")" == "$runner" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	if declare -F _interactive_claim_fence_blocks_dispatch >/dev/null 2>&1 &&
		_interactive_claim_fence_blocks_dispatch "$issue" "$repo"; then
		return 1
	fi
	local -a target=("$issue" "$repo" "$pr" "$head" "$ref" "$runner" "$session" "$owner" "$author" "$released")
	before=$(_dch_automatic_checkpoint_snapshot "${target[@]}") || return 1
	snapshot=$(jq -er '.snapshot' <<<"$before") || return 1
	status=$(jq -er '.previous_status' <<<"$before") || return 1
	nonce=$(_generate_nonce) || return 1
	comment_id=$(_post_claim "$issue" "$repo" "$runner" "$nonce" "$(_now_utc)" \
		"checkpoint_mode=automatic checkpoint_snapshot=${snapshot} checkpoint_owner=${owner:-none} checkpoint_status=${status}" \
		"$session") || return 1
	sleep "$DISPATCH_CLAIM_WINDOW"
	claims=$(_fetch_claims "$issue" "$repo" "$runner") || return 1
	_resolve_claim_race_result "$issue" "$repo" "$runner" "$nonce" "$comment_id" "$claims" >/dev/null || return 1
	# Re-read before any assignment transfer. Only the winning claim and its
	# immutable admission snapshot may explain the changed comment history.
	if ! after=$(_dch_automatic_checkpoint_snapshot "${target[@]}" "$nonce") ||
		[[ "$(jq -r '.snapshot' <<<"$after")" != "$snapshot" ]] ||
		{ declare -F _interactive_claim_fence_blocks_dispatch >/dev/null 2>&1 &&
			_interactive_claim_fence_blocks_dispatch "$issue" "$repo"; }; then
		_delete_losing_claim_comment "$repo" "$comment_id"
		return 1
	fi
	expires=$(jq -er --arg n "$nonce" '[.[] | select(.nonce == $n)][0].lease_expires_at | numbers' <<<"$claims") || return 1
	jq -c --arg lease "$nonce" --arg session "$session" --arg device "$(_resolve_device_id)" --argjson id "$comment_id" --argjson expires "$expires" \
		'. + {mode:"automatic",lease:$lease,session:$session,device:$device,claim_id:$id,prelaunch_expires_at:$expires}' <<<"$after"
	return 0
}

_dch_verify_automatic_checkpoint() {
	local repo="$1" pr_json="$2" issue_json="$3" pr="$4" issue="$5" head="$6" ref="$7" runner="$8" author="$9"
	local comments="" result=""
	[[ "$(_resolve_runner "")" == "$runner" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	_pr_checkpoint_pr_metadata_is_eligible "$pr_json" "$repo" "$pr" "$issue" "$head" "$ref" "$author" || return 1
	comments=$(_dch_issue_comments "$issue" "$repo") || return 2
	result=$(_pr_checkpoint_automatic_target "$repo" "$pr_json" "$issue_json" "$comments" "$runner" \
		"${AIDEVOPS_PR_CHECKPOINT_SESSION:-}" "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" false "$runner") || return 1
	[[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" ]] || return 1
	jq -e '.claim_id | numbers' <<<"$result" >/dev/null || return 1
	printf 'PR_CHECKPOINT_TARGET_VALID: automatic_checkpoint pr=#%s issue=#%s\n' "$pr" "$issue"
	return 0
}
