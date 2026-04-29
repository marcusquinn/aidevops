#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-log-no-json-pollution.sh — Regression test for t3053.
#
# Verifies that the pulse supervisor launch redirect prevents OpenCode's
# --format json event stream from contaminating pulse.log.
#
# Root cause: pulse-wrapper-cycle.sh launched the supervisor with
# ">>"$LOGFILE" 2>&1" which routed both stdout and stderr to pulse.log.
# OpenCode's JSON event stream flowed: opencode → tee "$output_file" → stdout
# → LOGFILE, polluting pulse.log with multi-KB tool_use JSON blobs.
#
# Fix (t3053): Changed to ">/dev/null 2>>"$LOGFILE"" so JSON events (stdout)
# go to /dev/null while diagnostic messages (stderr, via print_info) still
# reach pulse.log.
#
# Tests:
#   1. pulse-wrapper-cycle.sh does NOT use ">>"$LOGFILE" 2>&1" for supervisor
#   2. pulse-wrapper-cycle.sh DOES use ">/dev/null 2>>"$LOGFILE"" for supervisor
#   3. Simulation: a mock headless-runtime that emits JSON to stdout does NOT
#      contaminate a temp LOGFILE when launched with the fixed redirect
#   4. Simulation: stderr messages from the mock do reach LOGFILE
#   5. The JSON pattern grep-cE '^\{"type":"tool_use"' returns 0 on clean log
#   6. pulse-wrapper-cycle.sh passes shellcheck
#
# No live GitHub API calls. No OpenCode launch required.

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
		echo "  in output:        $(printf '%q' "${haystack:0:400}")"
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
		echo "  in output:            $(printf '%q' "${haystack:0:400}")"
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
# Setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE_FILE="$SCRIPT_DIR/pulse-wrapper-cycle.sh"

if [[ ! -f "$CYCLE_FILE" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $CYCLE_FILE not found"
	exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: Static check — supervisor launch must use >/dev/null 2>>"$LOGFILE"
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}--- Static source checks ---${TEST_NC}"

cycle_source=$(cat "$CYCLE_FILE")

# Needle strings for static checks (stored in vars to avoid SC2016 — the
# dollar sign in these strings is intentional literal text, not expansion).
FIXED_REDIRECT='>/dev/null 2>>"'"$"'LOGFILE"'
CONTAMINATING_REDIRECT='>>"'"$"'LOGFILE" 2>&1 &'

# The fixed redirect must be present
assert_contains \
	"supervisor launch uses >/dev/null 2>>LOGFILE redirect" \
	"$FIXED_REDIRECT" \
	"$cycle_source"

# The contaminating redirect must NOT be present
assert_not_contains \
	"supervisor launch does NOT use >>\$LOGFILE 2>&1 redirect" \
	"$CONTAMINATING_REDIRECT" \
	"$cycle_source"

# ---------------------------------------------------------------------------
# Test 2: Simulation — mock headless runtime emitting JSON to stdout
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}--- Simulation: mock headless runtime output routing ---${TEST_NC}"

# Create a temp LOGFILE
TEMP_LOGFILE=$(mktemp)

# Create a mock "headless runtime" script that:
# - Prints a JSON event to stdout (what OpenCode does with --format json)
# - Prints a diagnostic message to stderr (what print_info does)
MOCK_RUNTIME=$(mktemp)
cat >"$MOCK_RUNTIME" <<'MOCK'
#!/usr/bin/env bash
# Mock OpenCode runtime: emits JSON to stdout, diagnostic to stderr
printf '%s\n' '{"type":"tool_use","timestamp":1777477333510,"sessionID":"ses_test123","part":{"type":"tool","tool":"bash","callID":"toolu_test"}}'
printf '%s\n' '[INFO] [lifecycle] worker_start session=test-key pid=99999' >&2
exit 0
MOCK
chmod +x "$MOCK_RUNTIME"

# Simulate the FIXED redirect: >/dev/null 2>>"$LOGFILE"
"$MOCK_RUNTIME" >/dev/null 2>>"$TEMP_LOGFILE"
logfile_content=$(cat "$TEMP_LOGFILE")

# JSON must NOT appear in LOGFILE
json_count=0
if [[ -f "$TEMP_LOGFILE" ]]; then
	json_count=$(grep -cE '^\{"type":"tool_use"' "$TEMP_LOGFILE" 2>/dev/null || true)
	[[ "$json_count" =~ ^[0-9]+$ ]] || json_count=0
fi
assert_rc "fixed redirect: no JSON tool_use events in LOGFILE (count=0)" "0" "$json_count"

# stderr diagnostic must appear in LOGFILE
assert_contains \
	"fixed redirect: stderr diagnostic messages reach LOGFILE" \
	"[lifecycle] worker_start" \
	"$logfile_content"

# Reset logfile for contaminating redirect test
: >"$TEMP_LOGFILE"

# Simulate the OLD contaminating redirect: >>"$LOGFILE" 2>&1
"$MOCK_RUNTIME" >>"$TEMP_LOGFILE" 2>&1
logfile_content_contaminated=$(cat "$TEMP_LOGFILE")

# JSON WOULD appear with old redirect (this documents the bug, not a gate)
json_count_contaminated=0
json_count_contaminated=$(grep -cE '^\{"type":"tool_use"' "$TEMP_LOGFILE" 2>/dev/null || true)
[[ "$json_count_contaminated" =~ ^[0-9]+$ ]] || json_count_contaminated=0
assert_contains \
	"old redirect (regression evidence): JSON events DO appear in LOGFILE with >>\$LOGFILE 2>&1" \
	'{"type":"tool_use"' \
	"$logfile_content_contaminated"

# ---------------------------------------------------------------------------
# Test 3: Acceptance criterion — grep pattern from issue returns 0 on clean log
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}--- Acceptance criterion check ---${TEST_NC}"

# Create a clean log (no JSON blobs — fixed redirect result)
CLEAN_LOG=$(mktemp)
printf '%s\n' '[pulse-wrapper] Dispatched worker PID 88900 for #21729 in marcusquinn/aidevops' >>"$CLEAN_LOG"
printf '%s\n' '[INFO] [lifecycle] worker_start session=supervisor-pulse' >>"$CLEAN_LOG"
printf '%s\n' '[pulse-wrapper] Pulse completed at 2026-04-29T21:06:41Z (ran 127s)' >>"$CLEAN_LOG"

clean_json_count=0
clean_json_count=$(grep -cE '^\{"type":"tool_use"' "$CLEAN_LOG" 2>/dev/null || true)
[[ "$clean_json_count" =~ ^[0-9]+$ ]] || clean_json_count=0
assert_rc "clean log (fixed redirect output): grep -cE tool_use returns 0" "0" "$clean_json_count"

# Polluted log (old redirect result)
POLLUTED_LOG=$(mktemp)
printf '%s\n' '[pulse-wrapper] Dispatched worker PID 88900 for #21729 in marcusquinn/aidevops' >>"$POLLUTED_LOG"
printf '%s\n' '{"type":"tool_use","timestamp":1777477333510,"sessionID":"ses_226266e9fffe3QEIogoKjX2PLI","part":{"type":"tool","tool":"bash","callID":"toolu_01C9qE8WppNAVPLy5H3bZLXR","state":{"status":"completed","input":{"command":"headless-runtime-helper.sh run --role worker"}}}}' >>"$POLLUTED_LOG"
printf '%s\n' '[pulse-wrapper] Pulse completed at 2026-04-29T21:06:41Z (ran 127s)' >>"$POLLUTED_LOG"

polluted_json_count=0
polluted_json_count=$(grep -cE '^\{"type":"tool_use"' "$POLLUTED_LOG" 2>/dev/null || true)
[[ "$polluted_json_count" =~ ^[0-9]+$ ]] || polluted_json_count=0
assert_rc "polluted log (regression evidence): grep -cE tool_use returns 1 (bug present)" "1" "$polluted_json_count"

# ---------------------------------------------------------------------------
# Test 4: ShellCheck on pulse-wrapper-cycle.sh
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}--- ShellCheck ---${TEST_NC}"

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck_output=""
	shellcheck_output=$(shellcheck -x -S warning "$CYCLE_FILE" 2>&1) || true
	if [[ -z "$shellcheck_output" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: pulse-wrapper-cycle.sh passes shellcheck"
		TESTS_RUN=$((TESTS_RUN + 1))
	else
		TESTS_RUN=$((TESTS_RUN + 1))
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: pulse-wrapper-cycle.sh has shellcheck violations"
		echo "$shellcheck_output"
	fi
else
	echo "  [SKIP] shellcheck not installed — skipping lint check"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f "$MOCK_RUNTIME" "$TEMP_LOGFILE" "$CLEAN_LOG" "$POLLUTED_LOG"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}All ${TESTS_RUN} tests passed.${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}${TESTS_FAILED} of ${TESTS_RUN} tests FAILED.${TEST_NC}"
	exit 1
fi
