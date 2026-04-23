#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-consolidation-phase2.sh — regression tests for t2749
#
# Covers the Phase 2 fill-floor pass that dispatches consolidation-task
# children in the same pulse cycle as their creation.
#
# The bug: newly-created consolidation children were invisible to the
# fill-floor loop because candidate enumeration ran BEFORE the loop,
# forcing children to wait a minimum of one additional pulse cycle
# (3–7 min stable; 10–20 min with unstable wrapper cycles).
#
# Fix: after Phase 1 completes, check for the per-cycle sentinel file
# (pulse-cycle-$$-consolidation-fired). If it exists, consume it and
# re-run dispatch_deterministic_fill_floor (Phase 2) when slots are
# available.
#
# Test strategy:
#   1. Source pulse-dispatch-engine.sh with stub overrides for the
#      external functions it calls.
#   2. Track dispatch_deterministic_fill_floor call count via a counter
#      file (required because the function runs inside $(...) subshells
#      where variable mutations are lost in the parent).
#   3. Verify sentinel file mechanics: created → Phase 2 fires → consumed.
#   4. Verify Phase 2 is skipped when no sentinel or slots full.
#   5. Source pulse-triage.sh with lock stubs to verify sentinel write.
#   6. Verify cycle-start glob cleanup of stale sentinels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LOGFILE=""

# ---------------------------------------------------------------------------
# Test harness helpers
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

# ---------------------------------------------------------------------------
# File-based dispatch counter
#
# dispatch_deterministic_fill_floor runs inside $(...) command substitution
# which creates a subshell. Variable mutations in a subshell are lost when
# the subshell exits. Use a counter file so the parent shell can read the
# updated count after the subshell returns.
# ---------------------------------------------------------------------------
_DISPATCH_COUNT_FILE=""

_init_dispatch_counter() {
	_DISPATCH_COUNT_FILE="${TEST_ROOT}/dispatch-count.txt"
	echo "0" >"$_DISPATCH_COUNT_FILE"
	return 0
}

_read_dispatch_count() {
	cat "$_DISPATCH_COUNT_FILE" 2>/dev/null || echo "0"
	return 0
}

# ---------------------------------------------------------------------------
# Environment setup / teardown
# ---------------------------------------------------------------------------

setup_test_env() {
	TEST_ROOT=$(mktemp -d -t t2749-phase2.XXXXXX)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${HOME}/.aidevops/logs"

	LOGFILE="${TEST_ROOT}/pulse.log"
	export LOGFILE
	: >"$LOGFILE"

	# STOP_FLAG must NOT exist by default.
	export STOP_FLAG="${TEST_ROOT}/stop.flag"
	[[ -f "$STOP_FLAG" ]] && rm -f "$STOP_FLAG"

	_init_dispatch_counter

	# Stubs: defined BEFORE sourcing so the module load does not fail on
	# missing external symbols. The module's own definitions overwrite
	# these during source; we re-declare them AFTER source to win back.

	dispatch_deterministic_fill_floor() {
		local c; c=$(cat "$_DISPATCH_COUNT_FILE" 2>/dev/null || echo 0)
		echo "$((c + 1))" >"$_DISPATCH_COUNT_FILE"
		printf '0\n'
		return 0
	}
	count_active_workers() { printf '%s\n' "${_STUB_ACTIVE_WORKERS:-0}"; return 0; }
	get_max_workers_target() { printf '%s\n' "${_STUB_MAX_WORKERS:-3}"; return 0; }
	_adaptive_launch_settle_wait() { return 0; }
	pulse_dispatch_debug_log() { return 0; }

	# Prevent loading the rate-limit circuit breaker (it has its own deps).
	export _PULSE_RATE_LIMIT_CB_LOADED=1

	# Clear the engine load guard so the module re-evaluates on source.
	unset _PULSE_DISPATCH_ENGINE_LOADED

	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-dispatch-engine.sh" || {
		printf 'ERROR: failed to source pulse-dispatch-engine.sh\n' >&2
		return 1
	}

	# Re-declare stubs AFTER source to override the module's definitions.
	dispatch_deterministic_fill_floor() {
		local c; c=$(cat "$_DISPATCH_COUNT_FILE" 2>/dev/null || echo 0)
		echo "$((c + 1))" >"$_DISPATCH_COUNT_FILE"
		printf '0\n'
		return 0
	}
	count_active_workers() { printf '%s\n' "${_STUB_ACTIVE_WORKERS:-0}"; return 0; }
	get_max_workers_target() { printf '%s\n' "${_STUB_MAX_WORKERS:-3}"; return 0; }
	_adaptive_launch_settle_wait() { return 0; }

	_STUB_ACTIVE_WORKERS=0
	_STUB_MAX_WORKERS=3

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	LOGFILE=""
	_DISPATCH_COUNT_FILE=""
	unset _PULSE_DISPATCH_ENGINE_LOADED _PULSE_RATE_LIMIT_CB_LOADED
	unset _STUB_ACTIVE_WORKERS _STUB_MAX_WORKERS
	return 0
}

# Sentinel path: mirrors the formula in pulse-dispatch-engine.sh.
_sentinel_path() {
	printf '%s/.aidevops/cache/pulse-cycle-%s-consolidation-fired\n' \
		"$HOME" "$$"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: sentinel exists + worker slots available → Phase 2 fires
# ---------------------------------------------------------------------------

test_phase2_fires_when_sentinel_and_slots_available() {
	setup_test_env
	_STUB_ACTIVE_WORKERS=0
	_STUB_MAX_WORKERS=3

	# Simulate consolidation fired: create the sentinel.
	touch "$(_sentinel_path)"

	_init_dispatch_counter
	apply_deterministic_fill_floor
	local count; count=$(_read_dispatch_count)

	local sentinel_after; sentinel_after="$(_sentinel_path)"
	local failures=0 failmsg=""

	# Phase 1 + Phase 2 = dispatch called twice.
	if [[ "$count" -ne 2 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch called ${count} times (expected 2)"
	fi

	# Sentinel must be consumed.
	if [[ -f "$sentinel_after" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sentinel not removed after Phase 2"
	fi

	# Phase 2 log line must appear.
	if ! grep -q "fill floor Phase 2.*re-enumerating" "$LOGFILE" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | Phase 2 log line not found"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: Phase 2 fires when sentinel exists and slots available" 0
	else
		print_result "t2749: Phase 2 fires when sentinel exists and slots available" 1 "$failmsg"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: no sentinel → Phase 2 does NOT fire
# ---------------------------------------------------------------------------

test_phase2_skipped_when_no_sentinel() {
	setup_test_env
	_STUB_ACTIVE_WORKERS=0
	_STUB_MAX_WORKERS=3
	# No sentinel created.

	_init_dispatch_counter
	apply_deterministic_fill_floor
	local count; count=$(_read_dispatch_count)

	local failures=0 failmsg=""

	# Only Phase 1 should dispatch.
	if [[ "$count" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch called ${count} times (expected 1)"
	fi

	# No Phase 2 log line.
	if grep -q "fill floor Phase 2" "$LOGFILE" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | unexpected Phase 2 log line found"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: Phase 2 skipped when no sentinel" 0
	else
		print_result "t2749: Phase 2 skipped when no sentinel" 1 "$failmsg"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: sentinel exists but all slots occupied → Phase 2 skipped
# ---------------------------------------------------------------------------

test_phase2_skipped_when_slots_full() {
	setup_test_env
	_STUB_ACTIVE_WORKERS=3
	_STUB_MAX_WORKERS=3

	touch "$(_sentinel_path)"

	_init_dispatch_counter
	apply_deterministic_fill_floor
	local count; count=$(_read_dispatch_count)

	local sentinel_after; sentinel_after="$(_sentinel_path)"
	local failures=0 failmsg=""

	# Sentinel consumed even when Phase 2 is skipped (prevents triggering
	# Phase 2 a second time if apply_deterministic_fill_floor is called again
	# in the same cycle: early-dispatch pass + main fill floor both call it).
	if [[ -f "$sentinel_after" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sentinel not consumed despite slot check"
	fi

	# Only Phase 1 dispatched.
	if [[ "$count" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch called ${count} times (expected 1)"
	fi

	# Slots-full skip log line.
	if ! grep -q "Phase 2.*slots full" "$LOGFILE" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | 'Phase 2.*slots full' log line not found"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: Phase 2 skipped (sentinel consumed) when slots full" 0
	else
		print_result "t2749: Phase 2 skipped (sentinel consumed) when slots full" 1 "$failmsg"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: sentinel consumed on first call — second call does NOT re-trigger
# ---------------------------------------------------------------------------

test_sentinel_consumed_prevents_double_phase2() {
	setup_test_env
	_STUB_ACTIVE_WORKERS=0
	_STUB_MAX_WORKERS=3

	touch "$(_sentinel_path)"

	_init_dispatch_counter

	# First call: Phase 1 + Phase 2 (sentinel consumed).
	apply_deterministic_fill_floor
	local count_after_first; count_after_first=$(_read_dispatch_count)

	# Second call: sentinel gone → Phase 1 only.
	apply_deterministic_fill_floor
	local count_after_second; count_after_second=$(_read_dispatch_count)

	local failures=0 failmsg=""
	local delta=$((count_after_second - count_after_first))

	if [[ "$count_after_first" -ne 2 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | first call: count=${count_after_first} (expected 2)"
	fi

	if [[ "$delta" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | second call: delta=${delta} (expected 1, no Phase 2)"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: sentinel consumed — second call skips Phase 2" 0
	else
		print_result "t2749: sentinel consumed — second call skips Phase 2" 1 "$failmsg"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: stop flag prevents entire function (Phase 1 + Phase 2 skipped)
# ---------------------------------------------------------------------------

test_stop_flag_skips_entire_fill_floor() {
	setup_test_env
	_STUB_ACTIVE_WORKERS=0
	_STUB_MAX_WORKERS=3

	touch "$(_sentinel_path)"
	touch "$STOP_FLAG"  # Set stop flag.

	_init_dispatch_counter
	apply_deterministic_fill_floor
	local count; count=$(_read_dispatch_count)

	local failures=0 failmsg=""

	# Stop flag short-circuits before Phase 1 — dispatch count must be 0.
	if [[ "$count" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch called ${count} times despite stop flag (expected 0)"
	fi

	rm -f "$STOP_FLAG"

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: stop flag skips entire fill floor (Phase 1 + Phase 2)" 0
	else
		print_result "t2749: stop flag skips entire fill floor (Phase 1 + Phase 2)" 1 "$failmsg"
	fi

	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: stale sentinel glob cleanup (pulse-wrapper.sh cycle-start defence)
#
# The cycle-start cleanup in main() removes ALL
# pulse-cycle-*-consolidation-fired files before preflight stages run.
# This test verifies: the glob pattern matches the sentinel filename format,
# and leaves unrelated cache files untouched.
# ---------------------------------------------------------------------------

test_stale_sentinel_glob_cleanup() {
	local tmp; tmp=$(mktemp -d -t t2749-glob.XXXXXX)
	local fake_home="${tmp}/home"
	mkdir -p "${fake_home}/.aidevops/cache"

	# Stale sentinel left by a hypothetical previous cycle.
	local stale_sentinel="${fake_home}/.aidevops/cache/pulse-cycle-99999-consolidation-fired"
	touch "$stale_sentinel"

	# An unrelated cache file that must NOT be removed.
	local unrelated="${fake_home}/.aidevops/cache/some-other-file"
	touch "$unrelated"

	# Exactly the cleanup command from pulse-wrapper.sh.
	# shellcheck disable=SC2086,SC2015
	rm -f "${fake_home}/.aidevops/cache/pulse-cycle-"*"-consolidation-fired" 2>/dev/null || true

	local failures=0 failmsg=""

	if [[ -f "$stale_sentinel" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | stale sentinel not removed by glob"
	fi

	if [[ ! -f "$unrelated" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | unrelated cache file removed by glob (too broad)"
	fi

	rm -rf "$tmp"

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: stale sentinel glob cleanup is specific enough" 0
	else
		print_result "t2749: stale sentinel glob cleanup is specific enough" 1 "$failmsg"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: sentinel pattern present in all three modified files
# ---------------------------------------------------------------------------

test_sentinel_path_pattern_in_source() {
	local triage_file="${REPO_ROOT}/.agents/scripts/pulse-triage.sh"
	local engine_file="${REPO_ROOT}/.agents/scripts/pulse-dispatch-engine.sh"
	local wrapper_file="${REPO_ROOT}/.agents/scripts/pulse-wrapper.sh"

	local failures=0 failmsg=""

	if ! grep -q 'pulse-cycle-\$\$-consolidation-fired' "$triage_file" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sentinel touch not found in pulse-triage.sh"
	fi

	if ! grep -q 'pulse-cycle-\$\$-consolidation-fired' "$engine_file" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sentinel reference not found in pulse-dispatch-engine.sh"
	fi

	if ! grep -q 'pulse-cycle.*consolidation-fired' "$wrapper_file" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | stale sentinel cleanup not found in pulse-wrapper.sh"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: sentinel pattern present in all three modified files" 0
	else
		print_result "t2749: sentinel pattern present in all three modified files" 1 "$failmsg"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: _dispatch_issue_consolidation writes sentinel on success
#
# Sources pulse-triage.sh with a minimal gh stub and the lock override so
# the full dispatch path runs and creates the sentinel file. Verifies that
# the sentinel at pulse-cycle-$$-consolidation-fired exists after a
# successful _dispatch_issue_consolidation call.
# ---------------------------------------------------------------------------

test_dispatch_writes_sentinel() {
	local tmp; tmp=$(mktemp -d -t t2749-sentinel.XXXXXX)
	local fake_home="${tmp}/home"
	mkdir -p "${fake_home}/.aidevops/cache" "${fake_home}/.aidevops/logs"
	local gh_log="${tmp}/gh.log"
	: >"$gh_log"

	# gh stub: handles all expected calls.
	local stub_bin="${tmp}/bin"
	mkdir -p "$stub_bin"
	# Export gh_log for use inside the stub.
	local _GH_LOG_PATH="$gh_log"
	export _GH_LOG_PATH
	cat >"${stub_bin}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${_GH_LOG_PATH:-/dev/null}"
case "${1:-}-${2:-}" in
issue-view)
	shift 2
	local_json=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json) local_json="$2"; shift 2 ;;
		--jq) shift 2 ;;
		*) shift ;;
		esac
	done
	case "$local_json" in
	title) printf 'Test parent title\n' ;;
	body) printf 'Parent body text for testing.\n' ;;
	labels) printf 'bug,tier:standard\n' ;;
	*) printf '\n' ;;
	esac ;;
issue-list) printf '[]\n' ;;
pr-list) printf '[]\n' ;;
issue-create) printf 'https://github.com/owner/repo/issues/9999\n' ;;
api-*) printf '[]\n' ;;
issue-edit | issue-comment | label-create | issue-close) ;;
*) ;;
esac
exit 0
STUB
	chmod +x "${stub_bin}/gh"

	local prev_path="$PATH"
	export PATH="${stub_bin}:${PATH}"
	local prev_home="$HOME"
	export HOME="$fake_home"

	local prev_logfile="${LOGFILE:-}"
	local log_file="${tmp}/pulse.log"
	: >"$log_file"
	export LOGFILE="$log_file"

	# Globals required by pulse-triage.sh.
	export TRIAGE_CACHE_DIR="${tmp}/triage-cache"
	mkdir -p "$TRIAGE_CACHE_DIR"
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=50
	export ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2
	export REPOS_JSON="${tmp}/repos.json"
	printf '{"initialized_repos": []}\n' >"$REPOS_JSON"

	# Lock override: bypass gh api user call in _consolidation_lock_self_login.
	export CONSOLIDATION_LOCK_SELF_LOGIN_OVERRIDE="testrunner"

	# gh stub env vars for view/list/comments.
	export GH_ISSUE_VIEW_TITLE="Test parent title"
	export GH_ISSUE_VIEW_BODY="Parent body text for testing."
	export GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_PR_LIST_RESOLVING_JSON="[]"
	# Two long comments (>50 chars) to satisfy the threshold.
	local long_body="Detailed review comment with enough characters to clear the minimum length threshold for consolidation."
	export GH_API_COMMENTS_JSON
	GH_API_COMMENTS_JSON=$(printf '[
  {"user": {"login": "alice", "type": "User"}, "created_at": "2026-01-01T00:00:00Z", "body": "%s"},
  {"user": {"login": "bob",   "type": "User"}, "created_at": "2026-01-01T01:00:00Z", "body": "%s"}
]' "$long_body" "$long_body")

	# Clear the triage module load guard before sourcing.
	unset _PULSE_TRIAGE_LOADED

	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage.sh" || {
		printf 'ERROR: failed to source pulse-triage.sh\n' >&2
		PATH="$prev_path"
		HOME="$prev_home"
		LOGFILE="$prev_logfile"
		rm -rf "$tmp"
		return 1
	}

	# gh_create_issue wrapper (defined in shared-constants.sh, not sourced here).
	gh_create_issue() { gh issue create "$@"; }
	# gh_issue_comment wrapper: just call the stubbed gh.
	gh_issue_comment() { gh issue comment "$@"; }

	local sentinel="${fake_home}/.aidevops/cache/pulse-cycle-$$-consolidation-fired"
	rm -f "$sentinel" 2>/dev/null || true

	local rc=0
	_dispatch_issue_consolidation 123 "owner/repo" "/tmp/fake-path" || rc=$?

	local failures=0 failmsg=""

	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | _dispatch_issue_consolidation returned rc=${rc}"
	fi

	if [[ ! -f "$sentinel" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sentinel file not created"
		# Diagnostic: show log and gh invocations.
		printf '  LOG: %s\n' "$(cat "$log_file" 2>/dev/null || echo '<empty>')"
		printf '  GH:  %s\n' "$(cat "$gh_log" 2>/dev/null || echo '<empty>')"
	fi

	# Restore environment.
	rm -f "$sentinel" 2>/dev/null || true
	PATH="$prev_path"
	HOME="$prev_home"
	LOGFILE="$prev_logfile"
	unset _PULSE_TRIAGE_LOADED CONSOLIDATION_LOCK_SELF_LOGIN_OVERRIDE _GH_LOG_PATH
	unset GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	unset GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON
	unset GH_PR_LIST_RESOLVING_JSON GH_API_COMMENTS_JSON
	rm -rf "$tmp"

	if [[ "$failures" -eq 0 ]]; then
		print_result "t2749: _dispatch_issue_consolidation writes sentinel on success" 0
	else
		print_result "t2749: _dispatch_issue_consolidation writes sentinel on success" 1 "$failmsg"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	test_sentinel_path_pattern_in_source
	test_phase2_fires_when_sentinel_and_slots_available
	test_phase2_skipped_when_no_sentinel
	test_phase2_skipped_when_slots_full
	test_sentinel_consumed_prevents_double_phase2
	test_stop_flag_skips_entire_fill_floor
	test_stale_sentinel_glob_cleanup
	test_dispatch_writes_sentinel

	echo
	echo "============================================"
	printf 'Tests run:    %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	echo "============================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
