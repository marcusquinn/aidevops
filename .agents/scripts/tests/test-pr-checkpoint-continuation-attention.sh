#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-pr-checkpoint-continuation-helper.sh; relies on its fixtures.
# shellcheck disable=SC2154  # fixtures and variables are defined by sibling modules

# t18869: an attended draft is re-checked each cycle; one new record per changed
# template refusal reason, none when the reason is unchanged.
test_refusal_reason_change() (
	local STUB_POST_DIR="${TEST_ROOT}/posts-refusal" template_reason="" status=0 output="" body=""
	export STUB_POST_DIR
	mkdir -p "$STUB_POST_DIR"
	_pcc_approval_template() {
		[[ -n "$template_reason" ]] || { printf 'CHECKPOINT_CONTINUATION_APPROVED {}\n'; return 0; }
		printf 'approval-template: intervening coordination is not fully released; rejected comment=9 event=CLAIM_RELEASED runner=worker-bot episode_claim=none reason=%s\n' "$template_reason" >&2
		return 1
	}
	STUB_PR_JSON="$(valid_pr_json)"
	STUB_COMMENTS_JSON="$(blocked_comments)"
	output=$(_pcc_blocked_attention owner/repo 123 42) || status=1
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:* && "$(post_count)" == 1 ]] || status=1
	body="$(<"${STUB_POST_DIR}/post-1")"
	[[ "$body" != *"Diagnostic (metadata only):"* ]] || status=1
	STUB_COMMENTS_JSON="$(jq --arg body "$body" '. + [[{id:22,author_association:"OWNER",user:{login:"pulse-runner"},body:$body}]]' <<<"$(blocked_comments)")"
	# Unchanged (no refusal): exists, no repost.
	output=$(_pcc_blocked_attention owner/repo 123 42) || status=1
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_EXISTS:* && "$(post_count)" == 1 ]] || status=1
	# New refusal reason: exactly one new record naming the command.
	template_reason="transition_rejected"
	output=$(_pcc_blocked_attention owner/repo 123 42) || status=1
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*refusal=transition_rejected && "$(post_count)" == 2 ]] || status=1
	grep -Fq 'approval-template owner/repo 42 123 21 attempt:abc123' "${STUB_POST_DIR}/post-2" || status=1
	body="$(<"${STUB_POST_DIR}/post-2")"
	STUB_COMMENTS_JSON="$(jq --arg body "$body" '. + [[{id:23,author_association:"OWNER",user:{login:"pulse-runner"},body:$body}]]' <<<"$STUB_COMMENTS_JSON")"
	# Same reason next cycle: no repost.
	output=$(_pcc_blocked_attention owner/repo 123 42) || status=1
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_EXISTS:* && "$(post_count)" == 2 ]] || status=1
	# Reason changes again: one more record.
	template_reason="unattributed_release"
	output=$(_pcc_blocked_attention owner/repo 123 42) || status=1
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*refusal=unattributed_release && "$(post_count)" == 3 ]] || status=1
	# A refusal already present at first publication must be visible, not only
	# baselined in a hidden dedup marker.
	STUB_COMMENTS_JSON="$(blocked_comments)"
	output=$(_pcc_blocked_attention owner/repo 123 42) || status=1
	body="$(<"${STUB_POST_DIR}/post-4")"
	[[ "$body" == *"Diagnostic (metadata only): intervening coordination"* &&
		"$body" == *"reason=unattributed_release"* ]] || status=1
	[[ "$status" == 0 ]] || return 1
	return 0
)
if test_refusal_reason_change; then
	print_result "changed approval-template refusal reposts once; unchanged reason does not" 0
else
	print_result "changed approval-template refusal reposts once; unchanged reason does not" 1
fi
STUB_POST_DIR="${TEST_ROOT}/posts"
STUB_PR_JSON="$(valid_pr_json)"

# GH#33839: production launchers close the released attempt's lease with a
# terminal DISPATCH_LEASE after CLAIM_RELEASED. That is not new ownership.
closing_lease_comments() {
	local terminal_login="$1" terminal_lease="$2"
	blocked_comments ",
  {\"id\":19,\"created_at\":\"2026-09-30T00:59:00Z\",\"author_association\":\"COLLABORATOR\",\"user\":{\"login\":\"worker-bot\"},\"body\":\"DISPATCH_LEASE phase=prelaunch lease_token=closing-lease session=s1\"},
  {\"id\":24,\"created_at\":\"2026-09-30T01:10:40Z\",\"author_association\":\"COLLABORATOR\",\"user\":{\"login\":\"${terminal_login}\"},\"body\":\"<!-- ops:start -->\\nDISPATCH_LEASE phase=terminal lease_token=${terminal_lease} session=s1 expires_at=0\\n<!-- ops:end -->\"}"
	return 0
}
STUB_COMMENTS_JSON="$(closing_lease_comments worker-bot closing-lease)"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*release=21 && "$(post_count)" == 2 ]]; then
	print_result "released attempt's own terminal lease does not suppress blocked attention" 0
else
	print_result "released attempt's own terminal lease does not suppress blocked attention" 1 "output=${output:-missing} posts=$(post_count)"
fi
for foreign_case in "worker-bot unseen-lease" "other-runner closing-lease"; do
	read -r foreign_login foreign_lease <<<"$foreign_case"
	STUB_COMMENTS_JSON="$(closing_lease_comments "$foreign_login" "$foreign_lease")"
	if ! _pcc_blocked_attention owner/repo 123 42 >/dev/null && [[ "$(post_count)" == 2 ]]; then
		print_result "terminal lease from ${foreign_login}/${foreign_lease} still counts as ownership" 0
	else
		print_result "terminal lease from ${foreign_login}/${foreign_lease} still counts as ownership" 1 "posts=$(post_count)"
	fi
done

# GH#35683: a later claim released as blocked before any ready lease must not be
# paired with the checkpoint attempt; name the checkpoint's own release instead.
STUB_POST_DIR="${TEST_ROOT}/posts-never-ready"
mkdir -p "$STUB_POST_DIR"
never_ready_comments() {
	closing_lease_comments worker-bot closing-lease | jq '. + [[
		{id:30,created_at:"2026-09-30T02:00:00Z",author_association:"COLLABORATOR",user:{login:"worker-bot"},
			body:"DISPATCH_CLAIM nonce=claimb runner=worker-bot session=s2 phase=prelaunch expires_at=1"},
		{id:31,created_at:"2026-09-30T02:05:00Z",author_association:"COLLABORATOR",user:{login:"worker-bot"},
			body:"<!-- ops:start -->\nCLAIM_RELEASED reason=blocked runner=worker-bot ts=2026-09-30T02:05:00Z\n\nTerminal blocker: reason=permission_required owner=permission-maintainer task=123 attempt=abcdef0123456789.\n<!-- ops:end -->"}
	]]'
	return 0
}
STUB_COMMENTS_JSON="$(never_ready_comments)"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*release=21 && "$(post_count)" == 1 ]] &&
	grep -Fq 'approval-template owner/repo 42 123 21 attempt:abc123' "${STUB_POST_DIR}/post-1" &&
	grep -Fq 'Newer release comment 31 closed a claim that never reached a ready lease' "${STUB_POST_DIR}/post-1" &&
	! grep -Fq 'approval-template owner/repo 42 123 31' "${STUB_POST_DIR}/post-1"; then
	print_result "never-ready blocked release names the checkpoint's own release and attempt" 0
else
	print_result "never-ready blocked release names the checkpoint's own release and attempt" 1 "output=${output:-missing} posts=$(post_count)"
fi
STUB_COMMENTS_JSON="$(never_ready_comments | jq 'map(map(select(.id != 19 and .id != 20)))')"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*release=31 && "$(post_count)" == 2 ]] &&
	grep -Fq 'No approval template is offered' "${STUB_POST_DIR}/post-2" &&
	! grep -Fq 'approval-template owner/repo' "${STUB_POST_DIR}/post-2"; then
	print_result "unpaired never-ready blocked release posts no approval template" 0
else
	print_result "unpaired never-ready blocked release posts no approval template" 1 "output=${output:-missing} posts=$(post_count)"
fi

# GH#35932: production comments are `gh --paginate --slurp` pages. A runner
# capability release keeps the runner-owner text (GH#35788) on that input and
# never asks the brief owner for a revision-bound approval.
STUB_POST_DIR="${TEST_ROOT}/posts-capability"
mkdir -p "$STUB_POST_DIR"
STUB_COMMENTS_JSON="$(blocked_comments | jq -c 'map(map(if .id == 21 then
	.body |= sub("\n<!-- ops:end -->"; "\n\nTerminal blocker: reason=runner_capability_unmet owner=runner-recovery task=123 attempt=a1.\n<!-- ops:end -->")
	else . end))')"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*release=21 && "$(post_count)" == 1 ]] &&
	grep -Fq 'No brief change or revision-bound approval is needed' "${STUB_POST_DIR}/post-1" &&
	! grep -Fq 'approval-template' "${STUB_POST_DIR}/post-1"; then
	print_result "paginated capability release keeps runner-owner attention text" 0
else
	print_result "paginated capability release keeps runner-owner attention text" 1 "output=${output:-missing} posts=$(post_count)"
fi
STUB_POST_DIR="${TEST_ROOT}/posts"

# GH#33850: releases by another trusted runner must reach an attention outcome
# through the existing Pulse entrypoint, without dispatching. GH#36019: that
# now covers every reason dispatch-stalled cannot continue (clean and
# worker_complete and capability_limit moved to bounded exact-head continuation).
for completed_reason in worker_failed unknown_exit; do
	STUB_COMMENTS_JSON="$(closing_lease_comments worker-bot closing-lease | jq --arg reason "$completed_reason" '
		map(map(if .id == 21 then .body = ("CLAIM_RELEASED reason=" + $reason + " runner=pulse-runner") |
			.user.login = "pulse-runner" else . end))')"
	before_posts="$(post_count)"
	if output=$(_pcc_blocked_attention owner/repo 123 42) &&
		[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:*reason="${completed_reason}" &&
			"$(post_count)" == "$((before_posts + 1))" ]]; then
		print_result "${completed_reason} release from another runner gets attention despite closing terminal lease" 0
	else
		print_result "${completed_reason} release gets attention" 1 "output=${output:-missing}"
	fi
	completed_body="$(<"${STUB_POST_DIR}/post-$((before_posts + 1))")"
	if [[ "$completed_body" == *"verified merged replacement"* ]] &&
		! grep -Eq '^(DISPATCH_CLAIM |DISPATCH_LEASE |CLAIM_RELEASED |Dispatching worker|Interactive session claimed|CHECKPOINT_CONTINUATION_APPROVED |terminal-blocker-circuit:retry)' \
			"${STUB_POST_DIR}/post-$((before_posts + 1))"; then
		print_result "${completed_reason} attention is actionable without forging approval or ownership" 0
	else
		print_result "${completed_reason} attention is actionable without forging approval or ownership" 1
	fi
	STUB_COMMENTS_JSON="$(jq --arg body "$completed_body" --arg reason "$completed_reason" '. + [[
		{id:25,author_association:"OWNER",user:{login:"pulse-runner"},body:$body},
		{id:26,author_association:"OWNER",user:{login:"pulse-runner"},body:("CLAIM_RELEASED reason=" + $reason + " runner=pulse-runner")}
	]]' <<<"$STUB_COMMENTS_JSON")"
	if output=$(_pcc_blocked_attention owner/repo 123 42) &&
		[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_EXISTS:* && "$(post_count)" == "$((before_posts + 1))" ]]; then
		print_result "${completed_reason} attention deduplicates later releases at the same head" 0
	else
		print_result "${completed_reason} attention deduplicates later releases at the same head" 1
	fi
	new_head="2222222222222222222222222222222222222222"
	if evidence=$(_pcc_completed_release_evidence "$STUB_COMMENTS_JSON" "aidevops:blocked-checkpoint-attention pr=42 head=${new_head}") &&
		[[ "$evidence" == $'26\t'"${completed_reason}"$'\tfalse' ]]; then
		print_result "new head re-arms ${completed_reason} attention" 0
	else
		print_result "new head re-arms ${completed_reason} attention" 1
	fi
	for ownership_body in 'DISPATCH_CLAIM runner=pulse-runner' 'DISPATCH_LEASE phase=terminal lease_token=foreign'; do
		owned_comments="$(jq --arg body "$ownership_body" '. + [[
			{id:27,author_association:"OWNER",user:{login:"pulse-runner"},body:$body}
		]]' <<<"$STUB_COMMENTS_JSON")"
		if ! _pcc_completed_release_evidence "$owned_comments" key >/dev/null; then
			print_result "new ownership suppresses ${completed_reason} attention: ${ownership_body}" 0
		else
			print_result "new ownership suppresses ${completed_reason} attention" 1
		fi
	done
done
for invalid_release in untrusted mismatched_runner continuable_reason blocked_reason; do
	invalid_comments="$(blocked_comments | jq --arg invalid "$invalid_release" '
		map(map(if .id == 21 then .body = "CLAIM_RELEASED reason=capability_limit runner=worker-bot" |
			if $invalid == "untrusted" then .author_association = "NONE"
			elif $invalid == "mismatched_runner" then .user.login = "other-runner"
			elif $invalid == "continuable_reason" then .body = "CLAIM_RELEASED reason=worker_complete runner=worker-bot"
			else .body = "CLAIM_RELEASED reason=blocked runner=worker-bot" end
		else . end))')"
	if ! _pcc_completed_release_evidence "$invalid_comments" key >/dev/null; then
		print_result "completed attention rejects ${invalid_release}" 0
	else
		print_result "completed attention rejects ${invalid_release}" 1
	fi
done
unset STUB_POST_DIR

stall_comments() {
	local terminal_lease="$1"
	printf '[[
  {"id":30,"created_at":"2026-09-30T01:00:00Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"DISPATCH_LEASE phase=ready lease_token=stall-lease session=s1"},
  {"id":31,"created_at":"2026-09-30T01:30:00Z","author_association":"OWNER","user":{"login":"pulse-runner"},"body":"CLAIM_RELEASED reason=no_activity runner=pulse-runner ts=2026-09-30T01:30:00Z"},
  {"id":32,"created_at":"2026-09-30T01:30:40Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"DISPATCH_LEASE phase=terminal lease_token=%s session=s1 expires_at=0"}
]]\n' "$terminal_lease"
	return 0
}
if output=$(_pcc_stall_release_evidence "$(stall_comments stall-lease)" "2026-09-30T00:30:00Z" key) &&
	[[ "$output" == $'31\tno_activity\t1\tfalse\t0\tfalse\t0\t1790731800\t-' ]]; then
	print_result "released attempt's own terminal lease keeps stall release evidence" 0
else
	print_result "released attempt's own terminal lease keeps stall release evidence" 1 "output=${output:-missing}"
fi
if ! _pcc_stall_release_evidence "$(stall_comments other-lease)" "2026-09-30T00:30:00Z" key >/dev/null 2>&1; then
	print_result "unrelated terminal lease after a stall release still counts as ownership" 0
else
	print_result "unrelated terminal lease after a stall release still counts as ownership" 1
fi

# GH#34008: a killed attempt runs no release path; the proactive sweep already
# reset its issue. Its own expired claim, older than the recovery draft head,
# is the only stall evidence accepted, and only for For #N recovery drafts.
LEASE_FIELD="lease""_token"
expired_claim_comments() {
	local extra="${1:-[]}"
	jq -nc --arg lf "$LEASE_FIELD" --argjson extra "$extra" '[[
		{id:40,created_at:"2026-09-30T01:00:00Z",author_association:"COLLABORATOR",user:{login:"worker-bot"},
			body:("DISPATCH_CLAIM nonce=n1 runner=worker-bot " + $lf + "=t1 session=issue-123 phase=prelaunch expires_at=1790000000")},
		{id:41,created_at:"2026-09-30T01:01:00Z",author_association:"COLLABORATOR",user:{login:"worker-bot"},
			body:("<!-- ops:start -->\nDISPATCH_LEASE phase=ready " + $lf + "=t1 session=issue-123 expires_at=1790000000 attempt_id=attempt:a1\n<!-- ops:end -->")}
	] + $extra]'
	return 0
}
recovery_head_date="2026-09-30T01:20:00Z"
if output=$(_pcc_expired_claim_evidence "$(expired_claim_comments)" "$recovery_head_date" 1791427000) &&
	[[ "$output" == 41 ]]; then
	print_result "expired claim older than the recovery head is stall evidence" 0
else
	print_result "expired claim older than the recovery head is stall evidence" 1 "output=${output:-missing}"
fi
if ! _pcc_expired_claim_evidence "$(expired_claim_comments)" "$recovery_head_date" 1789999999 >/dev/null 2>&1; then
	print_result "unexpired claim is not stall evidence" 0
else
	print_result "unexpired claim is not stall evidence" 1
fi
if ! _pcc_expired_claim_evidence "$(expired_claim_comments)" "2026-09-30T00:59:00Z" 1791427000 >/dev/null 2>&1; then
	print_result "claim newer than the draft head is not stall evidence" 0
else
	print_result "claim newer than the draft head is not stall evidence" 1
fi
for newer_event in \
	'CLAIM_RELEASED reason=blocked runner=worker-bot' \
	'Interactive session claimed this issue' \
	"DISPATCH_LEASE phase=terminal ${LEASE_FIELD}=t9 session=issue-123 expires_at=0"; do
	newer_comments="$(expired_claim_comments "$(jq -nc --arg body "$newer_event" \
		'[{id:42,created_at:"2026-09-30T01:10:00Z",author_association:"MEMBER",user:{login:"other-runner"},body:$body}]')")"
	if ! _pcc_expired_claim_evidence "$newer_comments" "$recovery_head_date" 1791427000 >/dev/null 2>&1; then
		print_result "newer coordination event suppresses expired-claim evidence: ${newer_event%% *}" 0
	else
		print_result "newer coordination event suppresses expired-claim evidence: ${newer_event%% *}" 1
	fi
done
untrusted_comments="$(expired_claim_comments | jq -c 'map(map(.author_association = "NONE"))')"
if ! _pcc_expired_claim_evidence "$untrusted_comments" "$recovery_head_date" 1791427000 >/dev/null 2>&1; then
	print_result "untrusted claim is not stall evidence" 0
else
	print_result "untrusted claim is not stall evidence" 1
fi

with_head_commit() {
	jq -c --arg date "$recovery_head_date" \
		'. + {commits:[{oid:"1111111111111111111111111111111111111111",committedDate:$date}]}'
	return 0
}
RELEASED_ISSUE_JSON="$(jq -nc '{number:123,body:"Preserve checkpoint scope",state:"open",labels:[{name:"status:available"}],assignees:[]}')"
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_COMMENTS_JSON="$(expired_claim_comments)"
STUB_PR_JSON="$(valid_pr_json 'Recovered dirty worktree.\nFor #123' "$TAKEOVER_LABELS" '[]' | with_head_commit)"
export STUB_ISSUE_JSON STUB_COMMENTS_JSON STUB_PR_JSON
DISPATCH_ARGS=""
DISPATCH_RESULT=0
STATUS_CALLS=""
PCC_ALLOW_RELEASED=false
output_file="${TEST_ROOT}/expired-dispatch-output"
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *"assignee=worker-bot release=none reason=expired_claim claim_comment=41"* &&
	"$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
	"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* &&
	"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner' &&
	"$PCC_LINK_KIND" == for ]]; then
	print_result "already-reset For #N recovery draft reaches exact-head continuation" 0
else
	print_result "already-reset For #N recovery draft reaches exact-head continuation" 1 \
		"output=${output:-missing} args=${DISPATCH_ARGS:-missing} calls=${STATUS_CALLS:-missing}"
fi

STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | with_head_commit)"
DISPATCH_ARGS=""
PCC_ALLOW_RELEASED=false
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *"has no current stall release"* && -z "$DISPATCH_ARGS" ]]; then
	print_result "ordinary worker draft still requires a stall release" 0
else
	print_result "ordinary worker draft still requires a stall release" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false
PCC_LINK_KIND="closing"

# GH#35363/GH#35715: stale-assignment and ownership-loss releases must resume
# the PR author's exact checkpoint, with the same one-retry-per-head bound.
# GH#36019: so must the worker's own draft-checkpoint handoff and clean or
# completed exits that left the draft open.
# GH#36597: zero-output and incomplete exits are runtime stalls, not decisions.
export STUB_POST_DIR="${TEST_ROOT}/posts"
for release_reason in stale_assignment_reset worker_ownership_lost worker_draft_checkpoint worker_noop_zero_output worker_incomplete_exit capability_limit clean worker_complete; do
	STUB_COMMENTS_JSON="$(stall_comments stall-lease | jq -c --arg reason "$release_reason" '
		map(map(if .id == 31 then .body |= sub("reason=no_activity"; "reason=" + $reason) else . end))')"
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	DISPATCH_ARGS=""
	STATUS_CALLS=""
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
	output="$(<"$output_file")"
	if [[ "$output" == *"assignee=worker-bot release=31 reason=${release_reason}"* &&
		"$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
		"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* &&
		"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner' ]]; then
		print_result "${release_reason} resumes unassigned checkpoint bound to PR author" 0
	else
		print_result "${release_reason} resumes unassigned checkpoint bound to PR author" 1 \
			"output=${output:-missing} args=${DISPATCH_ARGS:-missing} calls=${STATUS_CALLS:-missing}"
	fi

	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	STUB_COMMENTS_JSON="$(jq -c --arg reason "$release_reason" 'map(. + [
		{id:33,created_at:"2026-09-30T01:40:00Z",author_association:"COLLABORATOR",user:{login:"current-runner"},
			body:"DISPATCH_CLAIM nonce=n2 runner=current-runner"},
		{id:34,created_at:"2026-09-30T02:00:00Z",author_association:"OWNER",user:{login:"pulse-runner"},
			body:("CLAIM_RELEASED reason=" + $reason + " runner=pulse-runner")}
	])' <<<"$STUB_COMMENTS_JSON")"
	DISPATCH_ARGS=""
	posts_before="$(post_count)"
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
	output="$(<"$output_file")"
	if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_POSTED* && "$output" == *"stalls=2"* &&
		-z "$DISPATCH_ARGS" && "$(post_count)" -eq $((posts_before + 1)) ]]; then
		print_result "second ${release_reason} posts attention without another dispatch" 0
	else
		print_result "second ${release_reason} posts attention without another dispatch" 1 "output=${output:-missing}"
	fi
	posted_body="$(<"${STUB_POST_DIR}/post-$((posts_before + 1))")"
	STUB_COMMENTS_JSON="$(jq -c --arg body "$posted_body" 'map(. + [
		{id:35,created_at:"2026-09-30T02:01:00Z",author_association:"OWNER",user:{login:"pulse-runner"},body:$body}
	])' <<<"$STUB_COMMENTS_JSON")"
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
	output="$(<"$output_file")"
	if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS* && -z "$DISPATCH_ARGS" &&
		"$(post_count)" -eq $((posts_before + 1)) ]]; then
		print_result "repeated ${release_reason} sweep deduplicates exact-head attention" 0
	else
		print_result "repeated ${release_reason} sweep deduplicates exact-head attention" 1 "output=${output:-missing}"
	fi
	PCC_ALLOW_RELEASED=false
done

# GH#36019: one attention record per head. A blocked-checkpoint attention
# record already posted for this head suppresses a second stall record.
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_COMMENTS_JSON="$(stall_comments stall-lease | jq -c 'map(map(if .id == 31 then .body |= sub("reason=no_activity"; "reason=worker_complete") else . end) + [
	{id:33,created_at:"2026-09-30T01:40:00Z",author_association:"OWNER",user:{login:"pulse-runner"},
		body:"<!-- ops:start -->\n<!-- aidevops:blocked-checkpoint-attention pr=42 head=1111111111111111111111111111111111111111 release=31 -->\nBLOCKED_CHECKPOINT_ATTENTION pr=42\n<!-- ops:end -->"},
	{id:34,created_at:"2026-09-30T02:00:00Z",author_association:"OWNER",user:{login:"pulse-runner"},
		body:"CLAIM_RELEASED reason=clean runner=pulse-runner"}
])')"
DISPATCH_ARGS=""
posts_before="$(post_count)"
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS* && -z "$DISPATCH_ARGS" &&
	"$(post_count)" -eq "$posts_before" ]]; then
	print_result "existing blocked-checkpoint attention for the head suppresses a second record" 0
else
	print_result "existing blocked-checkpoint attention for the head suppresses a second record" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false

# Attention is a pause, not a permanent stop: once the record is older than the
# re-arm window, a runner with no coordination event for the head since its
# commit continues it once. Runners that already tried the head stay paused.
rearm_comments="$STUB_COMMENTS_JSON"
_PCC_ATTENTION_REARM_SECONDS=43200
DISPATCH_ARGS=""
STATUS_CALLS=""
posts_before="$(post_count)"
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *"STALLED_CHECKPOINT_REARMED: PR #42 in owner/repo head=${blocked_head} runner=current-runner"* &&
	"$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
	"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 ${blocked_head} worker-bot"* &&
	"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner' &&
	"$(post_count)" -eq "$posts_before" ]]; then
	print_result "aged head attention re-arms one continuation for an untried runner" 0
else
	print_result "aged head attention re-arms one continuation for an untried runner" 1 \
		"output=${output:-missing} args=${DISPATCH_ARGS:-missing} calls=${STATUS_CALLS:-missing}"
fi
PCC_ALLOW_RELEASED=false
# GH#37514: pin `date +%s` so the fleet re-arm window is deterministic.
date() {
	if [[ "${1:-}" == +%s && -n "${PCC_TEST_NOW:-}" ]]; then
		printf '%s\n' "$PCC_TEST_NOW"
		return 0
	fi
	command date "$@"
	return $?
}
# The newest stall release (02:00) anchors the fleet window: one minute before
# it closes, runners that already tried the head stay paused.
PCC_TEST_NOW=1790776740
for tried_runner in pulse-runner worker-bot; do
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	STUB_COMMENTS_JSON="$rearm_comments"
	printf '[]' >"$STUB_CLAIM_FILE"
	DISPATCH_ARGS=""
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 "$tried_runner" >"$output_file" || true
	output="$(<"$output_file")"
	if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS* && -z "$DISPATCH_ARGS" &&
		"$(post_count)" -eq "$posts_before" ]]; then
		print_result "aged attention does not re-arm ${tried_runner} before the fleet window" 0
	else
		print_result "aged attention does not re-arm ${tried_runner} before the fleet window" 1 "output=${output:-missing}"
	fi
	PCC_ALLOW_RELEASED=false
done
# GH#37514: once every runner has tried the head, the fleet window re-arms one
# exact-head continuation through the normal fenced claim.
PCC_TEST_NOW=1790776800
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_COMMENTS_JSON="$rearm_comments"
printf '[]' >"$STUB_CLAIM_FILE"
DISPATCH_ARGS=""
STATUS_CALLS=""
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 pulse-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *"STALLED_CHECKPOINT_REARMED: PR #42 in owner/repo head=${blocked_head} runner=pulse-runner stalls=2"*"mode=fleet window=43200s"* &&
	"$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
	"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 ${blocked_head} worker-bot"* &&
	"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee pulse-runner' &&
	"$(post_count)" -eq "$posts_before" ]]; then
	print_result "fleet window re-arms one continuation after every runner tried the head" 0
else
	print_result "fleet window re-arms one continuation after every runner tried the head" 1 \
		"output=${output:-missing} args=${DISPATCH_ARGS:-missing} calls=${STATUS_CALLS:-missing}"
fi
PCC_ALLOW_RELEASED=false
# The winner's claim owns the draft, so a second runner in the same window
# finds no current stall release and launches nothing.
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_COMMENTS_JSON="$(jq -c 'map(. + [{id:36,created_at:"2026-09-30T14:00:05Z",author_association:"OWNER",
	user:{login:"pulse-runner"},body:"DISPATCH_CLAIM nonce=n3 runner=pulse-runner"}])' <<<"$rearm_comments")"
DISPATCH_ARGS=""
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 worker-bot >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *"has no current stall release"* && -z "$DISPATCH_ARGS" ]]; then
	print_result "fleet re-arm launches exactly one continuation per window" 0
else
	print_result "fleet re-arm launches exactly one continuation per window" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false
# A further stall of the same head doubles the window from its release.
doubled_comments="$(jq -c 'map(. + [{id:37,created_at:"2026-09-30T15:00:00Z",author_association:"OWNER",
	user:{login:"pulse-runner"},body:"CLAIM_RELEASED reason=no_activity runner=pulse-runner"}])' <<<"$rearm_comments")"
for doubled_case in 1790866740:closed 1790866800:open; do
	PCC_TEST_NOW="${doubled_case%%:*}"
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	STUB_COMMENTS_JSON="$doubled_comments"
	printf '[]' >"$STUB_CLAIM_FILE"
	DISPATCH_ARGS=""
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 pulse-runner >"$output_file" || true
	output="$(<"$output_file")"
	if [[ "${doubled_case#*:}" == closed && "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS* && -z "$DISPATCH_ARGS" ]] ||
		[[ "${doubled_case#*:}" == open && "$output" == *"stalls=3"*"mode=fleet window=86400s"* &&
			"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 ${blocked_head} worker-bot"* ]]; then
		print_result "third stall doubles the fleet window (${doubled_case#*:})" 0
	else
		print_result "third stall doubles the fleet window (${doubled_case#*:})" 1 "output=${output:-missing}"
	fi
	PCC_ALLOW_RELEASED=false
done
# The per-PR fuse stays the hard stop for the fleet re-arm.
saved_pr_json="$STUB_PR_JSON"
saved_max_releases="$_PCC_MAX_PR_RELEASES"
_PCC_MAX_PR_RELEASES=3
STUB_PR_JSON="$(jq -c '. + {createdAt:"2026-09-29T23:00:00Z"}' <<<"$saved_pr_json")"
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_COMMENTS_JSON="$doubled_comments"
printf '[]' >"$STUB_CLAIM_FILE"
DISPATCH_ARGS=""
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 pulse-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS* && "$output" != *STALLED_CHECKPOINT_REARMED* &&
	-z "$DISPATCH_ARGS" ]]; then
	print_result "per-PR fuse stops the fleet re-arm" 0
else
	print_result "per-PR fuse stops the fleet re-arm" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false
_PCC_MAX_PR_RELEASES="$saved_max_releases"
STUB_PR_JSON="$saved_pr_json"
unset PCC_TEST_NOW
# A runner whose only claim predates the head commit has not tried this head.
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_COMMENTS_JSON="$(jq -c 'map(. + [{id:5,created_at:"2026-09-30T00:10:00Z",author_association:"COLLABORATOR",
	user:{login:"old-runner"},body:"DISPATCH_CLAIM nonce=n0 runner=old-runner"}])' <<<"$rearm_comments")"
if ! _pcc_runner_tried_head "$STUB_COMMENTS_JSON" "$recovery_head_date" old-runner &&
	_pcc_runner_tried_head "$STUB_COMMENTS_JSON" "$recovery_head_date" pulse-runner &&
	_pcc_runner_tried_head 'not-json' "$recovery_head_date" old-runner; then
	print_result "head participation counts only events after the head commit and fails closed" 0
else
	print_result "head participation counts only events after the head commit and fails closed" 1
fi
_PCC_ATTENTION_REARM_SECONDS=0
STUB_COMMENTS_JSON="$rearm_comments"
printf '[]' >"$STUB_CLAIM_FILE"
DISPATCH_ARGS=""
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS* && -z "$DISPATCH_ARGS" ]]; then
	print_result "a zero re-arm window keeps head attention as a permanent stop" 0
else
	print_result "a zero re-arm window keeps head attention as a permanent stop" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false
_PCC_ATTENTION_REARM_SECONDS="$ATTENTION_REARM_CLOSED"

# GH#36019: the per-PR fuse stops continuation once enough eligible releases
# accumulated since PR creation, even when each continuation pushed a new head.
fuse_comments="$(jq -nc '[[range(0; 6) as $i | {id:(60 + $i),
	created_at:("2026-09-30T00:0" + ($i | tostring) + ":00Z"), author_association:"OWNER",
	user:{login:"pulse-runner"}, body:"CLAIM_RELEASED reason=worker_complete runner=pulse-runner"}]]')"
STUB_COMMENTS_JSON="$fuse_comments"
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | jq -c '. + {createdAt:"2026-09-29T23:00:00Z",
	commits:[{oid:"1111111111111111111111111111111111111111",committedDate:"2026-09-30T00:04:30Z"}]}')"
DISPATCH_ARGS=""
posts_before="$(post_count)"
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
fuse_body=""
[[ "$(post_count)" -eq $((posts_before + 1)) ]] && fuse_body="$(<"${STUB_POST_DIR}/post-$((posts_before + 1))")"
if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_POSTED*"stalls=6"* && -z "$DISPATCH_ARGS" &&
	"$fuse_body" == *"per-PR automatic continuation limit (6)"* &&
	"$fuse_body" == *"does not re-arm automatic continuation"* ]]; then
	print_result "per-PR fuse posts attention instead of another continuation" 0
else
	print_result "per-PR fuse posts attention instead of another continuation" 1 "output=${output:-missing}"
fi
# A later head pushed after the fuse record adds no second fuse comment, and an
# aged fuse record never re-arms an untried runner: the fuse is a hard stop.
STUB_COMMENTS_JSON="$(jq -c --arg body "$fuse_body" 'map(. + [{id:70,created_at:"2026-09-30T00:06:00Z",
	author_association:"OWNER",user:{login:"pulse-runner"},body:$body}])' <<<"$fuse_comments")"
STUB_PR_JSON="$(jq -c '.headRefOid = "2222222222222222222222222222222222222222" |
	.commits += [{oid:"2222222222222222222222222222222222222222",committedDate:"2026-09-30T00:10:00Z"}]' <<<"$STUB_PR_JSON")"
DISPATCH_ARGS=""
posts_before="$(post_count)"
_PCC_ATTENTION_REARM_SECONDS=43200
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
_PCC_ATTENTION_REARM_SECONDS="$ATTENTION_REARM_CLOSED"
output="$(<"$output_file")"
if [[ -n "$fuse_body" && "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS*"head=2222"* &&
	-z "$DISPATCH_ARGS" && "$(post_count)" -eq "$posts_before" ]]; then
	print_result "per-PR fuse record is not repeated or re-armed for a later head" 0
else
	print_result "per-PR fuse record is not repeated or re-armed for a later head" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | jq -c '. + {createdAt:"2026-09-29T23:00:00Z",
	commits:[{oid:"1111111111111111111111111111111111111111",committedDate:"2026-09-30T00:04:30Z"}]}')"
STUB_COMMENTS_JSON="$(jq -c 'map(.[1:])' <<<"$fuse_comments")"
DISPATCH_ARGS=""
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* && -n "$DISPATCH_ARGS" ]]; then
	print_result "below the per-PR fuse a new head still gets one continuation" 0
else
	print_result "below the per-PR fuse a new head still gets one continuation" 1 "output=${output:-missing}"
fi
PCC_ALLOW_RELEASED=false

