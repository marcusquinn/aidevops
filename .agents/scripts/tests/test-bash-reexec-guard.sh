#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2087 / GH#18950 — bash re-exec guard in shared-constants.sh
# and bash-upgrade-helper.sh subcommands.
#
# Locks in these invariants:
#   1. bash-upgrade-helper.sh check exits 0 regardless of bash version
#   2. bash-upgrade-helper.sh status emits "current:" line
#   3. bash-upgrade-helper.sh path exits 0 on this machine (modern bash available
#      via Homebrew on macOS) OR exits 1 with no output on Linux with no Homebrew
#   4. bash-upgrade-helper.sh with unknown subcommand exits non-zero
#   5. shared-constants.sh includes the re-exec guard block
#   6. Re-exec guard uses AIDEVOPS_BASH_REEXECED to prevent infinite loops
#   7. bash-upgrade-helper.sh is shellcheck-clean
#   8. shared-constants.sh re-exec guard is bash 3.2 compatible (no 4.0+ features)
#
# Usage: bash tests/test-bash-reexec-guard.sh
# Or:    /bin/bash tests/test-bash-reexec-guard.sh  (runs under macOS bash 3.2)
# Environment: runnable under /bin/bash 3.2 (macOS default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/bash-upgrade-helper.sh"
SHARED_CONSTANTS="$REPO_ROOT/.agents/scripts/shared-constants.sh"

pass_count=0
fail_count=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

assert_exit0() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s (command exited non-zero)\n' "$label"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

assert_exit_nonzero() {
	local label="$1"
	shift
	local rc=0
	"$@" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s (expected non-zero exit, got 0)\n' "$label"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

assert_contains() {
	local label="$1" pattern="$2" actual="$3"
	if printf '%s' "$actual" | grep -qF "$pattern" 2>/dev/null; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  pattern: %s\n  actual:  %s\n' "$label" "$pattern" "$actual"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

assert_not_contains() {
	local label="$1" pattern="$2" actual="$3"
	if ! printf '%s' "$actual" | grep -qF "$pattern" 2>/dev/null; then
		printf 'PASS: %s\n' "$label"
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: %s\n  pattern must NOT appear: %s\n  actual: %s\n' "$label" "$pattern" "$actual"
		fail_count=$((fail_count + 1))
	fi
	return 0
}

# =============================================================================
# Assertion 1: bash-upgrade-helper.sh check exits 0 (always — never blocks setup)
# =============================================================================
assert_exit0 "check subcommand exits 0 (never blocking)" bash "$HELPER" check

# =============================================================================
# Assertion 2: bash-upgrade-helper.sh status emits "current:" line
# =============================================================================
status_output=$(bash "$HELPER" status 2>&1 || true)
assert_contains "status subcommand emits 'current:' line" "current:" "$status_output"

# =============================================================================
# Assertion 3: bash-upgrade-helper.sh status emits "status:" line with ok or drift
# =============================================================================
assert_contains "status subcommand emits 'status:' line" "status:" "$status_output"

# =============================================================================
# Assertion 4: bash-upgrade-helper.sh with unknown subcommand exits non-zero
# =============================================================================
assert_exit_nonzero "unknown subcommand exits non-zero" bash "$HELPER" bogus-subcommand-xyz

# =============================================================================
# Assertion 5: shared-constants.sh contains the re-exec guard block
# =============================================================================
guard_present=$(grep -c "AIDEVOPS_BASH_REEXECED" "$SHARED_CONSTANTS" 2>/dev/null || echo "0")
if [[ "$guard_present" -ge 2 ]]; then
	printf 'PASS: shared-constants.sh contains re-exec guard (AIDEVOPS_BASH_REEXECED found %s times)\n' "$guard_present"
	pass_count=$((pass_count + 1))
else
	printf 'FAIL: shared-constants.sh missing AIDEVOPS_BASH_REEXECED guard (found %s, expected >=2)\n' "$guard_present"
	fail_count=$((fail_count + 1))
fi

# =============================================================================
# Assertion 6: Re-exec guard uses exec with BASH_SOURCE[1] and candidate paths
# =============================================================================
exec_guard_present=$(grep -c "exec.*_aidevops_bash_candidate.*BASH_SOURCE" "$SHARED_CONSTANTS" 2>/dev/null || echo "0")
if [[ "$exec_guard_present" -ge 1 ]]; then
	printf 'PASS: shared-constants.sh re-exec guard exec pattern found\n'
	pass_count=$((pass_count + 1))
else
	printf 'FAIL: shared-constants.sh missing exec guard pattern (exec *_aidevops_bash_candidate*BASH_SOURCE)\n'
	fail_count=$((fail_count + 1))
fi

# =============================================================================
# Assertion 7: bash-upgrade-helper.sh is shellcheck-clean
# =============================================================================
if command -v shellcheck >/dev/null 2>&1; then
	sc_output=$(shellcheck "$HELPER" 2>&1 || true)
	# SC1091 (not following source) is expected/allowed; anything else is a fail
	filtered=$(printf '%s' "$sc_output" | grep -v 'SC1091' | grep -v '^For more' | grep -v 'https://' | grep 'SC[0-9]' || true)
	if [[ -z "$filtered" ]]; then
		printf 'PASS: bash-upgrade-helper.sh is shellcheck-clean\n'
		pass_count=$((pass_count + 1))
	else
		printf 'FAIL: bash-upgrade-helper.sh has shellcheck violations:\n%s\n' "$filtered"
		fail_count=$((fail_count + 1))
	fi
else
	printf 'SKIP: shellcheck not installed — skipping SC7 assertion\n'
fi

# =============================================================================
# Assertion 8: re-exec guard does NOT use bash 4.0+ syntax
# =============================================================================
# Forbidden patterns: declare -A, mapfile, ${var,,}, ${var^^}, declare -n
guard_block=$(awk '/Runtime re-exec guard/,/^# ==/' "$SHARED_CONSTANTS" 2>/dev/null || true)
bash4_patterns="declare -A|mapfile|readarray|\${[A-Za-z_]*,,}|\${[A-Za-z_]*\^\^}|declare -n"
bad_syntax=$(printf '%s' "$guard_block" | grep -E "$bash4_patterns" || true)
if [[ -z "$bad_syntax" ]]; then
	printf 'PASS: re-exec guard contains no bash 4.0+ forbidden syntax\n'
	pass_count=$((pass_count + 1))
else
	printf 'FAIL: re-exec guard contains bash 4.0+ syntax:\n%s\n' "$bad_syntax"
	fail_count=$((fail_count + 1))
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
printf 'Results: %s passed, %s failed\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

exit 0
