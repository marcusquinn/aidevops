#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2814 (Phase 3): launch_recovery:no_worker_process fixes.
#
# This test asserts the four fixes landed in t2814 are present and behave
# correctly. Without these regression assertions, a future refactor could
# silently re-introduce the diagnostic gap and the negative-cache miss that
# caused 109 affected issues / ~242 events in the 5-day t2812 window.
#
# Fixes covered:
#   1. pulse-cleanup.sh:_post_launch_recovery_claim_released — includes
#      worker-log tail in the CLAIM_RELEASED comment body.
#   2. pulse-dispatch-worker-launch.sh:_dlw_exec_detached — closes
#      inherited FDs 3-9 and forks a spawn-time exit monitor that writes
#      a `[t2814:early_exit]` marker on early death.
#   3. (same path) — FD-closure redirections present on both setsid and
#      fallback launch lines.
#   4. headless-runtime-lib.sh:_run_canary_test — short-circuits via
#      negative cache when canary-last-fail is fresh (< CANARY_NEGATIVE_TTL_SECONDS).
#
# Why this test is critical: the failure mode in question (no_worker_process)
# is INVISIBLE — workers exit before detection and leave no audit trail.
# The fixes plug the diagnostic gap. Without regression coverage, a
# silent revert would re-create the same invisible failure mode.
#
# Test strategy: structural (grep for the fix markers + behavioural
# assertions on isolated functions). The full dispatch pipeline depends
# on gh API + opencode runtime which cannot be exercised in CI without
# extensive mocking — see test-pulse-wrapper-canary.sh for the precedent
# that runs the wrapper end-to-end with --canary and a sandboxed HOME.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AGENT_SCRIPT_DIR="${SCRIPT_DIR}/.."
PULSE_CLEANUP="${AGENT_SCRIPT_DIR}/pulse-cleanup.sh"
WORKER_LAUNCH="${AGENT_SCRIPT_DIR}/pulse-dispatch-worker-launch.sh"
HEADLESS_LIB="${AGENT_SCRIPT_DIR}/headless-runtime-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

# ---------------------------------------------------------------------------
# Fix #1: CLAIM_RELEASED comment includes worker-log tail
# ---------------------------------------------------------------------------

# Static check: the helper reads the worker log path candidates.
#
# t2820 update: log-path enumeration was extracted from
# `_post_launch_recovery_claim_released` (pulse-cleanup.sh) into
# `_read_worker_log_tail_classified` (shared-claim-lifecycle.sh) so that the
# pulse-cleanup CLAIM_RELEASED comment AND the worker-lifecycle no_work
# reclassification (Phase 5) share one parser. Assert both: pulse-cleanup
# delegates to the shared helper, and the shared helper enumerates the
# canonical log paths.
test_claim_released_reads_log() {
	local shared_lifecycle="${AGENT_SCRIPT_DIR}/shared-claim-lifecycle.sh"
	# shellcheck disable=SC2016  # literal text in source — no expansion intended
	if grep -q '/tmp/pulse-\${safe_slug}-\${issue_number}.log' "$shared_lifecycle" \
		&& grep -q 'log_candidates=' "$shared_lifecycle" \
		&& grep -q '_read_worker_log_tail_classified' "$PULSE_CLEANUP"; then
		print_result "fix #1: _post_launch_recovery_claim_released enumerates worker-log paths" 0
		return 0
	fi
	print_result "fix #1: _post_launch_recovery_claim_released enumerates worker-log paths" 1 \
		"Expected shared helper in $shared_lifecycle and delegation from $PULSE_CLEANUP (t2820 extraction)"
	return 0
}

# Static check: tail is bounded so we cannot accidentally embed a 10MB
# stack trace into a GitHub comment.
#
# t2820 update: same extraction note — bounds now live in the shared helper.
test_claim_released_bounds_tail() {
	local shared_lifecycle="${AGENT_SCRIPT_DIR}/shared-claim-lifecycle.sh"
	# tail -20 lines AND head -c 4096 byte cap (may be on adjacent lines
	# joined with `|`, so use a windowed grep instead of a single-line regex).
	if grep -q 'tail -20' "$shared_lifecycle" \
		&& grep -q 'head -c 4096' "$shared_lifecycle"; then
		print_result "fix #1: log tail bounded to 20 lines / 4KB" 0
		return 0
	fi
	print_result "fix #1: log tail bounded to 20 lines / 4KB" 1 \
		"Expected 'tail -20' AND 'head -c 4096' in $shared_lifecycle (t2820 extraction) — \
without this, giant logs could be embedded in CLAIM_RELEASED comments and leak \
credentials or blow the GitHub 65535-byte body limit."
	return 0
}

# Behavioural check: source the cleanup script in a sandbox + stub `gh` so
# we can capture the CLAIM_RELEASED body. Verify it contains the log tail
# when a log file exists, and is NOT corrupted/blank when no log exists.
test_claim_released_includes_tail_behavioural() {
	local sandbox
	sandbox=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-t2814-test.XXXXXX")
	# shellcheck disable=SC2064  # capture sandbox now, expand at trap time
	trap "rm -rf '$sandbox' 2>/dev/null || true" RETURN

	# Mocked tmp log location (the helper checks /tmp/pulse-${safe_slug}-N.log).
	local fake_log="${sandbox}/fake-pulse.log"
	cat >"$fake_log" <<'EOF'
[2026-04-25T00:00:00Z] starting opencode run
[2026-04-25T00:00:01Z] AUTH_ERROR: token expired
[2026-04-25T00:00:01Z] canary returned 1, aborting
EOF

	# Stub gh: capture --field body to a file. The helper redirects stderr
	# to /dev/null so we use a side-channel file instead of stdout.
	mkdir -p "${sandbox}/bin"
	cat >"${sandbox}/bin/gh" <<EOF
#!/usr/bin/env bash
# stub: capture body for assertion
for arg in "\$@"; do
    case "\$arg" in
        body=*) printf '%s\n' "\${arg#body=}" >>"${sandbox}/captured-body.txt" ;;
    esac
done
exit 0
EOF
	chmod +x "${sandbox}/bin/gh"

	# Override the log candidates by monkey-patching: substitute /tmp with
	# the sandbox via a wrapper. Easier: extract the function definition
	# directly into a tiny harness shell that uses our sandbox path.
	#
	# The helper hard-codes /tmp paths; rather than patch them, we extract
	# the function and inline a sandbox version. This keeps the test
	# hermetic without requiring root or /tmp writes that linger.
	local harness="${sandbox}/harness.sh"
	cat >"$harness" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Inline the helper, but redirect the log_candidates to our fake log.
_post_launch_recovery_claim_released() {
    local issue_number="\$1"
    local repo_slug="\$2"
    local self_login="\$3"
    local failure_reason="\$4"

    local body
    body="CLAIM_RELEASED reason=launch_recovery:\${failure_reason} runner=\${self_login} ts=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local log_file log_tail
    local -a log_candidates=("${fake_log}")
    for log_file in "\${log_candidates[@]}"; do
        if [[ -f "\$log_file" ]] && [[ -s "\$log_file" ]]; then
            log_tail=\$(tail -20 "\$log_file" 2>/dev/null | head -c 4096 || true)
            if [[ -n "\$log_tail" ]]; then
                body="\${body}

<details>
<summary>worker log tail (last 20 lines, source: \${log_file})</summary>

\\\`\\\`\\\`text
\${log_tail}
\\\`\\\`\\\`

</details>"
            fi
            break
        fi
    done

    gh api "repos/\${repo_slug}/issues/\${issue_number}/comments" \\
        --method POST \\
        --field "body=\${body}" \\
        >/dev/null 2>&1 || true
    return 0
}

PATH="${sandbox}/bin:\$PATH" _post_launch_recovery_claim_released 999 "test/repo" "tester" "no_worker_process"
EOF
	chmod +x "$harness"
	bash "$harness" || true

	if [[ ! -f "${sandbox}/captured-body.txt" ]]; then
		print_result "fix #1: CLAIM_RELEASED body posted via gh api" 1 \
			"Expected stub gh to capture body — file not created. Harness output: $(cat "${sandbox}/captured-body.txt" 2>/dev/null || true)"
		return 0
	fi

	local captured
	captured=$(cat "${sandbox}/captured-body.txt")

	# Assert prefix + log tail present
	if [[ "$captured" == *"CLAIM_RELEASED reason=launch_recovery:no_worker_process"* ]] \
		&& [[ "$captured" == *"AUTH_ERROR: token expired"* ]] \
		&& [[ "$captured" == *"worker log tail"* ]]; then
		print_result "fix #1: CLAIM_RELEASED body contains failure reason + log tail" 0
	else
		print_result "fix #1: CLAIM_RELEASED body contains failure reason + log tail" 1 \
			"Captured body did not contain expected markers. Body: $captured"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Fix #2: spawn-time exit monitor
# ---------------------------------------------------------------------------

test_exit_monitor_function_present() {
	if grep -q '_dlw_spawn_early_exit_monitor()' "$WORKER_LAUNCH"; then
		print_result "fix #2: _dlw_spawn_early_exit_monitor() defined" 0
		return 0
	fi
	print_result "fix #2: _dlw_spawn_early_exit_monitor() defined" 1 \
		"Expected _dlw_spawn_early_exit_monitor() in $WORKER_LAUNCH"
	return 0
}

test_exit_monitor_called_after_launch() {
	# The monitor must be invoked from _dlw_exec_detached after worker_pid
	# is captured. Both invocations (setsid path and fallback path) feed
	# into the single trailing _dlw_spawn_early_exit_monitor call.
	# shellcheck disable=SC2016  # literal grep pattern — no expansion intended
	if grep -q 'worker_pid=$(_dlw_nohup_launch\|_dlw_spawn_early_exit_monitor "\$worker_pid"' "$WORKER_LAUNCH"; then
		print_result "fix #2: monitor invoked with worker_pid" 0
		return 0
	fi
	print_result "fix #2: monitor invoked with worker_pid" 1 \
		"Expected '_dlw_spawn_early_exit_monitor \"\$worker_pid\"' call in $WORKER_LAUNCH"
	return 0
}

# Behavioural: when invoked with a PID that exits immediately, the monitor
# writes the early_exit marker to the log within the polling window.
test_exit_monitor_writes_marker_behavioural() {
	local sandbox
	sandbox=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-t2814-test.XXXXXX")
	# shellcheck disable=SC2064
	trap "rm -rf '$sandbox' 2>/dev/null || true" RETURN

	local fake_log="${sandbox}/worker.log"
	: >"$fake_log"

	# Spawn a sleeper, then kill it immediately to simulate early exit.
	local victim_pid
	(sleep 30) &
	victim_pid="$!"
	# Kill before monitor starts polling — ensures early-exit branch fires
	kill "$victim_pid" 2>/dev/null || true
	wait "$victim_pid" 2>/dev/null || true

	# Inline the monitor body (matches the deployed implementation).
	# Use a 6s window with 2s poll for fast test execution.
	# shellcheck disable=SC2016
	bash -c '
		_dlw_monitor_body() {
			local pid="$1" log="$2" issue="$3" window="$4" interval="$5"
			local elapsed=0 ts=""
			while [[ "$elapsed" -lt "$window" ]]; do
				if ! kill -0 "$pid" 2>/dev/null; then
					ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
					printf "[t2814:early_exit] worker PID %s for issue #%s exited within %ss spawn window at %s\n" "$pid" "$issue" "$elapsed" "$ts" >>"$log" 2>/dev/null || true
					return 0
				fi
				sleep "$interval"
				elapsed=$((elapsed + interval))
			done
			return 0
		}
		_dlw_monitor_body "$@"
	' _dlw_monitor "$victim_pid" "$fake_log" "999" 6 2

	if grep -q '\[t2814:early_exit\]' "$fake_log"; then
		print_result "fix #2: monitor writes [t2814:early_exit] marker on early death" 0
	else
		print_result "fix #2: monitor writes [t2814:early_exit] marker on early death" 1 \
			"Expected marker in $fake_log. Contents: $(cat "$fake_log")"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Fix #3: FD closure on launch
# ---------------------------------------------------------------------------

test_fd_closure_setsid_path() {
	# Both the setsid path and the fallback nohup path must close FDs 3-9.
	# Match the redirection sequence — the exact line is:
	# `setsid nohup "$@" </dev/null >>"$worker_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &`
	if grep -E 'setsid nohup "\$@".*3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-' "$WORKER_LAUNCH" >/dev/null; then
		print_result "fix #3: setsid path closes FDs 3-9" 0
	else
		print_result "fix #3: setsid path closes FDs 3-9" 1 \
			"Expected '3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-' on the setsid launch line in $WORKER_LAUNCH"
	fi
	return 0
}

test_fd_closure_fallback_path() {
	# Fallback (no setsid) must also close FDs.
	# Look for a `nohup "$@"` line (NOT preceded by setsid) with the closure.
	if grep -E '^[[:space:]]*nohup "\$@".*3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-' "$WORKER_LAUNCH" >/dev/null; then
		print_result "fix #3: fallback nohup path closes FDs 3-9" 0
	else
		print_result "fix #3: fallback nohup path closes FDs 3-9" 1 \
			"Expected fallback nohup line with FD closures in $WORKER_LAUNCH"
	fi
	return 0
}

# Behavioural: launching with FD closures must not leak open FDs.
# We open extra FDs before launch and verify the child process does
# NOT see them.
test_fd_closure_behavioural() {
	# Skip on systems without /proc/<pid>/fd OR macOS-equivalent enumeration.
	# We test by passing a marker FD and asserting the child cannot read it.
	local sandbox
	sandbox=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-t2814-test.XXXXXX")
	# shellcheck disable=SC2064
	trap "rm -rf '$sandbox' 2>/dev/null || true" RETURN

	local marker_file="${sandbox}/parent-fd-marker.txt"
	echo "PARENT_HAD_FD_OPEN" >"$marker_file"

	local child_output="${sandbox}/child-output.txt"

	# Open FD 5 to the marker file in the parent shell, then launch a
	# child that tries to read FD 5. With the closure (5>&-), the child
	# read should fail.
	exec 5<"$marker_file"
	bash -c 'cat <&5 2>/dev/null || echo "FD_CLOSED"' </dev/null >"$child_output" 2>&1 5>&-
	exec 5<&-

	if grep -q 'FD_CLOSED' "$child_output"; then
		print_result "fix #3: child process cannot read FD 5 when closed via 5>&-" 0
	else
		print_result "fix #3: child process cannot read FD 5 when closed via 5>&-" 1 \
			"Expected child to report 'FD_CLOSED'. Got: $(cat "$child_output")"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Fix #4: negative canary cache
# ---------------------------------------------------------------------------

test_negative_cache_constant_present() {
	if grep -q 'CANARY_NEGATIVE_TTL_SECONDS' "$HEADLESS_LIB"; then
		print_result "fix #4: CANARY_NEGATIVE_TTL_SECONDS constant defined" 0
		return 0
	fi
	print_result "fix #4: CANARY_NEGATIVE_TTL_SECONDS constant defined" 1 \
		"Expected CANARY_NEGATIVE_TTL_SECONDS in $HEADLESS_LIB"
	return 0
}

test_negative_cache_short_circuit_present() {
	# Match the short-circuit branch: reads canary-last-fail, returns 1 fast.
	if grep -q 'canary-last-fail' "$HEADLESS_LIB" \
		&& grep -q 'Canary negative cache active' "$HEADLESS_LIB"; then
		print_result "fix #4: negative cache short-circuit branch present" 0
		return 0
	fi
	print_result "fix #4: negative cache short-circuit branch present" 1 \
		"Expected 'canary-last-fail' read + 'Canary negative cache active' message in $HEADLESS_LIB"
	return 0
}

test_negative_cache_writeback_present() {
	# On canary failure, the timestamp must be written to canary-last-fail.
	# On canary success, the file must be removed.
	local lib_text
	lib_text=$(cat "$HEADLESS_LIB")
	# Look for both the writeback (after FAIL log) and the cleanup-on-success
	# shellcheck disable=SC2016  # matching literal source text — no expansion intended
	if [[ "$lib_text" == *'date +%s >"$fail_cache_file"'* ]] \
		&& [[ "$lib_text" == *'rm -f "$fail_cache_file"'* ]]; then
		print_result "fix #4: success clears + failure stamps the negative cache" 0
		return 0
	fi
	print_result "fix #4: success clears + failure stamps the negative cache" 1 \
		"Expected both 'date +%s >\"\$fail_cache_file\"' (failure) and 'rm -f \"\$fail_cache_file\"' (success) in $HEADLESS_LIB"
	return 0
}

# Behavioural: extract the negative-cache check logic and verify it
# returns fast when the fail file is fresh.
test_negative_cache_behavioural() {
	local sandbox
	sandbox=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-t2814-test.XXXXXX")
	# shellcheck disable=SC2064
	trap "rm -rf '$sandbox' 2>/dev/null || true" RETURN

	local fail_cache="${sandbox}/canary-last-fail"
	# Stamp 5 seconds ago (well within default 90s TTL).
	local now stamp
	now=$(date +%s)
	stamp=$((now - 5))
	echo "$stamp" >"$fail_cache"

	# Inline check matching the deployed branch.
	local result=""
	local CANARY_NEGATIVE_TTL_SECONDS=90
	if [[ -f "$fail_cache" ]]; then
		local last_fail neg_now neg_age
		last_fail=$(cat "$fail_cache" 2>/dev/null || echo "0")
		neg_now=$(date +%s)
		neg_age=$((neg_now - last_fail))
		if [[ "$last_fail" =~ ^[0-9]+$ ]] && [[ "$neg_age" -ge 0 ]] && [[ "$neg_age" -lt "$CANARY_NEGATIVE_TTL_SECONDS" ]]; then
			result="SHORT_CIRCUIT_FIRED"
		fi
	fi

	if [[ "$result" == "SHORT_CIRCUIT_FIRED" ]]; then
		print_result "fix #4: fresh fail cache (age=5s, ttl=90s) triggers short-circuit" 0
	else
		print_result "fix #4: fresh fail cache (age=5s, ttl=90s) triggers short-circuit" 1 \
			"Expected SHORT_CIRCUIT_FIRED, got: '$result'"
	fi

	# Now verify expired cache does NOT short-circuit.
	stamp=$((now - 200)) # 200s old > 90s TTL
	echo "$stamp" >"$fail_cache"
	result=""
	if [[ -f "$fail_cache" ]]; then
		local last_fail neg_now neg_age
		last_fail=$(cat "$fail_cache" 2>/dev/null || echo "0")
		neg_now=$(date +%s)
		neg_age=$((neg_now - last_fail))
		if [[ "$last_fail" =~ ^[0-9]+$ ]] && [[ "$neg_age" -ge 0 ]] && [[ "$neg_age" -lt "$CANARY_NEGATIVE_TTL_SECONDS" ]]; then
			result="SHORT_CIRCUIT_FIRED"
		fi
	fi

	if [[ "$result" != "SHORT_CIRCUIT_FIRED" ]]; then
		print_result "fix #4: stale fail cache (age=200s, ttl=90s) does NOT short-circuit" 0
	else
		print_result "fix #4: stale fail cache (age=200s, ttl=90s) does NOT short-circuit" 1 \
			"Expected no short-circuit, got: '$result'"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Failure-mode invariant: the dispatch path must not silently classify
# infrastructure failures as worker coding failures (overlaps with Phase 4
# but the assertion belongs here too — once it lands, Phase 4 can extend).
# ---------------------------------------------------------------------------

test_failure_classification_distinct() {
	# `recover_failed_launch_state` must be called with a failure_reason
	# argument distinct from generic worker-failure paths. Specifically:
	# - "no_worker_process" — never spawned (infra)
	# - "cli_usage_output" — spawned but invoked wrong (config bug)
	# These are wired in pulse-dispatch-engine.sh check_worker_launch.
	local engine="${AGENT_SCRIPT_DIR}/pulse-dispatch-engine.sh"
	if grep -q '"no_worker_process"' "$engine" \
		&& grep -q '"cli_usage_output"' "$engine"; then
		print_result "invariant: launch failures classified distinctly (no_worker_process vs cli_usage_output)" 0
		return 0
	fi
	print_result "invariant: launch failures classified distinctly (no_worker_process vs cli_usage_output)" 1 \
		"Expected both 'no_worker_process' and 'cli_usage_output' classifications in $engine"
	return 0
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------

main_test() {
	# Verify the target files exist before running tests
	local f
	for f in "$PULSE_CLEANUP" "$WORKER_LAUNCH" "$HEADLESS_LIB"; do
		if [[ ! -f "$f" ]]; then
			printf 'FATAL: target file missing: %s\n' "$f" >&2
			return 2
		fi
	done

	# Fix 1
	test_claim_released_reads_log
	test_claim_released_bounds_tail
	test_claim_released_includes_tail_behavioural

	# Fix 2
	test_exit_monitor_function_present
	test_exit_monitor_called_after_launch
	test_exit_monitor_writes_marker_behavioural

	# Fix 3
	test_fd_closure_setsid_path
	test_fd_closure_fallback_path
	test_fd_closure_behavioural

	# Fix 4
	test_negative_cache_constant_present
	test_negative_cache_short_circuit_present
	test_negative_cache_writeback_present
	test_negative_cache_behavioural

	# Cross-cutting invariant
	test_failure_classification_distinct

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
