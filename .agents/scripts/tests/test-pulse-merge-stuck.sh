#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for pulse-merge-stuck.sh (t3193, GH#21895).
#
# Verifies the stuck-merge detector classifiers, dedup markers,
# and zero-progress counter behaviour.
#
#   Case (1): PR stuck >threshold + MERGEABLE + checks failing
#             → STUCK_CHECKS_FAILING
#   Case (2): PR stuck >threshold + CONFLICTING + no nudge-eligible labels
#             → STUCK_CONFLICT_NO_NUDGE
#   Case (3): PR under age threshold
#             → NOT_STUCK (too young)
#   Case (4): PR with hold-for-review label
#             → NOT_STUCK (held)
#   Case (5): PR with CHANGES_REQUESTED
#             → NOT_STUCK (review block)
#   Case (6): PR stuck + MERGEABLE + no check failures
#             → STUCK_OTHER
#   Case (7): Zero-progress counter increments and resets
#   Case (8): Config loading with env var override
#   Case (9): Failure fingerprint extraction
#
# Pattern: source the module directly, stub gh and API calls, assert
# on classification output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MODULE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-stuck.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	export PULSE_STATS_FILE="${TEST_ROOT}/pulse-stats.json"
	printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"

	# Override zero-progress file location.
	export _STUCK_ZERO_PROGRESS_FILE="${TEST_ROOT}/zero-progress.count"

	# Set a low threshold for testing.
	export AIDEVOPS_MERGE_STUCK_AGE_MINUTES=60
	export AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=3
	export AIDEVOPS_MERGE_PATTERN_MIN_PRS=2

	# Mock gh: logs every call, dispatches by argument shape.
	# Returns raw JSON — the functions under test process jq in-code.
	# NOTE: check-runs fixture is embedded directly in the mock via a
	# sentinel file written by each test. The mock reads the fixture
	# from the path stored in MOCK_CHECK_RUNS_FILE env var (avoids
	# subshell path resolution issues).
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# gh pr view for headRefOid
if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"headRefOid"* ]]; then
	echo "abc123def456"
	exit 0
fi

# gh api for check-runs — returns raw API response
if [[ "$1" == "api" && "$*" == *"check-runs"* ]]; then
	if [[ -n "${MOCK_CHECK_RUNS_FILE:-}" && -f "$MOCK_CHECK_RUNS_FILE" ]]; then
		cat "$MOCK_CHECK_RUNS_FILE"
	else
		echo '{"check_runs":[]}'
	fi
	exit 0
fi

# gh issue list (dedup check — no existing issues)
if [[ "$1" == "issue" && "$2" == "list" ]]; then
	echo "[]"
	exit 0
fi

# gh pr list
if [[ "$1" == "pr" && "$2" == "list" ]]; then
	echo "[]"
	exit 0
fi

# Default: succeed silently.
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	export GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

load_module() {
	# Source the module. Need to unset the include guard first.
	unset _PULSE_MERGE_STUCK_LOADED 2>/dev/null || true
	# Provide stub for pulse_stats_increment if not available.
	pulse_stats_increment() { return 0; }
	export -f pulse_stats_increment
	# shellcheck source=/dev/null
	source "$MODULE_SCRIPT"
	return 0
}

# ── Test Cases ────────────────────────────────────────────────────────

test_classify_stuck_checks_failing() {
	setup_test_env
	load_module

	# Old PR (2h ago) with MERGEABLE, APPROVED, no hold labels.
	local two_hours_ago
	two_hours_ago=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T03:00:00Z')

	local pr_json="{\"number\":42,\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"APPROVED\",\"labels\":[],\"createdAt\":\"${two_hours_ago}\",\"headRefOid\":\"abc123\"}"

	# Set up check-runs response with failures (API format with wrapper object).
	export MOCK_CHECK_RUNS_FILE="${TEST_ROOT}/check_runs_response.json"
	cat >"$MOCK_CHECK_RUNS_FILE" <<'EOF'
{"check_runs":[{"name":"Format","conclusion":"failure"},{"name":"Lint","conclusion":"failure"},{"name":"Build","conclusion":"success"}]}
EOF

	local result
	result=$(_classify_stuck_pr 42 "owner/repo" "$pr_json")

	if [[ "$result" == "STUCK_CHECKS_FAILING" ]]; then
		print_result "classify: STUCK_CHECKS_FAILING" 0
	else
		print_result "classify: STUCK_CHECKS_FAILING" 1 "expected STUCK_CHECKS_FAILING, got '$result'"
	fi

	teardown_test_env
	return 0
}

test_classify_stuck_conflict_no_nudge() {
	setup_test_env
	load_module

	local two_hours_ago
	two_hours_ago=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T03:00:00Z')

	# CONFLICTING PR with no origin:interactive or origin:contributor.
	local pr_json="{\"number\":43,\"mergeable\":\"CONFLICTING\",\"reviewDecision\":\"APPROVED\",\"labels\":[{\"name\":\"origin:worker\"}],\"createdAt\":\"${two_hours_ago}\"}"

	local result
	result=$(_classify_stuck_pr 43 "owner/repo" "$pr_json")

	if [[ "$result" == "STUCK_CONFLICT_NO_NUDGE" ]]; then
		print_result "classify: STUCK_CONFLICT_NO_NUDGE" 0
	else
		print_result "classify: STUCK_CONFLICT_NO_NUDGE" 1 "expected STUCK_CONFLICT_NO_NUDGE, got '$result'"
	fi

	teardown_test_env
	return 0
}

test_classify_not_stuck_young_pr() {
	setup_test_env
	load_module

	# PR created 10 minutes ago — under the 60-min test threshold.
	local ten_min_ago
	ten_min_ago=$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T14:50:00Z')

	local pr_json="{\"number\":44,\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"APPROVED\",\"labels\":[],\"createdAt\":\"${ten_min_ago}\"}"

	local result
	result=$(_classify_stuck_pr 44 "owner/repo" "$pr_json")

	if [[ "$result" == "$_STUCK_CLASS_NOT_STUCK" ]]; then
		print_result "classify: NOT_STUCK (young PR)" 0
	else
		print_result "classify: NOT_STUCK (young PR)" 1 "expected NOT_STUCK, got '$result'"
	fi

	teardown_test_env
	return 0
}

test_classify_not_stuck_hold_for_review() {
	setup_test_env
	load_module

	local two_hours_ago
	two_hours_ago=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T03:00:00Z')

	local pr_json="{\"number\":45,\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"APPROVED\",\"labels\":[{\"name\":\"hold-for-review\"}],\"createdAt\":\"${two_hours_ago}\"}"

	local result
	result=$(_classify_stuck_pr 45 "owner/repo" "$pr_json")

	if [[ "$result" == "$_STUCK_CLASS_NOT_STUCK" ]]; then
		print_result "classify: NOT_STUCK (hold-for-review)" 0
	else
		print_result "classify: NOT_STUCK (hold-for-review)" 1 "expected NOT_STUCK, got '$result'"
	fi

	teardown_test_env
	return 0
}

test_classify_not_stuck_changes_requested() {
	setup_test_env
	load_module

	local two_hours_ago
	two_hours_ago=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T03:00:00Z')

	local pr_json="{\"number\":46,\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"CHANGES_REQUESTED\",\"labels\":[],\"createdAt\":\"${two_hours_ago}\"}"

	local result
	result=$(_classify_stuck_pr 46 "owner/repo" "$pr_json")

	if [[ "$result" == "$_STUCK_CLASS_NOT_STUCK" ]]; then
		print_result "classify: NOT_STUCK (CHANGES_REQUESTED)" 0
	else
		print_result "classify: NOT_STUCK (CHANGES_REQUESTED)" 1 "expected NOT_STUCK, got '$result'"
	fi

	teardown_test_env
	return 0
}

test_classify_stuck_other() {
	setup_test_env
	load_module

	local two_hours_ago
	two_hours_ago=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T03:00:00Z')

	# MERGEABLE, APPROVED, no failing checks → STUCK_OTHER.
	local pr_json="{\"number\":47,\"mergeable\":\"MERGEABLE\",\"reviewDecision\":\"APPROVED\",\"labels\":[],\"createdAt\":\"${two_hours_ago}\",\"headRefOid\":\"abc123\"}"

	# No failing checks (API format with wrapper object).
	export MOCK_CHECK_RUNS_FILE="${TEST_ROOT}/check_runs_response.json"
	cat >"$MOCK_CHECK_RUNS_FILE" <<'EOF'
{"check_runs":[{"name":"Build","conclusion":"success"},{"name":"Test","conclusion":"success"}]}
EOF

	local result
	result=$(_classify_stuck_pr 47 "owner/repo" "$pr_json")

	if [[ "$result" == "STUCK_OTHER" ]]; then
		print_result "classify: STUCK_OTHER" 0
	else
		print_result "classify: STUCK_OTHER" 1 "expected STUCK_OTHER, got '$result'"
	fi

	teardown_test_env
	return 0
}

test_zero_progress_counter() {
	setup_test_env
	load_module

	# Simulate 3 zero-progress cycles (threshold=3).
	_update_zero_progress_counter 0 2
	_update_zero_progress_counter 0 2
	# Third call should trigger (but we suppress the actual issue filing).
	_update_zero_progress_counter 0 2

	# Counter should have been reset after filing.
	local count
	count=$(cat "$_STUCK_ZERO_PROGRESS_FILE" 2>/dev/null) || count=""
	if [[ "$count" == "0" ]]; then
		print_result "zero-progress: resets after threshold" 0
	else
		print_result "zero-progress: resets after threshold" 1 "expected 0, got '$count'"
	fi

	# Now simulate a merge — counter should reset.
	_update_zero_progress_counter 0 1
	_update_zero_progress_counter 1 0  # 1 merged = reset

	count=$(cat "$_STUCK_ZERO_PROGRESS_FILE" 2>/dev/null) || count=""
	if [[ "$count" == "0" ]]; then
		print_result "zero-progress: resets on merge" 0
	else
		print_result "zero-progress: resets on merge" 1 "expected 0, got '$count'"
	fi

	teardown_test_env
	return 0
}

test_config_env_override() {
	setup_test_env
	load_module

	# Set env vars to override config.
	export AIDEVOPS_MERGE_STUCK_AGE_MINUTES=30
	_stuck_merge_load_config

	if [[ "$AIDEVOPS_MERGE_STUCK_AGE_MINUTES" == "30" ]]; then
		print_result "config: env override preserved" 0
	else
		print_result "config: env override preserved" 1 "expected 30, got '$AIDEVOPS_MERGE_STUCK_AGE_MINUTES'"
	fi

	teardown_test_env
	return 0
}

test_fingerprint_extraction() {
	setup_test_env
	load_module

	# Set up check-runs response with specific failures (API format).
	export MOCK_CHECK_RUNS_FILE="${TEST_ROOT}/check_runs_response.json"
	cat >"$MOCK_CHECK_RUNS_FILE" <<'EOF'
{"check_runs":[{"name":"Format","conclusion":"failure"},{"name":"Lint","conclusion":"failure"},{"name":"Build","conclusion":"success"}]}
EOF

	local fp
	fp=$(_stuck_pr_failure_fingerprint 42 "owner/repo")

	if [[ "$fp" == "Format,Lint" ]]; then
		print_result "fingerprint: correct extraction" 0
	else
		print_result "fingerprint: correct extraction" 1 "expected 'Format,Lint', got '$fp'"
	fi

	teardown_test_env
	return 0
}

# ── Run all tests ─────────────────────────────────────────────────────

main() {
	echo "=== pulse-merge-stuck.sh tests (t3193) ==="
	echo ""

	test_classify_stuck_checks_failing
	test_classify_stuck_conflict_no_nudge
	test_classify_not_stuck_young_pr
	test_classify_not_stuck_hold_for_review
	test_classify_not_stuck_changes_requested
	test_classify_stuck_other
	test_zero_progress_counter
	test_config_env_override
	test_fingerprint_extraction

	echo ""
	echo "=== Results: ${TESTS_RUN} run, ${TESTS_FAILED} failed ==="
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
