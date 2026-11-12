#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-pr-checkpoint-continuation-helper.sh; relies on its fixtures.
# shellcheck disable=SC2154  # fixtures and variables are defined by sibling modules

# GH#36138: an approval-superseded runner self-hold is removed only after the
# exact-head continuation actually launched. The approval fence itself is
# covered by test-pr-checkpoint-self-hold.py.
self_hold_lift_case() {
	local name="$1" lift_rc="$2" lift_flag="$3" expect_edit="$4"
	local edits_file="${TEST_ROOT}/self-hold-edits" lift_output="" edits=""
	: >"$edits_file"
	lift_output=$(
		_pcc_target_row() {
			printf 'Continue existing work\tworker/issue-123\t%s\tworker-bot\tin-review\tworker-bot\t77\tclosing\t%s\n' \
				"1111111111111111111111111111111111111111" "$lift_flag"
			return 0
		}
		_prrts_dispatch_guarded() { return "$lift_rc"; }
		gh_pr_edit_safe() {
			printf '%s\n' "$*" >>"$edits_file"
			return 0
		}
		_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot" 2>/dev/null || true
	)
	edits="$(<"$edits_file")"
	if [[ "$expect_edit" == 1 && "$edits" == '42 --repo owner/repo --remove-label hold-for-review' &&
		"$lift_output" == *'PR_CHECKPOINT_SELF_HOLD_LIFTED: PR #42 in owner/repo hold-for-review superseded by approval 77'* ]] ||
		[[ "$expect_edit" == 0 && -z "$edits" && "$lift_output" != *PR_CHECKPOINT_SELF_HOLD_LIFTED* ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "edits=${edits:-none} output=${lift_output:-missing}"
	fi
	return 0
}
self_hold_lift_case "dispatched continuation lifts the superseded runner self-hold" 0 1 1
self_hold_lift_case "dispatch without a superseded hold edits no labels" 0 0 0
self_hold_lift_case "failed launch keeps the superseded hold" 1 1 0
self_hold_lift_case "deduplicated continuation keeps the hold for its launcher" "$PRRTS_RC_DISPATCH_DEFERRED" 1 0

STUB_PR_JSON="$(valid_pr_json)"
PCC_LINKED_ISSUE="123"
PCC_HEAD_REF="worker/issue-123"
PCC_HEAD_OID="1111111111111111111111111111111111111111"
PCC_ISSUE_ASSIGNEE="worker-bot"
PCC_EXPECTED_ASSIGNEE="worker-bot"
PCC_AUTHENTICATED_LOGIN="worker-bot"
PCC_CHECKPOINT_ASSIGNEE="worker-bot"
PCC_ORIGINAL_STATUS="in-review"
PCC_OWNERSHIP_TRANSFERRED=0
PCC_CLAIM_ACQUIRED=0
if [[ "$(_prrts_worker_task_id 42)" == "123" ]] &&
	[[ "$(_prrts_worker_login 42)" == "worker-bot" ]] &&
	_prrts_apply_expected_worktree_owner owner/repo 42 "${TEST_ROOT}/repo" \
		9999 issue-worker batch-1 123 2026-08-01T00:00:00Z process-start-1 "" &&
	[[ "$PRRTS_WORKTREE_EXPECTED_OWNER_TASK" == "123" &&
		"$PRRTS_WORKTREE_EXPECTED_OWNER_PROCESS_START" == "process-start-1" ]]; then
	print_result "continuation preserves the linked issue worktree task identity" 0
else
	print_result "continuation preserves the linked issue worktree task identity" 1
fi
STUB_ISSUE_JSON="$(valid_issue_json '' 'replacement-owner')"
if ! _prrts_prelaunch_target_fence "owner/repo" "42" "$PCC_HEAD_REF" "$PCC_HEAD_OID" && \
	[[ "$PRRTS_WORKTREE_FAILURE_REASON" == "pr_checkpoint_eligibility_changed_before_launch" ]]; then
	print_result "prelaunch fence rejects one-for-one issue reassignment" 0
else
	print_result "prelaunch fence rejects one-for-one issue reassignment" 1
fi
STUB_ISSUE_JSON="$(valid_issue_json)"
prompt_file=$(_prrts_write_prompt_file "owner/repo" "${TEST_ROOT}/repo" "42" "Continue existing work" "0" "fingerprint" "preview")
if [[ -f "$prompt_file" ]] && \
	grep -q 'verify-pr-checkpoint-target' "$prompt_file" && \
	grep -q 'PR_CHECKPOINT_TARGET_VALID' "$prompt_file" && \
	grep -Fq "\$AIDEVOPS_PR_REPAIR_LINKED_ISSUE" "$prompt_file" && \
	grep -Fq "\$AIDEVOPS_PR_REPAIR_ISSUE_ASSIGNEE" "$prompt_file" && \
	grep -Fq '"worker-bot"`' "$prompt_file" && \
	grep -q "HEAD:\$AIDEVOPS_PR_REPAIR_HEAD_REF" "$prompt_file" && \
	grep -q 'Do not create another branch' "$prompt_file"; then
	print_result "continuation prompt preserves exact-target ownership contract" 0
else
	print_result "continuation prompt preserves exact-target ownership contract" 1
fi
if ! grep -q 'non-closing checkpoint linked to issue' "$prompt_file"; then
	print_result "closing-linked continuation prompt has no For-line rewrite step" 0
else
	print_result "closing-linked continuation prompt has no For-line rewrite step" 1
fi
PCC_LINK_KIND="for"
prompt_file=$(_prrts_write_prompt_file "owner/repo" "${TEST_ROOT}/repo" "42" "Continue existing work" "0" "fingerprint" "preview")
if grep -Fq 'non-closing checkpoint linked to issue' "$prompt_file" &&
	grep -Fq 'replace that exact line with' "$prompt_file" &&
	grep -Fq "\`Resolves #123\`" "$prompt_file" &&
	grep -Fq -- '--json closingIssuesReferences' "$prompt_file"; then
	print_result "For-linked continuation must add a closing link before ready" 0
else
	print_result "For-linked continuation must add a closing link before ready" 1
fi
PCC_LINK_KIND="closing"

# Exercise the actual producer, transfer fence and worker preparation together.
# Only worktree/process mechanics are stubbed; GitHub remains the fixture above.
export CHECKPOINT_PREPARE_LIB="${TEST_SCRIPT_DIR}/../headless-runtime-worker-prepare.sh"
export HEADLESS_RUNTIME_OWNERSHIP_HELPER="${TEST_SCRIPT_DIR}/../dispatch-claim-helper.sh"
HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/bin/checkpoint-worker"
cat >"$HEADLESS_RUNTIME_HELPER" <<'WORKER_STUB'
#!/usr/bin/env bash
set -euo pipefail
source "$CHECKPOINT_PREPARE_LIB"
print_info() { printf '%s\n' "$*"; return 0; }
print_warning() { printf '%s\n' "$*"; return 0; }
print_error() { printf '%s\n' "$*"; return 0; }
_hrw_verify_dispatch_ownership
WORKER_STUB
chmod +x "$HEADLESS_RUNTIME_HELPER"

_prrts_prepare_thread_batch() {
	printf -v "$5" '%s' "$4"
	printf -v "$6" '%s' "$3"
	return 0
}
_prrts_prepare_worker_worktree() {
	printf -v "$6" '%s' "${TEST_ROOT}/repo"
	return 0
}
_prrts_initialize_attempt_state() {
	printf -v "$5" '%s' "${TEST_ROOT}/attempt.json"
	return 0
}
_prrts_write_state() { return 0; }
_prrts_activate_global_capacity() {
	[[ "$LAUNCH_VERIFIED" == 1 ]] || return 1
	return 0
}
_prrts_release_global_capacity() { return 0; }
_prrts_launch_detached_worker() {
	printf -v "$3" '%s' ""
	printf -v "$4" '%s' "fixture"
	shift 4
	LAUNCH_VERIFIED=0
	if "$@"; then
		LAUNCH_VERIFIED=1
	fi
	return 0
}

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'stale-runner')"
STUB_ISSUE_JSON="$(valid_issue_json '' 'stale-runner')"
PCC_LINKED_ISSUE=123
PCC_ISSUE_ASSIGNEE=stale-runner
PCC_EXPECTED_ASSIGNEE=stale-runner
PCC_AUTHENTICATED_LOGIN=current-runner
PCC_CHECKPOINT_ASSIGNEE=stale-runner
PCC_OWNERSHIP_TRANSFERRED=0
PCC_CLAIM_ACQUIRED=0
STUB_AUTH_LOGIN=current-runner
printf '[]' >"$STUB_CLAIM_FILE"
LAUNCH_VERIFIED=0
export DISPATCH_REPO_SLUG=unrelated/repository
if _prrts_dispatch_worker owner/repo "${TEST_ROOT}/repo" 42 checkpoint 0 fixture preview \
	"$PCC_HEAD_REF" "$PCC_HEAD_OID" attempt-fixture 1 1 false 0 fixture &&
	[[ "$LAUNCH_VERIFIED" == 1 && "$PCC_ISSUE_ASSIGNEE" == current-runner ]]; then
	print_result "producer-to-worker preparation preserves transferred owner and original author" 0
else
	print_result "producer-to-worker preparation preserves transferred owner and original author" 1
fi

run_checkpoint_preparation() {
	local original_author="$1"
	env WORKER_ISSUE_NUMBER=123 DISPATCH_REPO_SLUG=owner/repo \
		WORKER_GITHUB_LOGIN=current-runner AIDEVOPS_PR_REPAIR_NUMBER=42 \
		AIDEVOPS_PR_REPAIR_LINKED_ISSUE=123 AIDEVOPS_PR_REPAIR_OWNERSHIP_MODE= \
		AIDEVOPS_PR_REPAIR_ISSUE_ASSIGNEE=current-runner \
		"AIDEVOPS_PR_CHECKPOINT_AUTHOR=${original_author}" \
		"AIDEVOPS_PR_REPAIR_HEAD_SHA=${PCC_HEAD_OID}" \
		"AIDEVOPS_PR_REPAIR_HEAD_REF=${PCC_HEAD_REF}" "$HEADLESS_RUNTIME_HELPER"
	return $?
}

for rejected_author in foreign-runner current-runner ''; do
	if ! run_checkpoint_preparation "$rejected_author"; then
		print_result "worker preparation rejects wrong original author ${rejected_author:-missing}" 0
	else
		print_result "worker preparation rejects wrong original author ${rejected_author:-missing}" 1
	fi
done
STUB_ISSUE_JSON="$(valid_issue_json '' 'newer-owner')"
if ! run_checkpoint_preparation stale-runner; then
	print_result "worker preparation rejects newer owner after producer fence" 0
else
	print_result "worker preparation rejects newer owner after producer fence" 1
fi
STUB_ISSUE_JSON="$(valid_issue_json '' 'current-runner')"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'current-runner')"
if ! run_checkpoint_preparation ''; then
	print_result "worker preparation rejects unclaimed legacy same-runner continuation" 0
else
	print_result "worker preparation rejects unclaimed legacy same-runner continuation" 1
fi

# GH#33132: a worker that released as blocked after opening a draft must get
# one durable attention record instead of a silent WORKER_DRAFT_CHECKPOINT stall.
export STUB_POST_DIR="${TEST_ROOT}/posts"
mkdir -p "$STUB_POST_DIR"
blocked_head="1111111111111111111111111111111111111111"
blocked_comments() {
	local extra="${1:-}"
	printf '[[
  {"id":20,"created_at":"2026-09-30T01:00:00Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"DISPATCH_LEASE phase=ready attempt_id=attempt:abc123 lease_token=[redacted-credential] session=s1"},
  {"id":21,"created_at":"2026-09-30T01:10:00Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"<!-- ops:start -->\\nCLAIM_RELEASED reason=blocked runner=worker-bot ts=2026-09-30T01:10:00Z\\n<!-- ops:end -->"}%s
]]\n' "$extra"
	return 0
}
post_count() {
	find "$STUB_POST_DIR" -type f | wc -l | tr -d ' '
	return 0
}
STUB_PR_JSON="$(valid_pr_json)"
STUB_COMMENTS_JSON="$(blocked_comments)"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:* && "$(post_count)" == 1 ]] &&
	grep -Fq "<!-- aidevops:blocked-checkpoint-attention pr=42 head=${blocked_head} release=21 -->" "${STUB_POST_DIR}/post-1" &&
	grep -Fq 'approval-template owner/repo 42 123 21 attempt:abc123' "${STUB_POST_DIR}/post-1"; then
	print_result "blocked release plus worker draft posts one actionable attention record" 0
else
	print_result "blocked release plus worker draft posts one actionable attention record" 1 "output=${output:-missing} posts=$(post_count)"
fi

# The record must not look like a coordination event, or it would invalidate the
# release/successor chain a later revision-bound approval is validated against.
if ! grep -Eq '^(DISPATCH_CLAIM |DISPATCH_LEASE |CLAIM_RELEASED |Dispatching worker|Interactive session claimed|CHECKPOINT_CONTINUATION_APPROVED |terminal-blocker-circuit:retry)' \
	"${STUB_POST_DIR}/post-1"; then
	print_result "attention record never forges coordination or approval events" 0
else
	print_result "attention record never forges coordination or approval events" 1
fi

posted_body="$(<"${STUB_POST_DIR}/post-1")"
STUB_COMMENTS_JSON="$(blocked_comments ",
  $(jq -nc --arg body "$posted_body" '{id:22,created_at:"2026-09-30T01:20:00Z",author_association:"OWNER",user:{login:"pulse-runner"},body:$body}')")"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_EXISTS:* && "$(post_count)" == 1 ]]; then
	print_result "later pulse cycles deduplicate the attention record" 0
else
	print_result "later pulse cycles deduplicate the attention record" 1 "output=${output:-missing} posts=$(post_count)"
fi

STUB_COMMENTS_JSON="$(blocked_comments ',
  {"id":23,"created_at":"2026-09-30T01:30:00Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"DISPATCH_CLAIM nonce=n1 runner=worker-bot"}')"
if ! _pcc_blocked_attention owner/repo 123 42 >/dev/null && [[ "$(post_count)" == 1 ]]; then
	print_result "newer ownership evidence suppresses attention" 0
else
	print_result "newer ownership evidence suppresses attention" 1 "posts=$(post_count)"
fi

STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
if ! _pcc_blocked_attention owner/repo 123 42 >/dev/null && [[ "$(post_count)" == 1 ]]; then
	print_result "non-blocked draft checkpoint keeps its existing lifecycle" 0
else
	print_result "non-blocked draft checkpoint keeps its existing lifecycle" 1 "posts=$(post_count)"
fi

STUB_COMMENTS_JSON="$(blocked_comments)"
STUB_PR_JSON="$(valid_pr_json)"
STUB_PR_JSON="${STUB_PR_JSON/\"isDraft\":true/\"isDraft\":false}"
if ! _pcc_blocked_attention owner/repo 123 42 >/dev/null && [[ "$(post_count)" == 1 ]]; then
	print_result "ready PR is not treated as a blocked draft checkpoint" 0
else
	print_result "ready PR is not treated as a blocked draft checkpoint" 1 "posts=$(post_count)"
fi
STUB_PR_JSON="$(valid_pr_json)"

# GH#35174: an absent ready lease leaves the middle evidence field empty.
# Keep these posts separate from the existing fixtures' fixed post counts.
STUB_POST_DIR="${TEST_ROOT}/posts-no-attempt"
mkdir -p "$STUB_POST_DIR"
STUB_COMMENTS_JSON="$(blocked_comments | jq 'map(map(select(.id != 20)))')"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:* && "$(post_count)" == 1 ]] &&
	grep -Fq 'release_comment=21 attempt=unknown' "${STUB_POST_DIR}/post-1" &&
	grep -Fq 'approval-template owner/repo 42 123 21 attempt:<ORIGINAL_ID>' "${STUB_POST_DIR}/post-1"; then
	print_result "blocked release without ready lease preserves the unknown attempt" 0
else
	print_result "blocked release without ready lease preserves the unknown attempt" 1 "output=${output:-missing} posts=$(post_count)"
fi
posted_body="$(<"${STUB_POST_DIR}/post-1")"
STUB_COMMENTS_JSON="$(jq --arg body "$posted_body" '. + [[
	{id:22,author_association:"OWNER",user:{login:"pulse-runner"},body:$body}
]]' <<<"$STUB_COMMENTS_JSON")"
if output=$(_pcc_blocked_attention owner/repo 123 42) &&
	[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_EXISTS:* && "$(post_count)" == 1 ]]; then
	print_result "blocked release without ready lease deduplicates the second pulse" 0
else
	print_result "blocked release without ready lease deduplicates the second pulse" 1 "output=${output:-missing} posts=$(post_count)"
fi
for rearm in head release; do
	if [[ "$rearm" == head ]]; then
		STUB_PR_JSON="${STUB_PR_JSON//$blocked_head/2222222222222222222222222222222222222222}"
	else
		STUB_PR_JSON="$(valid_pr_json)"
		STUB_COMMENTS_JSON="$(jq '. + [[
			{id:23,author_association:"COLLABORATOR",user:{login:"worker-bot"},body:"CLAIM_RELEASED reason=blocked runner=worker-bot"}
		]]' <<<"$STUB_COMMENTS_JSON")"
	fi
	before_posts="$(post_count)"
	if output=$(_pcc_blocked_attention owner/repo 123 42) &&
		[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_POSTED:* && "$(post_count)" == "$((before_posts + 1))" ]]; then
		print_result "new ${rearm} re-arms blocked attention without ready lease" 0
	else
		print_result "new ${rearm} re-arms blocked attention without ready lease" 1 "output=${output:-missing}"
	fi
done

