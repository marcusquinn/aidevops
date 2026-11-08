#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36769: exercise both real merge entry points with local GitHub fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=../full-loop-helper-merge.sh
source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
# Match the full-loop entrypoint's readonly directory before cold-loading Pulse.
readonly SCRIPT_DIR
# shellcheck source=../pulse-merge.sh
source "${SCRIPT_DIR}/pulse-merge.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
export TMPDIR="$TEST_ROOT"
AIDEVOPS_TRUSTED_AUTHORS_CONF="${TEST_ROOT}/no-allowlist"
unset AIDEVOPS_HEADLESS Claude_HEADLESS GITHUB_ACTIONS WORKER_SESSION_KEY
FULL_LOOP_HEADLESS=true
AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=1
ISSUE_ASSOC=CONTRIBUTOR
ISSUE_LOGIN=outsider
ISSUE_PERMISSION="read"
ISSUE_STATE=open
ISSUE_LABELS='[]'
PR_BODY='Resolves #42'
PR_LABELS='[{"name":"origin:worker"}]'
CRYPTO_APPROVED=0
USER_API_FAIL=0
PR_API_FAIL=0
PR_BODY_ONLY_FAIL=0
WRITER_LOGIN=runner
SYNC_HEAD=""
PR_FILES='[{"filename":".agents/scripts/example.sh","status":"modified"}]'
PR_FILES_API_FAIL=0

# No network calls: any unexpected gh request fails rather than reaching GitHub.
gh() {
	local endpoint="" filter="" arg="" previous="" payload=""
	for arg in "$@"; do
		[[ "$previous" != "--jq" ]] || filter="$arg"
		case "$arg" in repos/* | user) endpoint="$arg" ;; esac
		previous="$arg"
	done
	case "$endpoint" in
	user)
		[[ "$USER_API_FAIL" == 0 ]] || return 1
		payload='{"login":"runner"}'
		;;
	*/comments*)
		payload=$(jq -s '.' "${TEST_ROOT}/comments.jsonl")
		payload="[$payload]"
		;;
	*/collaborators/*/permission) payload=$(jq -n --arg p "$ISSUE_PERMISSION" '{permission:$p}') ;;
	repos/owner/repo/pulls/100/files*)
		[[ "$PR_FILES_API_FAIL" == 0 ]] || return 1
		payload="$PR_FILES"
		;;
	repos/owner/repo/pulls/100)
		payload='{"head":{"sha":"0123456789abcdef0123456789abcdef01234567"}}'
		;;
	repos/owner/repo/issues/42)
		payload=$(jq -n --arg assoc "$ISSUE_ASSOC" --arg login "$ISSUE_LOGIN" --arg state "$ISSUE_STATE" \
			--argjson labels "$ISSUE_LABELS" \
			'{number:42,author_association:$assoc,user:{login:$login,type:"User"},state:$state,labels:$labels,title:"Generated service sync"}')
		;;
	repos/owner/repo) payload='{"permissions":{"push":true}}' ;;
	*) printf 'Unexpected gh call: %s\n' "$*" >&2; return 1 ;;
	esac
	if [[ -n "$filter" ]]; then jq -r "$filter" <<<"$payload"; else printf '%s\n' "$payload"; fi
	return 0
}

gh_pr_view() {
	local arg="" previous="" filter="" payload="" body="$PR_BODY"
	[[ "$PR_API_FAIL" == 0 ]] || return 1
	if [[ "${TEST_STALE_CACHE:-0}" == 1 && "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" != 1 ]]; then
		body=$'Resolves #42\nResolves #43'
	fi
	for arg in "$@"; do
		[[ "$previous" != "--jq" ]] || filter="$arg"
		previous="$arg"
	done
	[[ "$PR_BODY_ONLY_FAIL" != 1 || -z "$filter" ]] || return 1
	payload=$(jq -n --arg body "$body" --argjson labels "$PR_LABELS" '{body:$body,labels:$labels,isDraft:false,headRefOid:"fixture-head"}')
	if [[ -n "$filter" ]]; then jq -r "$filter" <<<"$payload"; else printf '%s\n' "$payload"; fi
	return 0
}

gh_issue_comment() {
	local arg="" previous="" body_file=""
	for arg in "$@"; do
		[[ "$previous" != "--body-file" ]] || body_file="$arg"
		previous="$arg"
	done
	jq -n --rawfile body "$body_file" --arg login "$WRITER_LOGIN" '{user:{login:$login},body:$body}' >>"${TEST_ROOT}/comments.jsonl"
	return 0
}

_issue_has_verified_crypto_approval() {
	[[ "$CRYPTO_APPROVED" == 1 ]] && return 0
	return 1
}

_pulse_is_trusted_issue_sync_pr() {
	local head_sha="$3"
	[[ "$SYNC_HEAD" == "$head_sha" ]] && return 0
	return 1
}

expect_parity() {
	local expected="$1" name="$2" deterministic=0 full_loop=0
	local linked_issue="${3-42}"
	_attempt_worker_briefed_auto_merge 100 owner/repo origin:worker false "$linked_issue" || deterministic=$?
	_merge_worker_briefed_trust_gate 100 owner/repo 1 || full_loop=$?
	[[ "$deterministic" == "$expected" && "$full_loop" == "$expected" ]] || {
		printf 'FAIL %s: deterministic=%s full-loop=%s\n' "$name" "$deterministic" "$full_loop" >&2
		return 1
	}
	printf 'PASS %s\n' "$name"
	return 0
}

: >"${TEST_ROOT}/comments.jsonl"
expect_parity 1 'external issue denied even with headless --admin'
WORKER_SESSION_KEY=supervisor-pulse
FULL_LOOP_HEADLESS=false
expect_parity 1 'supervisor denied even with --admin and no headless flag'
unset WORKER_SESSION_KEY
FULL_LOOP_HEADLESS=true
ISSUE_ASSOC=OWNER
expect_parity 0 'owner issue allowed'
TEST_STALE_CACHE=1
[[ "$(worker_briefed_trust_verdict 100 owner/repo)" == deny:* ]]
_merge_worker_briefed_trust_gate 100 owner/repo 0
unset TEST_STALE_CACHE
printf 'PASS full-loop trust gate bypasses stale ambiguous PR body\n'
PR_BODY_ONLY_FAIL=1
[[ "$(worker_briefed_trust_verdict 100 owner/repo)" == allow ]]
PR_BODY='For #42'
[[ "$(worker_briefed_trust_verdict 100 owner/repo)" == allow ]]
printf 'PASS closing and explicit references use the same metadata body without a second body read\n'
PR_BODY_ONLY_FAIL=0
PR_BODY='Resolves #42'
ISSUE_ASSOC=COLLABORATOR
ISSUE_PERMISSION="write"
expect_parity 0 'live write authority allowed'
ISSUE_PERMISSION="read"
CRYPTO_APPROVED=1
expect_parity 0 'verified crypto approval allowed'
CRYPTO_APPROVED=0
ISSUE_ASSOC=OWNER
PR_BODY='For #42'
expect_parity 0 'open non-parent For reference allowed'
ISSUE_STATE=closed
expect_parity 1 'closed non-closing reference denied'
ISSUE_STATE=open
ISSUE_LABELS='[{"name":"parent-task"}]'
expect_parity 1 'non-closing parent reference denied'
_merge_worker_briefed_trust_gate 100 owner/repo 0 >"${TEST_ROOT}/parent-code.log" 2>&1 || true
grep -q 'only eligible for a planning checkpoint' "${TEST_ROOT}/parent-code.log"
printf 'PASS parent code diff refusal names the planning-checkpoint policy\n'
# GH#36922: planning checkpoints for an open parent use the same guarded route.
PR_FILES='[{"filename":"TODO.md","status":"modified"},{"filename":"todo/tasks/t1-brief.md","status":"added"}]'
expect_parity 0 'trusted parent planning checkpoint allowed'
ISSUE_ASSOC=CONTRIBUTOR
expect_parity 1 'untrusted parent planning checkpoint denied'
ISSUE_ASSOC=OWNER
PR_FILES_API_FAIL=1
expect_parity 1 'parent planning file metadata failure denied'
_merge_worker_briefed_trust_gate 100 owner/repo 0 >"${TEST_ROOT}/parent-meta.log" 2>&1 || true
grep -q 'linked issue metadata unavailable: PR #100 file list' "${TEST_ROOT}/parent-meta.log"
printf 'PASS metadata failure is distinct from parent-link policy refusal\n'
PR_FILES_API_FAIL=0
PR_FILES='[{"filename":".agents/scripts/example.sh","status":"modified"}]'
ISSUE_LABELS='[]'
PR_BODY=$'Routine r004 scheduled content update\n\nRef #42'
ISSUE_LABELS='[{"name":"routine-tracking"},{"name":"persistent"},{"name":"no-auto-dispatch"}]'
expect_parity 0 'routine without a task issue allowed through maintainer tracking anchor'
ISSUE_ASSOC=CONTRIBUTOR
expect_parity 1 'routine tracking labels cannot authorize an untrusted anchor author'
ISSUE_ASSOC=OWNER
PR_BODY='Routine r004 scheduled content update; TODO.md SOP only'
expect_parity 1 'routine entry without an anchor reference is not merge authority' ''
ISSUE_LABELS='[]'
PR_BODY='Resolves #42'
ISSUE_ASSOC=CONTRIBUTOR
ISSUE_LOGIN='github-actions[bot]'
expect_parity 1 'workflow bot remains denied and gets a decision'
expect_parity 1 'repeated workflow-bot denial does not duplicate comment'
[[ "$(jq -s 'length' "${TEST_ROOT}/comments.jsonl")" == 1 ]]
jq -es '.[0].body | contains("sudo aidevops approve issue 42")' "${TEST_ROOT}/comments.jsonl" >/dev/null
printf 'PASS exactly one workflow-bot decision with the approval command\n'

: >"${TEST_ROOT}/comments.jsonl"
USER_API_FAIL=1
WRITER_LOGIN='github-actions[bot]'
expect_parity 1 'installation token without user endpoint records bot decision'
expect_parity 1 'installation token deduplicates its bot decision'
[[ "$(jq -s 'length' "${TEST_ROOT}/comments.jsonl")" == 1 ]]
USER_API_FAIL=0
WRITER_LOGIN=runner
PR_API_FAIL=1
if _merge_worker_briefed_trust_gate 100 owner/repo 1 >/dev/null 2>&1; then
	printf 'FAIL missing PR metadata allowed merge\n' >&2
	exit 1
fi
PR_API_FAIL=0
PR_LABELS=null
if _merge_worker_briefed_trust_gate 100 owner/repo 1 >/dev/null 2>&1; then
	printf 'FAIL malformed PR labels allowed merge\n' >&2
	exit 1
fi
PR_LABELS='[{"name":"origin:worker"}]'
printf 'PASS missing/malformed PR metadata fails closed\n'

# Prove cmd_merge exits before pre-merge/native/admin transport on denial.
_merge_handle_already_merged_provenance() { return 2; }
_merge_check_closure_metadata() { return 0; }
_merge_pre_merge_gate_with_admission_retry() { printf 'unexpected gate\n' >>"${TEST_ROOT}/transport"; return 0; }
_merge_execute() { printf 'unexpected merge\n' >>"${TEST_ROOT}/transport"; return 1; }
if cmd_merge 100 owner/repo --admin >"${TEST_ROOT}/command.log" 2>&1; then
	printf 'FAIL cmd_merge accepted untrusted issue\n' >&2
	exit 1
fi
[[ ! -e "${TEST_ROOT}/transport" ]]
grep -q 't2449/t3052' "${TEST_ROOT}/command.log"
printf 'PASS cmd_merge denies with t2449 reason before any merge/admin fallback\n'

FULL_LOOP_HEADLESS=false
_merge_worker_briefed_trust_gate 100 owner/repo 1 >"${TEST_ROOT}/override.log" 2>&1
grep -q 'Explicit interactive --admin overrides t2449' "${TEST_ROOT}/override.log"
if _merge_worker_briefed_trust_gate 100 owner/repo 0 >/dev/null 2>&1; then
	printf 'FAIL implicit interactive override\n' >&2
	exit 1
fi
printf 'PASS interactive override requires explicit --admin and is logged\n'

FULL_LOOP_HEADLESS=true
PR_BODY='Generated Issue Sync PR without a linked issue'
SYNC_HEAD=fixture-head
_merge_worker_briefed_trust_gate 100 owner/repo 0
SYNC_HEAD=stale-head
if _merge_worker_briefed_trust_gate 100 owner/repo 0 >/dev/null 2>&1; then
	printf 'FAIL stale Issue Sync trust evidence bypassed linked issue gate\n' >&2
	exit 1
fi
printf 'PASS existing exact-head Issue Sync exception retained; stale head denied\n'

# Exercise the actual anchor creation path in a fresh shell (SCRIPT_DIR above is
# readonly). Fixtures deny unexpected network calls, including label failures.
bash -s -- "$SCRIPT_DIR" "$TEST_ROOT" <<'ANCHOR_TEST'
set -euo pipefail
source "$1/routine-log-helper.sh"
FIXTURE_ROOT="$2"
CRON_BASE="$FIXTURE_ROOT/cron"
gh() {
	local command="$1" endpoint="${2:-}"
	case "$command:$endpoint" in
	api:repos/owner/repo/labels/*) return 1 ;;
	label:create) printf '%s\n' "$3" >>"$FIXTURE_ROOT/labels" ;;
	*) printf 'Unexpected gh call: %s\n' "$*" >&2; return 1 ;;
	esac
	return 0
}
gh_create_issue() {
	local args="$*" arg="" previous="" body_file=""
	for arg in "$@"; do
		[[ "$previous" != --body-file ]] || body_file="$arg"
		previous="$arg"
	done
	[[ -f "$body_file" ]] || return 1
	[[ "$args" == *'--label persistent'* && "$args" == *'--label no-auto-dispatch'* ]] || return 1
	grep -q 'persistent tracking anchor' "$body_file" || return 1
	printf 'https://github.com/owner/repo/issues/42\n'
	return 0
}
cmd_create_issue r004 --repo owner/repo --title 'r004: Content update' >/dev/null
[[ "$(_get_state_field r004 issue_number)" == 42 ]]
[[ "$(wc -l <"$FIXTURE_ROOT/labels")" -eq 4 ]]
printf 'PASS routine setup provisions labels and creates a persistent non-dispatchable anchor\n'
gh() { return 1; }
if _create_github_issue owner/repo 'r004: Content update' body >/dev/null 2>&1; then
	printf 'FAIL label provisioning failure allowed issue creation\n' >&2
	exit 1
fi
printf 'PASS label provisioning failure prevents anchor creation\n'
ANCHOR_TEST
