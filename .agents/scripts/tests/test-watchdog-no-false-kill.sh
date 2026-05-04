#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-watchdog-no-false-kill.sh — Regression tests for t3056 / GH#21781
# (94% headless worker kill rate investigation).
#
# Verifies:
#   1. _watchdog_tree_cpu function exists in worker-activity-watchdog.sh
#   2. STALL_TIMEOUT default is 600s (raised from 300s)
#   3. Structured [lifecycle] worker_killed lines are emitted by _kill_worker
#   4. CPU semantic check defers kill when tree_cpu >= STALL_CPU_THRESHOLD
#   5. Hard-kill fires regardless of CPU (safety net)
#   6. pulse-watchdog.sh kill sites emit [lifecycle] lines
#   7. pulse-dispatch-engine.sh timeout handler emits [lifecycle] line
#   8. worker-watchdog.sh does not auto-kill quiet long-running workers
#   9. All modified scripts pass ShellCheck
#
# Tests are structural — no live worker processes required.

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
		echo "  in output starting with: $(printf '%.200s' "$haystack")"
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
	fi
	return 0
}

assert_equals() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

assert_match() {
	local label="$1" pattern="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qE -- "$pattern" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in output starting with: $(printf '%.200s' "$haystack")"
	fi
	return 0
}

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "${TEST_BLUE}=== t3056: Watchdog No-False-Kill Regression Tests ===${TEST_NC}"
echo ""

#######################################
# Test 1: _watchdog_tree_cpu function exists
#######################################
watchdog_source=$(< "${SCRIPT_DIR}/worker-activity-watchdog.sh")
worker_watchdog_source=$(< "${SCRIPT_DIR}/worker-watchdog.sh")
worker_watchdog_cmd_source=$(< "${SCRIPT_DIR}/worker-watchdog-cmd.sh")
assert_contains \
	"1. _watchdog_tree_cpu function exists in worker-activity-watchdog.sh" \
	"_watchdog_tree_cpu()" \
	"$watchdog_source"

#######################################
# Test 2: STALL_TIMEOUT default raised from 300 to 600
#######################################
# shellcheck disable=SC2016  # Literal string for grep match — not variable expansion
assert_contains \
	"2. STALL_TIMEOUT default is 600s (raised from 300)" \
	'STALL_TIMEOUT="${WORKER_STALL_TIMEOUT:-600}"' \
	"$watchdog_source"

#######################################
# Test 3: [lifecycle] worker_killed line in _kill_worker
#######################################
assert_contains \
	"3. _kill_worker emits [lifecycle] worker_killed structured line" \
	"[lifecycle] worker_killed pid=" \
	"$watchdog_source"

#######################################
# Test 4: CPU semantic check exists (STALL_CPU_THRESHOLD)
#######################################
# shellcheck disable=SC2016  # Literal string for grep match
assert_contains \
	"4a. STALL_CPU_THRESHOLD config variable exists" \
	'STALL_CPU_THRESHOLD="${WORKER_STALL_CPU_THRESHOLD:-2}"' \
	"$watchdog_source"
assert_contains \
	"4b. CPU check defers kill (worker_stall_deferred lifecycle marker)" \
	"worker_stall_deferred" \
	"$watchdog_source"

#######################################
# Test 5: Hard-kill fires regardless of CPU
# (The hard-kill block must come BEFORE the CPU check in the code)
#######################################
# Verify hard-kill check comes before CPU check by checking line order
hard_kill_line=$(grep -n "HARD_KILL_SECONDS.*elapsed_total.*HARD_KILL_SECONDS" "${SCRIPT_DIR}/worker-activity-watchdog.sh" | head -1 | cut -d: -f1)
cpu_check_line=$(grep -n "_watchdog_tree_cpu.*WORKER_PID" "${SCRIPT_DIR}/worker-activity-watchdog.sh" | head -1 | cut -d: -f1)
if [[ -n "$hard_kill_line" && -n "$cpu_check_line" && "$hard_kill_line" -lt "$cpu_check_line" ]]; then
	TESTS_RUN=$((TESTS_RUN + 1))
	echo "${TEST_GREEN}PASS${TEST_NC}: 5. Hard-kill check precedes CPU check (line $hard_kill_line < $cpu_check_line)"
else
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5. Hard-kill check must precede CPU check (hard_kill=$hard_kill_line, cpu=$cpu_check_line)"
fi

#######################################
# Test 6: pulse-watchdog.sh kill sites emit [lifecycle] lines
#######################################
pulse_wd_source=$(< "${SCRIPT_DIR}/pulse-watchdog.sh")
assert_contains \
	"6a. pulse-watchdog.sh guard_child_processes emits [lifecycle] line" \
	"reason=process_guard_" \
	"$pulse_wd_source"
assert_contains \
	"6b. pulse-watchdog.sh run_stage_with_timeout emits [lifecycle] line" \
	"reason=stage_timeout_" \
	"$pulse_wd_source"
assert_contains \
	"6c. pulse-watchdog.sh _run_pulse_watchdog emits [lifecycle] line" \
	"_pw_reason_class" \
	"$pulse_wd_source"

#######################################
# Test 7: pulse-dispatch-lib.sh timeout handler emits [lifecycle] line
#######################################
dispatch_source=$(< "${SCRIPT_DIR}/pulse-dispatch-lib.sh")
assert_contains \
	"7. pulse-dispatch-lib.sh per-candidate timeout emits [lifecycle] line" \
	"reason=wait_loop_timeout_" \
	"$dispatch_source"

#######################################
# Test 8: legacy worker watchdog quiet signals are advisory only
#######################################
assert_contains \
	"8a. worker-watchdog runtime cap disabled by default" \
	'WORKER_MAX_RUNTIME="${WORKER_MAX_RUNTIME:-0}"' \
	"$worker_watchdog_source"
assert_contains \
	"8b. worker-watchdog emits idle advisory instead of kill" \
	"IDLE ADVISORY" \
	"$worker_watchdog_cmd_source"
assert_not_contains \
	"8c. worker-watchdog no longer kills on idle" \
	'kill_worker "$pid" "idle"' \
	"$worker_watchdog_cmd_source"
assert_not_contains \
	"8d. worker-watchdog no longer kills on stall" \
	'kill_worker "$pid" "stall"' \
	"$worker_watchdog_cmd_source"
assert_not_contains \
	"8e. worker-watchdog no longer kills on runtime" \
	'kill_worker "$pid" "runtime"' \
	"$worker_watchdog_cmd_source"

#######################################
# Test 9: All modified scripts pass ShellCheck
#######################################
echo ""
echo "${TEST_BLUE}--- ShellCheck validation ---${TEST_NC}"

shellcheck_pass=true
for script in \
	"${SCRIPT_DIR}/worker-activity-watchdog.sh" \
	"${SCRIPT_DIR}/worker-watchdog.sh" \
	"${SCRIPT_DIR}/worker-watchdog-cmd.sh" \
	"${SCRIPT_DIR}/pulse-watchdog.sh" \
	"${SCRIPT_DIR}/pulse-dispatch-lib.sh"; do

	local_name="$(basename "$script")"
	if command -v shellcheck >/dev/null 2>&1; then
		sc_out=$(shellcheck -S error "$script" 2>&1) || true
		if [[ -n "$sc_out" ]]; then
			TESTS_RUN=$((TESTS_RUN + 1))
			TESTS_FAILED=$((TESTS_FAILED + 1))
			echo "${TEST_RED}FAIL${TEST_NC}: 9. ShellCheck ${local_name}"
			echo "  $sc_out"
			shellcheck_pass=false
		else
			TESTS_RUN=$((TESTS_RUN + 1))
			echo "${TEST_GREEN}PASS${TEST_NC}: 9. ShellCheck ${local_name}"
		fi
	else
		TESTS_RUN=$((TESTS_RUN + 1))
		echo "${TEST_GREEN}PASS${TEST_NC}: 9. ShellCheck ${local_name} (skipped — shellcheck not installed)"
	fi
done

#######################################
# Test 9: kill_reason classification covers all call sites
#######################################
# Verify that each kill reason class is mapped in _kill_worker
assert_contains \
	"9a. kill_reason class: phase1_zero_output mapped" \
	"phase1_zero_output" \
	"$watchdog_source"
assert_contains \
	"9b. kill_reason class: hard_kill_stall mapped" \
	"hard_kill_stall" \
	"$watchdog_source"
assert_contains \
	"9c. kill_reason class: no_output_stall mapped" \
	"no_output_stall" \
	"$watchdog_source"
assert_contains \
	"9d. kill_reason class: provider_rate_limit mapped" \
	"provider_rate_limit" \
	"$watchdog_source"

#######################################
# Test 10: Lifecycle log path is configurable via env
#######################################
# shellcheck disable=SC2016  # Literal string for grep match
assert_contains \
	"10. LIFECYCLE_LOG configurable via WORKER_LIFECYCLE_LOG env" \
	'LIFECYCLE_LOG="${WORKER_LIFECYCLE_LOG:-' \
	"$watchdog_source"

#######################################
# Test 11: _watchdog_tree_cpu validates PID input
#######################################
# shellcheck disable=SC2016  # Literal string for grep match
assert_contains \
	"11. _watchdog_tree_cpu validates PID is numeric" \
	'[[ "$pid" =~ ^[0-9]+$ ]]' \
	"$watchdog_source"

#######################################
# Test 12: Deferred stall seconds tracked cumulatively
#######################################
assert_contains \
	"12. Deferred stall seconds tracked cumulatively" \
	"deferred_stall_seconds=\$((deferred_stall_seconds + stall_seconds))" \
	"$watchdog_source"
assert_contains \
	"12b. CPU-active defers are labeled distinctly" \
	"reason=cpu_active" \
	"$watchdog_source"
assert_contains \
	"12c. CI-wait defers are labeled distinctly" \
	"reason=ci_wait" \
	"$watchdog_source"
assert_contains \
	"12d. Output-active path is documented as live work" \
	"output-active" \
	"$watchdog_source"

#######################################
# Test 13: pulse-watchdog reason class mapping is complete
#######################################
assert_contains \
	"13a. pulse-watchdog maps wall_clock_stale" \
	"wall_clock_stale" \
	"$pulse_wd_source"
assert_contains \
	"13b. pulse-watchdog maps cold_start_timeout" \
	"cold_start_timeout" \
	"$pulse_wd_source"
assert_contains \
	"13c. pulse-watchdog maps progress_timeout" \
	"progress_timeout" \
	"$pulse_wd_source"
assert_contains \
	"13d. pulse-watchdog maps idle_timeout" \
	"idle_timeout" \
	"$pulse_wd_source"
assert_contains \
	"13e. pulse-watchdog maps stop_flag" \
	"stop_flag" \
	"$pulse_wd_source"

#######################################
# Tests 14-17: t3057 / GH#21785 — interval-sampled CPU (false-defer fix)
#
# Verify that _watchdog_tree_cpu uses two-sample ps -o time= delta instead
# of lifetime-average ps -o %cpu=. A frozen worker that was hot historically
# must be detected within STALL_TIMEOUT, not allowed to survive to HARD_KILL.
#######################################
assert_contains \
	"14. _parse_ps_cpu_time helper exists (t3057)" \
	"_parse_ps_cpu_time()" \
	"$watchdog_source"

assert_contains \
	"15. _watchdog_tree_cpu uses ps -o time= (interval sampling, t3057)" \
	"ps -p" \
	"$watchdog_source"

assert_not_contains \
	"15b. _watchdog_tree_cpu does NOT use ps -o %cpu= (lifetime avg removed, t3057)" \
	"ps -p \"\$pid\" -o %cpu=" \
	"$watchdog_source"

assert_contains \
	"16. _watchdog_tree_cpu sleeps for sample interval (t3057)" \
	"sleep \"\$sample_interval\"" \
	"$watchdog_source"

assert_contains \
	"17. _watchdog_tree_cpu calls _parse_ps_cpu_time (t3057)" \
	"_parse_ps_cpu_time" \
	"$watchdog_source"

#######################################
# Test 18: t3060 / GH#21788 — enum-prefix kill_reason coupling
#######################################
# The classifier in _run_pulse_watchdog extracts via ${kill_reason%%:*} and
# matches against UPPERCASE enum literals. Setter sites must emit a matching
# enum prefix or the classifier silently falls back to pulse_unknown. These
# assertions pin the contract: setter prefix ↔ classifier enum case.

# 18a-18e: Each setter site emits its enum prefix. Match the WD_KILL_REASON
# assignment with the prefix attached so a future refactor that drops the
# prefix is caught immediately.
# shellcheck disable=SC2016  # Literal string for grep match — not variable expansion
assert_contains \
	"18a. WALL_CLOCK_STALE setter has enum prefix" \
	'WD_KILL_REASON="WALL_CLOCK_STALE:' \
	"$pulse_wd_source"
# shellcheck disable=SC2016
assert_contains \
	"18b. COLD_START_TIMEOUT setter has enum prefix" \
	'WD_KILL_REASON="COLD_START_TIMEOUT:' \
	"$pulse_wd_source"
# shellcheck disable=SC2016
assert_contains \
	"18c. PROGRESS_TIMEOUT setter has enum prefix" \
	'WD_KILL_REASON="PROGRESS_TIMEOUT:' \
	"$pulse_wd_source"
# shellcheck disable=SC2016
assert_contains \
	"18d. IDLE_TIMEOUT setter has enum prefix" \
	'WD_KILL_REASON="IDLE_TIMEOUT:' \
	"$pulse_wd_source"
# shellcheck disable=SC2016
assert_contains \
	"18e. STOP_FLAG setter has enum prefix" \
	'WD_KILL_REASON="STOP_FLAG:' \
	"$pulse_wd_source"

# 18f: Classifier extracts via ${kill_reason%%:*} (deterministic) — not via
# prose substring matching that drifts when the message is reworded.
# shellcheck disable=SC2016
assert_contains \
	"18f. Classifier extracts enum prefix via parameter expansion" \
	'_pw_reason_prefix="${kill_reason%%:*}"' \
	"$pulse_wd_source"

# 18g: Classifier dispatches on the prefix variable, not on the full
# kill_reason string. This is the structural anti-regression check —
# `case "$_pw_reason_prefix" in` proves the prose-substring classifier
# is gone.
# shellcheck disable=SC2016
assert_contains \
	"18g. Classifier case dispatches on prefix variable" \
	'case "$_pw_reason_prefix" in' \
	"$pulse_wd_source"

# 18h-18i: The pre-t3060 prose-substring patterns must NOT reappear in the
# classifier. If a future refactor reverts to "*"stale threshold"*) ..."
# the coupling breaks again. Pin negation.
assert_not_contains \
	"18h. Prose-substring classifier 'stale threshold' is gone" \
	'*"stale threshold"*) _pw_reason_class=' \
	"$pulse_wd_source"
assert_not_contains \
	"18i. Prose-substring classifier 'cold-start stalled' is gone" \
	'*"cold-start stalled"*) _pw_reason_class=' \
	"$pulse_wd_source"

# 18j: pulse_unknown remains as the defensive default — a setter added
# without its enum mapping must surface as pulse_unknown, not a wrong
# class. This catches the failure mode where a developer adds a 6th
# kill site but forgets to extend the case statement.
# shellcheck disable=SC2016
assert_contains \
	"18j. pulse_unknown default preserved as classifier safety net" \
	'_pw_reason_class="pulse_unknown"' \
	"$pulse_wd_source"

#######################################
# Tests 19-22: t3059 / GH#21787 — _watchdog_tree_cpu walks full descendant tree (BFS)
#
# Earlier implementation used `pgrep -P "$root_pid"` (one level only),
# undercounting CPU on deeper trees like `bash → opencode → node → LSP`.
# These assertions pin the BFS contract: a shared _get_descendant_pids
# helper lives in worker-lifecycle-common.sh, the watchdog sources it,
# and a runtime spawn proves grandchildren are visited. The interval-CPU
# sampling (t3057) is preserved — t3059 only changes which PIDs are sampled.
#######################################
lifecycle_source=$(< "${SCRIPT_DIR}/worker-lifecycle-common.sh")
assert_contains \
	"19. _get_descendant_pids defined in worker-lifecycle-common.sh (t3059)" \
	"_get_descendant_pids()" \
	"$lifecycle_source"

assert_contains \
	"20. _watchdog_tree_cpu calls _get_descendant_pids (BFS, not pgrep -P) (t3059)" \
	"_get_descendant_pids" \
	"$watchdog_source"

assert_contains \
	"21. worker-activity-watchdog.sh sources worker-lifecycle-common.sh (t3059)" \
	"worker-lifecycle-common.sh" \
	"$watchdog_source"

#######################################
# Test 22: Runtime — _get_descendant_pids returns >=2 PIDs for a 3-level tree
#######################################
# Source the lifecycle helpers in this test shell.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

# Spawn parent_bash → middle_bash → sleep (grandchild). The trailing
# `; :` in the inner command prevents bash's tail-call exec optimization
# (otherwise middle_bash would execve into sleep and the tree would
# collapse to two levels). 30s sleep gives a stable tree; cleanup
# below kills it deterministically.
bash -c 'bash -c "sleep 30; :" & wait' >/dev/null 2>&1 &
test_root_pid=$!
sleep 1 # let fork+exec settle so pgrep sees the children

descendants=$(_get_descendant_pids "$test_root_pid" 2>/dev/null || true)
descendant_count=$(echo "$descendants" | grep -c '^[0-9]\+$' 2>/dev/null || true)
[[ "$descendant_count" =~ ^[0-9]+$ ]] || descendant_count=0

if [[ "$descendant_count" -ge 2 ]]; then
	TESTS_RUN=$((TESTS_RUN + 1))
	echo "${TEST_GREEN}PASS${TEST_NC}: 22. _get_descendant_pids walks BFS (descendants=$descendant_count, expected >=2 for parent->child->grandchild) (t3059)"
else
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 22. _get_descendant_pids returned $descendant_count descendants, expected >=2 for 3-level tree (t3059)"
fi

# Cleanup the spawned tree
for cleanup_pid in $descendants "$test_root_pid"; do
	kill "$cleanup_pid" 2>/dev/null || true
done
wait 2>/dev/null || true

#######################################
# Test 23: Runtime — CI-wait quiet worker survives beyond stall timeout
#######################################
tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t watchdog-live)
live_output="${tmp_dir}/worker.out"
live_exit="${tmp_dir}/worker.exit"
live_log="${tmp_dir}/lifecycle.log"
printf 'waiting for CI checks to finish before merge\n' >"$live_output"

bash -c 'while :; do sleep 1; done' >/dev/null 2>&1 &
live_worker_pid=$!
WORKER_LIFECYCLE_LOG="$live_log" \
	"${SCRIPT_DIR}/worker-activity-watchdog.sh" \
	--output-file "$live_output" \
	--worker-pid "$live_worker_pid" \
	--exit-code-file "$live_exit" \
	--stall-timeout 1 \
	--poll-interval 1 \
	--hard-kill-seconds 0 >/dev/null 2>&1 &
live_watchdog_pid=$!

sleep 8
if kill -0 "$live_worker_pid" 2>/dev/null && [[ ! -f "${live_exit}.watchdog_killed" ]]; then
	TESTS_RUN=$((TESTS_RUN + 1))
	echo "${TEST_GREEN}PASS${TEST_NC}: 23. CI-wait quiet worker survives beyond stall timeout (long-but-live path)"
else
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 23. CI-wait quiet worker was killed despite live-work evidence"
fi

pkill -P "$live_worker_pid" 2>/dev/null || true
kill "$live_worker_pid" "$live_watchdog_pid" 2>/dev/null || true
wait "$live_worker_pid" 2>/dev/null || true
wait "$live_watchdog_pid" 2>/dev/null || true
rm -rf "$tmp_dir"

#######################################
# Summary
#######################################
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ===${TEST_NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
