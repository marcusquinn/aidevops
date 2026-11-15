#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38169: decision tests for _route_pr_to_conflict_repair_worker
# (pulse-merge-conflict-repair.sh). `gh` is a shell-function stub that
# returns post-jq output; the detached launcher is a stub script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MODULE="${SCRIPT_DIR}/../pulse-merge-conflict-repair.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BASE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
OTHER_HEAD="cccccccccccccccccccccccccccccccccccccccc"
REPO="owner/repo"
WORKER_LABELS=",origin:worker,status:in-review,"

export LOGFILE="${TEST_ROOT}/pulse.log"
export PULSE_CONFLICT_REPAIR_STATE_DIR="${TEST_ROOT}/state"
export PULSE_CONFLICT_REPAIR_REPO_PATH="$TEST_ROOT"
export PULSE_CONFLICT_REPAIR_LAUNCHER="${TEST_ROOT}/launcher.sh"
LAUNCH_LOG="${TEST_ROOT}/launch.log"
COMMENT_LOG="${TEST_ROOT}/comments.log"

# shellcheck source=../pulse-merge-conflict-repair.sh
source "$MODULE"

# Stub state, reset per test.
STUB_PR_STATE="open"
STUB_PR_HEAD="$HEAD_SHA"
STUB_HEAD_REPO="$REPO"
STUB_PR_LABELS="origin:worker"
STUB_RECORDS=""
STUB_LAUNCH_RC=0

gh() {
	local joined="$*"
	local sep=$'\037'
	case "$joined" in
	"api repos/${REPO}/pulls/42 "*)
		printf '%s\n' "${STUB_PR_STATE}${sep}${STUB_PR_HEAD}${sep}feature/x${sep}${STUB_HEAD_REPO}${sep}main${sep}${STUB_PR_LABELS}${sep}false"
		;;
	"api repos/${REPO}/git/ref/heads/main "*)
		printf '%s\n' "$BASE_SHA"
		;;
	"api --paginate repos/${REPO}/issues/42/comments"*)
		[[ -z "$STUB_RECORDS" ]] || printf '%s\n' "$STUB_RECORDS"
		;;
	"pr comment"*)
		printf '%s\n' "$joined" >>"$COMMENT_LOG"
		;;
	esac
	return 0
}

reset_stubs() {
	STUB_PR_STATE="open"
	STUB_PR_HEAD="$HEAD_SHA"
	STUB_HEAD_REPO="$REPO"
	STUB_PR_LABELS="origin:worker"
	STUB_RECORDS=""
	STUB_LAUNCH_RC=0
	rm -rf "$PULSE_CONFLICT_REPAIR_STATE_DIR" "$LAUNCH_LOG" "$COMMENT_LOG"
	mkdir -p "$PULSE_CONFLICT_REPAIR_STATE_DIR"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit %s\n' "$LAUNCH_LOG" "$STUB_LAUNCH_RC" >"$PULSE_CONFLICT_REPAIR_LAUNCHER"
	return 0
}

set_launch_rc() {
	local rc="$1"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit %s\n' "$LAUNCH_LOG" "$rc" >"$PULSE_CONFLICT_REPAIR_LAUNCHER"
	return 0
}

route() {
	local rc=0
	_route_pr_to_conflict_repair_worker 42 "$REPO" 7 "${1:-$WORKER_LABELS}" "${2:-$HEAD_SHA}" || rc=$?
	printf '%s\n' "$rc"
	return 0
}

check() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
	fi
	return 0
}

launch_count() {
	local count=0
	[[ -f "$LAUNCH_LOG" ]] && count=$(wc -l <"$LAUNCH_LOG" | tr -d ' ')
	printf '%s\n' "$count"
	return 0
}

now=$(date +%s)

reset_stubs
check "eligible conflict dispatches repair and preserves PR" 77 "$(route)"
check "eligible conflict launches exactly once" 1 "$(launch_count)"
check "dispatch posts one attempt marker" 1 "$( [[ -f "$COMMENT_LOG" ]] && wc -l <"$COMMENT_LOG" | tr -d ' ' || printf 0)"

reset_stubs
STUB_RECORDS="42 ${HEAD_SHA} ${BASE_SHA} $((now - 60))"
check "live attempt for current head preserves PR without relaunch" 77 "$(route)"
check "live attempt does not relaunch" 0 "$(launch_count)"

reset_stubs
STUB_RECORDS="42 ${HEAD_SHA} ${BASE_SHA} $((now - 7300))"
check "expired attempt falls back to close-and-redispatch" 1 "$(route)"
check "expired attempt does not relaunch" 0 "$(launch_count)"

reset_stubs
STUB_RECORDS="42 ${HEAD_SHA} ${BASE_SHA} $((now - 60))"
state_file="$(_pmcr_state_file "$REPO" 42)"
printf 'fingerprint=conflict-repair:%s:%s\nanalysis_complete=true\n' "$HEAD_SHA" "$BASE_SHA" >"$state_file"
check "worker stopped without advancing head falls back" 1 "$(route)"

reset_stubs
STUB_RECORDS="42 ${OTHER_HEAD} ${BASE_SHA} $((now - 60))"
check "new head after an earlier attempt gets a fresh attempt" 77 "$(route)"

reset_stubs
STUB_RECORDS="43 ${HEAD_SHA} ${BASE_SHA} $((now - 60))"
check "marker for a different PR is ignored" 77 "$(route)"

reset_stubs
PULSE_CONFLICT_REPAIR_MAX_ATTEMPTS=1
STUB_RECORDS="42 ${OTHER_HEAD} ${BASE_SHA} $((now - 60))"
check "attempt budget exhausted falls back" 1 "$(route)"
PULSE_CONFLICT_REPAIR_MAX_ATTEMPTS=3

reset_stubs
check "blocking route label skips repair" 1 "$(route ",origin:worker,no-takeover,")"
check "blocking route label never launches" 0 "$(launch_count)"

reset_stubs
STUB_PR_LABELS="origin:worker,needs-maintainer-review"
check "blocking live PR label skips repair" 1 "$(route)"

reset_stubs
STUB_HEAD_REPO="fork/repo"
check "fork head skips repair" 1 "$(route)"

reset_stubs
check "head moved during merge pass defers" 75 "$(route "$WORKER_LABELS" "$OTHER_HEAD")"

reset_stubs
set_launch_rc 10
check "launcher capacity/lock deferral defers" 75 "$(route)"

reset_stubs
set_launch_rc 13
check "launcher failure falls back" 1 "$(route)"

reset_stubs
PULSE_CONFLICT_REPAIR_ENABLED=false
check "disabled feature uses existing route" 1 "$(route)"
PULSE_CONFLICT_REPAIR_ENABLED=true

printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
