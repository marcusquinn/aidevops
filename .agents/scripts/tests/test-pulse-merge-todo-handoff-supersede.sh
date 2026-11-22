#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#36112: conflicting Pulse TODO handoffs are superseded, never routed or held.
# Isolated: GitHub reads and writes are stubbed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../pulse-merge-feedback-finalizer.sh
source "${SCRIPT_DIR}/../pulse-merge-feedback-finalizer.sh"
# shellcheck source=../pulse-merge-todo-handoff.sh
source "${SCRIPT_DIR}/../pulse-merge-todo-handoff.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
REPO="owner/repo"
PR=36021
HEAD_SHA="1d8cdd35c86019d318ae308afedcaa6157fceb25"
OTHER_SHA="0000000000000000000000000000000000000001"
BRANCH="aidevops/pulse-todo-a0d84857f731fd58"
TRUST_RC=0 CLOSE_RC=0 CLOSES="" COMMENT_JSON='[]'
PASS=0 FAIL=0

_pulse_is_trusted_issue_sync_pr() {
	local pr_number="$1" repo_slug="$2" head_sha="$3"
	[[ "$pr_number" == "$PR" && "$repo_slug" == "$REPO" && "$head_sha" == "$HEAD_SHA" ]] || return 1
	return "$TRUST_RC"
}
# Records `_gh_with_timeout write gh <args>` as "|<args>".
_gh_with_timeout() {
	local _mode="$1" command="$2"
	shift 2
	[[ "$command" == "gh" ]] || return 1
	CLOSES="${CLOSES}|$*"
	return "$CLOSE_RC"
}
gh() {
	local command="$1" endpoint="$2"
	[[ "$command" == "api" && "$endpoint" == "repos/${REPO}/issues/${PR}/comments?per_page=100" ]] || return 1
	printf '%s\n' "$COMMENT_JSON"
	return 0
}
# Only other-runner holds write permission; production uses pulse-merge-author-checks.sh.
_is_collaborator_author() {
	local author="$1"
	[[ "$author" == "other-runner" ]] && return 0
	return 1
}
receipt() {
	local login="$1" association="$2" sha="$3"
	jq -n --arg login "$login" --arg association "$association" \
		--arg body "<!-- feedback-route:closed-issue:PR${PR}:ISSUE36017:SHA${sha}:RUNNER1040920176 -->
Holding this conflict repair PR for maintainer review." \
		'[{id:1,body:$body,user:{login:$login,id:9},author_association:$association}]'
	return 0
}
check() {
	local name="$1" expected_rc="$2" expected_closes="$3" labels="$4" head_ref="${5:-$BRANCH}"
	local rc=0 closes=0
	CLOSES=""
	_pmth_handle_conflicting_handoff "$PR" "$REPO" "$head_ref" "$HEAD_SHA" "$labels" || rc=$?
	[[ -z "$CLOSES" ]] || closes=$(printf '%s' "$CLOSES" | tr -cd '|' | wc -c | tr -d ' ')
	if [[ "$rc" == "$expected_rc" && "$closes" == "$expected_closes" ]]; then
		PASS=$((PASS + 1))
		printf 'PASS %s\n' "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s (rc=%s want %s, closes=%s want %s)\n' "$name" "$rc" "$expected_rc" "$closes" "$expected_closes"
	fi
	return 0
}

check "non-handoff head continues generic handling" 10 0 "origin:worker" "feature/gh1-x"
check "trusted handoff is superseded" 2 1 "origin:worker"
[[ "$CLOSES" == *"pr close ${PR} --repo ${REPO} --delete-branch"* ]] \
	&& { PASS=$((PASS + 1)); printf 'PASS close deletes the handoff branch\n'; } \
	|| { FAIL=$((FAIL + 1)); printf 'FAIL close args: %s\n' "$CLOSES"; }
TRUST_RC=1
check "untrusted lookalike continues generic handling" 10 0 "origin:worker"
TRUST_RC=2
check "unavailable trust evidence touches nothing" 1 0 "origin:worker"
TRUST_RC=0
check "no-takeover is preserved" 1 0 "origin:worker,no-takeover"
check "needs-maintainer-review is preserved" 1 0 "origin:worker,needs-maintainer-review"
check "human hold without receipt is preserved" 1 0 "origin:worker,hold-for-review"
COMMENT_JSON=$(receipt automation OWNER "$HEAD_SHA")
check "exact-head trusted closed-issue hold is superseded" 2 1 "origin:worker,hold-for-review"
COMMENT_JSON=$(receipt other-runner CONTRIBUTOR "$HEAD_SHA")
check "verified writer receipt is superseded" 2 1 "origin:worker,hold-for-review"
COMMENT_JSON=$(receipt automation OWNER "$OTHER_SHA")
check "receipt for another head keeps the hold" 1 0 "origin:worker,hold-for-review"
COMMENT_JSON=$(receipt outsider NONE "$HEAD_SHA")
check "untrusted receipt keeps the hold" 1 0 "origin:worker,hold-for-review"
COMMENT_JSON='[]'
CLOSE_RC=1
check "failed close retries next cycle" 1 1 "origin:worker"
grep -q 'superseded conflicting Pulse TODO handoff PR #36021' "$LOGFILE" \
	&& { PASS=$((PASS + 1)); printf 'PASS supersession is logged\n'; } \
	|| { FAIL=$((FAIL + 1)); printf 'FAIL supersession log line missing\n'; }

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
