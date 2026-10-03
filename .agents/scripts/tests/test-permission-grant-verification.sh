#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

ORIGINAL_HOME="$HOME"
TEST_ROOT=$(mktemp -d)
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME/.aidevops/approval-keys/private" "$TEST_ROOT/bin"
trap 'rm -rf "$TEST_ROOT"; export HOME="$ORIGINAL_HOME"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../approval-helper.sh
source "${SCRIPT_DIR}/approval-helper.sh"

ssh-keygen -t ed25519 -N '' -q -f "$APPROVAL_KEY"
cp "${APPROVAL_KEY}.pub" "$APPROVAL_PUB"

resume_worktree="${TEST_ROOT}/preserved worker"
git init -q --initial-branch=feature/auto-gh123 --separate-git-dir="${TEST_ROOT}/worker-git" "$resume_worktree"
git -C "$resume_worktree" remote add origin https://github.com/owner/repo.git
resume_digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$resume_worktree")
request_base=$(jq -cnS --arg worktree "$resume_digest" '{
  schema: "aidevops-permission-request/v1",
  target: {kind: "issue", repository: "owner/repo", number: 123},
  worker: {session: "manual-cli-123-100", branch: "feature/auto-gh123", worktree_sha256: $worktree},
  context: {stage: "worker tool execution", changed_files: [], alternatives: "none", resume_auto_dispatch: true},
  capabilities: [{
    permission: "external_directory",
    patterns: ["~/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    tool: "read",
    intent: "Inspect generated SDK declarations",
    risk: {level: "medium", grantable: true, reason: "external boundary"},
    opencode: {request_id: "oc-1", session_id: "ses-1"}
  }],
  created_at: "2026-07-14T00:00:00Z"
}')
request_digest=$(_permission_request_digest "$request_base")
request_id="perm-${request_digest:0:16}"
request_json=$(jq -cS --arg id "$request_id" --arg digest "$request_digest" \
  '. + {request_id: $id, request_sha256: $digest}' <<<"$request_base")

issued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
expires_at=$(_permission_grant_expiry)
payload=$(jq -cS --arg issued "$issued_at" --arg expires "$expires_at" '
  {
    schema: "aidevops-permission-grant/v1",
    authority: "worker-permissions",
    target,
    request_id,
    request_sha256,
    worker,
    capabilities,
    issued_at: $issued,
    expires_at: $expires
  }
' <<<"$request_json")
signature_file=$(mktemp)
_sign_approval_payload "$payload" "$APPROVAL_KEY" "$signature_file"
grant_comment=$(_build_permission_grant_comment "$payload" "$signature_file")
rm -f "$signature_file"
request_comment=$(printf '%s\n~~~json\n%s\n~~~\n' "$PERMISSION_REQUEST_MARKER" "$request_json")
fake_request_comment=$(printf '%s\n~~~json\n{}\n~~~\n' "$PERMISSION_REQUEST_MARKER")
fake_grant_comment=$(printf '%s\nmalformed\n' "$PERMISSION_GRANT_MARKER")

comments_file="${TEST_ROOT}/comments.json"
events_file="${TEST_ROOT}/events.json"
jq -cn --arg request "$request_comment" --arg grant "$grant_comment" \
	--arg fake_request "$fake_request_comment" --arg fake_grant "$fake_grant_comment" \
	'[[
		{id: 1, author_association: "MEMBER", body: $request},
		{id: 2, author_association: "OWNER", body: $grant},
		{id: 3, author_association: "CONTRIBUTOR", body: $fake_request},
		{id: 4, author_association: "NONE", body: $fake_grant}
	]]' >"$comments_file"
jq -cn '[[{event: "labeled", label: {name: "needs-maintainer-permissions"}}]]' >"$events_file"

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *"/events?"* ]]; then
	printf 'event\n' >>"$PERMISSION_GH_CALLS_FILE"
	call_count=$(wc -l <"$PERMISSION_GH_CALLS_FILE" | tr -d ' ')
	case "${PERMISSION_GH_MODE:-success}" in
	events-fail-first)
		[[ "$call_count" -gt 1 ]] || exit 75
		;;
	events-always-fail)
		exit 75
		;;
	events-malformed)
		printf '{malformed\n'
		exit 0
		;;
	esac
  command cat "$PERMISSION_EVENTS_FILE"
else
	[[ "${PERMISSION_GH_MODE:-success}" != "comments-always-fail" ]] || exit 75
  command cat "$PERMISSION_COMMENTS_FILE"
fi
STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"
export PERMISSION_COMMENTS_FILE="$comments_file"
export PERMISSION_EVENTS_FILE="$events_file"
export PERMISSION_GH_CALLS_FILE="${TEST_ROOT}/gh-calls"
export AIDEVOPS_PERMISSION_HISTORY_RETRY_DELAY=0

verification=$(cmd_verify_permissions issue 123 owner/repo)
[[ "$verification" == "VERIFIED" ]] || {
	printf 'valid permission grant did not verify: %s\n' "$verification" >&2
	exit 1
}

[[ "$(cmd_verify_permissions issue 123 owner/repo "$request_id" manual-cli-123-100 feature/auto-gh123 "$resume_digest")" == VERIFIED ]]
for binding in request session branch worktree; do
	expected_request="$request_id" expected_session=manual-cli-123-100
	expected_branch=feature/auto-gh123 expected_digest="$resume_digest"
	case "$binding" in
	request) expected_request=perm-0000000000000000 ;;
	session) expected_session=manual-cli-123-101 ;;
	branch) expected_branch=feature/replacement ;;
	worktree) expected_digest=invalid ;;
	esac
	verification=$(cmd_verify_permissions issue 123 owner/repo "$expected_request" "$expected_session" "$expected_branch" "$expected_digest") && exit 1
	[[ "$verification" == BINDING_MISMATCH ]]
done

# Exercise production resume discovery against the real signed comments and Git
# metadata, then the unchanged runtime request/grant environment preparation.
(
	# shellcheck source=../dispatch-single-issue-helper.sh
	source "${SCRIPT_DIR}/dispatch-single-issue-helper.sh"
	# shellcheck source=../headless-runtime-worker-prepare.sh
	source "${SCRIPT_DIR}/headless-runtime-worker-prepare.sh"
	_dsi_repo_path_for_slug() {
		printf '%s\n' "$resume_worktree"
		return 0
	}
	git() {
		local args="$*"
		if [[ "$args" == *'worktree list --porcelain' ]]; then
			printf 'worktree %s\n' "$resume_worktree"
			return 0
		fi
		command git "$@"
		return $?
	}
	jq -cn --arg request "$request_id" '{issue:123,session:"manual-cli-123-100",request_id:$request}' \
		>"${TEST_ROOT}/worker-git/aidevops-permission-pending"
	_dsi_resolve_permission_resume 123 owner/repo
	[[ "$_DSI_WORKTREE_PATH" == "$resume_worktree" && "$_DSI_RESUME_SESSION" == manual-cli-123-100 ]]
	export WORKER_ISSUE_NUMBER=123 WORKER_SESSION_KEY="$_DSI_RESUME_SESSION"
	_hrw_prepare_role_context worker "$_DSI_WORKTREE_PATH"
	_hrw_prepare_permission_grant_path owner/repo
	[[ "$AIDEVOPS_PERMISSION_REQUEST_ID" == "$request_id" ]]
	[[ "$AIDEVOPS_PERMISSION_GRANT_FILE" == "$HOME/.aidevops/permission-grants/owner_repo/123.json" ]]
	command git -C "$resume_worktree" symbolic-ref HEAD refs/heads/feature/replacement
	if _dsi_resolve_permission_resume 123 owner/repo; then exit 1; fi
	command git -C "$resume_worktree" symbolic-ref HEAD refs/heads/feature/auto-gh123
	jq '.session = "manual-cli-123-101"' "${TEST_ROOT}/worker-git/aidevops-permission-pending" >"${TEST_ROOT}/changed-marker"
	mv "${TEST_ROOT}/changed-marker" "${TEST_ROOT}/worker-git/aidevops-permission-pending"
	if _dsi_resolve_permission_resume 123 owner/repo; then exit 1; fi
)

# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPT_DIR}/pulse-dispatch-core.sh"

: >"$PERMISSION_GH_CALLS_FILE"
export PERMISSION_GH_MODE="events-fail-first"
if _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch remained blocked after a transient permission-history failure: %s\n' "${_DISPATCH_PERMISSION_VERIFY_RESULT:-}" >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "VERIFIED" ]]
[[ "$(wc -l <"$PERMISSION_GH_CALLS_FILE" | tr -d ' ')" == "2" ]]

: >"$PERMISSION_GH_CALLS_FILE"
export PERMISSION_GH_MODE="events-always-fail"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed after repeated permission-history failures\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "API_ERROR" ]]
[[ "$(wc -l <"$PERMISSION_GH_CALLS_FILE" | tr -d ' ')" == "2" ]]

export PERMISSION_GH_MODE="events-malformed"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed after malformed permission-history data\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "API_ERROR" ]]

export PERMISSION_GH_MODE="success"
if _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch remained blocked despite a matching valid grant: %s\n' "${_DISPATCH_PERMISSION_VERIFY_RESULT:-}" >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "VERIFIED" ]]

cp "$comments_file" "${comments_file}.with-request"
jq '.[0] = [.[0][1], .[0][2], .[0][3]]' "$comments_file" >"${comments_file}.pending"
mv "${comments_file}.pending" "$comments_file"
if _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'label-only legacy history still required a grant: %s\n' "${_DISPATCH_PERMISSION_VERIFY_RESULT:-}" >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "NO_REQUEST" ]]
mv "${comments_file}.with-request" "$comments_file"

export PERMISSION_GH_MODE="comments-always-fail"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed when permission-request history could not be read\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "API_ERROR" ]]

export PERMISSION_GH_MODE="success"
jq '.[0] = [.[0][0], .[0][2], .[0][3]]' "$comments_file" >"${comments_file}.pending"
mv "${comments_file}.pending" "$comments_file"
if ! _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch was allowed after the signed grant disappeared\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "NO_APPROVAL" ]]

# GH#33330: signed withdrawal releases only the withdrawn request.
build_withdrawal_comment() {
	local source_request="$1"
	local withdrawal_payload withdrawal_sig
	withdrawal_payload=$(jq -cS --arg schema "$PERMISSION_WITHDRAWAL_SCHEMA" --arg issued "$issued_at" '
		{schema: $schema, authority: "worker-permissions", decision: "withdrawn", target,
		 request_id, request_sha256, worker, issued_at: $issued}' <<<"$source_request")
	withdrawal_sig=$(mktemp)
	_sign_approval_payload "$withdrawal_payload" "$APPROVAL_KEY" "$withdrawal_sig"
	_build_permission_withdrawal_comment "$withdrawal_payload" "$withdrawal_sig"
	rm -f "$withdrawal_sig"
	return 0
}
withdrawal_comment=$(build_withdrawal_comment "$request_json")
jq -cn --arg request "$request_comment" --arg withdrawal "$withdrawal_comment" \
	'[[{id: 1, author_association: "MEMBER", body: $request},
	   {id: 5, author_association: "OWNER", body: $withdrawal}]]' >"$comments_file"
withdrawn_rc=0
withdrawn=$(cmd_verify_permissions issue 123 owner/repo) || withdrawn_rc=$?
[[ "$withdrawn" == "WITHDRAWN" && "$withdrawn_rc" -ne 0 ]] || {
	printf 'withdrawal verified as %s (rc=%s); expected non-success WITHDRAWN\n' "$withdrawn" "$withdrawn_rc" >&2
	exit 1
}
if _dispatch_permission_history_requires_grant 123 owner/repo; then
	printf 'dispatch remained blocked after a signed withdrawal: %s\n' "${_DISPATCH_PERMISSION_VERIFY_RESULT:-}" >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "WITHDRAWN" ]]

# A withdrawal replayed against a different request digest is not accepted.
other_base=$(jq -cS '.created_at = "2026-07-15T00:00:00Z"' <<<"$request_base")
other_digest=$(_permission_request_digest "$other_base")
other_request=$(jq -cS --arg id "perm-${other_digest:0:16}" --arg digest "$other_digest" \
	'. + {request_id: $id, request_sha256: $digest}' <<<"$other_base")
forged=$(build_withdrawal_comment "$other_request" | sed "s/perm-${other_digest:0:16}/${request_id}/")
jq -cn --arg request "$request_comment" --arg withdrawal "$forged" \
	'[[{id: 1, author_association: "MEMBER", body: $request},
	   {id: 5, author_association: "OWNER", body: $withdrawal}]]' >"$comments_file"
if _dispatch_permission_history_requires_grant 123 owner/repo; then :; else
	printf 'dispatch was allowed by a withdrawal bound to another request\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "MALFORMED_APPROVAL" ]]

# A newer request after the withdrawal still blocks.
other_comment=$(printf '%s\n~~~json\n%s\n~~~\n' "$PERMISSION_REQUEST_MARKER" "$other_request")
jq -cn --arg request "$request_comment" --arg withdrawal "$withdrawal_comment" --arg newer "$other_comment" \
	'[[{id: 1, author_association: "MEMBER", body: $request},
	   {id: 5, author_association: "OWNER", body: $withdrawal},
	   {id: 6, author_association: "MEMBER", body: $newer}]]' >"$comments_file"
if _dispatch_permission_history_requires_grant 123 owner/repo; then :; else
	printf 'a newer request was released by an older withdrawal\n' >&2
	exit 1
fi
[[ "$_DISPATCH_PERMISSION_VERIFY_RESULT" == "NO_APPROVAL" ]]

# Withdrawal removes only the local grant bound to the withdrawn request.
grant_path=$(_permission_grant_path owner/repo 123)
mkdir -p "$(dirname "$grant_path")"
jq -n --arg payload "$payload" '{payload: $payload, signature: "x"}' >"$grant_path"
_revoke_local_permission_grant owner/repo 123 "perm-${other_digest:0:16}"
[[ -f "$grant_path" ]]
_revoke_local_permission_grant owner/repo 123 "$request_id"
[[ ! -e "$grant_path" ]]

permission_retry_result=$(bash -c '
	set -euo pipefail
	source "$1"
	export AIDEVOPS_PERMISSION_PERSISTENCE_ATTEMPTS=3
	export AIDEVOPS_PERMISSION_PERSISTENCE_RETRY_DELAY=0
	edit_calls=0
	block_visible=false
	gh_issue_view() {
		if [[ "$block_visible" == true ]]; then
			printf "%s\n" "{\"labels\":[{\"name\":\"needs-maintainer-permissions\"},{\"name\":\"status:blocked\"}]}"
		else
			printf "%s\n" "{\"labels\":[{\"name\":\"status:in-progress\"}]}"
		fi
	}
	gh_issue_edit_safe() {
		edit_calls=$((edit_calls + 1))
		if [[ "$edit_calls" -eq 1 ]]; then
			return 1
		fi
		block_visible=true
		return 0
	}
	permission_apply_block 123 owner/repo
	permission_apply_block 123 owner/repo

	capture_file=$(mktemp)
	jq -cn '\''{
		schema: "aidevops-permission-capture/v1",
		issue: "123",
		repo: "owner/repo",
		requests: [{
			permission: "network",
			patterns: ["example.invalid"],
			tool: "webfetch",
			intent: "test non-grantable boundary",
			risk: {level: "critical", grantable: false, reason: "not representable"}
		}]
	}'\'' >"$capture_file"
	recorded_event=""
	post_calls=0
	block_calls=0
	permission_record_blocker() { recorded_event="$1"; }
	permission_post_request() { post_calls=$((post_calls + 1)); }
	permission_apply_block() { block_calls=$((block_calls + 1)); }
	non_grantable_rc=0
	cmd_request --file "$capture_file" --issue 123 --repo owner/repo --session issue-123 --work-dir "" || non_grantable_rc=$?
	rm -f "$capture_file"
	printf "calls=%s visible=%s nongrantable_rc=%s event=%s post=%s block=%s\n" \
		"$edit_calls" "$block_visible" "$non_grantable_rc" "$recorded_event" "$post_calls" "$block_calls"
' _ "${SCRIPT_DIR}/worker-permission-helper.sh")
[[ "$permission_retry_result" == "calls=2 visible=true nongrantable_rc=1 event=permission_request_non_grantable post=0 block=0" ]] || {
	printf 'permission blocker retry was not idempotent: %s\n' "$permission_retry_result" >&2
	exit 1
}

printf 'permission grant verification tests passed\n'
