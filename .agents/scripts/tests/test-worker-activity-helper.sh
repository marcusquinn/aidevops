#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-activity-helper.sh — Fixture-driven tests for t3215.
#
# Verifies worker-activity-helper.sh aggregates the canonical sources
# (headless-runtime-metrics.jsonl + pulse-stats.json) correctly without
# touching the real ~/.aidevops files. Tests are offline (--no-pr-check).

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

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  got:      $(printf '%q' "$actual")"
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
# Setup: locate the helper, build temp fixtures.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/worker-activity-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $HELPER not found or not executable"
	exit 1
fi

FIXTURE_DIR="$(mktemp -d -t wah-test-XXXXXX)"
METRICS="$FIXTURE_DIR/headless-runtime-metrics.jsonl"
STATS="$FIXTURE_DIR/pulse-stats.json"
PR_CACHE="$FIXTURE_DIR/pr-cache.json"
OAUTH_POOL="$FIXTURE_DIR/oauth-pool.json"

cleanup() {
	rm -rf "$FIXTURE_DIR"
	return 0
}
trap cleanup EXIT

NOW=$(date +%s)
T_5MIN_AGO=$((NOW - 300))
T_2H_AGO=$((NOW - 7200))
T_25H_AGO=$((NOW - 90000))
T_FUTURE_SENTINEL=4102444800
T_FUTURE_SENTINEL_MS=$((T_FUTURE_SENTINEL * 1000))

# Build metrics fixture covering every bucket and the regression cases that
# the original awk implementation handled correctly:
#   issue-1, issue-2 — success (terminal)
#   issue-3          — watchdog_stall_killed (terminal failure)
#   issue-4          — watchdog_stall_continue heartbeat (exit 0)
#   issue-5          — rate_limit
#   issue-6          — premature_exit-style unknown failure (exit != 0)
#   issue-7          — out-of-window success (must be excluded by --since 24h)
#   issue-8          — watchdog_stall_continue with NON-ZERO exit code; this
#                      is the t3215 of-bucket regression case. The bucket is
#                      result-name-based fallthrough, NOT exit-code-based —
#                      this record must count as wc, NOT as of.
#   issue-9          — synthetic future sentinel timestamp (year 2100); must
#                      be excluded from bounded-window metrics and examples.
#   issue-10         — missing timestamp; must not appear in bounded windows.
#   issue-11         — service_interruption_continue heartbeat, not terminal.
#   issue-12         — service_interruption_exhausted terminal failure after the
#                      dedicated continuation budget is spent.
{
	printf '{"ts":%d,"role":"worker","session_key":"issue-1","result":"success","exit_code":0,"duration_ms":1000,"load_1min":2.0,"load_per_cpu":0.25}\n' "$T_5MIN_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-2","result":"success","exit_code":0}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-3","session_id":"ses_3","issue_number":22349,"repo_slug":"marcusquinn/aidevops","work_dir":"/tmp/wt-3","output_file":"/tmp/excerpt-3.log","result":"watchdog_stall_killed","failure_reason":"watchdog_stall_killed","launch_failure_cause":"stall_hard_killed","kill_reason":"hard_kill_stall","next_action":"redispatch_worker","exit_code":79}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-4","result":"watchdog_stall_continue","exit_code":0}\n' "$T_5MIN_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-5","model":"openai/gpt-5.5","provider":"openai","result":"rate_limit","failure_reason":"rate_limit","provider_error_type":"rate_limit","provider_status":"429","classification_source":"output_pattern","classification_pattern":"rate_limit|rate_limit|429|too_many_requests|quota_exceeded","exit_code":1}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-6","model":"openai/gpt-5.5","provider":"openai","result":"provider_error","failure_reason":"provider_error","provider_error_type":"server_error","provider_status":"500","classification_source":"output_pattern","classification_pattern":"server_error|5xx|connection_failure|overloaded","launch_failure_cause":"provider_error","next_action":"inspect_failure_excerpt","exit_code":2}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-7","result":"success","exit_code":0}\n' "$T_25H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-8","result":"watchdog_stall_continue","exit_code":124}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-9","result":"success","exit_code":0}\n' "$T_FUTURE_SENTINEL"
	printf '{"role":"worker","session_key":"issue-10","result":"success","exit_code":0}\n'
	printf '{"ts":%d,"role":"worker","session_key":"issue-11","model":"openai/gpt-5.5","provider":"openai","result":"service_interruption_continue","failure_reason":"provider_error","provider_error_type":"server_error","provider_status":"503","exit_code":81}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-12","model":"openai/gpt-5.5","provider":"openai","result":"service_interruption_exhausted","failure_reason":"local_error","runtime_error_type":"sigterm","launch_failure_cause":"local_runtime_error","next_action":"inspect_failure_excerpt_and_retry_if_transient","exit_code":81}\n' "$T_2H_AGO"
} >"$METRICS"

cat >"$OAUTH_POOL" <<EOF
{
  "openai": [
    {"status": "idle"},
    {"status": "active"},
    {"status": "auth-error"},
    {"status": "rate-limited", "cooldownUntil": $T_FUTURE_SENTINEL_MS}
  ],
  "anthropic": [
    {"status": "idle"}
  ]
}
EOF

# Build pulse-stats fixture: counter arrays with timestamps inside and outside window.
cat >"$STATS" <<EOF
{
  "counters": {
    "pulse_dispatch_circuit_broken": [$T_5MIN_AGO, $T_2H_AGO, $T_25H_AGO],
    "pulse_cycle_skipped_graphql_low": [$T_2H_AGO],
    "dispatch_backoff_skipped": [],
    "pulse_dispatch_no_work_breaker_tripped": [$T_5MIN_AGO]
  },
  "invocation_sources": {}
}
EOF

# Common env for the helper: point at fixtures, skip network.
RUN_ENV=(
	"WAH_METRICS_FILE=$METRICS"
	"WAH_PULSE_STATS_FILE=$STATS"
	"WAH_PR_CACHE_FILE=$PR_CACHE"
	"WAH_OAUTH_POOL_FILE=$OAUTH_POOL"
	"PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER=24"
)

echo "${TEST_BLUE}=== t3215: worker-activity-helper.sh tests ===${TEST_NC}"
echo

# ---------------------------------------------------------------------------
# Section 1: argv & help.
# ---------------------------------------------------------------------------
echo "--- Section 1: argv parsing ---"

OUT=$("$HELPER" help 2>&1)
RC=$?
assert_rc "1a: help exits 0" 0 "$RC"
assert_contains "1b: help mentions canonical sources" "headless-runtime-metrics.jsonl" "$OUT"
assert_contains "1c: help mentions pulse-stats" "pulse-stats.json" "$OUT"
assert_contains "1d: help warns against worker-NNN.log mtime" "mtime" "$OUT"

# Bad subcommand exits 2.
OUT=$("$HELPER" frobnicate 2>&1)
RC=$?
assert_rc "1e: unknown command exits 2" 2 "$RC"

# Bad --since exits 2.
OUT=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 99x --no-pr-check 2>&1)
RC=$?
assert_rc "1f: bad --since exits 2" 2 "$RC"
assert_contains "1g: bad --since explains valid options" "1h|6h|24h|48h|7d" "$OUT"

# ---------------------------------------------------------------------------
# Section 2: 24h aggregation accuracy.
# ---------------------------------------------------------------------------
echo
echo "--- Section 2: 24h aggregation ---"

JSON=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 24h --no-pr-check --json 2>&1)
RC=$?
assert_rc "2a: --json exits 0" 0 "$RC"

# Validate it's parseable JSON.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$JSON" | jq . >/dev/null 2>&1; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 2b: output parses as JSON"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 2b: output is not valid JSON"
	echo "  output: $(printf '%q' "${JSON:0:300}")"
fi

# Assert exact counts. 24h window: events 1-6 + 8 + 11 + 12, excludes 7 (25h ago).
# issue-8 (watchdog_stall_continue with exit_code=124) tests the t3215
# regression case — must count as wc, not of, despite non-zero exit.
assert_eq "2c: total = 9" "9" "$(printf '%s' "$JSON" | jq -r '.metrics.total')"
assert_eq "2d: succeeded = 2" "2" "$(printf '%s' "$JSON" | jq -r '.metrics.succeeded')"
assert_eq "2e: watchdog_killed = 1" "1" "$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_killed')"
assert_eq "2f: watchdog_continued = 2 (incl. nonzero-exit heartbeat)" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_continued')"
assert_eq "2f2: service_interrupted = 1 (heartbeat)" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.service_interrupted')"
assert_eq "2g: rate_limited = 1" "1" "$(printf '%s' "$JSON" | jq -r '.metrics.rate_limited')"
assert_eq "2h: other_failure = 2 (heartbeat excluded, exhausted counted)" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.other_failure')"
assert_eq "2h2: rich result_counts includes success bucket" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.result_counts.success')"
assert_eq "2h3: timing summary includes samples" "9" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.timing_ms.samples')"
assert_eq "2h4: recent example carries load context" "2.0" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.recent_examples[] | select(.session_key == "issue-1") | .load_1min')"
assert_eq "2h5: future sentinel excluded from examples" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.recent_examples[] | select(.session_key == "issue-9")] | length')"
assert_eq "2h6: missing timestamp excluded from examples" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.recent_examples[] | select(.session_key == "issue-10")] | length')"
assert_eq "2h7: failure groups carry issue evidence" "22349" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-3") | .issue_number')"
assert_eq "2h8: failure groups include repo evidence" "marcusquinn/aidevops" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-3") | .repo_slug')"
assert_eq "2h9: failure groups expose provider subtype" "server_error" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-6") | .provider_error_type')"
assert_eq "2h10: failure groups expose provider status" "500" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-6") | .provider_status')"
assert_eq "2h10b: failure groups expose classification pattern" "server_error|5xx|connection_failure|overloaded" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-6") | .classification_pattern')"
assert_eq "2h11: recent examples carry provider evidence" "openai/gpt-5.5" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.recent_examples[] | select(.session_key == "issue-11") | .model')"
assert_eq "2h12: diagnostic focus counts stall-killed sessions" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.diagnostic_focus.stall_hard_killed')"
assert_eq "2h13: diagnostic focus counts local runtime errors" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.diagnostic_focus.local_runtime_error')"
assert_eq "2h14: failure families carry next action for stall kills" "redispatch_worker" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_families[] | select(.launch_failure_cause == "stall_hard_killed") | .next_action')"

# Pulse-stats counters (24h window: 25h-ago timestamp must be excluded).
assert_eq "2i: circuit_broken = 2" "2" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_dispatch_circuit_broken')"
assert_eq "2j: gql_low = 1" "1" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_cycle_skipped_graphql_low')"
assert_eq "2k: missing key returns 0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.dispatch_backoff_skipped')"
assert_eq "2l: nwbreaker = 1" "1" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_dispatch_no_work_breaker_tripped')"

# PR check skipped → null + state=skipped.
assert_eq "2m: pr count is null when skipped" "null" \
	"$(printf '%s' "$JSON" | jq -r '.worker_solved_issues.count')"
assert_eq "2n: pr check_state = skipped" "skipped" \
	"$(printf '%s' "$JSON" | jq -r '.worker_solved_issues.check_state')"

# ---------------------------------------------------------------------------
# Section 3: 1h window narrows correctly.
# ---------------------------------------------------------------------------
echo
echo "--- Section 3: 1h window ---"

JSON=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 1h --no-pr-check --json 2>&1)
# 1h window: only events at 5min ago (issue-1, issue-4) qualify; future
# sentinel and missing-ts rows are invalid worker evidence.
assert_eq "3a: 1h total = 2" "2" "$(printf '%s' "$JSON" | jq -r '.metrics.total')"
assert_eq "3b: 1h succeeded = 1" "1" "$(printf '%s' "$JSON" | jq -r '.metrics.succeeded')"
assert_eq "3c: 1h watchdog_continued = 1" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_continued')"
assert_eq "3d: 1h watchdog_killed = 0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_killed')"
assert_eq "3e: 1h recent examples exclude future sentinel" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.recent_examples[] | select(.session_key == "issue-9")] | length')"

# ---------------------------------------------------------------------------
# Section 4: missing files fail-open to zeros.
# ---------------------------------------------------------------------------
echo
echo "--- Section 4: missing-file resilience ---"

JSON=$(env \
	"WAH_METRICS_FILE=/nonexistent/metrics.jsonl" \
	"WAH_PULSE_STATS_FILE=/nonexistent/stats.json" \
	"WAH_PR_CACHE_FILE=$PR_CACHE" \
	"$HELPER" summary --since 24h --no-pr-check --json 2>&1)
RC=$?
assert_rc "4a: missing files exits 0 (fail-open)" 0 "$RC"
assert_eq "4b: missing metrics → total=0" "0" "$(printf '%s' "$JSON" | jq -r '.metrics.total')"
assert_eq "4c: missing stats → counter=0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_dispatch_circuit_broken')"

# ---------------------------------------------------------------------------
# Section 5: human-output legibility.
# ---------------------------------------------------------------------------
echo
echo "--- Section 5: human-readable output ---"

OUT=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 24h --no-pr-check 2>&1)
assert_contains "5a: human output names canonical jsonl source" \
	"headless-runtime-metrics.jsonl" "$OUT"
assert_contains "5b: human output names pulse-stats" "pulse-stats.json" "$OUT"
assert_contains "5c: human output shows succeeded count" "Succeeded:                   2" "$OUT"
assert_contains "5d: human output shows watchdog continued is heartbeat" \
	"heartbeat" "$OUT"
assert_contains "5d2: human output shows service interruption resumes" \
	"Service interruption resumed" "$OUT"
assert_contains "5e: human output shows pr-check opt-in note" "use --pr-check" "$OUT"
assert_contains "5f: human output shows timing summary" "Timing ms" "$OUT"
assert_contains "5g: human output shows failure groups" "Failure groups" "$OUT"
assert_contains "5h: human output shows diagnostic focus" "Diagnostic focus" "$OUT"
assert_contains "5i: human output shows failure families" "Failure families" "$OUT"

# ---------------------------------------------------------------------------
# Section 6: provider/account diagnostics expose redacted capacity slots.
# ---------------------------------------------------------------------------
echo
echo "--- Section 6: provider/account diagnostics ---"

printf '{"ts":%d,"role":"worker","session_key":"issue-13","model":"openai/gpt-5.5","provider":"openai","result":"success","exit_code":9}\n' "$T_5MIN_AGO" >>"$METRICS"

JSON=$(env "${RUN_ENV[@]}" "$HELPER" providers --since 24h --json 2>&1)
RC=$?
assert_rc "6a: providers --json exits 0" 0 "$RC"
assert_eq "6b: openai available accounts exclude auth-error/rate-limited" "2" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.account_pool[] | select(.provider == "openai") | .available')"
assert_eq "6c: openai capacity_slots uses redacted multiplier" "4" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.account_pool[] | select(.provider == "openai") | .capacity_slots')"
assert_eq "6c2: nonzero-exit success counts as other provider failure" "4" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.provider_model_usage[] | select(.provider == "openai" and .model == "openai/gpt-5.5") | .other_failure')"

OUT=$(env "${RUN_ENV[@]}" "$HELPER" providers --since 24h 2>&1)
assert_contains "6d: human provider output shows capacity slots" "capacity_slots=4" "$OUT"

# ---------------------------------------------------------------------------
# Section 7: solved:worker attribution query excludes origin-only PR counts.
# ---------------------------------------------------------------------------
echo
echo "--- Section 7: solved-by attribution query ---"

GH_STUB_DIR="$FIXTURE_DIR/bin"
mkdir -p "$GH_STUB_DIR"
GH_CALL_LOG="$FIXTURE_DIR/gh-calls.log"
cat >"$GH_STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALL_LOG}"
if [[ "$1" == "issue" && "$2" == "list" ]]; then
	printf '[{"number":101},{"number":102}]\n'
	exit 0
fi
printf '[]\n'
EOF
chmod +x "$GH_STUB_DIR/gh"

JSON=$(env "${RUN_ENV[@]}" "GH_CALL_LOG=$GH_CALL_LOG" "PATH=$GH_STUB_DIR:$PATH" \
	"$HELPER" summary --since 24h --repo marcusquinn/aidevops --pr-check --json 2>&1)
RC=$?
assert_rc "7a: solved attribution query exits 0" 0 "$RC"
assert_eq "7b: solved worker issue count = 2" "2" \
	"$(printf '%s' "$JSON" | jq -r '.worker_solved_issues.count')"
assert_contains "7c: gh query uses solved:worker label" "label:solved:worker" \
	"$(<"$GH_CALL_LOG")"
if grep -q "label:origin:worker" "$GH_CALL_LOG" 2>/dev/null; then
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 7d: query must not use origin:worker"
else
	TESTS_RUN=$((TESTS_RUN + 1))
	echo "${TEST_GREEN}PASS${TEST_NC}: 7d: query does not use origin:worker"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo
echo "${TEST_BLUE}=== Summary ===${TEST_NC}"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
	echo "${TEST_GREEN}All tests passed.${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}$TESTS_FAILED test(s) failed.${TEST_NC}"
	exit 1
fi
