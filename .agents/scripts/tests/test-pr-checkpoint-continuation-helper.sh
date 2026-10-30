#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pr-checkpoint-continuation-helper.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR="${TEST_ROOT}/state"
mkdir -p "${HOME}" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo" "$AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR"

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s%s\n' "$name" "${detail:+ — $detail}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
	printf '%s\n' "${STUB_PR_JSON:-}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123" ]]; then
	if [[ "${3:-}" == "--jq" ]]; then
		printf '%s\n' "${STUB_ISSUE_JSON:-}" | jq -r "$4"
		exit $?
	fi
	printf '%s\n' "${STUB_ISSUE_JSON:-}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123/comments?per_page=100" ]]; then
	printf '%s\n' "${STUB_COMMENTS_JSON:-[]}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123/comments" && "$3" == "--method" && "$4" == "POST" ]]; then
	[[ -n "${STUB_POST_DIR:-}" ]] || exit 1
	post_count=$(find "$STUB_POST_DIR" -type f | wc -l | tr -d ' ')
	printf '%s' "${6#body=}" >"${STUB_POST_DIR}/post-$((post_count + 1))"
	exit 0
fi
exit 1
GH_STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"

# shellcheck source=../pr-checkpoint-continuation-helper.sh
source "$HELPER"

valid_pr_json() {
	local body="${1:-Resolves #123}"
	local labels="${2:-}"
	local closing_refs="${3:-}"
	local author="${4:-worker-bot}"
	[[ -n "$labels" ]] || labels='[{"name":"origin:worker"}]'
	[[ -n "$closing_refs" ]] || closing_refs='[{"number":123,"repository":{"name":"repo","owner":{"login":"owner"}}}]'
	printf '{"number":42,"state":"OPEN","title":"Continue existing work","body":"%s","closingIssuesReferences":%s,"isDraft":true,"isCrossRepository":false,"labels":%s,"headRefName":"worker/issue-123","headRefOid":"1111111111111111111111111111111111111111","author":{"login":"%s"}}\n' \
		"$body" "$closing_refs" "$labels" "$author"
	return 0
}

valid_issue_json() {
	local labels="${1:-}"
	local assignee="${2:-worker-bot}"
	[[ -n "$labels" ]] || labels='[{"name":"status:in-review"}]'
	printf '{"number":123,"state":"open","labels":%s,"assignees":[{"login":"%s"}]}\n' "$labels" "$assignee"
	return 0
}

valid_checkpoint_comments() {
	local runner="worker-bot"
	printf '[[{"id":10,"created_at":"2026-08-04T22:29:37Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=worker_draft_checkpoint runner=%s ts=2026-08-04T22:29:36Z"}]]\n' "$runner"
	return 0
}

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'
export STUB_PR_JSON STUB_ISSUE_JSON STUB_COMMENTS_JSON
if row=$(_pcc_target_row "owner/repo" "42" "123") && \
	[[ "$row" == $'Continue existing work\tworker/issue-123\t1111111111111111111111111111111111111111\tworker-bot\tin-review\tworker-bot\t0\tclosing' ]]; then
	print_result "accepts exact open worker draft linked to issue" 0
else
	print_result "accepts exact open worker draft linked to issue" 1 "row=${row:-missing}"
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #1234' '' '[{"number":1234,"repository":{"name":"repo","owner":{"login":"owner"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects issue-number prefix collisions" 0
else
	print_result "rejects issue-number prefix collisions" 1
fi

STUB_PR_JSON="$(valid_pr_json 'unresolved #123' '' '[]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects bare issue references" 0
else
	print_result "rejects bare issue references" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123 and resolves #456' '' '[{"number":123,"repository":{"name":"repo","owner":{"login":"owner"}}},{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects ambiguous closing identities" 0
else
	print_result "rejects ambiguous closing identities" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves other/repo#123' '' '[{"number":123,"repository":{"name":"repo","owner":{"login":"other"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects cross-repository closing identities" 0
else
	print_result "rejects cross-repository closing identities" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_PR_JSON="${STUB_PR_JSON/\"isCrossRepository\":false/\"isCrossRepository\":true}"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects cross-repository checkpoint heads" 0
else
	print_result "rejects cross-repository checkpoint heads" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '[{"name":"origin:worker"},{"name":"needs-maintainer-review"}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects held worker drafts" 0
else
	print_result "rejects held worker drafts" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-review"},{"name":"needs-maintainer-review"}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects continuation after linked issue hold" 0
else
	print_result "rejects continuation after linked issue hold" 1
fi

for conflicting_status in status:blocked status:done status:in-progress; do
	STUB_ISSUE_JSON="$(valid_issue_json "[{\"name\":\"status:in-review\"},{\"name\":\"${conflicting_status}\"}]")"
	if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
		print_result "rejects contradictory linked issue lifecycle ${conflicting_status}" 0
	else
		print_result "rejects contradictory linked issue lifecycle ${conflicting_status}" 1
	fi
done

STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-review"},{"name":"origin:interactive"}]')"
STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
if _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "accepts interactive-provenance issue with current trusted checkpoint release" 0
else
	print_result "accepts interactive-provenance issue with current trusted checkpoint release" 1
fi

STUB_COMMENTS_JSON='[]'
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects interactive-provenance issue without checkpoint release" 0
else
	print_result "rejects interactive-provenance issue without checkpoint release" 1
fi

STUB_COMMENTS_JSON='[[
  {"id":10,"created_at":"2026-08-04T22:29:37Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=worker_draft_checkpoint runner=worker-bot ts=2026-08-04T22:29:36Z"},
  {"id":11,"created_at":"2026-08-04T22:30:37Z","author_association":"MEMBER","body":"Interactive session claimed this issue"}
]]'
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects replayed checkpoint release after a newer human claim" 0
else
	print_result "rejects replayed checkpoint release after a newer human claim" 1
fi

STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'foreign-runner')"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects foreign-authored worker checkpoint" 0
else
	print_result "rejects foreign-authored worker checkpoint" 1
fi

# GH#35883: auto-dispatch authorizes worker pickup of interactive-provenance
# issues, so a capability-released worker draft stays continuable on a capable
# runner, unless a newer trusted interactive claim owns the issue.
interactive_capability_comments() {
	local extra="${1:-}"
	printf '[[{"id":12,"created_at":"2026-08-04T22:40:00Z","author_association":"COLLABORATOR","user":{"login":"worker-bot"},"body":"CLAIM_RELEASED reason=blocked runner=worker-bot ts=2026-08-04T22:40:00Z\\n\\nTerminal blocker: reason=runner_capability_unmet owner=runner-recovery task=123 attempt=a1."}%s]]\n' "$extra"
	return 0
}
STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(jq -nc '{number:123,state:"open",labels:[{name:"status:available"},{name:"auto-dispatch"},{name:"origin:interactive"}],assignees:[]}')"
STUB_COMMENTS_JSON="$(interactive_capability_comments)"
PCC_ALLOW_RELEASED=true
if row=$(_pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" 2>/dev/null) &&
	[[ "$row" == *$'\tavailable\tworker-bot\t0\tclosing' ]]; then
	print_result "accepts capability-released draft on auto-dispatch interactive-provenance issue" 0
else
	print_result "accepts capability-released draft on auto-dispatch interactive-provenance issue" 1 "row=${row:-missing}"
fi
STUB_COMMENTS_JSON="$(interactive_capability_comments ',{"id":13,"created_at":"2026-08-04T22:50:00Z","author_association":"MEMBER","user":{"login":"maintainer"},"body":"Interactive session claimed this issue"}')"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null 2>&1; then
	print_result "rejects auto-dispatch interactive-provenance draft after a newer interactive claim" 0
else
	print_result "rejects auto-dispatch interactive-provenance draft after a newer interactive claim" 1
fi
STUB_ISSUE_JSON="$(jq -nc '{number:123,state:"open",labels:[{name:"status:available"},{name:"origin:interactive"}],assignees:[]}')"
STUB_COMMENTS_JSON="$(interactive_capability_comments)"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null 2>&1; then
	print_result "keeps interactive-provenance hold without auto-dispatch" 0
else
	print_result "keeps interactive-provenance hold without auto-dispatch" 1
fi
PCC_ALLOW_RELEASED=false
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'

# GH#34008: the pulse's own orphan-recovery draft links its issue only through
# a non-closing `For #N` line. The shared rule accepts exactly that shape.
TAKEOVER_LABELS='[{"name":"origin:worker-takeover"}]'
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'
STUB_PR_JSON="$(valid_pr_json 'Recovered dirty worktree.\nFor #123' "$TAKEOVER_LABELS" '[]')"
if row=$(_pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot") &&
	[[ "$row" == *$'\tworker-bot\t0\tfor' ]]; then
	print_result "accepts For #N origin:worker-takeover recovery draft" 0
else
	print_result "accepts For #N origin:worker-takeover recovery draft" 1 "row=${row:-missing}"
fi

for_reject_case() {
	local name="$1" body="$2" labels="$3" closing="$4" mutate="${5:-}"
	STUB_PR_JSON="$(valid_pr_json "$body" "$labels" "$closing")"
	case "$mutate" in
	ready) STUB_PR_JSON="${STUB_PR_JSON/\"isDraft\":true/\"isDraft\":false}" ;;
	cross) STUB_PR_JSON="${STUB_PR_JSON/\"isCrossRepository\":false/\"isCrossRepository\":true}" ;;
	esac
	if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null 2>&1; then
		print_result "rejects For #N draft: ${name}" 0
	else
		print_result "rejects For #N draft: ${name}" 1
	fi
	return 0
}
# Worker checkpoint drafts keep `For #N`/`Ref #N` on incomplete work (GH#33374)
# and has-open-pr already holds the issue for them, so continuation must accept
# the same exact single-target shape.
WORKER_LABELS='[{"name":"origin:worker"}]'
for worker_body in 'For #123' 'Ref #123. Incomplete checkpoint.' 'Notes\nRefs #123' 'For #123. Done part.\nRef #900'; do
	STUB_PR_JSON="$(valid_pr_json "$worker_body" "$WORKER_LABELS" '[]')"
	if row=$(_pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot") &&
		[[ "$row" == *$'\tworker-bot\t0\tfor' ]]; then
		print_result "accepts origin:worker non-closing checkpoint: ${worker_body}" 0
	else
		print_result "accepts origin:worker non-closing checkpoint: ${worker_body}" 1 "row=${row:-missing}"
	fi
done
for_reject_case "worker draft naming two For issues" 'For #123\nFor #456' "$WORKER_LABELS" '[]'
for_reject_case "worker draft whose For line names another issue" 'For #456\nRef #123' "$WORKER_LABELS" '[]'
for_reject_case "worker draft with Ref mid-line only" 'Batch for #77. Ref #123 later' "$WORKER_LABELS" '[]'
for_reject_case "worker draft with interactive label" 'Ref #123' '[{"name":"origin:worker"},{"name":"origin:interactive"}]' '[]'
for_reject_case "unlabelled draft" 'For #123' '[{"name":"bug"}]' '[]'
for_reject_case "ready PR" 'For #123' "$TAKEOVER_LABELS" '[]' ready
for_reject_case "cross-repository head" 'For #123' "$TAKEOVER_LABELS" '[]' cross
for_reject_case "protected label" 'For #123' '[{"name":"origin:worker-takeover"},{"name":"hold-for-review"}]' '[]'
for_reject_case "bare #N mention" 'Recovered work for #123' "$TAKEOVER_LABELS" '[]'
for_reject_case "issue-number prefix collision" 'For #1234' "$TAKEOVER_LABELS" '[]'
for_reject_case "closing link to another issue" 'For #123\nResolves #456' "$TAKEOVER_LABELS" \
	'[{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]'

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'

DISPATCH_ARGS=""
DISPATCH_RESULT=0
_prrts_dispatch_guarded() {
	local repo_slug="$1"
	local pr_number="$3"
	local head_ref="${11}"
	local head_oid="${12}"
	DISPATCH_ARGS="$*"
	_prrts_prelaunch_target_fence "$repo_slug" "$pr_number" "$head_ref" "$head_oid" || return 1
	return "$DISPATCH_RESULT"
}

STATUS_CALLS=""
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status="$3"
	local add_assignee=""
	local flag=""
	shift 3
	STATUS_CALLS="${STATUS_CALLS}${STATUS_CALLS:+$'\n'}${issue_number} ${repo_slug} ${status} $*"
	while [[ $# -gt 0 ]]; do
		flag="$1"
		case "$flag" in
		--add-assignee)
			add_assignee="${2:-}"
			shift 2
			;;
		--remove-assignee)
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	[[ -n "$add_assignee" ]] || return 1
	STUB_ISSUE_JSON="$(valid_issue_json "[{\"name\":\"status:${status}\"}]" "$add_assignee")"
	export STUB_ISSUE_JSON
	return 0
}

STUB_PR_JSON="$(valid_pr_json)"
output_file="${TEST_ROOT}/dispatch-output"
if _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot" >"$output_file"; then
	output="$(<"$output_file")"
else
	output="$(<"$output_file")"
fi
if [[ "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* ]] && \
	[[ "$DISPATCH_ARGS" == *"draft-checkpoint:1111111111111111111111111111111111111111:contract-4:0"* ]] && \
	[[ "$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* ]]; then
	print_result "dispatch binds continuation to exact PR branch and head" 0
else
	print_result "dispatch binds continuation to exact PR branch and head" 1 "output=${output:-missing} args=${DISPATCH_ARGS:-missing}"
fi

DISPATCH_RESULT="$PRRTS_RC_DISPATCH_DEFERRED"
if output=$(_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot") &&
	[[ "$output" == *PR_CHECKPOINT_CONTINUATION_DEDUPLICATED* ]]; then
	print_result "active exact-head continuation is deduplicated as handled" 0
else
	print_result "active exact-head continuation is deduplicated as handled" 1 "output=${output:-missing}"
fi

DISPATCH_RESULT="$PRRTS_RC_MAINTAINER_ATTENTION"
if ! output=$(_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot") &&
	[[ "$output" == *PR_CHECKPOINT_CONTINUATION_EXHAUSTED* ]]; then
	print_result "bounded retry exhaustion is explicit" 0
else
	print_result "bounded retry exhaustion is explicit" 1 "output=${output:-missing}"
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'stale-runner')"
STUB_ISSUE_JSON="$(valid_issue_json '' 'stale-runner')"
STATUS_CALLS=""
DISPATCH_RESULT=0
if _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "stale-runner" "current-runner" >/dev/null &&
	[[ "$STATUS_CALLS" == '123 owner/repo in-progress --add-assignee current-runner --remove-assignee stale-runner' ]] &&
	[[ "$PCC_ISSUE_ASSIGNEE" == "current-runner" ]] &&
	[[ "$(_prrts_worker_login 42)" == "current-runner" ]]; then
	print_result "cross-runner continuation transfers exact issue ownership before launch" 0
else
	print_result "cross-runner continuation transfers exact issue ownership before launch" 1 \
		"calls=${STATUS_CALLS:-missing} assignee=${PCC_ISSUE_ASSIGNEE:-missing}"
fi

STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:queued"}]' 'stale-runner')"
STATUS_CALLS=""
DISPATCH_RESULT=1
if ! _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "stale-runner" "current-runner" >/dev/null &&
	[[ "$STATUS_CALLS" == $'123 owner/repo in-progress --add-assignee current-runner --remove-assignee stale-runner\n123 owner/repo queued --add-assignee stale-runner --remove-assignee current-runner' ]] &&
	[[ "$PCC_ISSUE_ASSIGNEE" == "stale-runner" && "$PCC_OWNERSHIP_TRANSFERRED" -eq 0 ]] &&
	printf '%s' "$STUB_ISSUE_JSON" | jq -e '
		.assignees[0].login == "stale-runner" and
		([.labels[].name] | index("status:queued") != null)
	' >/dev/null; then
	print_result "failed cross-runner launch restores prior assignee and lifecycle" 0
else
	print_result "failed cross-runner launch restores prior assignee and lifecycle" 1 \
		"calls=${STATUS_CALLS:-missing} assignee=${PCC_ISSUE_ASSIGNEE:-missing}"
fi
DISPATCH_RESULT=0

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
if run_checkpoint_preparation ''; then
	print_result "worker preparation retains legacy same-runner author fallback" 0
else
	print_result "worker preparation retains legacy same-runner author fallback" 1
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
# worker_complete moved to the bounded exact-head continuation below).
for completed_reason in capability_limit worker_failed; do
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
	STUB_COMMENTS_JSON="$(jq --arg body "$completed_body" '. + [[
		{id:25,author_association:"OWNER",user:{login:"pulse-runner"},body:$body},
		{id:26,author_association:"OWNER",user:{login:"pulse-runner"},body:"CLAIM_RELEASED reason=capability_limit runner=pulse-runner"}
	]]' <<<"$STUB_COMMENTS_JSON")"
	if output=$(_pcc_blocked_attention owner/repo 123 42) &&
		[[ "$output" == BLOCKED_CHECKPOINT_ATTENTION_EXISTS:* && "$(post_count)" == "$((before_posts + 1))" ]]; then
		print_result "${completed_reason} attention deduplicates later releases at the same head" 0
	else
		print_result "${completed_reason} attention deduplicates later releases at the same head" 1
	fi
	new_head="2222222222222222222222222222222222222222"
	if evidence=$(_pcc_completed_release_evidence "$STUB_COMMENTS_JSON" "aidevops:blocked-checkpoint-attention pr=42 head=${new_head}") &&
		[[ "$evidence" == $'26\tcapability_limit\tfalse' ]]; then
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
	[[ "$output" == $'31\tno_activity\t1\tfalse\t0\tfalse' ]]; then
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
RELEASED_ISSUE_JSON="$(jq -nc '{number:123,state:"open",labels:[{name:"status:available"}],assignees:[]}')"
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
export STUB_POST_DIR="${TEST_ROOT}/posts"
for release_reason in stale_assignment_reset worker_ownership_lost worker_draft_checkpoint clean worker_complete; do
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
# A later head pushed after the fuse record adds no second fuse comment.
STUB_COMMENTS_JSON="$(jq -c --arg body "$fuse_body" 'map(. + [{id:70,created_at:"2026-09-30T00:06:00Z",
	author_association:"OWNER",user:{login:"pulse-runner"},body:$body}])' <<<"$fuse_comments")"
STUB_PR_JSON="$(jq -c '.headRefOid = "2222222222222222222222222222222222222222" |
	.commits += [{oid:"2222222222222222222222222222222222222222",committedDate:"2026-09-30T00:10:00Z"}]' <<<"$STUB_PR_JSON")"
DISPATCH_ARGS=""
posts_before="$(post_count)"
_pcc_dispatch_stalled owner/repo "${TEST_ROOT}/repo" 123 42 current-runner >"$output_file" || true
output="$(<"$output_file")"
if [[ -n "$fuse_body" && "$output" == *STALLED_CHECKPOINT_ATTENTION_EXISTS*"head=2222"* &&
	-z "$DISPATCH_ARGS" && "$(post_count)" -eq "$posts_before" ]]; then
	print_result "per-PR fuse record is not repeated for a later head" 0
else
	print_result "per-PR fuse record is not repeated for a later head" 1 "output=${output:-missing}"
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
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' | with_head_commit)"

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
if run_checkpoint_preparation worker-bot >/dev/null 2>&1; then
	print_result "worker fence accepts the capable successor after a capability release" 0
else
	print_result "worker fence accepts the capable successor after a capability release" 1
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
if run_checkpoint_preparation worker-bot >/dev/null 2>&1; then
	print_result "worker fence accepts the capable successor on an auto-dispatch interactive-provenance issue" 0
else
	print_result "worker fence accepts the capable successor on an auto-dispatch interactive-provenance issue" 1
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

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
