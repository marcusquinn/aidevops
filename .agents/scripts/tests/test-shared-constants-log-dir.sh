#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Test: _resolve_log_dir from shared-constants.sh
# Verifies that the resolver reads paths.log_dir from JSONC config and falls
# back to ~/.aidevops/logs when no config is present.
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
TESTS=0

_test() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	TESTS=$((TESTS + 1))
	if [[ "$actual" == "$expected" ]]; then
		echo "  PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $desc"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# --- Setup ---
SCRIPT_DIR="${BASH_SOURCE[0]%/*}/.."
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Save original HOME
ORIG_HOME="$HOME"

echo "=== _resolve_log_dir tests ==="

# --- Test 1: Default fallback (no JSONC config) ---
# Use a temp HOME with no config files so _jsonc_get is irrelevant
HOME="$TMPDIR_TEST/home-default"
mkdir -p "$HOME"

# Source shared-constants.sh (but NOT config-helper.sh — _jsonc_get unavailable)
# We need to isolate: unset the function if it exists
unset -f _jsonc_get 2>/dev/null || true

# Source only shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

result=$(_resolve_log_dir)
_test "Default fallback when no _jsonc_get" "$HOME/.aidevops/logs" "$result"

# --- Test 2: Custom paths.log_dir via _jsonc_get mock ---
HOME="$TMPDIR_TEST/home-custom"
mkdir -p "$HOME"

# Mock _jsonc_get to return a custom path
_jsonc_get() {
	local dotpath="$1"
	local default="${2:-}"
	if [[ "$dotpath" == "paths.log_dir" ]]; then
		printf '%s' "/tmp/custom-aidevops-logs"
	else
		printf '%s' "$default"
	fi
	return 0
}

result=$(_resolve_log_dir)
_test "Custom paths.log_dir via _jsonc_get" "/tmp/custom-aidevops-logs" "$result"

# --- Test 3: Tilde expansion ---
_jsonc_get() {
	local dotpath="$1"
	local default="${2:-}"
	if [[ "$dotpath" == "paths.log_dir" ]]; then
		# shellcheck disable=SC2088  # Tilde intentionally literal — testing expansion
		printf '%s' "~/.aidevops/custom-logs"
	else
		printf '%s' "$default"
	fi
	return 0
}

result=$(_resolve_log_dir)
_test "Tilde expansion in paths.log_dir" "$HOME/.aidevops/custom-logs" "$result"

# --- Test 4: _jsonc_get returns default ---
_jsonc_get() {
	local dotpath="$1"
	local default="${2:-}"
	printf '%s' "$default"
	return 0
}

result=$(_resolve_log_dir)
_test "_jsonc_get returns default value" "$HOME/.aidevops/logs" "$result"

# --- Restore HOME ---
HOME="$ORIG_HOME"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed, $TESTS total"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
