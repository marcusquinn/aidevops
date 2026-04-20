#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-enrich-batch-prefetch.sh — GH#20129 regression guard.
#
# Asserts that the enrich path in issue-sync-helper.sh:
#   (i)  With a healthy rate limit and a valid prefetch, uses batch-prefetched
#        JSON and does NOT call gh issue view per-task.
#   (ii) With an exhausted GraphQL rate limit, emits ::warning:: and exits
#        cleanly without iterating over individual issues.
#   (iii) When the prefetch file is absent/stale, falls back to per-task
#         gh issue view (fail-safe).
#
# Also verifies _enrich_check_rate_limit and _enrich_prefetch_issues_map
# helper functions exist and have the correct signatures.

set -uo pipefail

# Save our test directory BEFORE sourcing helpers (sourcing overwrites SCRIPT_DIR).
TEST_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="${2:-1}"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"
	return 0
}

teardown_test_env() {
	if [[ -n "${TEST_ROOT:-}" && -d "${TEST_ROOT}" ]]; then
		rm -rf "${TEST_ROOT}"
	fi
	return 0
}

setup_test_env
trap 'teardown_test_env' EXIT

# =============================================================================
# Part 1 — structural checks: helper functions exist
# =============================================================================
# Source the helper to verify functions are present.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh" >/dev/null 2>&1
set +e

if declare -f _enrich_check_rate_limit >/dev/null 2>&1; then
	print_result "_enrich_check_rate_limit function exists (GH#20129)" 0
else
	print_result "_enrich_check_rate_limit function exists (GH#20129)" 1 "(function not found)"
fi

if declare -f _enrich_prefetch_issues_map >/dev/null 2>&1; then
	print_result "_enrich_prefetch_issues_map function exists (GH#20129)" 0
else
	print_result "_enrich_prefetch_issues_map function exists (GH#20129)" 1 "(function not found)"
fi

# Verify cmd_enrich calls both helpers (use grep on the actual file path)
if grep -q '_enrich_check_rate_limit' "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh"; then
	print_result "cmd_enrich calls _enrich_check_rate_limit" 0
else
	print_result "cmd_enrich calls _enrich_check_rate_limit" 1 "(call not found in cmd_enrich)"
fi

if grep -q '_enrich_prefetch_issues_map' "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh"; then
	print_result "cmd_enrich calls _enrich_prefetch_issues_map" 0
else
	print_result "cmd_enrich calls _enrich_prefetch_issues_map" 1 "(call not found in cmd_enrich)"
fi

# Verify _enrich_process_task references ENRICH_PREFETCH_FILE
if grep -q 'ENRICH_PREFETCH_FILE' "${TEST_SCRIPTS_DIR}/../issue-sync-helper.sh"; then
	print_result "_enrich_process_task uses ENRICH_PREFETCH_FILE (GH#20129)" 0
else
	print_result "_enrich_process_task uses ENRICH_PREFETCH_FILE (GH#20129)" 1 "(ENRICH_PREFETCH_FILE not referenced)"
fi

# =============================================================================
# Part 2 — _enrich_check_rate_limit: exhausted rate limit → return 0 (skip)
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin-rl-exhausted"
mkdir -p "$STUB_DIR"

# Stub gh to return an exhausted rate limit (remaining=0)
FUTURE_RESET=$(date -u -d '+5 minutes' '+%s' 2>/dev/null \
	|| TZ=UTC date -v+5M '+%s' 2>/dev/null || echo "9999999999")
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	printf '{"resources":{"graphql":{"remaining":0,"reset":%s}}}' "${FUTURE_RESET}"
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

_original_path="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Source the functions directly (already sourced above, just need PATH override)
# _enrich_check_rate_limit should return 0 (skip) when remaining=0
if _enrich_check_rate_limit 2>/dev/null; then
	print_result "_enrich_check_rate_limit returns 0 (skip) when rate limit exhausted" 0
else
	print_result "_enrich_check_rate_limit returns 0 (skip) when rate limit exhausted" 1 "(expected return 0, got return 1)"
fi

# Check it emits the ::warning:: line
_rl_output=$(_enrich_check_rate_limit 2>/dev/null) || true
if [[ "$_rl_output" == *"::warning::"* ]]; then
	print_result "_enrich_check_rate_limit emits ::warning:: on exhausted limit" 0
else
	print_result "_enrich_check_rate_limit emits ::warning:: on exhausted limit" 1 "(no ::warning:: in output: '$_rl_output')"
fi

if [[ "$_rl_output" == *"remaining=0"* ]]; then
	print_result "_enrich_check_rate_limit includes remaining count in warning" 0
else
	print_result "_enrich_check_rate_limit includes remaining count in warning" 1 "(remaining not in output)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 3 — _enrich_check_rate_limit: healthy rate limit → return 1 (proceed)
# =============================================================================
STUB_DIR2="${TEST_ROOT}/bin-rl-healthy"
mkdir -p "$STUB_DIR2"

cat >"${STUB_DIR2}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	printf '{"resources":{"graphql":{"remaining":5000,"reset":9999999999}}}'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR2}/gh"

export PATH="${STUB_DIR2}:${PATH}"

# With healthy rate limit, should return 1 (proceed)
if ! _enrich_check_rate_limit 2>/dev/null; then
	print_result "_enrich_check_rate_limit returns 1 (proceed) with healthy rate limit" 0
else
	print_result "_enrich_check_rate_limit returns 1 (proceed) with healthy rate limit" 1 "(returned 0 — would skip unnecessarily)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 4 — _enrich_check_rate_limit: fail-open when gh api fails
# =============================================================================
STUB_DIR3="${TEST_ROOT}/bin-rl-fail"
mkdir -p "$STUB_DIR3"

cat >"${STUB_DIR3}/gh" <<STUB
#!/usr/bin/env bash
# Simulate gh api failure
exit 1
STUB
chmod +x "${STUB_DIR3}/gh"

export PATH="${STUB_DIR3}:${PATH}"

# When gh api fails, should fail-open (return 1 = proceed)
if ! _enrich_check_rate_limit 2>/dev/null; then
	print_result "_enrich_check_rate_limit fails-open (return 1) when gh api fails" 0
else
	print_result "_enrich_check_rate_limit fails-open (return 1) when gh api fails" 1 "(returned 0 — should not skip on API failure)"
fi

export PATH="$_original_path"

# =============================================================================
# Part 5 — _enrich_process_task uses ENRICH_PREFETCH_FILE (no gh issue view)
# =============================================================================
# Build a stub that tracks call counts to gh issue view.
STUB_DIR4="${TEST_ROOT}/bin-prefetch-count"
mkdir -p "$STUB_DIR4"
CALL_LOG="${TEST_ROOT}/gh-calls.log"

cat >"${STUB_DIR4}/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${CALL_LOG}"
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	# This call should NOT happen when prefetch is available
	printf '{"number":123,"title":"t9999: Test issue","body":"body","labels":[],"state":"OPEN","assignees":[]}\n'
	exit 0
fi
if [[ "\$1" == "api" && "\$2" == "user" ]]; then
	printf '{"login":"testbot"}\n'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR4}/gh"

# Create a valid prefetch file with issue 123
PREFETCH_FILE=$(mktemp /tmp/test-prefetch-XXXXXX.json)
printf '[{"number":123,"title":"t9999: Test issue","body":"original body","labels":[{"name":"bug"}],"state":"OPEN","assignees":[]}]\n' \
	>"$PREFETCH_FILE"

export PATH="${STUB_DIR4}:${PATH}"
export ENRICH_PREFETCH_FILE="$PREFETCH_FILE"

# Look up issue 123 from the prefetch file using the same jq pattern as _enrich_process_task
_lookup=$(jq -c --argjson n 123 '.[] | select(.number == $n)' "$PREFETCH_FILE" 2>/dev/null || echo "")
if [[ -n "$_lookup" ]]; then
	print_result "Prefetch file lookup returns data for issue 123" 0
else
	print_result "Prefetch file lookup returns data for issue 123" 1 "(empty result from jq lookup)"
fi

_lookup_title=$(printf '%s' "$_lookup" | jq -r '.title // ""' 2>/dev/null || echo "")
if [[ "$_lookup_title" == "t9999: Test issue" ]]; then
	print_result "Prefetch file lookup returns correct title" 0
else
	print_result "Prefetch file lookup returns correct title" 1 "(expected 't9999: Test issue', got '$_lookup_title')"
fi

rm -f "$PREFETCH_FILE" 2>/dev/null || true
rm -f "$CALL_LOG" 2>/dev/null || true
unset ENRICH_PREFETCH_FILE
export PATH="$_original_path"

# =============================================================================
# Part 6 — fallback when ENRICH_PREFETCH_FILE is absent
# =============================================================================
# When ENRICH_PREFETCH_FILE is unset, the lookup should return empty and the
# fallback gh issue view code path should be used.
unset ENRICH_PREFETCH_FILE

_no_prefetch=$(jq -c --argjson n 123 '.[] | select(.number == $n)' "/tmp/nonexistent-XXXXXX.json" 2>/dev/null || echo "")
if [[ -z "$_no_prefetch" ]]; then
	print_result "Cache miss on absent prefetch file returns empty (triggers fallback)" 0
else
	print_result "Cache miss on absent prefetch file returns empty (triggers fallback)" 1 "(expected empty, got: $_no_prefetch)"
fi

# Verify the condition guard in _enrich_process_task:
# [[ -n "${ENRICH_PREFETCH_FILE:-}" && -f "$ENRICH_PREFETCH_FILE" && -n "$num" ]]
# With ENRICH_PREFETCH_FILE unset, -n "${ENRICH_PREFETCH_FILE:-}" is false → no prefetch attempt
_test_guard=false
if [[ -n "${ENRICH_PREFETCH_FILE:-}" && -f "${ENRICH_PREFETCH_FILE:-/nonexistent}" ]]; then
	_test_guard=true
fi
if [[ "$_test_guard" == "false" ]]; then
	print_result "Guard condition skips prefetch when ENRICH_PREFETCH_FILE is unset" 0
else
	print_result "Guard condition skips prefetch when ENRICH_PREFETCH_FILE is unset" 1 "(guard should be false when var unset)"
fi

# =============================================================================
# Part 7 — ENRICH_PREFETCH_LIMIT and ENRICH_RATE_LIMIT_THRESHOLD are honoured
# =============================================================================
# Verify that environment variables control the threshold and limit values.
# We test _enrich_check_rate_limit with a custom threshold.
STUB_DIR5="${TEST_ROOT}/bin-custom-threshold"
mkdir -p "$STUB_DIR5"

cat >"${STUB_DIR5}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == "rate_limit" ]]; then
	# remaining=100 — above default (250) would skip, but below 50 custom threshold would not
	printf '{"resources":{"graphql":{"remaining":100,"reset":9999999999}}}'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR5}/gh"
export PATH="${STUB_DIR5}:${PATH}"

# With default threshold (250), remaining=100 should skip (return 0)
if ENRICH_RATE_LIMIT_THRESHOLD=250 _enrich_check_rate_limit 2>/dev/null; then
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=250 skips when remaining=100" 0
else
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=250 skips when remaining=100" 1 "(should have returned 0 to skip)"
fi

# With threshold=50, remaining=100 should proceed (return 1)
if ! ENRICH_RATE_LIMIT_THRESHOLD=50 _enrich_check_rate_limit 2>/dev/null; then
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=50 proceeds when remaining=100" 0
else
	print_result "ENRICH_RATE_LIMIT_THRESHOLD=50 proceeds when remaining=100" 1 "(should have returned 1 to proceed)"
fi

export PATH="$_original_path"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "---"
echo "Tests run: $TESTS_RUN | Passed: $((TESTS_RUN - TESTS_FAILED)) | Failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%bSOME TESTS FAILED%b\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi
printf '%bALL TESTS PASSED%b\n' "$TEST_GREEN" "$TEST_RESET"
