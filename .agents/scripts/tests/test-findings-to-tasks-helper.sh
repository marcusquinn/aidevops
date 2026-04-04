#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../findings-to-tasks-helper.sh"

PASS=0
FAIL=0
TEST_DIR=""

pass() {
	local message="$1"
	echo "PASS: ${message}"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local message="$1"
	echo "FAIL: ${message}"
	FAIL=$((FAIL + 1))
	return 0
}

cleanup() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

setup_repo() {
	local repo_path="$1"
	mkdir -p "$repo_path"
	(
		cd "$repo_path"
		git init -q
		git config user.email "test@example.com"
		git config user.name "Test Runner"
		cat >.task-counter <<'EOF'
100
EOF
		cat >TODO.md <<'EOF'
# Tasks

## Active

- [ ] t099 Existing task
EOF
		git add .task-counter TODO.md
		git commit -q -m "test: init repo"
	)
	return 0
}

test_successful_conversion() {
	local repo_path="$1"
	local findings_file="$2"
	local output_file="$3"

	cat >"$findings_file" <<'EOF'
# actionable findings
high|Fix race in worker lock|Use atomic lock file writes before dispatch
medium|Document retry strategy|Add retry policy section in workflows/pulse.md
EOF

	local status=0
	"$HELPER" create \
		--input "$findings_file" \
		--repo-path "$repo_path" \
		--source security-audit \
		--offline \
		--no-issue \
		--output "$output_file" >/tmp/findings-helper-success.out 2>&1 || status=$?

	if [[ "$status" -ne 0 ]]; then
		fail "create command should succeed for valid findings"
		return 0
	fi

	if [[ $(wc -l <"$output_file" | tr -d ' ') -eq 2 ]]; then
		pass "creates one TODO line per actionable finding"
	else
		fail "expected exactly 2 generated TODO lines"
	fi

	if grep -q "coverage=100%" /tmp/findings-helper-success.out; then
		pass "reports full coverage for converted findings"
	else
		fail "expected coverage=100% in command output"
	fi

	if grep -q "deferred_tasks_created=2" /tmp/findings-helper-success.out; then
		pass "reports deferred task creation count"
	else
		fail "expected deferred_tasks_created=2 in command output"
	fi

	return 0
}

test_fails_when_untracked_finding_remains() {
	local repo_path="$1"
	local findings_file="$2"

	cat >"$findings_file" <<'EOF'
||missing title should fail conversion
EOF

	local status=0
	"$HELPER" create \
		--input "$findings_file" \
		--repo-path "$repo_path" \
		--source review \
		--offline \
		--no-issue >/tmp/findings-helper-fail.out 2>&1 || status=$?

	if [[ "$status" -ne 0 ]]; then
		pass "fails when a finding cannot be converted"
	else
		fail "expected non-zero exit when conversion fails"
	fi

	if grep -q "coverage=0%" /tmp/findings-helper-fail.out; then
		pass "reports non-100% coverage for failed conversion"
	else
		fail "expected coverage=0% in failed conversion output"
	fi

	return 0
}

main() {
	trap cleanup EXIT

	TEST_DIR="$(mktemp -d)"
	local repo_path="${TEST_DIR}/repo"
	local findings_file="${TEST_DIR}/findings.txt"
	local output_file="${TEST_DIR}/todo-lines.txt"

	if [[ ! -x "$HELPER" ]]; then
		echo "Helper not executable: $HELPER"
		exit 1
	fi

	setup_repo "$repo_path"
	test_successful_conversion "$repo_path" "$findings_file" "$output_file"
	test_fails_when_untracked_finding_remains "$repo_path" "$findings_file"

	echo ""
	echo "Tests passed: $PASS"
	echo "Tests failed: $FAIL"

	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
