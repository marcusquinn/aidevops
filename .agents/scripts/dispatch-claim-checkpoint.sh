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
	comments=$(_dch_issue_comments "$issue" "$repo") || return 1
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
	jq --arg lease "$nonce" --arg session "$session" --argjson expires "$expires_at" --argjson claim_id "$comment_id" \
		'{lease:$lease,session:$session,claim_id:$claim_id,approval_id,previous_assignee,previous_status,prelaunch_expires_at:$expires}' <<<"$approval"
	return 0
}

# Print every issue comment as slurped REST pages.
_dch_issue_comments() {
	local issue="$1" repo="$2"
	gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate --slurp
	return $?
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
	comments=$(_dch_issue_comments "$issue" "$repo") || return 1
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

DCH_EXPIRED_READY_REASON="expired_ready_lease_reconciled"

# GH#36544: select the caller's own unedited checkpoint claim whose ready lease
# expired without any release or terminal lease. Prints
# `claim_id<TAB>token<TAB>attempt<TAB>open|released`, or one `deny:<reason>`.
# `released` means this command's own recovery release already exists and only
# the terminal lease is missing (an interrupted earlier run).
_dch_expired_ready_claim() {
	local comments="$1" runner="$2" claim_id="$3" session="$4" device="$5" now="$6"
	jq -r --arg runner "$runner" --argjson claim_id "$claim_id" --arg session "$session" \
		--arg device "$device" --argjson now "$now" --arg reason "$DCH_EXPIRED_READY_REASON" '
		def fields: [scan("(?:^|\\s)([a-z_]+)=([^\\s]+)") | {key: .[0], value: .[1]}] | from_entries;
		def own: .user.login == $runner and (.updated_at // .created_at) == .created_at
			and (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR"));
		def event: test("(^|\n)(DISPATCH_CLAIM |DISPATCH_LEASE |CLAIM_RELEASED |Dispatching worker)");
		def lines($prefix): split("\n")[] | select(startswith($prefix));
		def norm: if . == null or . == "" or . == "attempt:" or . == "unknown" then ""
			elif startswith("attempt:") then . else "attempt:" + . end;
		def deny($reason): "deny:" + $reason;
		def bound($token): any(.body | split("\n")[] | fields | (.lease_token, .nonce); . == $token);
		def recovery: own and (.body | [lines("CLAIM_RELEASED ") | fields
			| select(.reason == $reason and .claim_id == ($claim_id | tostring))] | length == 1);
		[.[][]] as $all
		| [$all[] | select(.id == $claim_id)] as $matches
		| [$matches[].body | lines("DISPATCH_CLAIM ") | fields] as $cf
		| if ($matches | length) != 1 or ($cf | length) != 1 then deny("claim_unmatched")
		else $matches[0] as $c | $cf[0] as $f | ($f.lease_token // "") as $token
		| if ($c | own | not) or $f.runner != $runner or $token == "" or $f.nonce != $token
			or $f.session != $session or $f.device != $device then deny("identity_mismatch")
		elif ($f.checkpoint_approval // "") == "" then deny("not_checkpoint_claim")
		else [$all[] | select(.id > $claim_id and (.body | event))] as $later
		| [$later[] | select(bound($token))] as $mine
		| [$later[] | select(recovery)] as $recoveries
		| [$mine[].body | lines("DISPATCH_LEASE ") | fields] as $leases
		| [$leases[] | select(.phase == "ready")] as $ready
		| ($ready | last // {} | .attempt_id | norm) as $attempt
		| [$f, $leases[] | .expires_at // ""] as $expiries
		| if any($later[]; (bound($token) | not) and (recovery | not)) then deny("later_coordination")
		elif any($mine[]; own | not) or any($leases[]; .lease_token != $token or .session != $session
			or .device != $device or (.phase | IN("prelaunch", "ready", "terminal") | not))
			then deny("identity_mismatch")
		elif any($leases[]; .phase == "terminal") then deny("already_terminal")
		# Only one recovery release from this command, after every lease and for the
		# same attempt, may already exist; any other release closed the attempt.
		elif any($mine[]; .body | test("(^|\n)CLAIM_RELEASED ")) or ($recoveries | length) > 1
			or (($recoveries | length) == 1 and (($recoveries[0].id < ($mine | map(.id) | max))
				or ([$recoveries[0].body | lines("CLAIM_RELEASED ") | fields | .attempt_id | norm][0]
					!= $attempt)))
			then deny("already_released")
		elif ($ready | length) == 0 then deny("not_ready")
		elif $attempt == "" then deny("attempt_unknown")
		# Unknown expiry is never treated as elapsed; the lease predicate keeps it active.
		elif any($expiries[]; test("^[1-9][0-9]*$") | not) then deny("expiry_unknown")
		elif ($expiries | map(tonumber) | max) >= $now then deny("lease_live")
		else [($c.id | tostring), $token, $attempt,
			(if ($recoveries | length) == 1 then "released" else "open" end)] | @tsv
		end end end' <<<"$comments"
	return $?
}

# Exit 0 when a local process still runs with `--session-key SESSION` exactly.
# Optional $2 supplies process arguments (one process per line) for tests.
_dch_session_has_live_executor() {
	local session="$1" processes="${2-}"
	if [[ $# -lt 2 ]]; then
		processes=$(ps -eo args= 2>/dev/null) || return 0 # unknown is live
	fi
	awk -v session="$session" '
		{ for (i = 1; i < NF; i++) if ($i == "--session-key" && $(i + 1) == session) found = 1 }
		END { exit(found ? 0 : 1) }' <<<"$processes"
	return $?
}

_dch_expired_ready_decision() {
	local issue="$1" repo="$2" runner="$3" claim_id="$4" session="$5" comments=""
	comments=$(_dch_issue_comments "$issue" "$repo") || return 1
	_dch_expired_ready_claim "$comments" "$runner" "$claim_id" "$session" \
		"$(_resolve_device_id)" "$(_now_epoch)"
	return $?
}

_dch_post_issue_event() {
	local issue="$1" repo="$2" line="$3"
	gh api "$(_issue_comments_endpoint "$repo" "$issue")" --method POST --field body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
${line}
<!-- ops:end -->" >/dev/null 2>&1
	return $?
}

#aidevops:trust-boundary — GH#36544: only the authenticated claim owner, on the
# claiming device and session, may close its own checkpoint attempt whose ready
# lease expired without a release or terminal lease, and only when no local
# process still runs that session. It appends one release and one terminal
# lease; published events are never edited. The closed attempt grants nothing:
# continuation still needs a fresh approval whose released_successors binds it.
cmd_close_expired_pr_checkpoint_lease() {
	local issue="${1:-}" repo="${2:-}" claim_id="${3:-}" session="${4:-}"
	local runner="" result="" token="" attempt="" state="" device=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
		"$claim_id" =~ ^[1-9][0-9]*$ && "$session" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
	runner=$(_resolve_runner "") || return 1
	[[ -n "$runner" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	if _dch_session_has_live_executor "$session"; then
		printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=executor_live\n' >&2
		return 1
	fi
	device=$(_resolve_device_id) || return 1
	result=$(_dch_expired_ready_decision "$issue" "$repo" "$runner" "$claim_id" "$session") || return 1
	if [[ "$result" == deny:* || -z "$result" ]]; then
		printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=%s\n' "${result#deny:}" >&2
		return 1
	fi
	IFS=$'\t' read -r _ token attempt state <<<"$result"
	if [[ "$state" == open ]]; then
		_dch_post_issue_event "$issue" "$repo" "CLAIM_RELEASED reason=${DCH_EXPIRED_READY_REASON} runner=${runner} ts=$(_now_utc) claim_id=${claim_id} attempt_id=${attempt} device=${device} session=${session}" || return 1
		# Re-read at the write boundary: only this command's release may follow.
		result=$(_dch_expired_ready_decision "$issue" "$repo" "$runner" "$claim_id" "$session") || return 1
		if [[ "$result" != "${claim_id}"$'\t'*$'\t'released ]]; then
			printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=%s\n' "${result#deny:}" >&2
			return 1
		fi
	fi
	_dch_post_issue_event "$issue" "$repo" "DISPATCH_LEASE phase=terminal lease_token=${token} device=${device} session=${session} expires_at=0 ts=$(_now_utc) attempt_id=${attempt}" || return 1
	printf 'PR_CHECKPOINT_LEASE_CLOSED claim_id=%s attempt=%s\n' "$claim_id" "$attempt"
	return 0
}
