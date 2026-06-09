#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_functions_under_test() {
	local fn_src=""
	fn_src=$(awk '
		/^_attempt_pr_ci_rebase_retry\(\) \{/,/^}$/ { print }
		/^_route_pr_to_fix_worker\(\) \{/,/^}$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract functions from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	_OW_LABEL_PAT=',origin:worker,'
	eval "$fn_src"
	return 0
}

install_stubs() {
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local args="$*"
		printf 'gh %s\n' "$args" >>"$GH_CALL_LOG"
		if [[ "$arg1" == "api" && "$args" == *"/compare/"* ]]; then
			printf '%s\n' "${COMPARE_BEHIND:-1}"
			return 0
		fi
		if [[ "$arg1" == "pr" && "$arg2" == "update-branch" ]]; then
			return 1
		fi
		return 0
	}
	gh_pr_view() {
		local args="$*"
		printf 'gh_pr_view %s\n' "$args" >>"$GH_CALL_LOG"
		if [[ "$args" == *"baseRefName,headRefOid"* ]]; then
			printf 'main abc123\n'
			return 0
		fi
		if [[ "$args" == *"labels"* ]]; then
			printf 'origin:worker\n'
			return 0
		fi
		return 0
	}
	_dispatch_ci_fix_worker() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; printf 'dispatch-ci %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" >>"$GH_CALL_LOG"; return 0; }
	_dispatch_pr_fix_worker() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; printf 'dispatch-review %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" >>"$GH_CALL_LOG"; return 0; }
	_dispatch_conflict_fix_worker() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; printf 'dispatch-conflict %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" >>"$GH_CALL_LOG"; return 0; }
	_interactive_pr_is_stale() { return 1; }
	return 0
}

test_ci_rebase_uses_provided_context() {
	: >"$GH_CALL_LOG"
	export COMPARE_BEHIND=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" "main" "deadbeef" || true

	if grep -q "gh_pr_view" "$GH_CALL_LOG"; then
		fail "CI rebase uses provided PR context" "Unexpected gh_pr_view call: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	if ! grep -q "compare/main...deadbeef" "$GH_CALL_LOG"; then
		fail "CI rebase uses provided PR context" "Expected compare to use provided refs: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "CI rebase uses provided PR context"
	return 0
}

test_ci_rebase_fetches_when_context_missing() {
	: >"$GH_CALL_LOG"
	export COMPARE_BEHIND=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" || true

	if ! grep -q "gh_pr_view 123" "$GH_CALL_LOG"; then
		fail "CI rebase falls back to volatile refetch" "Expected fallback gh_pr_view: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "CI rebase falls back to volatile refetch"
	return 0
}

test_route_uses_provided_labels() {
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "123" "owner/repo" "456" "ci" "origin:worker" || true

	if grep -q "gh_pr_view" "$GH_CALL_LOG"; then
		fail "fix-worker route uses provided labels" "Unexpected label refetch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	if ! grep -q "dispatch-ci 123 owner/repo 456" "$GH_CALL_LOG"; then
		fail "fix-worker route uses provided labels" "Expected CI dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "fix-worker route uses provided labels"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_functions_under_test
	install_stubs
	test_ci_rebase_uses_provided_context
	test_ci_rebase_fetches_when_context_missing
	test_route_uses_provided_labels
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
