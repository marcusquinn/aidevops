#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Proof-log enforcement regression tests.
# Ensures completion helpers keep requiring verifiable evidence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
TASK_COMPLETE_HELPER="${REPO_DIR}/.agents/scripts/task-complete-helper.sh"
PRE_COMMIT_HOOK="${REPO_DIR}/.agents/scripts/pre-commit-hook.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASS=0
FAIL=0

pass() {
	local description="$1"
	echo -e "  ${GREEN}PASS${NC}: ${description}"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local description="$1"
	echo -e "  ${RED}FAIL${NC}: ${description}"
	FAIL=$((FAIL + 1))
	return 0
}

assert_exit_code() {
	local expected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" -eq "$expected" ]]; then
		pass "$description"
	else
		fail "$description (expected exit ${expected}, got ${actual})"
	fi
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	local description="$3"

	if grep -qE "$pattern" "$file" 2>/dev/null; then
		pass "$description"
	else
		fail "$description"
	fi
	return 0
}

test_required_scripts_exist() {
	echo "Test: required scripts exist"

	if [[ -x "$TASK_COMPLETE_HELPER" ]]; then
		pass "task-complete helper is executable"
	else
		fail "task-complete helper missing or not executable"
	fi

	if [[ -f "$PRE_COMMIT_HOOK" ]]; then
		pass "pre-commit hook script exists"
	else
		fail "pre-commit hook script missing"
	fi
	return 0
}

test_requires_proof_log_argument() {
	echo "Test: task-complete requires --pr or --verified"

	local output=""
	local rc=0
	output=$("$TASK_COMPLETE_HELPER" t999 --repo-path "$REPO_DIR" --no-push 2>&1) || rc=$?

	assert_exit_code 1 "$rc" "helper exits non-zero without proof-log"
	if echo "$output" | grep -q "Missing required proof-log"; then
		pass "missing proof-log error message shown"
	else
		fail "missing proof-log error message not shown"
	fi
	return 0
}

test_verified_completion_updates_todo() {
	echo "Test: --verified marks task complete with proof-log"

	local temp_repo
	temp_repo=$(mktemp -d)

	git init "$temp_repo" >/dev/null 2>&1
	git -C "$temp_repo" config user.name "AI DevOps Test"
	git -C "$temp_repo" config user.email "aidevops-test@example.com"

	cat >"${temp_repo}/TODO.md" <<'EOF'
- [ ] t100 Test completion path #test
EOF

	git -C "$temp_repo" add TODO.md
	git -C "$temp_repo" commit -m "test: seed todo" >/dev/null 2>&1

	local rc=0
	"$TASK_COMPLETE_HELPER" t100 --verified 2026-03-14 --repo-path "$temp_repo" --no-push >/dev/null 2>&1 || rc=$?
	assert_exit_code 0 "$rc" "helper succeeds with verified proof-log"

	assert_file_contains "${temp_repo}/TODO.md" "^- \[x\] t100 " "task marked complete"
	assert_file_contains "${temp_repo}/TODO.md" "verified:2026-03-14" "verified proof-log appended"
	assert_file_contains "${temp_repo}/TODO.md" "completed:[0-9]{4}-[0-9]{2}-[0-9]{2}" "completed date appended"

	rm -rf "$temp_repo"
	return 0
}

test_pre_commit_script_enforces_proof_log() {
	echo "Test: pre-commit script includes proof-log checks"

	assert_file_contains "$PRE_COMMIT_HOOK" "pr:#" "hook checks pr:# format"
	assert_file_contains "$PRE_COMMIT_HOOK" "verified:" "hook checks verified: format"
	assert_file_contains "$PRE_COMMIT_HOOK" "return 1" "hook rejects invalid completion"
	return 0
}

main() {
	echo "============================================"
	echo "Proof-Log Enforcement - Test Suite"
	echo "============================================"
	echo ""

	test_required_scripts_exist
	echo ""
	test_requires_proof_log_argument
	echo ""
	test_verified_completion_updates_todo
	echo ""
	test_pre_commit_script_enforces_proof_log
	echo ""

	echo "============================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
