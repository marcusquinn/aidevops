#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-dispatch-eligibility.sh — Regression tests for pre-dispatch-eligibility-helper.sh (t2424, GH#20030)
#
# Tests:
#   test_closed_issue_blocked                      — CLOSED state → exit 2
#   test_status_done_blocked                       — status:done label → exit 3
#   test_status_resolved_blocked                   — status:resolved label → exit 3
#   test_recent_merge_blocked                      — linked PR merged <5 min ago → exit 4
#   test_eligible_open_no_labels                   — OPEN, no blocking labels → exit 0 (happy path)
#   test_eligible_open_with_queued                 — OPEN, status:queued (not blocking) → exit 0
#   test_api_error_fail_open                       — gh API failure → exit 20 (fail-open)
#   test_bypass_env_var                            — AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1 → exit 0
#   test_prefetched_json_reused                    — ISSUE_META_JSON avoids extra gh call for gates 1+2
#   test_recent_commit_closes_issue_blocked        — recent commit closes this issue → exit 5
#   test_recent_commit_ref_not_blocked             — Ref #NNN commit (not closing keyword) → exit 0
#   test_recent_commit_different_issue_not_blocked — recent commit closes a different issue → exit 0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../pre-dispatch-eligibility-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------
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
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/logs"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export HOME="$TEST_ROOT"
	export LOGFILE="${TEST_ROOT}/logs/pulse.log"
	export PULSE_STATS_FILE="${TEST_ROOT}/logs/pulse-stats.json"
	# Ensure the log file exists so >> appends work.
	touch "$LOGFILE"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# Create a gh stub that returns a specific issue JSON payload.
# Args: $1=state, $2=label_name (bare label string, e.g. "status:done")
#       $3=closed_at (ISO 8601 or ""), $4=timeline_json (optional, defaults to "[]")
#
# The label_name is embedded into a {"name":"<label>"} object inside the labels array.
# Pass "" for $2 to return an empty labels array.
# The JSON is written to a data file and read by the stub via cat to avoid quoting issues.
#######################################
create_gh_stub() {
	local state="$1"
	local label_name="${2:-}"
	local closed_at="${3:-}"
	local timeline_json="${4:-[]}"

	# Build the issue JSON and write to a data file (avoids heredoc quoting issues).
	local issue_data_file="${TEST_ROOT}/issue_data.json"
	local labels_json="[]"
	if [[ -n "$label_name" ]]; then
		labels_json="[{\"name\":\"${label_name}\"}]"
	fi
	printf '{"state":"%s","labels":%s,"closedAt":"%s"}\n' \
		"$state" "$labels_json" "$closed_at" >"$issue_data_file"

	# Write timeline JSON to a data file.
	local timeline_data_file="${TEST_ROOT}/timeline_data.json"
	printf '%s\n' "$timeline_json" >"$timeline_data_file"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

# gh issue view <num> --repo <slug> --json state,labels,closedAt
if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
	cat "${issue_data_file}"
	exit 0
fi

# gh api repos/<slug>/issues/<num>/timeline
if [[ "\${1:-}" == "api" ]]; then
	cat "${timeline_data_file}"
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

#######################################
# Create a gh stub that fails (simulates API error).
#######################################
create_gh_stub_failing() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf 'gh: API error\n' >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

#######################################
# Create a gh stub that supports Gate 4 (recent commit) testing.
# Routes API calls by path pattern so each gate gets the right data.
#
# Args:
#   $1 - state ("OPEN" or "CLOSED")
#   $2 - label_name (bare label string or "")
#   $3 - commit_message (the message of a single recent commit, or "")
#
# Routes:
#   gh issue view           → issue JSON (state + labels)
#   gh api *timeline*       → [] (no recent merges — ensures gate 3 passes)
#   gh api *commits*        → single-commit array with the given message (or [])
#   gh api repos/<slug>     → {"default_branch":"main"}
#######################################
create_gh_stub_with_commits() {
	local state="$1"
	local label_name="${2:-}"
	local commit_message="${3:-}"

	# Write issue JSON data.
	local issue_data_file="${TEST_ROOT}/issue_data.json"
	local labels_json="[]"
	if [[ -n "$label_name" ]]; then
		labels_json="[{\"name\":\"${label_name}\"}]"
	fi
	printf '{"state":"%s","labels":%s,"closedAt":""}\n' \
		"$state" "$labels_json" >"$issue_data_file"

	# Write commits JSON data (one commit with the given message, or empty).
	local commits_data_file="${TEST_ROOT}/commits_data.json"
	if [[ -n "$commit_message" ]]; then
		# Escape any double-quotes in the message for embedding in JSON.
		local escaped_msg="${commit_message//\"/\\\"}"
		printf '[{"commit":{"message":"%s"}}]\n' "$escaped_msg" >"$commits_data_file"
	else
		printf '[]\n' >"$commits_data_file"
	fi

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

# gh issue view <num> --repo <slug> --json state,labels,closedAt
if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
	cat "${issue_data_file}"
	exit 0
fi

if [[ "\${1:-}" == "api" ]]; then
	case "\${2:-}" in
		*"commits"*)
			# Gate 4: recent commits endpoint
			cat "${commits_data_file}"
			;;
		*"timeline"*)
			# Gate 3: timeline endpoint — return empty (no recent merges)
			printf '[]\n'
			;;
		*)
			# Repo info endpoint (default branch lookup)
			printf '{"default_branch":"main"}\n'
			;;
	esac
	exit 0
fi

printf 'unsupported gh invocation: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Test 1: CLOSED issue → exit 2
test_closed_issue_blocked() {
	setup_test_env

	create_gh_stub "CLOSED" "" "2026-04-19T10:00:00Z"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 2 ]] || fail=1
	print_result "test_closed_issue_blocked" "$fail" "expected exit 2, got ${rc}"

	teardown_test_env
	return 0
}

# Test 2: status:done label → exit 3
test_status_done_blocked() {
	setup_test_env

	create_gh_stub "OPEN" "status:done" ""

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 3 ]] || fail=1
	print_result "test_status_done_blocked" "$fail" "expected exit 3, got ${rc}"

	teardown_test_env
	return 0
}

# Test 3: status:resolved label → exit 3
test_status_resolved_blocked() {
	setup_test_env

	create_gh_stub "OPEN" "status:resolved" ""

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 3 ]] || fail=1
	print_result "test_status_resolved_blocked" "$fail" "expected exit 3, got ${rc}"

	teardown_test_env
	return 0
}

# Test 4: Recent merged event in timeline → exit 4
test_recent_merge_blocked() {
	setup_test_env

	# Build a recent timeline event (epoch: very recent).
	local now_epoch recent_ts timeline_json
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	recent_ts=$(( now_epoch - 60 ))  # 1 minute ago — within default 300s window
	local recent_iso
	recent_iso=$(date -r "$recent_ts" -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
		|| date -d "@${recent_ts}" -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
		|| printf '2026-04-20T01:00:00Z')
	timeline_json="[{\"event\":\"merged\",\"created_at\":\"${recent_iso}\"}]"

	create_gh_stub "OPEN" "status:queued" "" "$timeline_json"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 4 ]] || fail=1
	print_result "test_recent_merge_blocked" "$fail" "expected exit 4, got ${rc}"

	teardown_test_env
	return 0
}

# Test 5: OPEN, no blocking labels → exit 0 (happy path)
test_eligible_open_no_labels() {
	setup_test_env

	create_gh_stub "OPEN" "" "" "[]"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 0 ]] || fail=1
	print_result "test_eligible_open_no_labels" "$fail" "expected exit 0, got ${rc}"

	teardown_test_env
	return 0
}

# Test 6: OPEN with status:queued label (non-blocking) → exit 0
test_eligible_open_with_queued() {
	setup_test_env

	create_gh_stub "OPEN" "status:queued" "" "[]"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 0 ]] || fail=1
	print_result "test_eligible_open_with_queued" "$fail" "expected exit 0, got ${rc}"

	teardown_test_env
	return 0
}

# Test 7: gh API failure → exit 20 (fail-open)
test_api_error_fail_open() {
	setup_test_env

	create_gh_stub_failing

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 20 ]] || fail=1
	print_result "test_api_error_fail_open" "$fail" "expected exit 20, got ${rc}"

	teardown_test_env
	return 0
}

# Test 8: AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1 → exit 0 even for CLOSED issue
test_bypass_env_var() {
	setup_test_env

	create_gh_stub "CLOSED" "" "2026-04-19T10:00:00Z"

	local rc=0
	AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1 \
		"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 0 ]] || fail=1
	print_result "test_bypass_env_var" "$fail" "expected exit 0 with bypass, got ${rc}"

	teardown_test_env
	return 0
}

# Test 9: Pre-fetched ISSUE_META_JSON for CLOSED state avoids gh call for gates 1+2.
# Verifies the function uses ISSUE_META_JSON and returns exit 2.
test_prefetched_json_reused() {
	setup_test_env

	# Set up a gh stub that would NOT return CLOSED (to prove ISSUE_META_JSON is used).
	create_gh_stub "OPEN" "" "" "[]"

	# But inject CLOSED JSON via env var — the function should use this.
	local meta_json='{"state":"CLOSED","labels":[],"closedAt":"2026-04-19T10:00:00Z"}'

	local rc=0
	ISSUE_META_JSON="$meta_json" \
		"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 2 ]] || fail=1
	print_result "test_prefetched_json_reused" "$fail" "expected exit 2 from ISSUE_META_JSON, got ${rc}"

	teardown_test_env
	return 0
}

# Test 10: Recent commit closes this issue → exit 5 (happy path for gate 4)
test_recent_commit_closes_issue_blocked() {
	setup_test_env

	# Commit message uses a closing keyword ("closes") referencing issue 12345.
	create_gh_stub_with_commits "OPEN" "status:queued" "closes #12345"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 5 ]] || fail=1
	print_result "test_recent_commit_closes_issue_blocked" "$fail" "expected exit 5, got ${rc}"

	teardown_test_env
	return 0
}

# Test 11: Recent commit uses "Ref #NNN" (planning reference, not closing keyword) → exit 0
test_recent_commit_ref_not_blocked() {
	setup_test_env

	# "Ref #12345" is a planning reference — must NOT trigger gate 4.
	create_gh_stub_with_commits "OPEN" "" "Ref #12345 update planning notes"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 0 ]] || fail=1
	print_result "test_recent_commit_ref_not_blocked" "$fail" "expected exit 0 for Ref commit, got ${rc}"

	teardown_test_env
	return 0
}

# Test 12: Recent commit closes a DIFFERENT issue → exit 0
test_recent_commit_different_issue_not_blocked() {
	setup_test_env

	# Commit closes issue 99999, NOT the candidate issue 12345.
	create_gh_stub_with_commits "OPEN" "" "fixes #99999"

	local rc=0
	"$HELPER_SCRIPT" check 12345 "owner/repo" >/dev/null 2>&1 || rc=$?

	local fail=0
	[[ "$rc" -eq 0 ]] || fail=1
	print_result "test_recent_commit_different_issue_not_blocked" "$fail" "expected exit 0 for different issue, got ${rc}"

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
main() {
	echo "Running pre-dispatch-eligibility-helper.sh tests..."
	echo ""

	if [[ ! -f "$HELPER_SCRIPT" ]]; then
		echo "FATAL: Helper script not found: ${HELPER_SCRIPT}" >&2
		exit 1
	fi

	test_closed_issue_blocked
	test_status_done_blocked
	test_status_resolved_blocked
	test_recent_merge_blocked
	test_eligible_open_no_labels
	test_eligible_open_with_queued
	test_api_error_fail_open
	test_bypass_env_var
	test_prefetched_json_reused
	test_recent_commit_closes_issue_blocked
	test_recent_commit_ref_not_blocked
	test_recent_commit_different_issue_not_blocked

	echo ""
	echo "---"
	printf 'Results: %s/%s tests passed\n' "$(( TESTS_RUN - TESTS_FAILED ))" "$TESTS_RUN"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf '%bFAIL%b %s test(s) failed\n' "$TEST_RED" "$TEST_RESET" "$TESTS_FAILED"
		return 1
	fi

	printf '%bPASS%b All tests passed\n' "$TEST_GREEN" "$TEST_RESET"
	return 0
}

main "$@"
