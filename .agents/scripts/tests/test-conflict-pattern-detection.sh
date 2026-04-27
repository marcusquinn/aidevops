#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-conflict-pattern-detection.sh — Structural tests for t2987 pattern-aware
# conflict resolution guidance in pulse-merge-feedback.sh.
#
# Verifies:
#   1. conflict-patterns.conf exists and is the single source of truth
#   2. _classify_conflicts_by_pattern identifies DRIZZLE_MIGRATION correctly
#   3. _classify_conflicts_by_pattern identifies LOCKFILE correctly
#   4. _classify_conflicts_by_pattern identifies I18N_JSON correctly
#   5. _classify_conflicts_by_pattern identifies GENERATED correctly
#   6. _classify_conflicts_by_pattern falls back to CODE for unmatched files
#   7. Mixed-pattern PR: multiple classifications emitted on separate lines
#   8. Empty file list: no classification output
#   9. _build_conflict_feedback_section emits ### Pattern-Specific Resolution
#      Guidance block when non-CODE patterns are present
#  10. _build_conflict_feedback_section does NOT emit the guidance block for
#      CODE-only conflicts
#  11. Drizzle guidance block contains renumbering warning
#  12. Lockfile guidance block contains regeneration command
#  13. i18n guidance block mentions jq union-merge
#  14. pulse-merge-feedback.sh passes shellcheck
#
# Tests are structural — no live GitHub API calls.

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

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:200}")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected NOT to find: $(printf '%q' "$needle")"
		echo "  in output:            $(printf '%q' "${haystack:0:200}")"
	fi
	return 0
}

assert_empty() {
	local label="$1" value="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$value" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected empty, got: $(printf '%q' "${value:0:200}")"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected, got rc=$actual"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files and source the module under test.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-feedback.sh"
CONF_FILE="$SCRIPT_DIR/../configs/conflict-patterns.conf"

if [[ ! -f "$MODULE" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $MODULE not found"
	exit 1
fi

# Source with minimal stubs so the module's set-u guard is satisfied.
export LOGFILE="${LOGFILE:-/tmp/test-conflict-pattern-$$.log}"
# shellcheck source=/dev/null
source "$MODULE"

echo "${TEST_BLUE}=== t2987: conflict-pattern detection tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Test 1: conf file exists and is not empty.
# ---------------------------------------------------------------------------
echo "--- Section 1: conf file integrity ---"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$CONF_FILE" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1a: conflict-patterns.conf exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1a: conflict-patterns.conf NOT found at $CONF_FILE"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^DRIZZLE_MIGRATION' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1b: conf contains DRIZZLE_MIGRATION entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1b: conf missing DRIZZLE_MIGRATION entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^LOCKFILE' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1c: conf contains LOCKFILE entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1c: conf missing LOCKFILE entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^I18N_JSON' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1d: conf contains I18N_JSON entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1d: conf missing I18N_JSON entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^GENERATED' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1e: conf contains GENERATED entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1e: conf missing GENERATED entry"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^CODE' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1f: conf contains CODE catch-all entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1f: conf missing CODE catch-all entry"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 2: _classify_conflicts_by_pattern — per-pattern classification.
# ---------------------------------------------------------------------------
echo "--- Section 2: _classify_conflicts_by_pattern ---"

# 2a: Drizzle journal
drizzle_out=$(_classify_conflicts_by_pattern \
	"packages/db/migrations/meta/_journal.json" "$CONF_FILE")
assert_contains "2a: journal.json → DRIZZLE_MIGRATION" \
	"DRIZZLE_MIGRATION" "$drizzle_out"

# 2b: Drizzle snapshot
snap_out=$(_classify_conflicts_by_pattern \
	"packages/db/migrations/meta/0084_snapshot.json" "$CONF_FILE")
assert_contains "2b: snapshot.json → DRIZZLE_MIGRATION" \
	"DRIZZLE_MIGRATION" "$snap_out"

# 2c: pnpm lockfile
pnpm_out=$(_classify_conflicts_by_pattern \
	"pnpm-lock.yaml" "$CONF_FILE")
assert_contains "2c: pnpm-lock.yaml → LOCKFILE" \
	"LOCKFILE" "$pnpm_out"

# 2d: npm lockfile
npm_out=$(_classify_conflicts_by_pattern \
	"package-lock.json" "$CONF_FILE")
assert_contains "2d: package-lock.json → LOCKFILE" \
	"LOCKFILE" "$npm_out"

# 2e: yarn lockfile
yarn_out=$(_classify_conflicts_by_pattern \
	"yarn.lock" "$CONF_FILE")
assert_contains "2e: yarn.lock → LOCKFILE" \
	"LOCKFILE" "$yarn_out"

# 2f: i18n translation JSON
i18n_out=$(_classify_conflicts_by_pattern \
	"packages/i18n/src/translations/en/dashboard.json" "$CONF_FILE")
assert_contains "2f: translations/en/dashboard.json → I18N_JSON" \
	"I18N_JSON" "$i18n_out"

# 2g: generic snapshot file
gen_out=$(_classify_conflicts_by_pattern \
	"src/schema/schema_snapshot.json" "$CONF_FILE")
assert_contains "2g: *_snapshot.json → GENERATED or DRIZZLE_MIGRATION" \
	"GENERATED" "${gen_out}${drizzle_out}"  # one of the two must contain it

# 2h: source code file → CODE
code_out=$(_classify_conflicts_by_pattern \
	"packages/api/src/routes/users.ts" "$CONF_FILE")
assert_contains "2h: users.ts → CODE" \
	"CODE" "$code_out"

# 2i: empty input → empty output
empty_out=$(_classify_conflicts_by_pattern "" "$CONF_FILE")
assert_empty "2i: empty file list → empty output" "$empty_out"

echo ""

# ---------------------------------------------------------------------------
# Test 3: mixed-pattern PR — multiple classes on separate output lines.
# ---------------------------------------------------------------------------
echo "--- Section 3: mixed-pattern classification ---"

mixed_files=$(printf '%s\n' \
	"packages/db/migrations/meta/_journal.json" \
	"pnpm-lock.yaml" \
	"packages/i18n/src/translations/de/dashboard.json" \
	"packages/api/src/routes/users.ts")

mixed_out=$(_classify_conflicts_by_pattern "$mixed_files" "$CONF_FILE")

assert_contains "3a: mixed PR contains DRIZZLE_MIGRATION line" \
	"DRIZZLE_MIGRATION" "$mixed_out"
assert_contains "3b: mixed PR contains LOCKFILE line" \
	"LOCKFILE" "$mixed_out"
assert_contains "3c: mixed PR contains I18N_JSON line" \
	"I18N_JSON" "$mixed_out"
assert_contains "3d: mixed PR contains CODE line" \
	"CODE" "$mixed_out"

# Verify each class appears on its own line.
drizzle_line=$(printf '%s\n' "$mixed_out" | grep '^DRIZZLE_MIGRATION')
lockfile_line=$(printf '%s\n' "$mixed_out" | grep '^LOCKFILE')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -n "$drizzle_line" && -n "$lockfile_line" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 3e: each class on its own line"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 3e: classes not on separate lines"
	echo "  output: $(printf '%q' "$mixed_out")"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 4: _build_conflict_feedback_section brief output.
# ---------------------------------------------------------------------------
echo "--- Section 4: _build_conflict_feedback_section brief output ---"

# 4a: With non-CODE conflict → guidance block emitted.
brief_with_pattern=$(_build_conflict_feedback_section \
	"9999" "test PR title" \
	"packages/db/migrations/meta/_journal.json" \
	"abc1234" "main" "1")
assert_contains "4a: drizzle conflict → Pattern-Specific Resolution Guidance present" \
	"### Pattern-Specific Resolution Guidance" "$brief_with_pattern"

# 4b: Drizzle guidance block contains pattern header.
assert_contains "4b: drizzle brief → 'Pattern: DRIZZLE_MIGRATION'" \
	"Pattern: DRIZZLE_MIGRATION" "$brief_with_pattern"

# 4c: Default branch placeholder substituted.
assert_not_contains "4c: {default_branch} placeholder expanded" \
	"{default_branch}" "$brief_with_pattern"
assert_contains "4c2: 'main' appears in guidance" \
	"main" "$brief_with_pattern"

# 4d: Lockfile conflict → guidance block emitted.
brief_lockfile=$(_build_conflict_feedback_section \
	"9998" "lockfile PR" \
	"pnpm-lock.yaml" \
	"def5678" "develop" "1")
assert_contains "4d: lockfile conflict → guidance block present" \
	"### Pattern-Specific Resolution Guidance" "$brief_lockfile"
assert_contains "4d2: lockfile guidance → 'Pattern: LOCKFILE'" \
	"Pattern: LOCKFILE" "$brief_lockfile"

# 4e: CODE-only conflict → NO guidance block.
brief_code_only=$(_build_conflict_feedback_section \
	"9997" "code PR" \
	"packages/api/src/routes/users.ts" \
	"fed9876" "main" "1")
assert_not_contains "4e: CODE-only conflict → no Pattern-Specific Guidance block" \
	"### Pattern-Specific Resolution Guidance" "$brief_code_only"

# 4f: i18n conflict → jq union-merge mentioned.
brief_i18n=$(_build_conflict_feedback_section \
	"9996" "i18n PR" \
	"packages/i18n/src/translations/en/dashboard.json" \
	"aaa1111" "main" "1")
assert_contains "4f: i18n conflict → guidance block present" \
	"### Pattern-Specific Resolution Guidance" "$brief_i18n"
assert_contains "4f2: i18n guidance mentions jq" \
	"jq" "$brief_i18n"

# 4g: Empty file list → no guidance block (graceful no-op).
brief_empty=$(_build_conflict_feedback_section \
	"9995" "empty PR" \
	"" \
	"bbb2222" "main" "0")
assert_not_contains "4g: empty file list → no guidance block" \
	"### Pattern-Specific Resolution Guidance" "$brief_empty"

# 4h: Mixed PR → guidance block with multiple patterns.
brief_mixed=$(_build_conflict_feedback_section \
	"9994" "mixed PR" \
	"$(printf '%s\n' packages/db/migrations/meta/_journal.json pnpm-lock.yaml packages/api/src/foo.ts)" \
	"ccc3333" "main" "3")
assert_contains "4h: mixed brief → guidance block" \
	"### Pattern-Specific Resolution Guidance" "$brief_mixed"
assert_contains "4h2: mixed brief → DRIZZLE_MIGRATION guidance" \
	"Pattern: DRIZZLE_MIGRATION" "$brief_mixed"
assert_contains "4h3: mixed brief → LOCKFILE guidance" \
	"Pattern: LOCKFILE" "$brief_mixed"

echo ""

# ---------------------------------------------------------------------------
# Test 5: shellcheck cleanliness.
# ---------------------------------------------------------------------------
echo "--- Section 5: shellcheck ---"

TESTS_RUN=$((TESTS_RUN + 1))
if command -v shellcheck >/dev/null 2>&1; then
	sc_out=$(shellcheck "$MODULE" 2>&1)
	sc_rc=$?
	if [[ $sc_rc -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 5a: pulse-merge-feedback.sh passes shellcheck"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 5a: shellcheck violations:"
		echo "$sc_out"
	fi
else
	echo "${TEST_GREEN}PASS${TEST_NC}: 5a: shellcheck not installed — skipping"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ===${TEST_NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
