#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#39963: post-merge close authority must come from a fresh PR body.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../gh-closing-reference-lib.sh
source "${TEST_DIR}/../gh-closing-reference-lib.sh"
eval "$(awk '
	/^_handle_post_merge_actions\(\) \{/,/^}$/ { print }
	/^_extract_linked_issue\(\) \{/,/^}$/ { print }
	/^_pmp_stage_finalize_merge\(\) \{/,/^}$/ { print }
' "${TEST_DIR}/../pulse-merge.sh")"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
CALLS="${TEST_ROOT}/calls"
READS="${TEST_ROOT}/reads"

# File-backed read state survives command substitutions in the real functions.
gh_pr_view() {
	if [[ ! -e "$READS" ]]; then
		: >"$READS"
		printf '%s\n' 'Resolves #123'
		return 0
	fi
	printf 'cache-bypass:%s\n' "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" >>"$CALLS"
	[[ "$FRESH_BODY" != READ_FAILURE ]] || return 1
	printf '%s\n' "$FRESH_BODY"
	return 0
}

_pm_build_closing_comment() { printf 'closeout\n'; return 0; }
_pm_upsert_pr_closing_comment() { return 0; }
_pm_close_primary_linked_issue() {
	local target="$3"
	printf 'close:%s\n' "$target" >>"$CALLS"
	return 0
}
_pm_close_superseded_original_issue() { return 0; }
_pm_handle_partial_parent_closeout() { return 0; }
_pm_restore_partial_continuation() {
	local target="$3"
	printf 'restore:%s\n' "$target" >>"$CALLS"
	return 0
}
_release_interactive_claim_on_merge() { return 0; }
auto_file_next_phase() { return 0; }
_unblock_circuit_breaker_meta_pr() { return 0; }
_pmp_record_deterministic_progress_now() { return 0; }
_pmp_run_timed_stage() { "$@"; return $?; }
sleep() { return 0; }

run_case() {
	local name="$1" fresh_body="$2" expected_target="$3"
	local linked_issue="" expected_calls=""
	local pr_number=99 repo_slug=example/repo pr_labels=origin:worker
	local pr_base_ref_name=main merge_summary=summary merge_output="${4:-merged}"
	local _merge_exit="${5:-0}"
	FRESH_BODY="$fresh_body"
	rm -f "$READS"
	: >"$LOGFILE"
	: >"$CALLS"
	linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
	[[ "$linked_issue" == 123 ]]
	_pmp_stage_finalize_merge
	expected_calls=$'cache-bypass:1\n'
	if [[ -n "$expected_target" ]]; then
		expected_calls+="close:${expected_target}"$'\n'
	fi
	expected_calls+="restore:${expected_target}"
	[[ "$(<"$CALLS")" == "$expected_calls" ]] || {
		printf 'FAIL %s: incorrect close/restore target\n' "$name"
		return 1
	}
	if [[ "$expected_target" != 123 ]]; then
		grep -Fq "linked issue changed between gate and merge for PR #99: old=123 new=${expected_target:-none}" "$LOGFILE"
	fi
	if [[ "$fresh_body" == READ_FAILURE ]]; then
		grep -Fq 'body metadata unavailable' "$LOGFILE"
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

run_case 'Resolves downgraded to For restores partial without close' 'For #123' ''
run_case 'Resolves downgraded to Ref restores partial without close' 'Ref #123' ''
run_case 'unchanged closing target still closes' 'Resolves #123' 123
run_case 'changed closing target uses fresh issue' 'Fixes #456' 456
run_case 'empty body does not close stale issue' '' ''
run_case 'failed body read does not close stale issue' READ_FAILURE ''
run_case 'already-in-progress path refreshes closing target' 'For #123' '' 'Merge already in progress' 1
