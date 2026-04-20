#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-auto-decomposer-scanner.sh — smoke + wiring tests for t2442 Fix #1
#
# Verifies:
#   1. auto-decomposer-scanner.sh is executable and shellcheck-clean
#   2. help subcommand prints the usage block with all three subcommands
#   3. Scanner is wired into pulse-simplification.sh via _run_auto_decomposer_scanner
#   4. Wrapper respects AUTO_DECOMPOSER_INTERVAL time gate (last-run file path)
#   5. Wrapper is registered in pulse-dispatch-engine.sh via run_stage_with_timeout
#   6. Constants AUTO_DECOMPOSER_LAST_RUN / AUTO_DECOMPOSER_INTERVAL exist in pulse-wrapper.sh
#   7. Scanner uses worker-ready body template (5+ of 7 t2417 headings)
#   8. Scanner dedupes via title + source:auto-decomposer label
#   9. Scanner generator marker is pre-dispatch-validator friendly
#
# This is a structural test — we do not run the scanner against live GitHub
# state (that's live-fire verification after deploy). We verify the wiring
# and body shape so regressions surface in CI.

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

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	# Use `--` separator so patterns starting with `-` (e.g. `--label`,
	# `--add-label`) are not interpreted as grep options.
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$SCRIPT_DIR/auto-decomposer-scanner.sh"
WRAPPER="$SCRIPT_DIR/pulse-simplification.sh"
ENGINE="$SCRIPT_DIR/pulse-dispatch-engine.sh"
BOOTSTRAP="$SCRIPT_DIR/pulse-wrapper.sh"

for required in "$SCANNER" "$WRAPPER" "$ENGINE" "$BOOTSTRAP"; do
	if [[ ! -f "$required" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $required not found"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2442 Fix #1: auto-decomposer scanner tests ===${TEST_NC}"
echo ""

# --- Basic scanner properties ---

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -x "$SCANNER" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1: scanner is executable"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1: scanner is NOT executable"
fi

# Help subcommand works without a repo arg and prints the usage block.
help_output=$("$SCANNER" help 2>&1)
help_rc=$?
assert_rc "2a: 'help' returns 0" "0" "$help_rc"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"scan"* && "$help_output" == *"dry-run"* && "$help_output" == *"help"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 2b: help output lists scan / dry-run / help subcommands"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 2b: help output is malformed"
	echo "  got: $(printf '%q' "$help_output")"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"SCANNER_NUDGE_AGE_HOURS"* && "$help_output" == *"SCANNER_MAX_ISSUES"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 2c: help output documents env vars"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 2c: help output missing env var documentation"
fi

# Unknown subcommand returns non-zero
"$SCANNER" bogus 2>/dev/null
bogus_rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$bogus_rc" -ne 0 ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 3: unknown subcommand returns non-zero (rc=$bogus_rc)"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 3: unknown subcommand should return non-zero"
fi

# --- Worker-ready body shape (t2417 heading signals) ---
# Scanner body template must carry 4+ of the 7 heading signals so the
# brief-readiness check treats it as worker-ready without a separate brief.

assert_grep_fixed "4a: body carries ## What heading" '## What' "$SCANNER"
assert_grep_fixed "4b: body carries ## Why heading" '## Why' "$SCANNER"
assert_grep_fixed "4c: body carries ## How heading" '## How' "$SCANNER"
assert_grep_fixed "4d: body carries ## Acceptance heading" '## Acceptance' "$SCANNER"
assert_grep_fixed "4e: body carries ## Session Origin heading" '## Session Origin' "$SCANNER"

# --- Generator marker for pre-dispatch validators ---

assert_grep \
	"5: scanner emits pre-dispatch-validator-friendly generator marker" \
	'aidevops:generator=auto-decompose parent=' \
	"$SCANNER"

# --- Dedup strategy ---

assert_grep_fixed \
	"6a: scanner dedup uses 'source:auto-decomposer' label" \
	'source:auto-decomposer' \
	"$SCANNER"

assert_grep_fixed \
	"6b: scanner dedup filters by exact title prefix via jq startswith()" \
	'startswith(' \
	"$SCANNER"

assert_grep_fixed \
	"6c: scanner dedup filters by label via --label \"\$SCANNER_LABEL\"" \
	'--label "$SCANNER_LABEL"' \
	"$SCANNER"

# --- Scanner labels tier:thinking + auto-dispatch + origin:worker ---

assert_grep_fixed \
	"7a: scanner applies tier:thinking" \
	'tier:thinking' \
	"$SCANNER"

assert_grep_fixed \
	"7b: scanner applies auto-dispatch" \
	'auto-dispatch' \
	"$SCANNER"

assert_grep_fixed \
	"7c: scanner applies origin:worker (GH#18670 parity)" \
	'origin:worker' \
	"$SCANNER"

# --- Wrapper wiring (pulse-simplification.sh) ---

assert_grep \
	"8: _run_auto_decomposer_scanner wrapper defined" \
	'^_run_auto_decomposer_scanner\(\) \{' \
	"$WRAPPER"

assert_grep_fixed \
	"9: wrapper uses AUTO_DECOMPOSER_LAST_RUN time gate" \
	'AUTO_DECOMPOSER_LAST_RUN' \
	"$WRAPPER"

assert_grep_fixed \
	"10: wrapper uses AUTO_DECOMPOSER_INTERVAL time gate" \
	'AUTO_DECOMPOSER_INTERVAL' \
	"$WRAPPER"

assert_grep_fixed \
	"11: wrapper skips contributor-role repos (t2145 parity)" \
	'repo_role=$(get_repo_role_by_slug' \
	"$WRAPPER"

# --- Dispatch engine registration ---

assert_grep \
	"12: dispatch engine registers _run_auto_decomposer_scanner via run_stage_with_timeout" \
	'run_stage_with_timeout "auto_decomposer_scanner".*_run_auto_decomposer_scanner' \
	"$ENGINE"

# --- Constants in pulse-wrapper.sh bootstrap ---

assert_grep \
	"13a: AUTO_DECOMPOSER_LAST_RUN constant defined in pulse-wrapper" \
	'^AUTO_DECOMPOSER_LAST_RUN="\$\{HOME\}/\.aidevops/logs/auto-decomposer-last-run"' \
	"$BOOTSTRAP"

assert_grep \
	"13b: AUTO_DECOMPOSER_INTERVAL constant defined with env override" \
	'^AUTO_DECOMPOSER_INTERVAL="\$\{AUTO_DECOMPOSER_INTERVAL:-[0-9]+\}"' \
	"$BOOTSTRAP"

assert_grep \
	"13c: AUTO_DECOMPOSER_INTERVAL passed through _validate_int" \
	'_validate_int AUTO_DECOMPOSER_INTERVAL' \
	"$BOOTSTRAP"

# --- Shared helper — jq repos-json filter is deduplicated ---

assert_grep \
	"14: _pulse_enabled_repo_slugs helper defined (de-dupes jq filter)" \
	'^_pulse_enabled_repo_slugs\(\) \{' \
	"$WRAPPER"

# --- Shellcheck cleanliness ---

if command -v shellcheck >/dev/null 2>&1; then
	TESTS_RUN=$((TESTS_RUN + 1))
	if shellcheck "$SCANNER" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 15: scanner is shellcheck-clean"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 15: scanner has shellcheck violations"
		shellcheck "$SCANNER" || true
	fi
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: 15: shellcheck not installed"
fi

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
