#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-ci-failure-pattern-detection.sh — Structural tests for t3225
# pattern-aware CI-failure resolution guidance in pulse-merge-feedback.sh.
#
# Verifies:
#   1. ci-failure-patterns.conf exists, contains all seven classifications,
#      and keeps TEST_FAILURE guidance reachable through one broad entry
#   2. _classify_ci_failures_by_pattern identifies FORMAT_FAILURE checks
#   3. _classify_ci_failures_by_pattern identifies LINT_FAILURE checks
#   4. _classify_ci_failures_by_pattern identifies EXTERNAL_STATIC_ANALYSIS checks
#   5. _classify_ci_failures_by_pattern identifies TYPECHECK_FAILURE checks
#   6. _classify_ci_failures_by_pattern identifies TEST_FAILURE checks
#   7. _classify_ci_failures_by_pattern falls back to OTHER for unmatched
#   8. Mixed-pattern CI: multiple classifications emitted on separate lines
#   9. Empty input: no classification output
#  10. _classify_ci_failures_by_pattern identifies TIMEOUT_NO_OUTPUT checks
#  11. _build_ci_feedback_section emits ### Pattern-Specific Resolution
#      Guidance block when non-OTHER patterns are present
#  12. _build_ci_feedback_section does NOT emit guidance for OTHER-only
#  13. FORMAT_FAILURE guidance contains auto-fix sequence (write/--fix)
#  14. LINT_FAILURE guidance contains lint --fix and changed-file CI commands
#  15. TYPECHECK_FAILURE guidance does NOT suggest auto-fix
#  16. TEST_FAILURE guidance includes pnpm/Vitest hermeticity triage
#  17. TIMEOUT_NO_OUTPUT guidance includes heartbeat and exit-code triage
#  18. CodeFactor external failures receive source-quality guidance
#  19. Qlty smell threshold failures receive shared-workflow guidance,
#      including the lowercase step-name signature seen in GH#26022
#  20. pulse-merge-feedback.sh passes shellcheck after t3225 changes
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
		echo "  in output:        $(printf '%q' "${haystack:0:300}")"
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
		echo "  in output:            $(printf '%q' "${haystack:0:300}")"
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
		echo "  expected empty, got: $(printf '%q' "${value:0:300}")"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files and source the module under test.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-feedback.sh"
CONF_FILE="$SCRIPT_DIR/../configs/ci-failure-patterns.conf"

if [[ ! -f "$MODULE" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $MODULE not found"
	exit 1
fi

# Source with minimal stubs so the module's set-u guard is satisfied.
export LOGFILE="${LOGFILE:-/tmp/test-ci-failure-pattern-$$.log}"
# shellcheck source=/dev/null
source "$MODULE"

echo "${TEST_BLUE}=== t3225: CI failure pattern detection tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Section 1: conf file integrity
# ---------------------------------------------------------------------------
echo "--- Section 1: conf file integrity ---"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$CONF_FILE" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1a: ci-failure-patterns.conf exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1a: ci-failure-patterns.conf NOT found at $CONF_FILE"
fi

for class in FORMAT_FAILURE LINT_FAILURE EXTERNAL_STATIC_ANALYSIS TYPECHECK_FAILURE TEST_FAILURE TIMEOUT_NO_OUTPUT OTHER; do
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "^${class}" "$CONF_FILE" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 1: conf contains ${class} entry"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 1: conf missing ${class} entry"
	fi
done

test_entry_count=$(grep -Ec '^TEST_FAILURE[[:space:]]*\|' "$CONF_FILE" 2>/dev/null || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$test_entry_count" == "1" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1: conf has one reachable TEST_FAILURE entry"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1: expected one TEST_FAILURE entry, got $test_entry_count"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -Eq '^TEST_FAILURE[[:space:]]*\|[[:space:]]*\*(Vitest|pnpm\*test)\*' "$CONF_FILE" 2>/dev/null; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1: conf omits unreachable Vitest/pnpm duplicate entries"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1: conf contains unreachable Vitest/pnpm duplicate entries"
fi

echo ""

# ---------------------------------------------------------------------------
# Section 2: _classify_ci_failures_by_pattern — per-pattern classification
# ---------------------------------------------------------------------------
echo "--- Section 2: _classify_ci_failures_by_pattern ---"

# 2a: Capitalized "Format" check name
fmt_out=$(_classify_ci_failures_by_pattern "Format" "$CONF_FILE")
assert_contains "2a: Format → FORMAT_FAILURE" "FORMAT_FAILURE" "$fmt_out"

# 2b: Lowercase "format" check name
fmt_low_out=$(_classify_ci_failures_by_pattern "format" "$CONF_FILE")
assert_contains "2b: format (lowercase) → FORMAT_FAILURE" "FORMAT_FAILURE" "$fmt_low_out"

# 2c: Prettier
prettier_out=$(_classify_ci_failures_by_pattern "Prettier" "$CONF_FILE")
assert_contains "2c: Prettier → FORMAT_FAILURE" "FORMAT_FAILURE" "$prettier_out"

# 2d: Biome
biome_out=$(_classify_ci_failures_by_pattern "Biome CI" "$CONF_FILE")
assert_contains "2d: 'Biome CI' → FORMAT_FAILURE" "FORMAT_FAILURE" "$biome_out"

# 2e: gofmt
gofmt_out=$(_classify_ci_failures_by_pattern "gofmt" "$CONF_FILE")
assert_contains "2e: gofmt → FORMAT_FAILURE" "FORMAT_FAILURE" "$gofmt_out"

# 2f: Lint check name
lint_out=$(_classify_ci_failures_by_pattern "Lint" "$CONF_FILE")
assert_contains "2f: Lint → LINT_FAILURE" "LINT_FAILURE" "$lint_out"

# 2g: ESLint
eslint_out=$(_classify_ci_failures_by_pattern "ESLint" "$CONF_FILE")
assert_contains "2g: ESLint → LINT_FAILURE" "LINT_FAILURE" "$eslint_out"

# 2h: Markdown Lint
md_lint_out=$(_classify_ci_failures_by_pattern "Markdown Lint" "$CONF_FILE")
assert_contains "2h: 'Markdown Lint' → LINT_FAILURE" "LINT_FAILURE" "$md_lint_out"

# 2h2: CodeFactor external static analysis check
codefactor_out=$(_classify_ci_failures_by_pattern "CodeFactor" "$CONF_FILE")
assert_contains "2h2: CodeFactor → EXTERNAL_STATIC_ANALYSIS" \
	"EXTERNAL_STATIC_ANALYSIS" "$codefactor_out"

# 2h3: Qlty smell threshold check
qlty_out=$(_classify_ci_failures_by_pattern "Qlty Smell Threshold" "$CONF_FILE")
assert_contains "2h3: Qlty Smell Threshold → EXTERNAL_STATIC_ANALYSIS" \
	"EXTERNAL_STATIC_ANALYSIS" "$qlty_out"

# 2h4: Qlty smell threshold step name uses lowercase "smell threshold" in logs
qlty_step_out=$(_classify_ci_failures_by_pattern "Qlty smell threshold check" "$CONF_FILE")
assert_contains "2h4: Qlty smell threshold step → EXTERNAL_STATIC_ANALYSIS" \
	"EXTERNAL_STATIC_ANALYSIS" "$qlty_step_out"

# 2i: Clippy
clippy_out=$(_classify_ci_failures_by_pattern "Clippy" "$CONF_FILE")
assert_contains "2i: Clippy → LINT_FAILURE" "LINT_FAILURE" "$clippy_out"

# 2j: Typecheck
tc_out=$(_classify_ci_failures_by_pattern "Typecheck" "$CONF_FILE")
assert_contains "2j: Typecheck → TYPECHECK_FAILURE" "TYPECHECK_FAILURE" "$tc_out"

# 2k: typecheck lowercase
tc_low_out=$(_classify_ci_failures_by_pattern "typecheck" "$CONF_FILE")
assert_contains "2k: typecheck (lowercase) → TYPECHECK_FAILURE" "TYPECHECK_FAILURE" "$tc_low_out"

# 2l: Test check name
test_out=$(_classify_ci_failures_by_pattern "Test" "$CONF_FILE")
assert_contains "2l: Test → TEST_FAILURE" "TEST_FAILURE" "$test_out"

# 2m: Vitest check name
vitest_out=$(_classify_ci_failures_by_pattern "Vitest" "$CONF_FILE")
assert_contains "2m: Vitest → TEST_FAILURE" "TEST_FAILURE" "$vitest_out"

# 2n: pnpm test check name
pnpm_test_out=$(_classify_ci_failures_by_pattern "pnpm test" "$CONF_FILE")
assert_contains "2n: pnpm test → TEST_FAILURE" "TEST_FAILURE" "$pnpm_test_out"

# 2o: Timeout check name
timeout_out=$(_classify_ci_failures_by_pattern "CI Timeout" "$CONF_FILE")
assert_contains "2o: 'CI Timeout' → TIMEOUT_NO_OUTPUT" "TIMEOUT_NO_OUTPUT" "$timeout_out"

# 2o2: runner communication check name
runner_comm_out=$(_classify_ci_failures_by_pattern "Runner communication lost" "$CONF_FILE")
assert_contains "2o2: runner communication → TIMEOUT_NO_OUTPUT" "TIMEOUT_NO_OUTPUT" "$runner_comm_out"

# 2o3: watchdog check name
watchdog_out=$(_classify_ci_failures_by_pattern "Watchdog no output" "$CONF_FILE")
assert_contains "2o3: watchdog → TIMEOUT_NO_OUTPUT" "TIMEOUT_NO_OUTPUT" "$watchdog_out"

# 2p: Unknown / catch-all → OTHER
other_out=$(_classify_ci_failures_by_pattern "SonarCloud Analysis" "$CONF_FILE")
assert_contains "2p: 'SonarCloud Analysis' → OTHER" "OTHER" "$other_out"

# 2q: Empty input → empty output
empty_out=$(_classify_ci_failures_by_pattern "" "$CONF_FILE")
assert_empty "2q: empty input → empty output" "$empty_out"

echo ""

# ---------------------------------------------------------------------------
# Section 3: Mixed-pattern CI failures
# ---------------------------------------------------------------------------
echo "--- Section 3: mixed-pattern CI failures ---"

# Five checks: one Format, one Lint, one Typecheck, one Test, one Timeout — expect five lines
mixed_input=$(printf '%s\n' "Format" "Lint" "Typecheck" "Test" "CI Timeout")
mixed_out=$(_classify_ci_failures_by_pattern "$mixed_input" "$CONF_FILE")
assert_contains "3a: mixed has FORMAT_FAILURE" "FORMAT_FAILURE" "$mixed_out"
assert_contains "3b: mixed has LINT_FAILURE" "LINT_FAILURE" "$mixed_out"
assert_contains "3c: mixed has TYPECHECK_FAILURE" "TYPECHECK_FAILURE" "$mixed_out"
assert_contains "3d: mixed has TEST_FAILURE" "TEST_FAILURE" "$mixed_out"
assert_contains "3d2: mixed has TIMEOUT_NO_OUTPUT" "TIMEOUT_NO_OUTPUT" "$mixed_out"

# Mix with OTHER
mixed_other=$(printf '%s\n' "Format" "Random Bot Check")
mixed_other_out=$(_classify_ci_failures_by_pattern "$mixed_other" "$CONF_FILE")
assert_contains "3e: mixed format+other has FORMAT_FAILURE" "FORMAT_FAILURE" "$mixed_other_out"
assert_contains "3f: mixed format+other has OTHER" "OTHER" "$mixed_other_out"

echo ""

# ---------------------------------------------------------------------------
# Section 4: _emit_ci_failure_guidance_blocks
# ---------------------------------------------------------------------------
echo "--- Section 4: _emit_ci_failure_guidance_blocks ---"

# 4a: FORMAT_FAILURE classification → guidance block emitted
fmt_class=$(_classify_ci_failures_by_pattern "Format" "$CONF_FILE")
fmt_guidance=$(_emit_ci_failure_guidance_blocks "$fmt_class" "$CONF_FILE")
assert_contains "4a: FORMAT classification emits guidance header" \
	"### Pattern-Specific Resolution Guidance" "$fmt_guidance"
assert_contains "4b: FORMAT guidance includes Auto-fix sequence" \
	"Auto-fix sequence" "$fmt_guidance"
assert_contains "4c: FORMAT guidance mentions format-fix command pattern" \
	"format" "$fmt_guidance"

# 4d: LINT_FAILURE classification → guidance with --fix
lint_class=$(_classify_ci_failures_by_pattern "Lint" "$CONF_FILE")
lint_guidance=$(_emit_ci_failure_guidance_blocks "$lint_class" "$CONF_FILE")
assert_contains "4d: LINT classification emits guidance" \
	"### Pattern-Specific Resolution Guidance" "$lint_guidance"
assert_contains "4e: LINT guidance mentions --fix" "--fix" "$lint_guidance"
assert_contains "4e2: LINT guidance points to changed-file lint reproduction" \
	"node .github/scripts/lint-changed-files.mjs --base-ref <base>" "$lint_guidance"
assert_contains "4e3: LINT guidance flags generated type trap" \
	"generated Content Collections" "$lint_guidance"
assert_contains "4e4: LINT guidance flags timeout/no-output trap" \
	"Timeout/no-output trap" "$lint_guidance"
assert_contains "4e5: LINT guidance mentions heartbeat" "heartbeat" "$lint_guidance"

# 4e6: CodeFactor external guidance points workers at provider details and regression guards.
codefactor_class=$(_classify_ci_failures_by_pattern "CodeFactor" "$CONF_FILE")
codefactor_guidance=$(_emit_ci_failure_guidance_blocks "$codefactor_class" "$CONF_FILE")
assert_contains "4e6: CodeFactor guidance mentions external advisory/static-analysis" \
	"external advisory/static-analysis check" "$codefactor_guidance"
assert_contains "4e7: CodeFactor guidance mentions details URL" \
	"details URL" "$codefactor_guidance"
assert_contains "4e8: CodeFactor guidance mentions failure signature" \
	"failure:codefactor.io" "$codefactor_guidance"

# 4f: TYPECHECK_FAILURE classification → guidance does NOT mention auto-fix
tc_class=$(_classify_ci_failures_by_pattern "Typecheck" "$CONF_FILE")
tc_guidance=$(_emit_ci_failure_guidance_blocks "$tc_class" "$CONF_FILE")
assert_contains "4f: TYPECHECK guidance emitted" \
	"### Pattern-Specific Resolution Guidance" "$tc_guidance"
assert_contains "4g: TYPECHECK guidance mentions code change" "code change" "$tc_guidance"
assert_not_contains "4h: TYPECHECK guidance does NOT recommend auto-fix" \
	"Auto-fix sequence" "$tc_guidance"

# 4i: OTHER-only classification → empty guidance (no block emitted)
other_class=$(_classify_ci_failures_by_pattern "Random Bot Check" "$CONF_FILE")
other_guidance=$(_emit_ci_failure_guidance_blocks "$other_class" "$CONF_FILE")
assert_empty "4i: OTHER-only classification emits no guidance block" "$other_guidance"

# 4j: TEST_FAILURE classification → hermeticity guidance emitted
test_class=$(_classify_ci_failures_by_pattern "Vitest" "$CONF_FILE")
test_guidance=$(_emit_ci_failure_guidance_blocks "$test_class" "$CONF_FILE")
assert_contains "4j: TEST guidance emitted" \
	"### Pattern-Specific Resolution Guidance" "$test_guidance"
assert_contains "4k: TEST guidance mentions pnpm filter rerun" \
	"pnpm --filter <package> test" "$test_guidance"
assert_contains "4l: TEST guidance warns against production secrets" \
	"Do NOT require production secrets" "$test_guidance"
assert_contains "4m: TEST guidance mentions stale Vitest mocks" \
	"vi.mock" "$test_guidance"

# 4n: TIMEOUT_NO_OUTPUT classification → heartbeat guidance emitted
timeout_class=$(_classify_ci_failures_by_pattern "CI Timeout" "$CONF_FILE")
timeout_guidance=$(_emit_ci_failure_guidance_blocks "$timeout_class" "$CONF_FILE")
assert_contains "4n: TIMEOUT guidance emitted" \
	"### Pattern-Specific Resolution Guidance" "$timeout_guidance"
assert_contains "4o: TIMEOUT guidance mentions heartbeat" "heartbeat" "$timeout_guidance"
assert_contains "4p: TIMEOUT guidance mentions exit code 124" "124" "$timeout_guidance"
assert_contains "4q: TIMEOUT guidance mentions exit code 137" "137" "$timeout_guidance"
assert_contains "4r: TIMEOUT guidance mentions exit code 143" "143" "$timeout_guidance"

echo ""

# ---------------------------------------------------------------------------
# Section 5: _build_ci_feedback_section integration
# ---------------------------------------------------------------------------
echo "--- Section 5: _build_ci_feedback_section integration ---"

# 5a: With FORMAT classification, full section contains pattern guidance
sample_failing="- **Format**: fail — [link](https://example.com)"
fmt_class_input=$(_classify_ci_failures_by_pattern "Format" "$CONF_FILE")
section_with_guidance=$(_build_ci_feedback_section "12345" "$sample_failing" "$fmt_class_input")
assert_contains "5a: section header present" \
	"## CI Repair Feedback" "$section_with_guidance"
assert_contains "5b: failing checks list present" \
	"- **Format**" "$section_with_guidance"
assert_contains "5c: Pattern-Specific guidance present (FORMAT case)" \
	"### Pattern-Specific Resolution Guidance" "$section_with_guidance"
assert_contains "5d: generic Worker guidance still present (fallback)" \
	"### Worker guidance" "$section_with_guidance"

# 5d2: CI-only lint trap: section points to changed-file reproduction when lint failed
sample_lint_failing="- **ESLint**: fail — [link](https://example.com)"
lint_class_input=$(_classify_ci_failures_by_pattern "ESLint" "$CONF_FILE")
lint_section=$(_build_ci_feedback_section "12345" "$sample_lint_failing" "$lint_class_input")
assert_contains "5d2: ESLint section includes changed-file lint command" \
	"node .github/scripts/lint-changed-files.mjs --base-ref <base>" "$lint_section"
assert_contains "5d3: ESLint section avoids generic-only pnpm lint guidance" \
	"CI changed-file path" "$lint_section"

# 5d4: Timeout/no-output trap: section points to heartbeat triage
sample_timeout_failing="- **CI Timeout**: fail — [link](https://example.com)"
timeout_class_input=$(_classify_ci_failures_by_pattern "CI Timeout" "$CONF_FILE")
timeout_section=$(_build_ci_feedback_section "12345" "$sample_timeout_failing" "$timeout_class_input")
assert_contains "5d4: timeout section includes heartbeat guidance" \
	"heartbeat" "$timeout_section"
assert_contains "5d5: timeout section includes killed/timeout exit codes" \
	"124, 137, or 143" "$timeout_section"

# 5d6: CodeFactor external failure gets source-quality guidance in pulse feedback.
sample_codefactor_failing="- **CodeFactor**: failure — [details](https://www.codefactor.io/repository/github/marcusquinn/aidevops/pull/25324)"
codefactor_class_input=$(_classify_ci_failures_by_pattern "CodeFactor" "$CONF_FILE")
codefactor_section=$(_build_ci_feedback_section "12345" "$sample_codefactor_failing" "$codefactor_class_input")
assert_contains "5d6: CodeFactor section includes source-quality guidance" \
	"source-quality pattern" "$codefactor_section"

# 5d7: GH#26022 exact step-name signature gets shared-workflow guidance.
sample_qlty_failing="- **Qlty smell threshold check**: failure — empty SARIF output"
qlty_step_class_input=$(_classify_ci_failures_by_pattern "Qlty smell threshold check" "$CONF_FILE")
qlty_step_section=$(_build_ci_feedback_section "12345" "$sample_qlty_failing" "$qlty_step_class_input")
assert_contains "5d7: qlty step section includes shared workflow guidance" \
	"shared workflow/helper" "$qlty_step_section"
assert_contains "5d8: qlty step section includes local reproduction command" \
	".agents/scripts/qlty-smell-threshold-helper.sh .agents/configs/complexity-thresholds.conf" "$qlty_step_section"

# 5e: Without classification arg, section omits pattern guidance (back-compat)
section_no_classification=$(_build_ci_feedback_section "12345" "$sample_failing")
assert_not_contains "5e: no-classification mode omits pattern guidance" \
	"### Pattern-Specific Resolution Guidance" "$section_no_classification"
assert_contains "5f: no-classification mode still has Worker guidance" \
	"### Worker guidance" "$section_no_classification"

# 5g: OTHER-only classification → no pattern guidance block
other_class_input=$(_classify_ci_failures_by_pattern "Random Bot Check" "$CONF_FILE")
section_other=$(_build_ci_feedback_section "12345" "$sample_failing" "$other_class_input")
assert_not_contains "5g: OTHER-only classification omits pattern guidance" \
	"### Pattern-Specific Resolution Guidance" "$section_other"

echo ""

# ---------------------------------------------------------------------------
# Section 6: shellcheck on the modified module
# ---------------------------------------------------------------------------
echo "--- Section 6: shellcheck ---"

if command -v shellcheck >/dev/null 2>&1; then
	TESTS_RUN=$((TESTS_RUN + 1))
	if shellcheck "$MODULE" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 6: pulse-merge-feedback.sh passes shellcheck"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 6: pulse-merge-feedback.sh has shellcheck violations"
		shellcheck "$MODULE" 2>&1 | head -20
	fi
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: shellcheck not installed"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "--- summary ---"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
	echo "${TEST_GREEN}OK${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}FAILED${TEST_NC}"
	exit 1
fi
