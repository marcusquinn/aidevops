#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: worker CLAIM_RELEASED must unlock the issue that dispatch
# locked before worker launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
CALL_LOG="${TMP_HOME}/gh-calls.log"
: >"$CALL_LOG"
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1
# Terminal-blocker capture appends to the worker blocker log; keep fixture
# rows out of the operator's live ~/.aidevops/logs diagnostics (GH#36171).
export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="${TMP_HOME}/worker-progress-blockers.jsonl"
# Keep the upstream terminal-lease recovery outbox isolated as well.
export AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="${TMP_HOME}/objective-evidence.jsonl"

cleanup() {
	rm -rf "$TMP_HOME"
	return 0
}
trap cleanup EXIT

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >>"$CALL_LOG"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >>"$CALL_LOG"
	return 0
}

clear_active_status_on_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	local draft_projection="${4:-blocked}"
	printf 'CLEAR issue=%s repo=%s runner=%s draft=%s\n' "$issue_number" "$repo_slug" "$runner_name" "$draft_projection" >>"$CALL_LOG"
	return 0
}

whoami() {
	printf 'local-os-user\n'
	return 0
}

# Return the paginated fixture snapshot, including any release just persisted.
claim_comment_pages() {
	[[ "${GH_CLAIM_READ_FAILURE:-0}" -eq 0 ]] || return 1
	local claim_read_count=0 claim_fixture=""
	claim_read_count=$(grep -c '^CLAIM_READ$' "$CALL_LOG") || claim_read_count=0
	claim_read_count=$((claim_read_count + 1))
	printf 'CLAIM_READ\n' >>"$CALL_LOG"
	if [[ "${GH_CLAIM_READ_FAIL_AFTER_POST:-0}" -eq 1 ]] && grep -q '^POSTED_RELEASE$' "$CALL_LOG"; then
		return 1
	fi
	if [[ -n "${GH_CLAIM_EVIDENCE:-}" ]]; then
		claim_fixture="$GH_CLAIM_EVIDENCE"
	elif [[ -n "${GH_RELEASE_COMMENTS:-}" ]]; then
		claim_fixture=$(jq -c '[.]' <<<"$GH_RELEASE_COMMENTS")
	else
		claim_fixture=$(jq -nc --arg author "${CLAIM_FIXTURE_AUTHOR:-${WORKER_GITHUB_LOGIN:-api-login}}" \
			--arg token "${CLAIM_FIXTURE_TOKEN:-fixture-lease}" '
			[[{id:100, node_id:"CLAIM_FIXTURE_100", user:{login:$author}, author_association:"OWNER", created_at:"2026-11-01T00:00:00Z",
			updated_at:"2026-11-01T00:00:00Z", body:("DISPATCH_CLAIM runner=" + $author +
			" nonce=" + $token + " lease_token=" + $token + " device=fixture-device session=issue-12345")}]]')
	fi
	if [[ "$claim_read_count" -ge 2 && -n "${GH_CLAIM_EVIDENCE_AFTER_READ:-}" ]]; then
		claim_fixture="$GH_CLAIM_EVIDENCE_AFTER_READ"
	fi
	if grep -q '^POSTED_RELEASE$' "$CALL_LOG"; then
		claim_fixture="${GH_CLAIM_EVIDENCE_AFTER_POST:-$claim_fixture}"
		jq -c --slurpfile posted "${TMP_HOME}/posted-release.json" '.[0] += $posted' <<<"$claim_fixture"
	else
		printf '%s\n' "$claim_fixture"
	fi
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		local path="${1:-}"
		shift || true
		if [[ "$path" == "user" ]]; then
			printf 'api-login\n'
			return 0
		fi
		if [[ "$path" == graphql ]]; then
			[[ "${GH_EDIT_READ_FAILURE:-0}" -eq 0 ]] || return 1
			if [[ -n "${GH_EDIT_RESPONSE:-}" ]]; then
				printf '%s\n' "$GH_EDIT_RESPONSE"
			else
				jq -nc --args '$ARGS.positional | map(select(startswith("ids[]=")) |
					{id:ltrimstr("ids[]="),lastEditedAt:null}) | {data:{nodes:.}}' -- "$@"
			fi
			return 0
		fi
		if [[ "$path" == 'repos/owner/repo/issues/12345' && -n "${GH_LIVE_ISSUE:-}" ]]; then
			printf '%s\n' "$GH_LIVE_ISSUE"
			return 0
		fi
		if [[ "$path" == *'/comments?per_page=100' && " $* " == *' --slurp '* ]]; then
			claim_comment_pages
			return $?
		fi
		if [[ "$path" == *'/comments?per_page=100' && -n "${GH_RELEASE_COMMENTS:-}" ]]; then
			printf '%s\n' "$GH_RELEASE_COMMENTS"
			return 0
		fi
		if [[ "$path" == repos/*/issues/* && "${GH_ISSUE_LABELS:-}" != "" ]]; then
			printf '%s\n' "$GH_ISSUE_LABELS"
			return 0
		fi
		local method="GET" body="" prev=""
		local arg
		for arg in "$@"; do
			if [[ "$prev" == "--method" ]]; then
				method="$arg"
			fi
			if [[ "$arg" == body=* ]]; then
				body="${arg#body=}"
			fi
			prev="$arg"
		done
		printf 'API method=%s path=%s body=%s\n' "$method" "$path" "$body" >>"$CALL_LOG"
		if [[ "$path" == */comments && "$method" == "POST" ]]; then
			local attempt_count=0
			if [[ -f "${TMP_HOME}/comment-attempts" ]]; then
				attempt_count=$(<"${TMP_HOME}/comment-attempts")
			fi
			attempt_count=$((attempt_count + 1))
			printf '%s\n' "$attempt_count" >"${TMP_HOME}/comment-attempts"
			if [[ "$attempt_count" -le "${GH_COMMENT_FAILURES_BEFORE_SUCCESS:-0}" ]]; then
				printf 'temporary comment failure %s\n' "$attempt_count" >&2
				return 1
			fi
			jq -nc --arg body "$body" --arg author "${WORKER_GITHUB_LOGIN:-api-login}" '
				{id:200,node_id:"CLAIM_FIXTURE_200",user:{login:$author},created_at:"2026-11-03T00:00:00Z",updated_at:"2026-11-03T00:00:00Z",body:$body}' \
				>"${TMP_HOME}/posted-release.json"
			printf 'POSTED_RELEASE\n' >>"$CALL_LOG"
		fi
		printf '{}\n'
		;;
	issue)
		local subcmd="${1:-}"
		shift || true
		if [[ "$subcmd" == "unlock" ]]; then
			local issue_number="${1:-}"
			shift || true
			local repo_slug="" prev=""
			local arg
			for arg in "$@"; do
				if [[ "$prev" == "--repo" ]]; then
					repo_slug="$arg"
				fi
				prev="$arg"
			done
			printf 'UNLOCK issue=%s repo=%s\n' "$issue_number" "$repo_slug" >>"$CALL_LOG"
			case "${GH_UNLOCK_MODE:-success}" in
			already_unlocked)
				printf 'GraphQL: Issue is not locked\n' >&2
				return 1
				;;
			hard_fail)
				printf 'GraphQL: repository access denied\n' >&2
				return 1
				;;
			*) ;;
			esac
		fi
		;;
	*) ;;
	esac
	return 0
}

# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER
_release_dispatch_claim "supervisor-pulse" "process_exit" "1" "0"
if grep -q 'Cannot release claim: missing issue= repo=' "$CALL_LOG"; then
	printf 'FAIL empty non-worker claim release emitted warning\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
printf 'PASS empty non-worker claim release is a silent no-op\n'
: >"$CALL_LOG"

export DISPATCH_REPO_SLUG="owner/repo"
export WORKER_GITHUB_LOGIN="assigned-bot"
export AIDEVOPS_DISPATCH_LEASE_TOKEN="fixture-lease"
export AIDEVOPS_DISPATCH_LEASE_DEVICE="fixture-device"
export AIDEVOPS_DISPATCH_LEASE_SESSION="issue-12345"
# Keep lease-transition subprocesses offline; the explicit denial case below
# supplies its own executable fixture.
export DISPATCH_CLAIM_HELPER="${TMP_HOME}/missing-claim-helper"

for unowned_case in missing_context absent_claim wrong_actor wrong_token wrong_session wrong_device; do
	: >"$CALL_LOG"
	case "$unowned_case" in
	missing_context) AIDEVOPS_DISPATCH_LEASE_TOKEN="" _release_dispatch_claim "issue-12345" worker_ownership_lost ;;
	absent_claim) GH_CLAIM_EVIDENCE='[[]]' _release_dispatch_claim "issue-12345" worker_complete ;;
	wrong_actor) CLAIM_FIXTURE_AUTHOR="another-worker" _release_dispatch_claim "issue-12345" worker_complete ;;
	wrong_token) AIDEVOPS_DISPATCH_LEASE_TOKEN="another-lease" _release_dispatch_claim "issue-12345" worker_complete ;;
	wrong_session) AIDEVOPS_DISPATCH_LEASE_SESSION="another-session" _release_dispatch_claim "issue-12345" worker_complete ;;
	wrong_device) AIDEVOPS_DISPATCH_LEASE_DEVICE="another-device" _release_dispatch_claim "issue-12345" worker_complete ;;
	esac
	if grep -Eq 'API method=POST|^CLEAR |^UNLOCK ' "$CALL_LOG"; then
		printf 'FAIL unowned release mutated issue state: %s\n' "$unowned_case"
		exit 1
	fi
	printf 'PASS unowned release has no coordination or issue-state writes: %s\n' "$unowned_case"
done
: >"$CALL_LOG"
if GH_CLAIM_READ_FAILURE=1 _release_dispatch_claim "issue-12345" worker_complete; then
	printf 'FAIL unavailable claim evidence was treated as release authority\n'
	exit 1
fi
if grep -Eq 'API method=POST|^CLEAR |^UNLOCK ' "$CALL_LOG"; then
	printf 'FAIL unavailable claim evidence mutated issue state\n'
	exit 1
fi
printf 'PASS unavailable claim evidence remains retryable without writes\n'

valid_claim_evidence=$(gh api 'repos/owner/repo/issues/12345/comments?per_page=100' --slurp)
for evidence_case in edited ambiguous unreadable invalid_timestamp duplicate_fields already_released unbound_release wrong_claim_release wrong_nonce_release edited_release mixed_receipts terminal; do
	: >"$CALL_LOG"
	expected_result=1
	evidence_edit_response=""
	case "$evidence_case" in
	edited)
		evidence=$(jq -c '.[0][0].updated_at = "2026-11-02T00:00:00Z"' <<<"$valid_claim_evidence")
		evidence_edit_response='{"data":{"nodes":[{"id":"CLAIM_FIXTURE_100","lastEditedAt":"2026-11-02T00:00:00Z"}]}}'
		;;
	ambiguous) evidence=$(jq -c '.[0] += .[0]' <<<"$valid_claim_evidence") ;;
	unreadable) evidence='not JSON' ;;
	invalid_timestamp) evidence=$(jq -c '.[0][0] |= (.created_at = "invalid" | .updated_at = "invalid")' <<<"$valid_claim_evidence") ;;
	duplicate_fields) evidence=$(jq -c '.[0][0].body += " nonce=fixture-lease"' <<<"$valid_claim_evidence") ;;
	already_released | unbound_release | wrong_claim_release | wrong_nonce_release | edited_release | mixed_receipts)
		evidence=$(jq -c '.[0] += [(.[0][0] | .id=101 | .node_id="CLAIM_FIXTURE_101" |
			.body="CLAIM_RELEASED reason=worker_complete runner=assigned-bot claim_id=100 nonce=fixture-lease")]' <<<"$valid_claim_evidence")
		case "$evidence_case" in
		already_released) expected_result=0 ;;
		unbound_release) evidence=$(jq -c '.[0][1].body="CLAIM_RELEASED reason=worker_complete runner=assigned-bot"' <<<"$evidence") ;;
		wrong_claim_release) evidence=$(jq -c '.[0][1].body |= sub("claim_id=100";"claim_id=99")' <<<"$evidence") ;;
		wrong_nonce_release) evidence=$(jq -c '.[0][1].body |= sub("nonce=fixture-lease";"nonce=other-lease")' <<<"$evidence") ;;
		edited_release) evidence_edit_response='{"data":{"nodes":[{"id":"CLAIM_FIXTURE_100","lastEditedAt":null},{"id":"CLAIM_FIXTURE_101","lastEditedAt":"2026-11-01T00:00:00Z"}]}}' ;;
		mixed_receipts) evidence=$(jq -c '.[0] += [(.[0][1] | .id=102 | .node_id="CLAIM_FIXTURE_102" | .body |= sub("claim_id=100";"claim_id=99"))]' <<<"$evidence") ;;
		esac
		;;
	terminal)
		expected_result=0
		evidence=$(jq -c '.[0] += [(.[0][0] | .id = 101 |
			.body = "DISPATCH_LEASE phase=terminal lease_token=fixture-lease device=fixture-device session=issue-12345")]' <<<"$valid_claim_evidence")
		;;
	esac
	result=0
	GH_CLAIM_EVIDENCE="$evidence" GH_EDIT_RESPONSE="$evidence_edit_response" \
		_release_dispatch_claim "issue-12345" worker_complete || result=$?
	if [[ "$result" -ne "$expected_result" ]] ||
		grep -Eq 'API method=POST|^CLEAR |^UNLOCK ' "$CALL_LOG"; then
		printf 'FAIL invalid or consumed claim evidence was not held safely: %s\n' "$evidence_case"
		exit 1
	fi
	printf 'PASS invalid or consumed claim evidence has no writes: %s\n' "$evidence_case"
done
: >"$CALL_LOG"
paginated_claim_evidence=$(jq -c '[[], .[0]]' <<<"$valid_claim_evidence")
AIDEVOPS_DISPATCH_LEASE_DEVICE="" AIDEVOPS_DEVICE_ID="fixture-device" \
	GH_CLAIM_EVIDENCE="$paginated_claim_evidence" _release_dispatch_claim "issue-12345" "worker_noop" "0" "0"

if grep -q 'CLAIM_RELEASED reason=worker_noop' "$CALL_LOG" &&
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot draft=available' "$CALL_LOG" &&
	grep -q 'runner=assigned-bot' "$CALL_LOG" &&
	! grep -q 'runner=local-os-user' "$CALL_LOG" &&
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS paginated own claim with explicit device identity releases and projects issue state\n'
else
	printf 'FAIL release lifecycle missing expected calls\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

# A replacement generation fences both pre-post retries and post-write projection.
replacement_claim_evidence=$(jq -c '.[0] += [ (.[0][0] | .id = 101 |
	.user.login = "another-worker" | .body = "DISPATCH_CLAIM runner=another-worker nonce=other lease_token=other device=other session=other") ]' <<<"$valid_claim_evidence")
for race_case in before_post after_post unavailable_after_post; do
	: >"$CALL_LOG"
	case "$race_case" in
	before_post)
		GH_CLAIM_EVIDENCE_AFTER_READ="$replacement_claim_evidence" \
			_release_dispatch_claim "issue-12345" "worker_noop" "0" "0" && exit 1
		! grep -q '^POSTED_RELEASE$' "$CALL_LOG" || exit 1
		;;
	after_post)
		GH_CLAIM_EVIDENCE_AFTER_POST="$replacement_claim_evidence" \
			_release_dispatch_claim "issue-12345" "worker_noop" "0" "0" && exit 1
		grep -q '^POSTED_RELEASE$' "$CALL_LOG" || exit 1
		;;
	unavailable_after_post)
		GH_CLAIM_READ_FAIL_AFTER_POST=1 \
			_release_dispatch_claim "issue-12345" "worker_noop" "0" "0" && exit 1
		grep -q '^POSTED_RELEASE$' "$CALL_LOG" || exit 1
		;;
	esac
	if grep -Eq '^(CLEAR|UNLOCK|EDIT|LEASE) ' "$CALL_LOG"; then
		printf 'FAIL stale or uncertain generation projected issue state: %s\n' "$race_case"
		exit 1
	fi
	printf 'PASS claim-generation race preserves issue state: %s\n' "$race_case"
done

# Minimized comments can have REST update timestamps without a body edit.
edited_claim_evidence=$(jq -c '.[0][0].node_id = "NODE_FIXTURE" |
	.[0][0].updated_at = "2026-11-02T00:00:00Z"' <<<"$valid_claim_evidence")
for edit_case in confirmed_unedited body_edited partial_response; do
	: >"$CALL_LOG"
	case "$edit_case" in
	confirmed_unedited) edit_response='{"data":{"nodes":[{"id":"NODE_FIXTURE","lastEditedAt":null},{"id":"CLAIM_FIXTURE_200","lastEditedAt":null}]}}' ;;
	body_edited) edit_response='{"data":{"nodes":[{"id":"NODE_FIXTURE","lastEditedAt":"2026-11-02T00:00:00Z"}]}}' ;;
	partial_response) edit_response='{"data":{"nodes":[{"id":"NODE_FIXTURE"}]}}' ;;
	esac
	edit_rc=0
	GH_CLAIM_EVIDENCE="$edited_claim_evidence" GH_EDIT_RESPONSE="$edit_response" \
		_release_dispatch_claim "issue-12345" "worker_noop" "0" "0" || edit_rc=$?
	if [[ "$edit_case" == confirmed_unedited ]]; then
		[[ "$edit_rc" -eq 0 ]] && grep -q '^CLEAR ' "$CALL_LOG" || exit 1
	else
		[[ "$edit_rc" -ne 0 ]] || exit 1
		! grep -Eq '^(API .*POST|CLEAR|UNLOCK|EDIT|LEASE) ' "$CALL_LOG" || exit 1
	fi
	printf 'PASS edit evidence remains fail-closed: %s\n' "$edit_case"
done

# Equal REST timestamps cannot exclude same-second edits of either the claim
# or a later protocol event. Missing positive edit evidence must also hold.
for same_second_case in edited missing_evidence partial_evidence later_lease_edit projection_edit; do
	: >"$CALL_LOG"
	same_second_evidence="$valid_claim_evidence"
	same_second_failure=0
	same_second_response='{"data":{"nodes":[{"id":"CLAIM_FIXTURE_100","lastEditedAt":"2026-11-01T00:00:00Z"}]}}'
	case "$same_second_case" in
	missing_evidence) same_second_failure=1 ;;
	partial_evidence) same_second_response='{"data":{"nodes":[{"id":"CLAIM_FIXTURE_100"}]}}' ;;
	later_lease_edit)
		same_second_evidence=$(jq -c '.[0] += [(.[0][0] | .id=101 | .node_id="CLAIM_FIXTURE_101" |
			.body="DISPATCH_LEASE phase=ready lease_token=fixture-lease device=fixture-device session=issue-12345")]' <<<"$valid_claim_evidence")
		same_second_response='{"data":{"nodes":[{"id":"CLAIM_FIXTURE_100","lastEditedAt":null},{"id":"CLAIM_FIXTURE_101","lastEditedAt":"2026-11-01T00:00:00Z"}]}}'
		;;
	projection_edit)
		same_second_response='{"data":{"nodes":[{"id":"CLAIM_FIXTURE_100","lastEditedAt":null},{"id":"CLAIM_FIXTURE_200","lastEditedAt":"2026-11-03T00:00:00Z"}]}}'
		;;
	esac
	if GH_CLAIM_EVIDENCE="$same_second_evidence" GH_EDIT_RESPONSE="$same_second_response" \
		GH_EDIT_READ_FAILURE="$same_second_failure" _release_dispatch_claim issue-12345 worker_complete; then
		printf 'FAIL same-second edit evidence authorized projection: %s\n' "$same_second_case"
		exit 1
	fi
	! grep -Eq '^(CLEAR|UNLOCK|EDIT|LEASE) ' "$CALL_LOG" || exit 1
	if [[ "$same_second_case" == projection_edit ]]; then
		grep -q '^POSTED_RELEASE$' "$CALL_LOG" || exit 1
	else
		! grep -q 'API method=POST' "$CALL_LOG" || exit 1
	fi
	printf 'PASS same-second edit fence: %s\n' "$same_second_case"
done

# GH#35684: model selection fails before _cmd_run_prepare exports
# DISPATCH_REPO_SLUG; the dispatcher-supplied WORKER_REPO_SLUG must still
# release the claim instead of stranding the issue.
: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
unset DISPATCH_REPO_SLUG
export WORKER_REPO_SLUG="owner/repo"
_release_dispatch_claim "issue-12345" "worker_failed" "1" "0"
unset WORKER_REPO_SLUG
export DISPATCH_REPO_SLUG="owner/repo"
if grep -q 'CLAIM_RELEASED reason=worker_failed' "$CALL_LOG" &&
	grep -q 'CLEAR issue=12345 repo=owner/repo' "$CALL_LOG" &&
	! grep -q 'Cannot release claim' "$CALL_LOG"; then
	printf 'PASS pre-launch release falls back to WORKER_REPO_SLUG\n'
else
	printf 'FAIL pre-launch release did not use WORKER_REPO_SLUG\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
export WORKER_ISSUE_NUMBER="12345"
export AIDEVOPS_PR_REPAIR_NUMBER="12345"
export AIDEVOPS_PR_REPAIR_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export AIDEVOPS_PR_REPAIR_HEAD_REF="feature/review"
_release_dispatch_claim "pr-review-thread-response-owner-repo-12345" "worker_failed" "1" "0"
if grep -q 'scanner owns lifecycle state' "$CALL_LOG" && \
	! grep -q '^API ' "$CALL_LOG" && ! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS direct PR repair leaves release lifecycle to scanner without issue mutations\n'
else
	printf 'FAIL direct PR repair performed generic issue release mutations\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
export AIDEVOPS_PR_REPAIR_NUMBER="67890"
_release_dispatch_claim "issue-12345" "worker_noop" "0" "0"
if grep -q 'CLAIM_RELEASED reason=worker_noop' "$CALL_LOG" && \
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" && \
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS linked-issue PR repair preserves generic issue release lifecycle\n'
else
	printf 'FAIL linked-issue PR repair skipped strict issue release lifecycle\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
unset WORKER_ISSUE_NUMBER AIDEVOPS_PR_REPAIR_NUMBER AIDEVOPS_PR_REPAIR_HEAD_SHA AIDEVOPS_PR_REPAIR_HEAD_REF

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
if GH_COMMENT_FAILURES_BEFORE_SUCCESS=2 AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=3 \
	AIDEVOPS_CLAIM_RELEASE_POST_RETRY_DELAY=0 \
	_release_dispatch_claim "issue-12345" "worker_noop" "0" "0" && \
	[[ "$(<"${TMP_HOME}/comment-attempts")" == "3" ]] && \
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" && \
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS release comment retries transient persistence failures\n'
else
	printf 'FAIL release comment did not retry transient persistence failures\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
if GH_COMMENT_FAILURES_BEFORE_SUCCESS=5 AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=2 \
	AIDEVOPS_CLAIM_RELEASE_POST_RETRY_DELAY=0 \
	_release_dispatch_claim "issue-12345" "worker_noop" "0" "0"; then
	printf 'FAIL exhausted release comment persistence was reported as successful\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi
if [[ "$(<"${TMP_HOME}/comment-attempts")" == "2" ]] && \
	grep -q 'WARN Failed to post CLAIM_RELEASED on #12345 after 2 attempt(s)' "$CALL_LOG" && \
	! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS exhausted release comment persistence is surfaced and remains retryable\n'
else
	printf 'FAIL exhausted release comment persistence was not surfaced safely\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
_release_dispatch_claim "issue-12345" "worker_ownership_lost" "1" "0"
if grep -q 'CLAIM_RELEASED reason=worker_ownership_lost' "$CALL_LOG" && \
	! grep -q '^CLEAR ' "$CALL_LOG" && ! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS ownership-loss release terminalizes lease without changing live issue ownership\n'
else
	printf 'FAIL ownership-loss release changed live issue ownership\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
_release_dispatch_claim "issue-12345" "worker_draft_checkpoint" "1" "0"
# GH#36019: the preserved draft is projected for exact-head continuation, not
# as blocked partial work that the continuation target fence would reject.
if grep -q 'CLAIM_RELEASED reason=worker_draft_checkpoint' "$CALL_LOG" && \
	grep -q 'Draft checkpoint: partial work is preserved on the draft PR' "$CALL_LOG" && \
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot draft=available' "$CALL_LOG" && \
	grep -q 'Projected draft checkpoint #12345 for exact-head continuation' "$CALL_LOG"; then
	printf 'PASS draft-checkpoint release projects its draft for exact-head continuation\n'
else
	printf 'FAIL draft-checkpoint release did not project its draft for exact-head continuation\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

# GH#33545: a merged ready partial PR keeps the same projection but must not
# be described as blocked draft work.
: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
_release_dispatch_claim "issue-12345" "worker_merged_partial" "1" "0"
if grep -q 'CLAIM_RELEASED reason=worker_merged_partial' "$CALL_LOG" && \
	grep -q 'Partial PR merged; issue stays open for continuation from the brief ledger' "$CALL_LOG" && \
	! grep -q 'Draft checkpoint: partial work' "$CALL_LOG" && \
	grep -q 'CLEAR issue=12345 repo=owner/repo runner=assigned-bot' "$CALL_LOG" && \
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG" && \
	grep -q 'Released merged partial #12345 for continuation' "$CALL_LOG"; then
	printf 'PASS merged-partial release projects continuation, not blocked draft work\n'
else
	printf 'FAIL merged-partial release wording or projection is wrong\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

# GH#33287: ready-PR handoffs already projected status:in-review; the generic
# closing-keyword projection must not reset a `For #N` PR's issue to available.
for ready_reason in worker_ready_missing_linkage worker_ready_missing_summary; do
	: >"$CALL_LOG"
	rm -f "${TMP_HOME}/comment-attempts"
	_release_dispatch_claim "issue-12345" "$ready_reason" "0" "0"
	if grep -q "CLAIM_RELEASED reason=${ready_reason}" "$CALL_LOG" && \
		grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG" && \
		! grep -q '^CLEAR ' "$CALL_LOG"; then
		printf 'PASS %s release preserves the in-review handoff\n' "$ready_reason"
	else
		printf 'FAIL %s release reset the in-review handoff\n' "$ready_reason"
		sed 's/^/  /' "$CALL_LOG"
		exit 1
	fi
done

# GH#35574: a denied terminal-lease transition on the ready handoff is
# surfaced without raw helper output and never blocks the release.
: >"$CALL_LOG"
rm -f "${TMP_HOME}/comment-attempts"
STUB_CLAIM_HELPER="${TMP_HOME}/stub-claim-helper.sh"
printf '#!/usr/bin/env bash\nprintf "STUB %%s\\n" "$*" >>"%s"\nprintf "DISPATCH_LEASE_TRANSITION_DENIED reason=lease_unmatched\\n" >&2\nexit 1\n' \
	"$CALL_LOG" >"$STUB_CLAIM_HELPER"
chmod +x "$STUB_CLAIM_HELPER"
STUB_LEASE="stub-lease-fixture"
if AIDEVOPS_DISPATCH_LEASE_TOKEN="$STUB_LEASE" CLAIM_FIXTURE_TOKEN="$STUB_LEASE" DISPATCH_CLAIM_HELPER="$STUB_CLAIM_HELPER" \
	_release_dispatch_claim "issue-12345" worker_ready_missing_linkage "0" "0" && \
	grep -q "STUB transition terminal 12345 owner/repo ${STUB_LEASE} issue-12345 0" "$CALL_LOG" && \
	grep -q 'WARN Terminal dispatch lease not posted on #12345; checkpoint recovery recorded locally when eligible' "$CALL_LOG" && \
	! grep -q "^WARN .*${STUB_LEASE}" "$CALL_LOG" && \
	grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
	printf 'PASS ready handoff surfaces a denied terminal lease without failing release\n'
else
	printf 'FAIL ready handoff terminal lease emission was not surfaced safely\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
GH_ISSUE_LABELS=bug
GH_UNLOCK_MODE=already_unlocked _unlock_issue_after_dispatch_release "12345" "owner/repo"
if grep -q 'INFO Release unlock skipped for GitHub issue #12345 in owner/repo: already unlocked' "$CALL_LOG" &&
	! grep -q 'WARN Failed to unlock released' "$CALL_LOG"; then
	printf 'PASS already-unlocked release cleanup is benign\n'
else
	printf 'FAIL already-unlocked release cleanup was not benign\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
GH_ISSUE_LABELS=bug
GH_UNLOCK_MODE=hard_fail _unlock_issue_after_dispatch_release "12345" "owner/repo"
if grep -q 'WARN Failed to unlock released GitHub issue #12345 in owner/repo (non-fatal): GraphQL: repository access denied' "$CALL_LOG"; then
	printf 'PASS hard unlock failures include issue, repo, and cause\n'
else
	printf 'FAIL hard unlock failure did not include issue, repo, and cause\n'
	sed 's/^/  /' "$CALL_LOG"
	exit 1
fi

: >"$CALL_LOG"
GH_ISSUE_LABELS=auto-dispatch,status:available _unlock_issue_after_dispatch_release "12345" "owner/repo"
if grep -q 'INFO Retaining conversation lock for auto-dispatch issue #12345' "$CALL_LOG" &&
	! grep -q '^UNLOCK ' "$CALL_LOG"; then
	printf 'PASS auto-dispatch claim release retains conversation lock\n'
else
	printf 'FAIL auto-dispatch claim release reopened conversation\n'
	exit 1
fi

# GH#34775: legacy prose BLOCKED + worker-set label + merged For #N checkpoint
# must enter the blocked release path before completion/PR reconciliation.
(
	unset GH_ISSUE_LABELS
	GH_LIVE_ISSUE='{"state":"open","body":"### Files Scope","assignees":[{"login":"assigned-bot"}],"labels":[{"name":"status:blocked"},{"name":"origin:interactive"}]}'
	GH_RELEASE_COMMENTS=$(jq -c '.[0]' <<<"$valid_claim_evidence")
	# shellcheck source=../headless-runtime-result.sh
	source "${SCRIPT_DIR}/headless-runtime-result.sh"
	_headless_private_workload_enabled() { return 1; }
	gh_issue_edit_safe() { printf 'EDIT %s\n' "$*" >>"$CALL_LOG"; return 0; }
	_hrff_prepare_terminal_blocker_release() {
		_HRFF_TERMINAL_BLOCKER_MODE=normal
		_HRFF_TERMINAL_BLOCKER_FRAGMENT=$'\n<!-- aidevops:terminal-blocker-observation revision=aaaaaaaaaaaaaaaaaaaaaaaa blocker=bbbbbbbbbbbbbbbbbbbbbbbb -->\n'
		return 0
	}
	role=worker session_key=issue-12345 discovered_session="" selected_model=fixture
	_run_failure_reason=""
	output_file="${TMP_HOME}/legacy-output"
	printf '## Checkpoint: BLOCKED\nMerged For #12345 checkpoint PR; missing runner config\nTERMINAL_BLOCKER_MISSING_SECRETS=RUNNER_CONFIG,SECOND_CONFIG\n' >"$output_file"
	rc=0
	_handle_run_result_success_output || rc=$?
	[[ "$rc" == 83 && "$_run_failure_reason" == blocked && ! -e "$output_file" ]]
	[[ "$AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS" == $'RUNNER_CONFIG\nSECOND_CONFIG' ]]
	: >"$CALL_LOG"
	rm -f "${TMP_HOME}/comment-attempts"
	if GH_COMMENT_FAILURES_BEFORE_SUCCESS=3 AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=1 \
		_release_dispatch_claim issue-12345 blocked; then
		printf 'FAIL blocked release accepted unpersisted comment\n'; exit 1
	fi
	if grep -q '^EDIT ' "$CALL_LOG"; then
		printf 'FAIL unpersisted blocked release mutated labels\n'; exit 1
	fi
	: >"$CALL_LOG"
	rm -f "${TMP_HOME}/comment-attempts"
	_release_dispatch_claim issue-12345 blocked
	[[ "$(grep -c 'CLAIM_RELEASED reason=blocked' "$CALL_LOG")" == 1 ]]
	grep -q 'aidevops:terminal-blocker-observation' "$CALL_LOG"
	grep -q -- '--add-label needs-secret:RUNNER_CONFIG' "$CALL_LOG"
	grep -q -- '--add-label needs-secret:SECOND_CONFIG' "$CALL_LOG"
	grep -q -- '--add-label status:blocked' "$CALL_LOG"
	post_line=$(grep -n '^API method=POST' "$CALL_LOG" | cut -d: -f1)
	edit_line=$(grep -n '^EDIT ' "$CALL_LOG" | sed -n '1s/:.*//p')
	[[ "$post_line" -lt "$edit_line" ]]
	GH_RELEASE_COMMENTS=$(jq -c '.[0] + [(.[0][0] | .id=101 | .node_id="CLAIM_FIXTURE_101" |
		.body="CLAIM_RELEASED reason=blocked runner=assigned-bot claim_id=100 nonce=fixture-lease")]' <<<"$valid_claim_evidence")
	_release_dispatch_claim issue-12345 blocked
	[[ "$(grep -c 'CLAIM_RELEASED reason=blocked' "$CALL_LOG")" == 1 ]]
	printf 'PASS legacy live-blocked checkpoint releases exactly once before projection and gates missing names\n'
	: >"$CALL_LOG"
	GH_LIVE_ISSUE='{"state":"open","assignees":[{"login":"other-owner"}],"labels":[{"name":"status:claimed"}]}'
	_hrff_project_blocked_exit 12345 owner/repo assigned-bot
	if grep -q '^EDIT ' "$CALL_LOG"; then
		printf 'FAIL blocked projection changed concurrent ownership\n'; exit 1
	fi
	printf 'PASS blocked projection preserves concurrent owner without publishing secret gates\n'
	# A mixed-version dispatch may reach a circuit opened by an older attempt.
	_hrff_prepare_terminal_blocker_release() { _HRFF_TERMINAL_BLOCKER_MODE=open; return 0; }
	GH_LIVE_ISSUE='{"state":"open","labels":[{"name":"status:in-progress"}]}'
	GH_RELEASE_COMMENTS=$(jq -c '[{id:99, user:{login:"assigned-bot"}, author_association:"OWNER", body:"CLAIM_RELEASED reason=blocked runner=assigned-bot "}] + .[0]' <<<"$valid_claim_evidence")
	: >"$CALL_LOG"
	rm -f "${TMP_HOME}/comment-attempts"
	if GH_COMMENT_FAILURES_BEFORE_SUCCESS=3 AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS=1 \
		_release_dispatch_claim issue-12345 blocked; then
		printf 'FAIL open circuit accepted unpersisted current release\n'; exit 1
	fi
	if grep -qE '^EDIT |^UNLOCK ' "$CALL_LOG"; then
		printf 'FAIL old circuit mutated or unlocked without current release\n'; exit 1
	fi
	: >"$CALL_LOG"
	rm -f "${TMP_HOME}/comment-attempts"
	_release_dispatch_claim issue-12345 blocked
	[[ "$(grep -c 'CLAIM_RELEASED reason=blocked' "$CALL_LOG")" == 1 ]]
	grep -q -- '--remove-label status:in-progress' "$CALL_LOG"
	printf 'PASS old open circuit persists current release before projecting blocked\n'
)

# Exercise the actual finish path without contacting GitHub or the operator's logs.
(
	_hrff_release_repo_state_is_managed() { return 0; }
	_hrff_check_release_claim() { _HRFF_RELEASE_CLAIM_OWNED=1; _HRFF_RELEASE_CLAIM_ID=100; return 0; }
	_hrff_persist_and_project_release() { release_note="${9}"; return 0; }
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	AIDEVOPS_PR_CHECKPOINT_ADMISSION_MODE=revision
	release_note=""
	_hrff_release_dispatch_claim_attempt issue-12345 worker_not_launched
	[[ "$release_note" == *'stays reusable for this exact head'* ]]
	printf 'PASS unlaunched revision release keeps the exact-head approval reusable\n'
)
(
	export HOME="$TMP_HOME"
	# shellcheck source=../headless-runtime-worker.sh
	source "${SCRIPT_DIR}/headless-runtime-worker.sh"
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_reason="$2"; return 0; }
	_hrw_permission_pending_path() { return 1; }
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	_WORKER_PRELAUNCH_LAST_STAGE=pre_attempt_context_configure
	AIDEVOPS_ATTEMPT_ID=attempt:fixture123
	_HRW_TERMINAL_OUTCOME=""
	released_reason="" fast_fail_reason=""
	_hrw_finish_success_run issue-12345 ""
	[[ "$released_reason" == worker_not_launched && "$fast_fail_reason" == worker_runtime_not_invoked ]]
	[[ "$_HRW_FINAL_RUNTIME_CLASSIFICATION" == worker_not_launched ]]
	[[ "$(_hrff_retry_class_for_reason worker_not_launched 0)" == retryable_infrastructure ]]
	grep -q 'attempt_id=attempt:fixture123 stage=pre_attempt_context_configure' "$HOME/.aidevops/logs/headless-prelaunch.log"
	released_reason=""
	_hrw_finish_failed_run issue-12345 "" 1
	[[ "$released_reason" == worker_not_launched ]]
	_WORKER_RUNTIME_LAUNCH_STARTED=1
	_hrff_worker_session_count() { printf '0\n'; return 0; }
	# A runtime returning before it creates a session used to consume approval.
	_run_metric_session_id=""
	_WORKER_PERSISTED_SESSION_ID="old-session-is-not-launch-proof"
	_HRW_TERMINAL_OUTCOME=""
	released_reason=""
	_hrw_finish_success_run issue-12345 ""
	[[ "$released_reason" == worker_not_launched ]]
	[[ "$_HRW_FINAL_RUNTIME_CLASSIFICATION" == worker_not_launched ]]
	released_reason=""
	_hrw_finish_failed_run issue-12345 "" 1
	[[ "$released_reason" == worker_not_launched ]]
	_hrff_release_repo_state_is_managed() { return 0; }
	_hrff_check_release_claim() { _HRFF_RELEASE_CLAIM_OWNED=1; _HRFF_RELEASE_CLAIM_ID=100; return 0; }
	_hrff_persist_and_project_release() { released_reason="$4"; release_line="$8"; release_note="$9"; return 0; }
	AIDEVOPS_PR_CHECKPOINT_ADMISSION_MODE=revision
	AIDEVOPS_WORKER_ATTEMPT_LOG="${TMP_HOME}/worker-checkpoint-42.log.ABC123"
	_hrff_release_dispatch_claim_attempt issue-12345 worker_complete
	[[ "$released_reason" == worker_not_launched && "$release_note" == *'stays reusable for this exact head'* ]]
	[[ "$release_line" == *'attempt_log=worker-checkpoint-42.log.ABC123'* && "$release_line" != *"$TMP_HOME"* ]]
	# Even a caller omitting final classification must not default to complete.
	_hrff_write_external_outcome() { external_reason_seen="$2"; external_retry_seen="$4"; return 0; }
	_HRW_FINAL_RUNTIME_CLASSIFICATION=""
	_HRW_FINAL_RUNTIME_STATUS="success"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	_hrw_write_external_final_outcome issue-12345 success
	[[ "$external_reason_seen" == worker_not_launched && "$external_retry_seen" == retryable_infrastructure ]]
	# Output-derived IDs work for both runtimes; positive activity also proves
	# an invocation when an isolated DB was finalized before finish runs.
	_run_metric_session_id="current-invocation-session"
	_HRW_TERMINAL_OUTCOME=""
	released_reason=""
	_hrw_finish_success_run issue-12345 ""
	[[ "$released_reason" == worker_complete ]]
	_run_metric_session_id=""
	_hrff_worker_session_count() { printf '1\n'; return 0; }
	_hrw_runtime_launch_confirmed
	printf 'PASS no-launch success and failure are infrastructure outcomes; launched success completes\n'
)

# Exercise allocation and command/env routing without launching a detached worker.
(
	# shellcheck source=../pr-review-thread-response-launch.sh
	source "${SCRIPT_DIR}/pr-review-thread-response-launch.sh"
	export AIDEVOPS_TEMP_DIR="$TMP_HOME"
	_prrts_log() { return 0; }
	systemd_scope_available() { return 0; }
	systemd_scope_launch() {
		local unit="$1" description="$2" output="$3"
		shift 3
		"$@" >>"$output" 2>&1 || true
		printf '123 scope\n'
		return 0
	}
	worker_pid="" detach_mode=""
	_prrts_launch_detached_worker owner/repo 42 worker_pid detach_mode \
		bash -c "printf 'runtime failed before session log=%s\n' \"\$AIDEVOPS_WORKER_ATTEMPT_LOG\"; exit 7"
	[[ "$worker_pid" == 123 && "$detach_mode" == scope ]]
	logs=("$TMP_HOME"/worker-pr-review-owner-repo-42.log.*)
	[[ "${#logs[@]}" == 1 && -f "${logs[0]}" ]]
	grep -Fq "runtime failed before session log=${logs[0]}" "${logs[0]}"
	[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "${logs[0]}")" == 0o600 ]]
	# A repeated attempt must create a new log rather than overwrite the first.
	_prrts_launch_detached_worker owner/repo 42 worker_pid detach_mode bash -c 'exit 0'
	logs=("$TMP_HOME"/worker-pr-review-owner-repo-42.log.*)
	[[ "${#logs[@]}" == 2 ]]
	printf 'PASS review launches retain private unique per-attempt logs and propagate their identity\n'
)

: >"$CALL_LOG"
GH_UNLOCK_MODE=success _unlock_issue_after_dispatch_release "004" "owner/repo"
if grep -q 'INFO Skipping release unlock for local task ID 004 in owner/repo: not a GitHub issue number' "$CALL_LOG" &&
	! grep -q 'UNLOCK issue=004' "$CALL_LOG"; then
	printf 'PASS leading-zero local task IDs are not formatted as GitHub issues\n'
	exit 0
fi

printf 'FAIL leading-zero local task ID handling was not explicit\n'
sed 's/^/  /' "$CALL_LOG"
exit 1
