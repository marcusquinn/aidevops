#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-canary-saturation-classification.sh — t3549 (GH#22615)
#
# Regression test for advisory-only CPU saturation handling. The load-average
# pre-flight overload check is gone, and timeout-class canary exits classify
# as `timeout` regardless of cpu-saturation-helper.sh output.
#
# Test cases:
#   1. Timeout exit + saturated samples → reason=timeout (no CPU throttle)
#   2. Timeout exit + idle samples → reason=timeout (90s TTL)
#   3. Timeout exit + insufficient samples → reason=timeout (fail-open)
#   4. Auth-error pattern → reason=auth_error (saturation ignored)
#   5. Helper missing → reason=timeout (no helper dependency)
#   6. cpu-saturation-helper.sh check returns matching exit codes for
#      saturated, mixed, and short-span sample windows.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/.agent-workspace/headless-runtime"
mkdir -p "${HOME}/.aidevops/.agent-workspace/cpu-saturation"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${SCRIPT_DIR}/cpu-saturation-helper.sh"

# ---------------------------------------------------------------------------
# Helper test fixtures

write_samples() {
	# write_samples <window-seconds> <pct1> [<pct2> ...]
	# Writes one sample per ~30s span back from "now" so the window is
	# spanned in <= 5 entries. Fills the rolling state file directly.
	local window="$1"
	shift
	local now
	now=$(date +%s)
	local state_dir="${AIDEVOPS_CPU_SATURATION_STATE_DIR}"
	mkdir -p "$state_dir"
	: >"${state_dir}/samples.tsv"
	local n="$#"
	local i=0
	local step=$((window / (n - 1 > 0 ? n - 1 : 1)))
	[[ "$step" -lt 1 ]] && step=1
	for pct in "$@"; do
		local ts=$((now - window + (i * step)))
		printf '%s\t%s\n' "$ts" "$pct" >>"${state_dir}/samples.tsv"
		i=$((i + 1))
	done
	return 0
}

reset_state() {
	rm -rf "${AIDEVOPS_CPU_SATURATION_STATE_DIR}/samples.tsv" \
		"${AIDEVOPS_CPU_SATURATION_STATE_DIR}/.fake-pct-queue" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# Helper tests (cpu-saturation-helper.sh check / report)

test_helper_check_saturated() {
	export AIDEVOPS_CPU_SATURATION_STATE_DIR="${TEST_ROOT}/sat-saturated"
	reset_state
	write_samples 120 99 99 99 99 99
	if "$HELPER" check --window 120 --threshold 98 >/dev/null 2>&1; then
		print_result "helper.check: sustained 99% over 120s → saturated (rc=0)" 0
	else
		print_result "helper.check: sustained 99% over 120s → saturated (rc=0)" 1 "got non-zero"
	fi
	return 0
}

test_helper_check_mixed_idle() {
	export AIDEVOPS_CPU_SATURATION_STATE_DIR="${TEST_ROOT}/sat-mixed"
	reset_state
	write_samples 120 99 99 50 99 99
	if "$HELPER" check --window 120 --threshold 98 >/dev/null 2>&1; then
		print_result "helper.check: any sample <threshold → not saturated (rc=1)" 1 "unexpectedly saturated"
	else
		print_result "helper.check: any sample <threshold → not saturated (rc=1)" 0
	fi
	return 0
}

test_helper_check_short_span() {
	export AIDEVOPS_CPU_SATURATION_STATE_DIR="${TEST_ROOT}/sat-short"
	reset_state
	# Three samples across 10s only — span < window/2, must fail-open.
	local now
	now=$(date +%s)
	mkdir -p "$AIDEVOPS_CPU_SATURATION_STATE_DIR"
	for i in 0 5 10; do
		printf '%s\t%s\n' "$((now - 10 + i))" "99" \
			>>"${AIDEVOPS_CPU_SATURATION_STATE_DIR}/samples.tsv"
	done
	if "$HELPER" check --window 120 --threshold 98 >/dev/null 2>&1; then
		print_result "helper.check: short-span window → fail-open (rc=1)" 1 "unexpectedly saturated"
	else
		print_result "helper.check: short-span window → fail-open (rc=1)" 0
	fi
	return 0
}

test_helper_check_no_samples() {
	export AIDEVOPS_CPU_SATURATION_STATE_DIR="${TEST_ROOT}/sat-empty"
	reset_state
	if "$HELPER" check --window 120 --threshold 98 >/dev/null 2>&1; then
		print_result "helper.check: no samples → not saturated (rc=1)" 1 "unexpectedly saturated"
	else
		print_result "helper.check: no samples → not saturated (rc=1)" 0
	fi
	return 0
}

test_helper_report_summary_format() {
	export AIDEVOPS_CPU_SATURATION_STATE_DIR="${TEST_ROOT}/sat-report"
	reset_state
	write_samples 120 70 80 90
	local out
	out=$("$HELPER" report --window 120 2>/dev/null)
	if [[ "$out" == *"min=70%"* && "$out" == *"max=90%"* && "$out" == *"samples=3"* ]]; then
		print_result "helper.report: prints min/max/samples summary" 0
	else
		print_result "helper.report: prints min/max/samples summary" 1 "got=$out"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Classifier tests (_classify_canary_failure_reason)

# Source the lib so the classifier function is in scope. The lib pulls in
# headless-runtime-helper.sh constants, so we provide the SCRIPT_DIR
# environment it expects and stub the classify_failure_reason function
# (defined elsewhere) with a small fake.
export SCRIPT_DIR

# Fake classify_failure_reason: looks at output file content for our markers.
classify_failure_reason() {
	local output_file="$1"
	if grep -q "AUTH_ERROR_FAKE" "$output_file" 2>/dev/null; then
		printf '%s' "auth_error"
		return 0
	fi
	if grep -q "RATE_LIMIT_FAKE" "$output_file" 2>/dev/null; then
		printf '%s' "rate_limit"
		return 0
	fi
	if grep -q "PROVIDER_ERROR_FAKE" "$output_file" 2>/dev/null; then
		printf '%s' "provider_error"
		return 0
	fi
	printf '%s' "unknown"
	return 0
}

# Stub print_warning/info to silence
print_warning() { return 0; }
print_info() { return 0; }
print_error() { return 0; }
print_step() { return 0; }
print_success() { return 0; }
print_header() { return 0; }

# Surgically extract just the classifier from the lib via eval — sourcing
# the whole file pulls in many side effects. The function deliberately does
# not consult CPU/load helpers.
extract_classifier() {
	awk '
		/^_classify_canary_failure_reason\(\)/ { in_fn = 1 }
		in_fn { print }
		in_fn && /^}$/ { in_fn = 0 }
	' "${SCRIPT_DIR}/headless-runtime-lib.sh"
}

# shellcheck disable=SC2046
eval "$(extract_classifier)"

run_classifier() {
	# run_classifier <fake_pct_csv> <exit_code> <output_file_marker>
	local pcts="$1"
	local exit_code="$2"
	local marker="$3"
	local output_file
	output_file=$(mktemp "${TEST_ROOT}/canary-out.XXXXXX")
	if [[ -n "$marker" ]]; then
		printf '%s\n' "$marker" >"$output_file"
	fi
	export AIDEVOPS_CPU_SATURATION_STATE_DIR="${TEST_ROOT}/sat-classifier-$RANDOM"
	mkdir -p "$AIDEVOPS_CPU_SATURATION_STATE_DIR"
	# Pre-populate the rolling state with the requested utilisation pattern.
	if [[ "$pcts" == "saturated" ]]; then
		write_samples 120 99 99 99 99 99
	elif [[ "$pcts" == "idle" ]]; then
		write_samples 120 30 30 30 30 30
	elif [[ "$pcts" == "none" ]]; then
		: # leave empty
	fi
	# CANARY_SATURATION_WINDOW_SECONDS / PERCENT defaults inherited
	export CANARY_SATURATION_WINDOW_SECONDS=120
	export CANARY_SATURATION_PERCENT=98
	_classify_canary_failure_reason "$output_file" "$exit_code"
}

test_classifier_timeout_saturated_to_timeout() {
	local result
	result=$(run_classifier saturated 124 "")
	if [[ "$result" == "timeout" ]]; then
		print_result "classifier: exit=124 + saturated → timeout (no CPU throttle)" 0
	else
		print_result "classifier: exit=124 + saturated → timeout (no CPU throttle)" 1 "got=$result"
	fi
	return 0
}

test_classifier_timeout_idle_to_timeout() {
	local result
	result=$(run_classifier idle 124 "")
	if [[ "$result" == "timeout" ]]; then
		print_result "classifier: exit=124 + idle → timeout" 0
	else
		print_result "classifier: exit=124 + idle → timeout" 1 "got=$result"
	fi
	return 0
}

test_classifier_timeout_no_samples_to_timeout() {
	local result
	result=$(run_classifier none 137 "")
	if [[ "$result" == "timeout" ]]; then
		print_result "classifier: exit=137 + no samples → timeout (fail-open)" 0
	else
		print_result "classifier: exit=137 + no samples → timeout (fail-open)" 1 "got=$result"
	fi
	return 0
}

test_classifier_auth_error_ignores_saturation() {
	local result
	result=$(run_classifier saturated 124 "AUTH_ERROR_FAKE")
	if [[ "$result" == "auth_error" ]]; then
		print_result "classifier: auth_error pattern ignores saturation" 0
	else
		print_result "classifier: auth_error pattern ignores saturation" 1 "got=$result"
	fi
	return 0
}

test_classifier_runtime_error_unaffected() {
	local result
	result=$(run_classifier saturated 127 "")
	if [[ "$result" == "runtime_error" ]]; then
		print_result "classifier: exit=127 → runtime_error (saturation N/A)" 0
	else
		print_result "classifier: exit=127 → runtime_error (saturation N/A)" 1 "got=$result"
	fi
	return 0
}

test_classifier_helper_missing_no_dependency() {
	# Point at a non-existent helper to verify there is no CPU helper dependency.
	local saved_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="${TEST_ROOT}/no-such-dir"
	local result
	result=$(run_classifier saturated 124 "")
	SCRIPT_DIR="$saved_script_dir"
	if [[ "$result" == "timeout" ]]; then
		print_result "classifier: helper missing → timeout (no CPU dependency)" 0
	else
		print_result "classifier: helper missing → timeout (no CPU dependency)" 1 "got=$result"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run

test_helper_check_saturated
test_helper_check_mixed_idle
test_helper_check_short_span
test_helper_check_no_samples
test_helper_report_summary_format
test_classifier_timeout_saturated_to_timeout
test_classifier_timeout_idle_to_timeout
test_classifier_timeout_no_samples_to_timeout
test_classifier_auth_error_ignores_saturation
test_classifier_runtime_error_unaffected
test_classifier_helper_missing_no_dependency

echo ""
echo "===================="
echo "Tests run: $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"

[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
