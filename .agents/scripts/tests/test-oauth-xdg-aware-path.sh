#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-oauth-xdg-aware-path.sh — t2249 regression guard.
#
# Asserts that `oauth-pool-helper.sh`'s OPENCODE_AUTH_FILE constant is
# XDG_DATA_HOME-aware. This is the keystone fix: when set, rotation
# targets the isolated per-worker auth.json; when unset, rotation
# targets the shared interactive file (original behaviour).
#
# Production failure this prevents (GH#19787, t2249): when a headless
# worker's OAuth account was rate-limited, subsequent workers inherited
# the same rate-limited auth because `oauth-pool-helper.sh rotate`
# hardcoded the shared auth path and had been disabled for headless
# workers to protect the interactive session. XDG awareness makes
# rotation safe to call from either context.
#
# Tests:
#   1. XDG_DATA_HOME unset, HOME=/h  → /h/.local/share/opencode/auth.json
#   2. XDG_DATA_HOME=/x, HOME=/h     → /x/opencode/auth.json
#   3. XDG_DATA_HOME="" (empty)      → /h/.local/share/opencode/auth.json
#
# Strategy: extract the `OPENCODE_AUTH_FILE=` assignment line from the
# helper and eval it in isolated subshells with controlled env. This
# tests the exact expansion used at runtime without executing the rest
# of the helper.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/oauth-pool-helper.sh"

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

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
}

fail() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
}

# --- Setup -------------------------------------------------------------------

[[ -f "$HELPER" ]] || {
	printf 'FATAL: helper not found: %s\n' "$HELPER" >&2
	exit 1
}

# Extract the exact variable assignment line used at runtime.
LINE=$(grep -E '^OPENCODE_AUTH_FILE=' "$HELPER" | head -1)
[[ -n "$LINE" ]] || {
	printf 'FATAL: could not locate OPENCODE_AUTH_FILE= line in %s\n' "$HELPER" >&2
	exit 1
}

printf '%s[test]%s t2249 — OAuth pool OPENCODE_AUTH_FILE is XDG-aware\n' "$TEST_BLUE" "$TEST_NC"
printf '  extracted: %s\n' "$LINE"

# --- Test 1: XDG_DATA_HOME unset → default path under HOME -------------------

actual=$(env -i HOME=/h1 bash -c "unset XDG_DATA_HOME; $LINE; printf '%s' \"\$OPENCODE_AUTH_FILE\"")
expected="/h1/.local/share/opencode/auth.json"
if [[ "$actual" == "$expected" ]]; then
	pass "XDG_DATA_HOME unset resolves to default (HOME/.local/share/opencode/auth.json)"
else
	fail "XDG_DATA_HOME unset: expected '$expected', got '$actual'"
fi

# --- Test 2: XDG_DATA_HOME set → isolated path -------------------------------

actual=$(env -i HOME=/h2 XDG_DATA_HOME=/tmp/xdg-isolated bash -c "$LINE; printf '%s' \"\$OPENCODE_AUTH_FILE\"")
expected="/tmp/xdg-isolated/opencode/auth.json"
if [[ "$actual" == "$expected" ]]; then
	pass "XDG_DATA_HOME set routes to isolated path"
else
	fail "XDG_DATA_HOME set: expected '$expected', got '$actual'"
fi

# --- Test 3: XDG_DATA_HOME="" (empty) → default path (parameter default logic) ---

actual=$(env -i HOME=/h3 XDG_DATA_HOME="" bash -c "$LINE; printf '%s' \"\$OPENCODE_AUTH_FILE\"")
expected="/h3/.local/share/opencode/auth.json"
if [[ "$actual" == "$expected" ]]; then
	pass "XDG_DATA_HOME empty string falls back to HOME default (\${:-} semantics)"
else
	fail "XDG_DATA_HOME empty: expected '$expected', got '$actual'"
fi

# --- Summary -----------------------------------------------------------------

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
