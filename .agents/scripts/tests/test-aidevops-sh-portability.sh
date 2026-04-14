#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-aidevops-sh-portability.sh — Regression tests for cross-platform command
# portability in aidevops.sh (t2074, GH#18784).
#
# Background: PR #18686 added SUDO_USER → getent passwd home resolution to
# aidevops.sh but omitted the `command -v getent` guard (which the sibling
# fix in .agents/scripts/approval-helper.sh:33 does include). On macOS, where
# getent is not part of the base system, `set -euo pipefail` killed aidevops.sh
# before any subcommand could run, breaking `sudo aidevops approve` completely.
#
# This test asserts two things:
#   1. The home-resolution block in aidevops.sh guards getent behind a
#      `command -v getent` check. Caught by structural grep against the
#      source file — no sudo required.
#   2. The block still returns a sensible home directory when getent is
#      unavailable, simulated by scrubbing getent off PATH and mocking
#      `id -u` to return 0 (the in-sudo condition that triggers the bug).
#
# Both assertions are portable: they run on bash 3.2 (macOS) and bash 4+
# (Linux) and do not require root, sudo, or any external fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_info() {
	local msg="$1"
	printf '%b[INFO]%b %s\n' "${TEST_YELLOW}" "${TEST_NC}" "${msg}"
	return 0
}

# -----------------------------------------------------------------------------
# Test 1: structural guard — the getent call must be inside a `command -v` check
# -----------------------------------------------------------------------------
test_getent_structural_guard() {
	_info "Test 1: aidevops.sh getent call must be guarded"

	if [[ ! -f "${AIDEVOPS_SH}" ]]; then
		_fail "aidevops.sh not found at ${AIDEVOPS_SH}"
		return 1
	fi

	# Extract the line that calls `getent passwd "$SUDO_USER"` and inspect the
	# `if` statement preceding it. The canonical fixed pattern has the guard
	# on the same logical line: ` && command -v getent &>/dev/null; then`.
	local getent_line_num
	getent_line_num=$(grep -n '^[[:space:]]*_AIDEVOPS_REAL_HOME=.*getent passwd' "${AIDEVOPS_SH}" | head -1 | cut -d: -f1)

	if [[ -z "${getent_line_num}" ]]; then
		_fail "Could not find _AIDEVOPS_REAL_HOME=... getent passwd line in aidevops.sh"
		return 1
	fi

	# Scan the 4 lines immediately above the getent call for the guard
	local guard_start=$((getent_line_num - 4))
	[[ ${guard_start} -lt 1 ]] && guard_start=1

	local guard_block
	guard_block=$(sed -n "${guard_start},${getent_line_num}p" "${AIDEVOPS_SH}")

	if grep -q 'command -v getent' <<<"${guard_block}"; then
		_pass "getent call is guarded by 'command -v getent' check"
	else
		_fail "getent call at line ${getent_line_num} is NOT guarded — regression!"
		printf 'Context:\n%s\n' "${guard_block}" >&2
		return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test 2: runtime behaviour — resolve correctly with getent absent + SUDO_USER set
# -----------------------------------------------------------------------------
test_runtime_fallback_no_getent() {
	_info "Test 2: runtime resolves via \$HOME fallback when getent is absent"

	local out
	# Strip getent off PATH, mock `id -u` to return 0, set SUDO_USER, and
	# execute the exact guard+resolution block copied verbatim from aidevops.sh.
	# We inline the block rather than sourcing aidevops.sh because sourcing
	# executes the full CLI dispatcher (which we don't want in a unit test).
	out=$(bash -c '
		set -euo pipefail
		id() { if [[ "${1:-}" == "-u" ]]; then echo 0; else command id "$@"; fi; }
		export SUDO_USER="fakeuser"
		export HOME="/tmp/aidevops-test-fake-home"
		export PATH="/usr/bin:/bin"
		if command -v getent &>/dev/null; then
			echo "PRECONDITION_FAIL: getent still on PATH"
			exit 2
		fi
		if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]] && command -v getent &>/dev/null; then
			_AIDEVOPS_REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
		else
			_AIDEVOPS_REAL_HOME="$HOME"
		fi
		printf "%s\n" "$_AIDEVOPS_REAL_HOME"
	' 2>&1) || {
		_fail "Resolution block errored out: ${out}"
		return 1
	}

	if [[ "${out}" == "/tmp/aidevops-test-fake-home" ]]; then
		_pass "Resolved to \$HOME fallback (${out})"
	elif [[ "${out}" == *"PRECONDITION_FAIL"* ]]; then
		_fail "Test harness failure: ${out}"
		return 1
	else
		_fail "Unexpected resolution result: ${out}"
		return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test 3: approval-helper.sh continues to carry the same guard
# -----------------------------------------------------------------------------
test_approval_helper_still_guarded() {
	_info "Test 3: approval-helper.sh _resolve_real_home guard is intact"

	local helper="${REPO_ROOT}/.agents/scripts/approval-helper.sh"
	if [[ ! -f "${helper}" ]]; then
		_fail "approval-helper.sh not found at ${helper}"
		return 1
	fi

	if grep -q 'command -v getent' "${helper}"; then
		_pass "approval-helper.sh guards getent correctly"
	else
		_fail "approval-helper.sh has lost its command -v getent guard"
		return 1
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
	_info "aidevops.sh cross-platform portability regression tests (t2074, GH#18784)"
	printf '\n'

	test_getent_structural_guard
	test_runtime_fallback_no_getent
	test_approval_helper_still_guarded

	printf '\n'
	printf 'Results: %d passed, %d failed\n' "${pass_count}" "${fail_count}"

	if [[ ${fail_count} -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
