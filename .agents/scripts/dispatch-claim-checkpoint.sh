#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by dispatch-claim-helper.sh; revised checkpoints use the same claim
# producer, consensus and lease transitions, never an assignment-guard bypass.

# GH#38104: device-local ledger of this device's own open revision-checkpoint
# prelaunch claims, so the expired-claim sweep costs O(own expired claims)
# instead of scanning every worker draft in every repo. It is a discovery hint
# only: every release still passes the full fences in cmd_sweep_pr_checkpoint_claim.
_dch_ledger_file() {
	printf '%s' "${AIDEVOPS_CHECKPOINT_CLAIM_LEDGER:-${HOME}/.aidevops/state/checkpoint-claims.jsonl}"
	return 0
}

# Args: repo issue claim_id nonce session expires_at. Best effort: a missing
# entry only means the fallback repo rotation discovers the claim instead.
_dch_ledger_add() {
	local repo="$1" issue="$2" claim_id="$3" token="$4" session="$5" expires_at="$6" file="" line=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$claim_id" =~ ^[1-9][0-9]*$ && "$expires_at" =~ ^[1-9][0-9]*$ ]] || return 0
	file=$(_dch_ledger_file)
	line=$(jq -nc --arg repo "$repo" --argjson issue "$issue" --argjson claim_id "$claim_id" \
		--arg nonce "$token" --arg session "$session" --argjson expires_at "$expires_at" \
		'{repo:$repo,issue:$issue,claim_id:$claim_id,nonce:$nonce,session:$session,expires_at:$expires_at}') || return 0
	(
		umask 077
		mkdir -p "${file%/*}" && printf '%s\n' "$line" >>"$file" && chmod 600 "$file"
	) 2>/dev/null || true
	return 0
}

# Rewrite the ledger through a jq filter over parsed entries (malformed lines are
# dropped). Args: jq filter, then optional jq --arg/--argjson pairs.
_dch_ledger_rewrite() {
	local filter="$1" file="" tmp=""
	shift
	file=$(_dch_ledger_file)
	[[ -f "$file" ]] || return 0
	tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
	if jq -Rc "$@" "fromjson? | ${filter}" "$file" >"$tmp" 2>/dev/null; then
		chmod 600 "$tmp" 2>/dev/null || true
		mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
	return 0
}

_dch_ledger_remove_nonce() {
	local token="${1:-}"
	[[ -n "$token" ]] || return 0
	# shellcheck disable=SC2016 # jq variables, not shell expansions
	_dch_ledger_rewrite 'select(.nonce != $n)' --arg n "$token"
	return 0
}

# Args: nonce, new expires_at (renewal can only extend the deadline).
_dch_ledger_update_expiry() {
	local token="${1:-}" expires="${2:-}"
	[[ -n "$token" && "$expires" =~ ^[1-9][0-9]*$ ]] || return 0
	# shellcheck disable=SC2016 # jq variables, not shell expansions
	_dch_ledger_rewrite 'if .nonce == $n and .expires_at < $e then .expires_at = $e else . end' \
		--arg n "$token" --argjson e "$expires"
	return 0
}

# Keep the ledger in step with a lease transition: renewal extends the deadline;
# ready or terminal ends the prelaunch claim. Args: phase, lease token, expires_at.
_dch_ledger_sync_transition() {
	local phase="$1" token="$2" expires="$3"
	if [[ "$phase" == "$LEASE_PHASE_PRELAUNCH" ]]; then
		_dch_ledger_update_expiry "$token" "$expires"
	else
		_dch_ledger_remove_nonce "$token"
	fi
	return 0
}

#aidevops:trust-boundary — the ledger only nominates candidates; the release path
# revalidates identity, device, session, live executor and the live timeline.
# No GitHub reads happen unless an entry has expired. Arg: optional stop epoch.
cmd_sweep_checkpoint_ledger() {
	local stop="${1:-0}" file="" now="" due="" repo="" issue="" token="" session="" rc=0
	[[ "$stop" =~ ^[0-9]+$ ]] || return 2
	file=$(_dch_ledger_file)
	[[ -s "$file" ]] || return 0
	now=$(_now_epoch) || return 0
	# Entries stuck for over a week are dropped; the repo rotation still covers them.
	# shellcheck disable=SC2016 # jq variables, not shell expansions
	_dch_ledger_rewrite 'select(.expires_at + 604800 >= $now)' --argjson now "$now"
	due=$(jq -Rr --argjson now "$now" 'fromjson? | select((.expires_at | type) == "number" and .expires_at < $now
		and (.repo | type) == "string" and (.issue | type) == "number")
		| [.repo, (.issue | tostring), .nonce, .session] | @tsv' "$file" 2>/dev/null) || return 0
	[[ -n "$due" ]] || return 0
	while IFS=$'\t' read -r repo issue token session; do
		[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ &&
			"$token" =~ ^[A-Za-z0-9._-]+$ && "$session" =~ ^[A-Za-z0-9._-]+$ ]] || continue
		[[ "$stop" -eq 0 || "$(date +%s)" -lt "$stop" ]] || break
		_dch_session_has_live_executor "$session" && continue
		DCH_SWEEP_FAILED=0
		rc=0
		cmd_sweep_pr_checkpoint_claim "$issue" "$repo" 0 || rc=$?
		# GH#38144: one line per expired entry so a stranded claim is diagnosable
		# from pulse.log (the pulse stage appends this stdout there). `released`
		# also covers a claim the live timeline shows as already closed.
		if [[ "$rc" -eq 0 && "$DCH_SWEEP_FAILED" -eq 0 ]]; then
			_dch_ledger_remove_nonce "$token"
			printf 'CHECKPOINT_LEDGER_SWEEP outcome=released issue=%s repo=%s session=%s\n' "$issue" "$repo" "$session"
		else
			printf 'CHECKPOINT_LEDGER_SWEEP outcome=retained issue=%s repo=%s session=%s rc=%s release_failed=%s\n' \
				"$issue" "$repo" "$session" "$rc" "$DCH_SWEEP_FAILED"
		fi
	done <<<"$due"
	return 0
}

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
		"checkpoint_mode=revision checkpoint_approval=${approval_id}" "$session") || return 1
	sleep "$DISPATCH_CLAIM_WINDOW"
	if ! claims=$(_fetch_claims "$issue" "$repo" "$runner"); then
		printf 'PR_CHECKPOINT_CLAIM_FAILED stage=consensus_read issue=%s repo=%s claim_id=%s\n' "$issue" "$repo" "$comment_id" >&2
		# Release only if the prelaunch lease has already expired. Otherwise the
		# owning pulse retries after expiry; a premature release cannot authorize
		# a fresh approval and would leave the history invalid.
		cmd_sweep_pr_checkpoint_claim "$issue" "$repo" || true
		return 1
	fi
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
	_dch_ledger_add "$repo" "$issue" "$comment_id" "$nonce" "$session" "$expires_at"
	jq --arg lease "$nonce" --arg session "$session" --arg device "$(_resolve_device_id)" --argjson expires "$expires_at" --argjson claim_id "$comment_id" \
		'{lease:$lease,session:$session,device:$device,claim_id:$claim_id,approval_id,previous_assignee,previous_status,prelaunch_expires_at:$expires}' <<<"$approval"
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

#aidevops:trust-boundary — only the authenticated runner's own device can
# recover an expired revision claim, with a fresh timeline check at the write.
DCH_SWEEP_FAILED=0
cmd_sweep_pr_checkpoint_claim() {
	local issue="${1:-}" repo="${2:-}" stop="${3:-0}" runner="" device="" comments candidates=""
	local id="" nonce="" session="" release="" attempted=0
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
	[[ "$stop" =~ ^[0-9]+$ ]] || return 2
	runner=$(_resolve_runner "") || return 1
	device=$(_resolve_device_id) || return 1
	[[ -n "$runner" && -n "$device" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	comments=$(_fetch_claim_marker_comments "$issue" "$repo") || return 1
	candidates=$(jq -r --arg runner "$runner" --arg device "$device" --arg phase "$LEASE_PHASE_PRELAUNCH" '
		def fields: [scan("([a-z_]+)=([^ ]+)") | {key: .[0], value: .[1]}] | from_entries;
		.[] | select(.author == $runner and (.author_association | test("^(OWNER|MEMBER|COLLABORATOR)$")))
		| . as $c | .body | split("\n")[] | select(startswith("DISPATCH_CLAIM ")) | fields
		| select(.runner == $runner and .device == $device and .phase == $phase
			and .checkpoint_mode == "revision" and (.checkpoint_approval // "") != "")
		| [($c.id | tostring), .nonce, .session] | @tsv
	' <<<"$comments") || return 1
	while IFS=$'\t' read -r id nonce session; do
		[[ "$id" =~ ^[1-9][0-9]*$ && "$nonce" =~ ^[A-Za-z0-9._-]+$ && "$session" =~ ^[A-Za-z0-9._-]+$ ]] || continue
		_dch_orphan_release_valid "$comments" "$comments" "$id" "$nonce" "$runner" "$device" "$session" || continue
		_dch_session_has_live_executor "$session" && continue
		[[ "$stop" -eq 0 || "$(date +%s)" -lt "$stop" ]] || break
		attempted=$((attempted + 1))
		release=$(jq -nc --argjson id "$id" --arg nonce "$nonce" --arg runner "$runner" \
			'[{id:$id,nonce:$nonce,claim_author:$runner}]') || return 1
		AIDEVOPS_PR_CHECKPOINT_SESSION="$session" _post_orphan_claim_release "$issue" "$repo" "$runner" "$release" "$comments" ||
			DCH_SWEEP_FAILED=1
		[[ "$attempted" -lt 10 ]] || break
	done <<<"$candidates"
	return 0
}

DCH_EXPIRED_READY_REASON="expired_ready_lease_reconciled"

# GH#36544: select the caller's own unedited checkpoint claim whose ready lease
# expired without a terminal lease. Ordinary releases require explicit opt-in. Prints
# `claim_id<TAB>token<TAB>attempt<TAB>open|released`, or one `deny:<reason>`.
# `released` means an accepted release exists and only the terminal is missing.
_dch_expired_ready_claim() {
	local comments="$1" runner="$2" claim_id="$3" session="$4" device="$5" now="$6"
	local complete_released="${7:-false}"
	jq -r --arg runner "$runner" --argjson claim_id "$claim_id" --arg session "$session" \
		--arg device "$device" --argjson now "$now" --arg reason "$DCH_EXPIRED_READY_REASON" \
		--argjson complete_released "$complete_released" '
		def fields: [scan("(?:^|\\s)([a-z_]+)=([^\\s]+)") | {key: .[0], value: .[1]}] | from_entries;
		def own: .user.login == $runner and (.updated_at // .created_at) == .created_at
			and (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR"));
		def event: test("(^|\n)(DISPATCH_CLAIM |DISPATCH_LEASE |CLAIM_RELEASED |Dispatching worker)");
		def lines($prefix): split("\n")[] | select(startswith($prefix));
		def releases: lines("CLAIM_RELEASED ");
		def norm: if . == null or . == "" or . == "attempt:" or . == "unknown" then ""
			elif startswith("attempt:") then . else "attempt:" + . end;
		def deny($reason): "deny:" + $reason;
		def identity_mismatch: deny("identity_mismatch");
		def bound($token): any(.body | split("\n")[] | fields | (.lease_token, .nonce); . == $token);
		def recovery: own and (.body | [releases | fields
			| select(.reason == $reason and .claim_id == ($claim_id | tostring))] | length == 1);
		# Explicit recovery never accepts an identity-less or ambiguous ordinary release.
		def ordinary_release($token; $attempt): own and (.body | [releases] | length == 1)
			and (.body | releases | fields
			| (.reason | IN("blocked", "clean", "worker_complete")) and .runner == $runner
			and .claim_id == ($claim_id | tostring) and .nonce == $token and .lease_token == $token
			and .device == $device and .session == $session
			and ((.attempt_id // $attempt) | norm) == $attempt);
		[.[][]] as $all
		| [$all[] | select(.id == $claim_id)] as $matches
		| [$matches[].body | lines("DISPATCH_CLAIM ") | fields] as $cf
		| if ($matches | length) != 1 or ($cf | length) != 1 then deny("claim_unmatched")
		else $matches[0] as $c | $cf[0] as $f | ($f.lease_token // "") as $token
		| if ($c | own | not) or $f.runner != $runner or $token == "" or $f.nonce != $token
			or $f.session != $session or $f.device != $device then identity_mismatch
		elif ($f.checkpoint_approval // "") == "" then deny("not_checkpoint_claim")
		else [$all[] | select(.id > $claim_id and (.body | event))] as $later
		| [$later[] | select(bound($token))] as $mine
		| [$later[] | select(recovery)] as $recoveries
		| [$mine[].body | lines("DISPATCH_LEASE ") | fields] as $leases
		| [$leases[] | select(.phase == "ready")] as $ready
		| ($ready | last // {} | .attempt_id | norm) as $attempt
		| (if $complete_released then [$mine[] | select(ordinary_release($token; $attempt))]
			else [] end) as $ordinary
		| ($recoveries + $ordinary) as $closers
		| [$f, $leases[] | .expires_at // ""] as $expiries
		| if any($later[]; (bound($token) | not) and (recovery | not)) then deny("later_coordination")
		elif any($mine[]; own | not) or any($leases[]; .lease_token != $token or .session != $session
			or .device != $device or (.phase | IN("prelaunch", "ready", "terminal") | not))
			then identity_mismatch
		elif any($leases[]; .phase == "terminal") then deny("already_terminal")
		# Default behavior stays strict. Explicit mode permits one fully bound
		# ordinary release, after all the episode events, without replacing it.
		elif ([$mine[] | select(.body | test("(^|\n)CLAIM_RELEASED "))] | length) != ($ordinary | length)
			or ($closers | length) > 1
			or (($closers | length) == 1 and ($closers[0].id <=
				([$mine[] | select(.id != $closers[0].id) | .id] | max // $claim_id)))
			then deny("already_released")
		elif ($recoveries | length) == 1 and
			([$recoveries[0].body | releases | fields | .attempt_id | norm][0] != $attempt)
			then deny("already_released")
		elif $complete_released and ($closers | length) == 0 then deny("not_released")
		elif $complete_released and (any($leases[]; (.attempt_id | norm) != $attempt)
			or any($mine[] | select(.body | test("(^|\n)Dispatching worker")); .body | fields
				| .session != $session or .device != $device or (.attempt_id | norm) != $attempt))
			then identity_mismatch
		elif ($ready | length) == 0 then deny("not_ready")
		elif $attempt == "" then deny("attempt_unknown")
		# Unknown expiry is never treated as elapsed; the lease predicate keeps it active.
		elif any($expiries[]; test("^[1-9][0-9]*$") | not) then deny("expiry_unknown")
		elif ($expiries | map(tonumber) | max) >= $now then deny("lease_live")
		else [($c.id | tostring), $token, $attempt,
			(if ($closers | length) == 1 then "released" else "open" end)] | @tsv
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
	local complete_released="${6:-false}"
	comments=$(_dch_issue_comments "$issue" "$repo") || return 1
	_dch_expired_ready_claim "$comments" "$runner" "$claim_id" "$session" \
		"$(_resolve_device_id)" "$(_now_epoch)" "$complete_released"
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
# Explicit --complete-released accepts only a fully bound supported release and
# appends its missing terminal, never a replacement release or approval.
cmd_close_expired_pr_checkpoint_lease() {
	local issue="${1:-}" repo="${2:-}" claim_id="${3:-}" session="${4:-}"
	local runner="" result="" token="" attempt="" state="" device=""
	local option="${5:-}" complete_released="false"
	[[ $# -le 5 ]] || return 2
	case "$option" in
	"") ;;
	--complete-released) complete_released="true" ;;
	*) return 2 ;;
	esac
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
	result=$(_dch_expired_ready_decision "$issue" "$repo" "$runner" "$claim_id" "$session" "$complete_released") || return 1
	if [[ "$result" == deny:* || -z "$result" ]]; then
		printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=%s\n' "${result#deny:}" >&2
		return 1
	fi
	IFS=$'\t' read -r _ token attempt state <<<"$result"
	if [[ "$state" == open ]]; then
		_dch_post_issue_event "$issue" "$repo" "CLAIM_RELEASED reason=${DCH_EXPIRED_READY_REASON} runner=${runner} ts=$(_now_utc) claim_id=${claim_id} attempt_id=${attempt} device=${device} session=${session}" || return 1
	fi
	# Recheck shutdown and the same complete identity at the final write boundary,
	# including when an ordinary release already existed before this invocation.
	if _dch_session_has_live_executor "$session"; then
		printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=executor_live\n' >&2
		return 1
	fi
	result=$(_dch_expired_ready_decision "$issue" "$repo" "$runner" "$claim_id" "$session" "$complete_released") || return 1
	if [[ "$result" == deny:* ]]; then
		printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=%s\n' "${result#deny:}" >&2
		return 1
	fi
	if [[ "$result" != "${claim_id}"$'\t'"${token}"$'\t'"${attempt}"$'\t'released ]]; then
		printf 'PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=history_changed\n' >&2
		return 1
	fi
	_dch_post_issue_event "$issue" "$repo" "DISPATCH_LEASE phase=terminal lease_token=${token} device=${device} session=${session} expires_at=0 ts=$(_now_utc) attempt_id=${attempt}" || return 1
	printf 'PR_CHECKPOINT_LEASE_CLOSED claim_id=%s attempt=%s\n' "$claim_id" "$attempt"
	return 0
}
