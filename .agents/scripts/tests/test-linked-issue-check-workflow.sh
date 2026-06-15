#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-linked-issue-check-workflow.sh — Regression tests for linked issue gate
# noise control.
#
# The linked-issue-check workflow must block merge through the required
# `linked-issue-check` commit status, not by failing the workflow CheckRun.
# Expected policy blocks should not be mined as systemic CI failures.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/linked-issue-check.yml"

echo "${TEST_BLUE}=== linked-issue-check workflow tests ===${TEST_NC}"
echo ""

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$WORKFLOW" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: workflow exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: workflow missing at $WORKFLOW"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "context: 'linked-issue-check'" "$WORKFLOW" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: workflow writes linked-issue-check commit status"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: workflow does not write linked-issue-check commit status"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "state: 'failure'" "$WORKFLOW" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: missing linked issue still sets failure status"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: missing linked issue no longer sets failure status"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -q 'core\.setFailed' "$WORKFLOW" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: workflow does not fail CheckRun for expected policy block"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: workflow still calls core.setFailed"
fi

echo ""
echo "Tests run: $TESTS_RUN"
echo "Failures: $TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi

exit 0
