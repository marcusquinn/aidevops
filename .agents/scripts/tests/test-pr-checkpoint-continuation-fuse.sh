#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-pr-checkpoint-continuation-helper.sh; relies on its fixtures.
# shellcheck disable=SC2154  # fixtures and variables are defined by sibling modules

# GH#37779 (b): the fuse is the one block no re-arm lifts. Once the window has
# passed, dispatch-stalled names the block and takes one terminal action per
# head instead of holding the issue: land an additive passing For #N
# checkpoint, close anything else keeping the branch, never act twice.
fuse_terminal_comments="$(jq -c --arg body "$fuse_body" 'map(. + [{id:70,created_at:"2026-09-30T00:06:00Z",
	author_association:"OWNER",user:{login:"pulse-runner"},body:$body}])' <<<"$fuse_comments")"
test_fuse_terminal_action() (
	# Distinct names: the helper's own locals (e.g. `files`) shadow these
	# inside the gh stub through bash dynamic scoping.
	local fixture_pr_files="$1" expected="$2" comments="$3" window="${4:-43200}"
	local fixture_writes_file="${TEST_ROOT}/terminal-writes" output="" writes="" record=""
	: >"$fixture_writes_file"
	printf '[]' >"$STUB_CLAIM_FILE"
	# Record terminal writes and serve the PR file list; delegate the rest.
	# Args: gh argv. Returns: the stub's status.
	gh() {
		case "$1 $2" in
		"pr ready" | "pr close")
			# A close must never precede its durable issue salvage pointer.
			[[ "$2" != close || "$(post_count)" -gt "$posts_before" ]] || return 1
			printf '%s\n' "$2" >>"$fixture_writes_file"
			;;
		"api repos/owner/repo/issues/123/comments")
			if [[ "$expected" == pointer_failed && "${6:-}" == body=Preserved* ]] ||
				[[ "$expected" == audit_failed && "${6:-}" == *STALLED_CHECKPOINT_TERMINAL_ACTION* ]]; then
				return 1
			fi
			command gh "$@" || return $?
			if [[ "$expected" == contended && "${6:-}" == *DISPATCH_CLAIM* ]]; then
				jq '. + [(last | .id -= 1 | .node_id = "fixture-rival" |
					.body |= (sub("nonce=[^ ]+"; "nonce=00000000-0000-0000-0000-000000000001") |
						sub("lease_token=[^ ]+"; "lease_token=00000000-0000-0000-0000-000000000001")))]' \
					"$STUB_CLAIM_FILE" >"${STUB_CLAIM_FILE}.next"
				mv "${STUB_CLAIM_FILE}.next" "$STUB_CLAIM_FILE"
			fi
			;;
		"api repos/owner/repo/pulls/42/files?per_page=100") printf '%s\n' "$fixture_pr_files" ;;
		*) command gh "$@" || return $? ;;
		esac
		return 0
	}
	_PCC_TERMINAL_ACTION_SECONDS="$window"
	STUB_COMMENTS_JSON="$comments"
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	STUB_PR_JSON="$(valid_pr_json 'Partial checkpoint.\nFor #123' '' '[]' | jq -c '. + {createdAt:"2026-09-29T23:00:00Z",
		mergeable:"MERGEABLE",mergeStateStatus:"DRAFT",
		statusCheckRollup:[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"}],
		commits:[{oid:"1111111111111111111111111111111111111111",committedDate:"2026-09-30T00:04:30Z"}]}')"
	export STUB_COMMENTS_JSON STUB_ISSUE_JSON STUB_PR_JSON
	DISPATCH_ARGS=""
	local posts_before="" posts_after=""
	posts_before="$(post_count)"
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
	output="$(<"$output_file")"
	posts_after="$(post_count)"
	writes="$(<"$fixture_writes_file")"
	local ok=true
	[[ -z "$DISPATCH_ARGS" && "$output" == *"STALLED_CHECKPOINT_REARM_BLOCKED:"*"reason=per_pr_fuse"* ]] || ok=false
	case "$expected" in
	pointer_failed | contended)
		[[ -z "$writes" && "$posts_after" -eq "$posts_before" &&
			"$output" == *STALLED_CHECKPOINT_TERMINAL_DEFERRED* ]] || ok=false
		;;
	audit_failed)
		[[ "$writes" == close && "$posts_after" -eq $((posts_before + 1)) &&
			"$output" == *STALLED_CHECKPOINT_TERMINAL_RECORD_FAILED* &&
			"$output" != *'STALLED_CHECKPOINT_TERMINAL_ACTION:'* ]] || ok=false
		record="$(<"${STUB_POST_DIR}/post-${posts_after}")"
		[[ "$record" == *"Preserved checkpoint: branch \`worker/issue-123\` at \`1111111111111111111111111111111111111111\`"* ]] || ok=false
		;;
	none)
		[[ -z "$writes" && "$posts_after" -eq "$posts_before" &&
			"$output" != *STALLED_CHECKPOINT_TERMINAL_ACTION* ]] || ok=false
		;;
	exists)
		[[ -z "$writes" && "$posts_after" -eq "$posts_before" &&
			"$output" == *STALLED_CHECKPOINT_TERMINAL_EXISTS* ]] || ok=false
		;;
	*)
		local expected_posts=1
		[[ "$expected" != closed ]] || expected_posts=2
		[[ "$posts_after" -eq $((posts_before + expected_posts)) ]] && record="$(<"${STUB_POST_DIR}/post-${posts_after}")"
		[[ "$output" == *"STALLED_CHECKPOINT_TERMINAL_ACTION:"*"action=${expected}"*"cause=per_pr_fuse"* &&
			"$writes" == "$([[ "$expected" == closed ]] && printf close || printf ready)" &&
			"$record" == *"<!-- aidevops:stalled-checkpoint-terminal pr=42 head=1111111111111111111111111111111111111111 release=65 -->"* &&
			"$record" == *"action=${expected} cause=per_pr_fuse"* ]] || ok=false
		[[ "$expected" != closed || "$record" == *"Preserved checkpoint: branch \`worker/issue-123\`"* ]] || ok=false
		;;
	esac
	[[ "$ok" == true ]] && return 0
	printf '     output=[%s] writes=[%s] posts=%s->%s\n' "$output" "$writes" "$posts_before" "$posts_after" >&2
	return 1
)
additive_files='[[{"status":"added"},{"status":"modified"}]]'
if test_fuse_terminal_action "$additive_files" ready_for_merge "$fuse_terminal_comments"; then
	print_result "fused additive passing For #N checkpoint is marked ready once its window passes" 0
else
	print_result "fused additive passing For #N checkpoint is marked ready once its window passes" 1
fi
if test_fuse_terminal_action '[[{"status":"removed"}]]' closed "$fuse_terminal_comments"; then
	print_result "fused checkpoint that removes files is closed with its branch kept" 0
else
	print_result "fused checkpoint that removes files is closed with its branch kept" 1
fi
for failure in pointer_failed audit_failed contended; do
	if test_fuse_terminal_action '[[{"status":"removed"}]]' "$failure" "$fuse_terminal_comments"; then
		print_result "terminal close preserves salvage context when ${failure}" 0
	else
		print_result "terminal close preserves salvage context when ${failure}" 1
	fi
done
terminal_record='<!-- aidevops:stalled-checkpoint-terminal pr=42 head=1111111111111111111111111111111111111111 release=65 -->'
if test_fuse_terminal_action "$additive_files" exists "$(jq -c --arg body "$terminal_record" \
	'map(. + [{id:71,created_at:"2026-09-30T00:07:00Z",author_association:"OWNER",user:{login:"pulse-runner"},body:$body}])' \
	<<<"$fuse_terminal_comments")"; then
	print_result "terminal action is taken at most once per PR head" 0
else
	print_result "terminal action is taken at most once per PR head" 1
fi
if test_fuse_terminal_action "$additive_files" none "$fuse_terminal_comments" 0; then
	print_result "a zero terminal window keeps the fuse a visible permanent stop" 0
else
	print_result "a zero terminal window keeps the fuse a visible permanent stop" 1
fi
PCC_ALLOW_RELEASED=false
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | with_head_commit)"

# GH#37779 (a): a worker_draft_checkpoint release cannot be re-approved, so an
# expired approval must stop owning scheduling; an unexpired one still fences.
approval_stall_comments() {
	local created="$1" reason="$2"
	stall_comments stall-lease | jq -c --arg created "$created" --arg reason "$reason" '
		map(map(if .id == 31 then .body |= sub("reason=no_activity"; "reason=" + $reason) else . end) +
			(if $created == "" then [] else [{id:33,created_at:$created,updated_at:$created,
				author_association:"OWNER",user:{login:"maintainer"},
				body:("CHECKPOINT_CONTINUATION_APPROVED " + ({repo:"owner/repo",issue:123,pr:42,
					head:"1111111111111111111111111111111111111111"} | tojson))}] end))'
	return 0
}
for approval_age in expired current; do
	approval_created="2026-09-30T01:31:00Z"
	[[ "$approval_age" == expired ]] || approval_created="$(command date -u +%Y-%m-%dT%H:%M:%SZ)"
	STUB_COMMENTS_JSON="$(approval_stall_comments "$approval_created" worker_draft_checkpoint)"
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	printf '[]' >"$STUB_CLAIM_FILE"
	DISPATCH_ARGS=""
	STATUS_CALLS=""
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
	output="$(<"$output_file")"
	if [[ "$approval_age" == expired && "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
		"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* ]] ||
		[[ "$approval_age" == current && -z "$DISPATCH_ARGS" ]]; then
		print_result "${approval_age} approval on an unapprovable release: legacy route $([[ "$approval_age" == expired ]] && printf resumes || printf 'stays fenced')" 0
	else
		print_result "${approval_age} approval on an unapprovable release: legacy route $([[ "$approval_age" == expired ]] && printf resumes || printf 'stays fenced')" 1 \
			"output=${output:-missing} args=${DISPATCH_ARGS:-missing}"
	fi
	PCC_ALLOW_RELEASED=false
done

# GH#37779 (c): STALE_PR_CONTINUATION names the original assignee, but the
# issue may already be released unassigned; `dispatch` must re-verify it
# through dispatch-stalled instead of rejecting the missing assignee.
STUB_COMMENTS_JSON="$(approval_stall_comments "" stale_assignment_reset)"
STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
printf '[]' >"$STUB_CLAIM_FILE"
DISPATCH_ARGS=""
_pcc_dispatch owner/repo "${TEST_ROOT}/repo" 42 123 worker-bot current-runner >"$output_file" 2>&1 || true
legacy_args="$DISPATCH_ARGS"
PCC_ALLOW_RELEASED=false
printf '[]' >"$STUB_CLAIM_FILE"
DISPATCH_ARGS=""
STATUS_CALLS=""
_pcc_dispatch_command owner/repo "${TEST_ROOT}/repo" 42 123 worker-bot current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ -z "$legacy_args" && "$output" == *"STALE_PR_CONTINUATION_RELEASED: issue #123"* &&
	"$output" == *"release=31 reason=stale_assignment_reset"* && "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
	"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* &&
	"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner' ]]; then
	print_result "dispatch routes an already-released unassigned issue through dispatch-stalled" 0
else
	print_result "dispatch routes an already-released unassigned issue through dispatch-stalled" 1 \
		"legacy=${legacy_args:-none} output=${output:-missing} args=${DISPATCH_ARGS:-missing} calls=${STATUS_CALLS:-missing}"
fi
PCC_ALLOW_RELEASED=false

ownership_comments="$(stall_comments stall-lease | jq -c '
	map(map(if .id == 31 then .body |= sub("reason=no_activity"; "reason=worker_ownership_lost") else . end))')"
for ownership_event in \
	'DISPATCH_LEASE phase=ready lease_token=new-lease session=s2' \
	'Interactive session claimed this issue' \
	'CLAIM_RELEASED reason=blocked runner=worker-bot'; do
	newer_comments="$(jq -c --arg body "$ownership_event" 'map(. + [
		{id:33,created_at:"2026-09-30T02:00:00Z",author_association:"MEMBER",user:{login:"new-owner"},body:$body}
	])' <<<"$ownership_comments")"
	if ! _pcc_stall_release_evidence "$newer_comments" "$recovery_head_date" key >/dev/null 2>&1; then
		print_result "ownership-loss recovery respects newer ${ownership_event%% *}" 0
	else
		print_result "ownership-loss recovery respects newer ${ownership_event%% *}" 1
	fi
done

# GH#35883: runner_capability_unmet releases describe the releasing runner, not
# the head. Together they count as one original stall; a runner skips only a
# head its own login released for a missing capability, until a trusted retry.
CAPABILITY_HEAD="1111111111111111111111111111111111111111"
capability_comments() {
	local extra="${1:-[]}"
	jq -nc --argjson extra "$extra" '
		def capability_release($id; $at; $runner): {id:$id, created_at:$at,
			author_association:"COLLABORATOR", user:{login:$runner},
			body:("<!-- ops:start -->\nCLAIM_RELEASED reason=blocked runner=" + $runner + " ts=" + $at +
				"\n\nTerminal blocker: reason=runner_capability_unmet owner=runner-recovery task=123 attempt=abc.\n<!-- ops:end -->")};
		[[capability_release(50; "2026-09-30T01:30:00Z"; "cap-runner-a"),
			{id:51, created_at:"2026-09-30T01:40:00Z", author_association:"COLLABORATOR",
				user:{login:"cap-runner-b"}, body:"DISPATCH_CLAIM nonce=n5 runner=cap-runner-b"},
			capability_release(52; "2026-09-30T01:50:00Z"; "cap-runner-b")] + $extra]'
	return 0
}
run_capability_sweep() {
	local login="$1"
	printf '[]' >"$STUB_CLAIM_FILE"
	STUB_ISSUE_JSON="$RELEASED_ISSUE_JSON"
	DISPATCH_ARGS=""
	STATUS_CALLS=""
	PCC_ALLOW_RELEASED=false
	_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 "$login" >"$output_file" || true
	output="$(<"$output_file")"
	PCC_ALLOW_RELEASED=false
	return 0
}
# The attention record the old rule posted after two capability releases.
old_capability_attention="$(jq -nc --arg head "$CAPABILITY_HEAD" '[{id:53, created_at:"2026-09-30T01:55:00Z",
	author_association:"COLLABORATOR", user:{login:"pulse-runner"},
	body:("<!-- ops:start -->\n<!-- aidevops:stalled-checkpoint-attention pr=42 head=" + $head +
		" release=52 -->\nSTALLED_CHECKPOINT_ATTENTION pr=42 head=" + $head +
		" release_comment=52 reason=blocked stalls=2\n<!-- ops:end -->")}]')"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | with_head_commit)"
STUB_COMMENTS_JSON="$(capability_comments "$old_capability_attention")"
posts_before="$(post_count)"
run_capability_sweep current-runner
if [[ "$output" == *"assignee=worker-bot release=52 reason=blocked"* &&
	"$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
	"$DISPATCH_ARGS" == *"continue-pr worker/issue-123 ${CAPABILITY_HEAD} worker-bot"* &&
	"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner' &&
	"$(post_count)" -eq "$posts_before" ]]; then
	print_result "capability releases by other runners count once and a capable runner continues the head" 0
else
	print_result "capability releases by other runners count once and a capable runner continues the head" 1 \
		"output=${output:-missing} args=${DISPATCH_ARGS:-missing} calls=${STATUS_CALLS:-missing}"
fi

for released_runner in cap-runner-a cap-runner-b; do
	posts_before="$(post_count)"
	run_capability_sweep "$released_runner"
	if [[ "$output" == *"STALLED_CHECKPOINT_CONTINUATION_SKIPPED"*"runner ${released_runner} already released it as runner_capability_unmet"* &&
		-z "$DISPATCH_ARGS" && -z "$STATUS_CALLS" && "$(post_count)" -eq "$posts_before" ]]; then
		print_result "${released_runner} skips a head it released for a missing capability without comment or dispatch" 0
	else
		print_result "${released_runner} skips a head it released for a missing capability without comment or dispatch" 1 \
			"output=${output:-missing} args=${DISPATCH_ARGS:-missing}"
	fi
done

STUB_COMMENTS_JSON="$(capability_comments '[{"id":54,"created_at":"2026-09-30T02:00:00Z","author_association":"MEMBER","user":{"login":"maintainer"},"body":"Fixture installed.\nterminal-blocker-circuit:retry"}]')"
run_capability_sweep cap-runner-a
if [[ "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* &&
	"$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee cap-runner-a' ]]; then
	print_result "a newer trusted retry re-arms a runner after its capability release" 0
else
	print_result "a newer trusted retry re-arms a runner after its capability release" 1 "output=${output:-missing}"
fi

capability_retry_is_ignored() {
	local name="$1" id="$2" created_at="$3" association="$4" body="$5" retry="" released=""
	retry="$(jq -nc --argjson id "$id" --arg at "$created_at" --arg association "$association" --arg body "$body" \
		'[{id:$id, created_at:$at, author_association:$association, user:{login:"maintainer"}, body:$body}]')"
	if released=$(_pcc_self_capability_release "$(capability_comments "$retry")" "$recovery_head_date" cap-runner-a) &&
		[[ "$released" == 50 ]]; then
		print_result "capability skip ignores ${name}" 0
	else
		print_result "capability skip ignores ${name}" 1 "released=${released:-none}"
	fi
	return 0
}
capability_retry_is_ignored "a COLLABORATOR retry" 54 2026-09-30T02:00:00Z COLLABORATOR 'terminal-blocker-circuit:retry'
capability_retry_is_ignored "an inline retry mention" 54 2026-09-30T02:00:00Z MEMBER 'Post terminal-blocker-circuit:retry once installed.'
capability_retry_is_ignored "a circuit record" 54 2026-09-30T02:00:00Z MEMBER \
	$'<!-- aidevops:terminal-blocker-circuit revision=r blocker=b -->\nterminal-blocker-circuit:retry'
capability_retry_is_ignored "a retry older than the release" 45 2026-09-30T01:25:00Z MEMBER 'terminal-blocker-circuit:retry'
if ! _pcc_self_capability_release "$(capability_comments)" "2026-09-30T02:30:00Z" cap-runner-a >/dev/null 2>&1; then
	print_result "a new head re-arms runners whose capability releases predate it" 0
else
	print_result "a new head re-arms runners whose capability releases predate it" 1
fi

STUB_COMMENTS_JSON="$(capability_comments '[{"id":55,"created_at":"2026-09-30T02:10:00Z","author_association":"OWNER","user":{"login":"pulse-runner"},"body":"CLAIM_RELEASED reason=no_activity runner=pulse-runner"}]')"
posts_before="$(post_count)"
run_capability_sweep current-runner
if [[ "$output" == *STALLED_CHECKPOINT_ATTENTION_POSTED*"stalls=2"* && -z "$DISPATCH_ARGS" &&
	"$(post_count)" -eq $((posts_before + 1)) ]]; then
	print_result "a genuine stall after capability releases still posts one attention record" 0
else
	print_result "a genuine stall after capability releases still posts one attention record" 1 "output=${output:-missing}"
fi

# The successor's worker fence runs after the transfer, while the capability
# release is still the newest coordination event. An ordinary blocked release
# still requires the revision-bound approval.
STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-progress"}]' current-runner)"
STUB_COMMENTS_JSON="$(capability_comments)"
PCC_HEAD_REF="worker/issue-123"
PCC_HEAD_OID="$CAPABILITY_HEAD"
if ! run_checkpoint_preparation worker-bot >/dev/null 2>&1; then
	print_result "worker fence requires a fresh claim after a capability release" 0
else
	print_result "worker fence requires a fresh claim after a capability release" 1
fi
STUB_COMMENTS_JSON="$(capability_comments | jq -c 'map(map(.body |= sub("\n\nTerminal blocker: [^\n]*"; "")))')"
if ! run_checkpoint_preparation worker-bot >/dev/null 2>&1; then
	print_result "worker fence still rejects an ordinary blocked release without approval" 0
else
	print_result "worker fence still rejects an ordinary blocked release without approval" 1
fi
# The same fence on an interactive-provenance issue: auto-dispatch authorizes
# the capable successor; without it, interactive provenance still holds.
STUB_COMMENTS_JSON="$(capability_comments)"
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-progress"},{"name":"auto-dispatch"},{"name":"origin:interactive"}]' current-runner)"
if ! run_checkpoint_preparation worker-bot >/dev/null 2>&1; then
	print_result "worker fence requires a claim despite auto-dispatch interactive provenance" 0
else
	print_result "worker fence requires a claim despite auto-dispatch interactive provenance" 1
fi
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-progress"},{"name":"origin:interactive"}]' current-runner)"
if ! run_checkpoint_preparation worker-bot >/dev/null 2>&1; then
	print_result "worker fence keeps the interactive-provenance hold without auto-dispatch" 0
else
	print_result "worker fence keeps the interactive-provenance hold without auto-dispatch" 1
fi

# Rejections must identify the failed predicate without contaminating TSV stdout
# or leaking implementation text into the Pulse log.
STUB_COMMENTS_JSON='[]'
STUB_PR_JSON="$(valid_pr_json 'private-body-sentinel' | jq -c '.isDraft = false')"
STUB_ISSUE_JSON="$(valid_issue_json)"
diagnostics_file="${TEST_ROOT}/target-diagnostics"
if ! row=$(_pcc_target_row owner/repo 42 123 worker-bot worker-bot 2>"$diagnostics_file") &&
	[[ -z "$row" && "$(<"$diagnostics_file")" == *reason=pr_metadata_ineligible* &&
	"$(<"$diagnostics_file")" == *'"isDraft":false'* &&
	"$(<"$diagnostics_file")" != *private-body-sentinel* ]]; then
	print_result "target diagnostics identify PR metadata failure without bodies or TSV output" 0
else
	print_result "target diagnostics identify PR metadata failure without bodies or TSV output" 1
fi
STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:available"}]')"
if ! row=$(_pcc_target_row owner/repo 42 123 worker-bot worker-bot 2>"$diagnostics_file") &&
	[[ -z "$row" && "$(<"$diagnostics_file")" == *reason=issue_metadata_ineligible* &&
	"$(<"$diagnostics_file")" == *status:available* &&
	"$(<"$diagnostics_file")" == *'"assignees":[{"login":"worker-bot"}]'* ]]; then
	print_result "target diagnostics explain assigned available issue rejection" 0
else
	print_result "target diagnostics explain assigned available issue rejection" 1
fi

if python3 "${TEST_SCRIPT_DIR}/test-pr-checkpoint-revision.py"; then
	print_result "revised checkpoint claims, large metadata, worker lease lifecycle and durable progress" 0
else
	print_result "revised checkpoint claims, large metadata, worker lease lifecycle and durable progress" 1
fi

if python3 "${TEST_SCRIPT_DIR}/test-pr-checkpoint-claim-only.py"; then
	print_result "expired never-ready checkpoint claims recover only through bound closure" 0
else
	print_result "expired never-ready checkpoint claims recover only through bound closure" 1
fi

if python3 "${TEST_SCRIPT_DIR}/test-pr-checkpoint-private-member.py"; then
	print_result "private-member checkpoint trust preserves permission and edit fences" 0
else
	print_result "private-member checkpoint trust preserves permission and edit fences" 1
fi

if python3 "${TEST_SCRIPT_DIR}/test-pr-checkpoint-self-hold.py"; then
	print_result "exact approval supersedes only the runner's own pre-approval draft hold" 0
else
	print_result "exact approval supersedes only the runner's own pre-approval draft hold" 1
fi

if python3 "${TEST_SCRIPT_DIR}/test-pr-checkpoint-unattributed.py"; then
	print_result "unattributed releases require exact maintainer acknowledgement" 0
else
	print_result "unattributed releases require exact maintainer acknowledgement" 1
fi

if python3 "${TEST_SCRIPT_DIR}/test-pr-checkpoint-stall-approval.py"; then
	print_result "stalled draft checkpoints accept exact maintainer resume approvals" 0
else
	print_result "stalled draft checkpoints accept exact maintainer resume approvals" 1
fi

