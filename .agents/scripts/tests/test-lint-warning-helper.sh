#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-lint-warning-helper.sh — focused tests for lint-warning-helper.sh

set -u

TESTS_RUN=0
TESTS_FAILED=0

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="$SCRIPT_DIR/lint-warning-helper.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lint-warning-helper-test.XXXXXX") || exit 1

cleanup() {
	rm -rf "$TMP_ROOT"
	return 0
}
trap cleanup EXIT

assert_exit_code() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected exit %s, got %s\n' "$expected" "$actual"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected to find: %s\n' "$needle"
	fi
	return 0
}

write_fixture() {
	local path="$1" content="$2"
	printf '%s\n' "$content" >"$path"
	return 0
}

printf '%s=== lint-warning-helper tests ===%s\n' "$TEST_BLUE" "$TEST_NC"

PROJECT_DIR="$TMP_ROOT/react-project"
mkdir -p "$PROJECT_DIR" || exit 1
write_fixture "$PROJECT_DIR/package.json" '{"dependencies":{"react":"latest","typescript":"latest"}}'

HOOKS_OUTPUT="$TMP_ROOT/hooks-warning.txt"
write_fixture "$HOOKS_OUTPUT" 'apps/web/src/modules/applications/writer/section-editor.tsx
  316:6  warning  React Hook useEffect has a missing dependency: '\''isCollabActive'\''. Either include it or remove the dependency array  react-hooks/exhaustive-deps

✖ 1 problem (0 errors, 1 warning)'

ANALYZE_OUTPUT=$("$HELPER" analyze "$HOOKS_OUTPUT" "$PROJECT_DIR" 2>&1)
ANALYZE_RC=$?
assert_exit_code "react-hooks warning is actionable" 2 "$ANALYZE_RC"
assert_contains "react-hooks output explains actionable warning" "ACTIONABLE_LINT_WARNINGS" "$ANALYZE_OUTPUT"

TS_OUTPUT="$TMP_ROOT/typescript-eslint-warning.txt"
write_fixture "$TS_OUTPUT" 'src/example.ts
  12:10  warning  Unexpected any. Specify a different type  @typescript-eslint/no-explicit-any'

TS_ANALYZE_OUTPUT=$("$HELPER" analyze "$TS_OUTPUT" "$PROJECT_DIR" 2>&1)
TS_ANALYZE_RC=$?
assert_exit_code "typescript-eslint warning is actionable in React/TS project" 2 "$TS_ANALYZE_RC"
assert_contains "typescript-eslint output suggests zero-warning gate" "--max-warnings=0" "$TS_ANALYZE_OUTPUT"

CLEAN_OUTPUT="$TMP_ROOT/clean-lint.txt"
write_fixture "$CLEAN_OUTPUT" 'Lint completed successfully.'

CLEAN_ANALYZE_OUTPUT=$("$HELPER" analyze "$CLEAN_OUTPUT" "$PROJECT_DIR" 2>&1)
CLEAN_ANALYZE_RC=$?
assert_exit_code "clean output passes" 0 "$CLEAN_ANALYZE_RC"
assert_contains "clean output states no actionable warnings" "LINT_WARNINGS_CLEAN" "$CLEAN_ANALYZE_OUTPUT"

MISSING_PROJECT_OUTPUT=$("$HELPER" run --project-dir 2>&1)
MISSING_PROJECT_RC=$?
assert_exit_code "missing --project-dir value fails cleanly" 1 "$MISSING_PROJECT_RC"
assert_contains "missing --project-dir value prints usage" "Usage:" "$MISSING_PROJECT_OUTPUT"

if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '\n%sAll %s tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
fi

printf '\n%s%s/%s tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
exit 1
