#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#21063 regression tests — follow-up fixes for the t2906 atomic plist install.
# Covers the four priorities addressed by this PR:
#   (a) mv exit status checked — mv-failure path returns 1 and cleans up tmp file
#   (b) legacy plist cleanup restored and idempotent
#   (c) empty content rejected before write
#
# Usage: bash .agents/scripts/tests/test-launchd-install-if-changed.sh
# Platform: macOS only (launchd is macOS-specific; test skips on Linux)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SCHEDULERS_SH="$REPO_ROOT/setup-modules/schedulers.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Inline _launchd_install_if_changed from setup.sh for isolated testing.
# This is a COPY of the function as fixed by GH#21063; if setup.sh changes,
# update this copy and add/adjust tests accordingly.
# We cannot source setup.sh directly because it runs `main "$@"` at the
# bottom and sources many setup-modules at the top level.
# ---------------------------------------------------------------------------

_define_launchd_install_if_changed() {
	# Minimal stubs required by _launchd_install_if_changed
	print_warning() { echo "[WARN] $*" >&2; return 0; }
	print_info()    { return 0; }

	_launchd_has_agent() {
		# Default stub: agent not loaded
		return 1
	}

	# launchctl stub — no-op unless overridden by individual tests
	launchctl() { return 0; }

	# _launchd_install_if_changed — inline from setup.sh (GH#21063 fixes)
	_launchd_install_if_changed() {
		local label="$1"
		local plist_path="$2"
		local new_content="$3"

		if [[ -f "$plist_path" ]]; then
			local existing_content
			existing_content=$(cat "$plist_path")
			if [[ "$existing_content" == "$new_content" ]]; then
				if ! _launchd_has_agent "$label"; then
					launchctl load "$plist_path" 2>/dev/null || return 1
				fi
				return 0
			fi
			if _launchd_has_agent "$label"; then
				launchctl unload "$plist_path" 2>/dev/null || true
			fi
		fi

		# Atomic write: build at sibling tmp path, then rename into place.
		local tmp_plist
		tmp_plist=$(mktemp "${plist_path}.XXXXXX") || return 1
		# Guard: refuse to write empty content
		if [[ -z "$new_content" ]]; then
			rm -f "$tmp_plist"
			return 1
		fi
		if ! printf '%s\n' "$new_content" >"$tmp_plist"; then
			rm -f "$tmp_plist"
			return 1
		fi
		if [[ ! -s "$tmp_plist" ]]; then
			rm -f "$tmp_plist"
			return 1
		fi
		if ! mv -f "$tmp_plist" "$plist_path"; then
			rm -f "$tmp_plist"
			return 1
		fi
		launchctl load "$plist_path" 2>/dev/null || return 1
		return 0
	}
	return 0
}

# ---------------------------------------------------------------------------
# Load schedulers.sh functions (needed for legacy-cleanup test)
# ---------------------------------------------------------------------------

_load_schedulers_functions() {
	# Define stubs before sourcing so schedulers.sh function bodies find them
	print_info()              { return 0; }
	print_warning()           { echo "[WARN] $*" >&2; return 0; }
	print_error()             { echo "[ERROR] $*" >&2; return 0; }
	_log_plist_env_overrides() { return 0; }
	_read_pulse_interval_seconds() { echo 60; return 0; }
	# Stub _launchd_install_if_changed — schedulers.sh calls this but doesn't define it;
	# we want to isolate the legacy-cleanup logic without running the real install.
	_launchd_install_if_changed() { return 0; }
	_launchd_has_agent()           { return 1; }

	# shellcheck source=/dev/null
	source "$SCHEDULERS_SH" 2>/dev/null || {
		echo "SKIP: could not source $SCHEDULERS_SH (missing dependencies?)"
		exit 0
	}
	return 0
}

# ---------------------------------------------------------------------------
# (a) mv-failure path returns 1 and cleans up the tmp file (Priority 1 + 3)
# ---------------------------------------------------------------------------

test_mv_failure_returns_1() {
	local plist_dir="$TEST_DIR/la_mv"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"

	# Override mv to simulate failure
	mv() { return 1; }

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "some plist content" || rc=$?

	unset -f mv

	if [[ "$rc" -eq 0 ]]; then
		print_result "mv_failure_returns_1" 1 "expected non-zero return when mv fails, got 0"
		return 0
	fi

	# No tmp files should remain after cleanup
	local tmp_count
	tmp_count=$(find "$plist_dir" -name "test.plist.*" 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$tmp_count" -ne 0 ]]; then
		print_result "mv_failure_returns_1" 1 \
			"tmp file not cleaned up after mv failure ($tmp_count file(s) remain)"
		return 0
	fi

	print_result "mv_failure_returns_1" 0
	return 0
}

# ---------------------------------------------------------------------------
# (b) Legacy plist cleanup runs once and is idempotent (Priority 2)
# ---------------------------------------------------------------------------

test_legacy_cleanup_idempotent() {
	local fake_home="$TEST_DIR/home_legacy"
	mkdir -p "$fake_home/Library/LaunchAgents"

	# Create legacy plist
	local legacy_plist="$fake_home/Library/LaunchAgents/com.aidevops.supervisor-pulse.plist"
	printf 'fake legacy plist\n' >"$legacy_plist"

	# Track launchctl unload calls
	local unload_count=0
	launchctl() {
		if [[ "${1:-}" == "unload" ]]; then
			unload_count=$((unload_count + 1))
		fi
		return 0
	}
	# Override generate to return fake content (avoids real script path checks)
	_generate_pulse_plist_content() { printf 'fake plist content\n'; return 0; }

	local orig_home="$HOME"
	HOME="$fake_home"

	local rc=0
	_install_pulse_launchd \
		"com.aidevops.aidevops-supervisor-pulse" "/fake/wrapper.sh" "" "false" || rc=$?

	HOME="$orig_home"
	unset -f launchctl _generate_pulse_plist_content

	if [[ "$rc" -ne 0 ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"first call returned $rc (expected 0)"
		return 0
	fi

	if [[ -f "$legacy_plist" ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"legacy plist still present after first call"
		return 0
	fi

	if [[ "$unload_count" -lt 1 ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"launchctl unload was not called for legacy plist (unload_count=$unload_count)"
		return 0
	fi

	# Second call — idempotent: legacy file is gone, should not error
	launchctl() { return 0; }
	_generate_pulse_plist_content() { printf 'fake plist content\n'; return 0; }
	HOME="$fake_home"

	rc=0
	_install_pulse_launchd \
		"com.aidevops.aidevops-supervisor-pulse" "/fake/wrapper.sh" "" "true" || rc=$?

	HOME="$orig_home"
	unset -f launchctl _generate_pulse_plist_content

	if [[ "$rc" -ne 0 ]]; then
		print_result "legacy_cleanup_first_call_rc" 1 \
			"second call (idempotent) returned $rc (expected 0)"
		return 0
	fi

	print_result "legacy_cleanup_first_call_rc" 0
	return 0
}

# ---------------------------------------------------------------------------
# (c) Empty content is rejected before write (Priority 4)
# ---------------------------------------------------------------------------

test_empty_content_rejected() {
	local plist_dir="$TEST_DIR/la_empty"
	mkdir -p "$plist_dir"
	local plist_path="$plist_dir/test.plist"

	local rc=0
	_launchd_install_if_changed "test-label" "$plist_path" "" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "empty_content_rejected" 1 \
			"expected non-zero return for empty content, got 0"
		return 0
	fi

	# No tmp files should remain
	local tmp_count
	tmp_count=$(find "$plist_dir" -name "test.plist.*" 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$tmp_count" -ne 0 ]]; then
		print_result "empty_content_rejected" 1 \
			"tmp file not cleaned up after empty-content rejection ($tmp_count file(s))"
		return 0
	fi

	# Destination plist must not have been created
	if [[ -f "$plist_path" ]]; then
		print_result "empty_content_rejected" 1 \
			"plist was created despite empty content"
		return 0
	fi

	print_result "empty_content_rejected" 0
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	# macOS-only: launchd/launchctl is not available on Linux
	if [[ "$(uname -s)" != "Darwin" ]]; then
		echo "SKIP: launchd tests are macOS-only (current: $(uname -s))"
		exit 0
	fi

	setup

	# Tests (a) and (c) use the inline _launchd_install_if_changed definition
	_define_launchd_install_if_changed

	test_mv_failure_returns_1
	test_empty_content_rejected

	# Test (b) needs _install_pulse_launchd from schedulers.sh
	_load_schedulers_functions

	test_legacy_cleanup_idempotent

	echo ""
	echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
