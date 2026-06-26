#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25568: CodeFactor reports Bandit B603 findings via
# check-run annotations. The referenced subprocess calls are repo-controlled
# helper invocations, so each call site must carry an explicit nosec marker and
# local safety rationale instead of relying on provider-only context.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN=""
	TEST_RED=""
	TEST_NC=""
fi

assert_b603_annotated() {
	local rel_path="$1"
	local pattern="$2"
	local file="${REPO_ROOT}/${rel_path}"
	local match=""

	TESTS_RUN=$((TESTS_RUN + 1))
	match=$(grep -nF -- "$pattern" "$file" 2>/dev/null | head -n 1 || true)
	if [[ -n "$match" && "$match" == *"# nosec B603"* ]]; then
		printf '%sPASS%s: %s annotates %s\n' "$TEST_GREEN" "$TEST_NC" "$rel_path" "$pattern"
		return 0
	fi

	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: %s must annotate %s with # nosec B603\n' "$TEST_RED" "$TEST_NC" "$rel_path" "$pattern" >&2
	return 0
}

assert_b603_annotated ".agents/scripts/session-miner/extract.py" "subprocess.run(  # nosec B603"
assert_b603_annotated ".agents/scripts/session_tail_query.py" "subprocess.run(  # nosec B603"
assert_b603_annotated ".agents/scripts/vault-crypto-helper.py" "subprocess.Popen(  # nosec B603"

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf 'Tests failed: %s\n' "$TESTS_FAILED" >&2
	exit 1
fi

printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
