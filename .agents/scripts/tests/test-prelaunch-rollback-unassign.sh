#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#1214 / t2769 root cause.
#
# When a pre-launch abort (worker_branch_orphan_hold, canary fail, etc.) fires
# AFTER the dispatch has claimed and assigned the issue, _rollback_prelaunch_ownership
# must unassign self regardless of whether the issue still has status:queued.
#
# Previously, the function checked `owns_queued` (status:queued AND assigned)
# and returned 0 without unassigning when the status label was absent. This left
# a stale assignment that fed the stale-recovery→fast-fail→t2769 circuit breaker.
#
# The fix separates "should I unassign?" (always if assigned) from "should I
# change status labels?" (only if status:queued is present).
#
# shellcheck disable=SC1090,SC1091,SC2034

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
SCRIPT_DIR="$SCRIPTS_DIR"

TMP_HOME=$(mktemp -d -t prelaunch-rollback.XXXXXX) || exit 1
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
export REPOS_JSON="${TMP_HOME}/repos.json"
printf '{"initialized_repos":[]}' >"$REPOS_JSON"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

# ── Mock infrastructure ──────────────────────────────────────────────────────
GH_COMMENT_LOG="${TMP_HOME}/gh-comment.log"
GH_API_COMMENTS_RESPONSE="${TMP_HOME}/gh-api-comments.json"
GH_ISSUE_RESPONSE="${TMP_HOME}/gh-issue.json"
GH_EDIT_LOG="${TMP_HOME}/gh-edit.log"

reset_state() {
	: >"$GH_COMMENT_LOG"
	: >"$GH_EDIT_LOG"
	: >"$LOGFILE"
	printf '[]' >"$GH_API_COMMENTS_RESPONSE"
	printf '{}' >"$GH_ISSUE_RESPONSE"
	return 0
}

_extract_jq_filter() {
	local prev=""
	local arg
	for arg in "$@"; do
		[[ "$prev" == "--jq" ]] && { printf '%s' "$arg"; return 0; }
		prev="$arg"
	done
	return 1
}

_mock_gh_response() {
	local response_file="$1"
	shift
	local jq_filter
	if jq_filter=$(_extract_jq_filter "$@"); then
		jq -r "$jq_filter" <"$response_file" 2>/dev/null || cat "$response_file"
	else
		cat "$response_file"
	fi
	return 0
}

STATUS_MUTATION_FAIL=0
EDIT_SHOULD_UPDATE=1

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		local path="${1:-}"
		shift || true
		case "$path" in
		repos/*/issues/*/comments | repos/*/issues/*/comments\?*)
			local is_post=0
			local arg prev=""
			for arg in "$@"; do
				[[ "$prev" == "--method" && "$arg" == "POST" ]] && is_post=1
				prev="$arg"
			done
			if [[ "$is_post" -eq 1 ]]; then
				printf '{"id":123456}\n'
				return 0
			fi
			_mock_gh_response "$GH_API_COMMENTS_RESPONSE" "$@"
			;;
		repos/*/issues/comments/*)
			local is_delete=0 prev=""
			local arg
			for arg in "$@"; do
				[[ "$prev" == "--method" && "$arg" == "DELETE" ]] && is_delete=1
				prev="$arg"
			done
			if [[ "$is_delete" -eq 1 ]]; then
				printf '%s\n' 'DELETE_COMMENT' >>"$GH_COMMENT_LOG"
			fi
			printf '{}\n'
			;;
		*)
			echo "{}"
			;;
		esac
		;;
	issue)
		local sub="${1:-}"
		shift || true
		case "$sub" in
		view)
			cat "$GH_ISSUE_RESPONSE"
			;;
		edit)
			# Log the edit call for assertions.
			printf 'EDIT %s\n' "$*" >>"$GH_EDIT_LOG"
			# Simulate successful unassign: update the response to remove assignee.
			if [[ "$EDIT_SHOULD_UPDATE" -eq 1 ]]; then
				local current_response=""
				current_response=$(cat "$GH_ISSUE_RESPONSE")
				printf '%s' "$current_response" | jq '.assignees = []' >"$GH_ISSUE_RESPONSE"
			fi
			return 0
			;;
		*) ;;
		esac
		;;
	*) ;;
	esac
	return 0
}

set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status_name="$3"
	: "$issue_number" "$repo_slug" "$status_name"
	[[ "$STATUS_MUTATION_FAIL" -eq 0 ]] || return 1
	printf '{"state":"OPEN","labels":[{"name":"status:%s"}],"assignees":[],"locked":false}' "$status_name" >"$GH_ISSUE_RESPONSE"
	return 0
}

unlock_issue_after_worker() {
	return 0
}

sleep() {
	return 0
}

# ── Test 1: status:queued present → full rollback (existing behaviour) ───────
test_rollback_with_queued() {
	reset_state
	_claim_comment_id="claim-queued"
	printf '[{"id":"claim-queued","body":"DISPATCH_CLAIM nonce=test runner=runner-a"}]' >"$GH_API_COMMENTS_RESPONSE"
	printf '{"state":"OPEN","labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}],"locked":false}' >"$GH_ISSUE_RESPONSE"

	_release_dispatch_claim_on_abort "100" "owner/repo" "runner-a" "worker_launch_rc_2"

	if grep -q 'Pre-launch rollback verified' "$LOGFILE"; then
		pass "rollback with status:queued present → full rollback (existing)"
	else
		fail "rollback with status:queued present → full rollback (existing)" "log: $(cat "$LOGFILE")"
	fi
	if grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG"; then
		pass "rollback with status:queued present → claim deleted"
	else
		fail "rollback with status:queued present → claim deleted" "log: $(cat "$GH_COMMENT_LOG")"
	fi
	return 0
}

# ── Test 2: status:queued ABSENT, self assigned → unassign-only (GH#1214) ───
test_rollback_without_queued() {
	reset_state
	_claim_comment_id="claim-no-queued"
	printf '[{"id":"claim-no-queued","body":"DISPATCH_CLAIM nonce=test runner=runner-a"}]' >"$GH_API_COMMENTS_RESPONSE"
	# Issue has status:in-review (NOT queued) but IS assigned to self.
	printf '{"state":"OPEN","labels":[{"name":"status:in-review"}],"assignees":[{"login":"runner-a"}],"locked":false}' >"$GH_ISSUE_RESPONSE"

	_release_dispatch_claim_on_abort "200" "owner/repo" "runner-a" "worker_launch_rc_2"

	if grep -q 'Pre-launch rollback.*unassigned\|Pre-launch rollback verified\|Pre-launch rollback: unassigned' "$LOGFILE"; then
		pass "rollback without status:queued → unassign-only (GH#1214)"
	else
		fail "rollback without status:queued → unassign-only (GH#1214)" "log: $(cat "$LOGFILE")"
	fi
	if grep -q 'remove-assignee' "$GH_EDIT_LOG"; then
		pass "rollback without status:queued → gh issue edit --remove-assignee called"
	else
		fail "rollback without status:queued → gh issue edit --remove-assignee called" "edit log: $(cat "$GH_EDIT_LOG")"
	fi
	if grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG"; then
		pass "rollback without status:queued → claim deleted after unassign"
	else
		fail "rollback without status:queued → claim deleted after unassign" "comment log: $(cat "$GH_COMMENT_LOG")"
	fi
	return 0
}

# ── Test 3: self NOT assigned → no-op, claim deleted ─────────────────────────
test_rollback_not_assigned() {
	reset_state
	_claim_comment_id="claim-not-assigned"
	printf '[{"id":"claim-not-assigned","body":"DISPATCH_CLAIM nonce=test runner=runner-a"}]' >"$GH_API_COMMENTS_RESPONSE"
	# Issue is open but assigned to someone else, not to runner-a.
	printf '{"state":"OPEN","labels":[{"name":"status:queued"}],"assignees":[{"login":"other-runner"}],"locked":false}' >"$GH_ISSUE_RESPONSE"

	_release_dispatch_claim_on_abort "300" "owner/repo" "runner-a" "worker_launch_rc_2"

	# Should return 0 without attempting unassign (self not assigned).
	if ! grep -q 'remove-assignee' "$GH_EDIT_LOG" && ! grep -q 'set_issue_status' "$GH_EDIT_LOG"; then
		pass "rollback when not assigned → no unassign attempted"
	else
		fail "rollback when not assigned → no unassign attempted" "edit log: $(cat "$GH_EDIT_LOG")"
	fi
	if grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG"; then
		pass "rollback when not assigned → claim deleted (no-op rollback)"
	else
		fail "rollback when not assigned → claim deleted (no-op rollback)" "comment log: $(cat "$GH_COMMENT_LOG")"
	fi
	return 0
}

test_rollback_with_queued
test_rollback_without_queued
test_rollback_not_assigned

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
