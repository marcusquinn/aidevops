#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/command-policy-helper.py"
POLICY="${SCRIPT_DIR}/../configs/command-policy.json"
TEST_ROOT="$(mktemp -d)"
TESTS=0
FAILURES=0
trap 'rm -rf "$TEST_ROOT"' EXIT

# Fixture construction must bypass the deployed guard shim. Policy assertions
# still invoke canonical-git-command-guard.py through the helper under test.
git() {
	/usr/bin/git "$@"
	return $?
}

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

assert_decision() {
	local name="$1"
	local command_text="$2"
	local expected_decision="$3"
	local expected_rule="$4"
	local expected_status="$5"
	local cwd="${6:-$TEST_ROOT}"
	local output=""
	local status=0
	local actual=""

	output="$(python3 "$HELPER" check-command --cwd "$cwd" --command "$command_text")" || status=$?
	actual="$(python3 - "$output" <<'PY'
import json
import sys

try:
    result = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    print("invalid/invalid")
else:
    print(f"{result.get('decision', '')}/{result.get('rule_id', '')}")
PY
)"
	if [[ "$status" -eq "$expected_status" && "$actual" == "${expected_decision}/${expected_rule}" ]]; then
		pass "$name"
	else
		fail "$name" "status=${status} decision=${actual} output=${output}"
	fi
	return 0
}

test_validation() {
	if python3 "$HELPER" validate --policy "$POLICY" >/dev/null; then
		pass "validates declarative policy and fixtures"
	else
		fail "validates declarative policy and fixtures"
	fi
	return 0
}

test_static_decisions() {
	assert_decision "allows unmatched command" "printf safe" allow command.default-allow 0
	assert_decision "prompts for recursive forced removal" "rm -rf ./build-output" prompt filesystem.rm-recursive-force 10
	assert_decision "forbids recursive root removal" "rm --recursive --force /" forbid filesystem.rm-recursive-force-root 20
	assert_decision "allows temporary cleanup" "rm -rf /tmp/aidevops-example" allow command.default-allow 0
	assert_decision "detects nested destructive command" "sh -c 'rm -r -f ./generated'" prompt filesystem.rm-recursive-force 10
	assert_decision "fails closed on malformed shell" "printf 'unterminated" forbid command.parse-error 20
	return 0
}

test_canonical_delegation() {
	local repo="${TEST_ROOT}/repo"
	local linked="${TEST_ROOT}/linked"
	mkdir -p "$repo"
	git -C "$repo" init -q -b main
	git -C "$repo" config user.name Test
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config commit.gpgsign false
	printf 'seed\n' >"${repo}/README.md"
	git -C "$repo" add README.md
	git -C "$repo" commit -q -m seed
	assert_decision "forbids canonical branch mutation through canonical guard" "git branch -m main renamed" forbid git.canonical-worktree 20 "$repo"
	git -C "$repo" worktree add -q -b feature/test "$linked"
	assert_decision "allows linked-worktree branch creation" "git switch -c feature/child" allow command.default-allow 0 "$linked"
	assert_decision "retains generic Git destructive prompt in linked worktree" "git reset --hard HEAD" prompt git.reset-destructive 10 "$linked"
	return 0
}

test_policy_fail_closed() {
	local output=""
	local status=0
	output="$(python3 "$HELPER" check-command --policy "${TEST_ROOT}/missing.json" --command "printf safe")" || status=$?
	if [[ "$status" -eq 21 && "$output" == *'"decision": "forbid"'* && "$output" == *'"rule_id": "policy.invalid"'* ]]; then
		pass "missing required policy fails closed"
	else
		fail "missing required policy fails closed" "status=${status} output=${output}"
	fi

	local malformed="${TEST_ROOT}/malformed.json"
	printf '{not-json\n' >"$malformed"
	status=0
	output="$(python3 "$HELPER" check-command --policy "$malformed" --command "printf safe")" || status=$?
	if [[ "$status" -eq 21 && "$output" == *'"decision": "forbid"'* && "$output" == *malformed* ]]; then
		pass "malformed required policy fails closed"
	else
		fail "malformed required policy fails closed" "status=${status} output=${output}"
	fi
	return 0
}

main() {
	test_validation
	test_static_decisions
	test_canonical_delegation
	test_policy_fail_closed
	printf '\nTests: %d, Failures: %d\n' "$TESTS" "$FAILURES"
	[[ "$FAILURES" -eq 0 ]] || return 1
	return 0
}

main "$@"
