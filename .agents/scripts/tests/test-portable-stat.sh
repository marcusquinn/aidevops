#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-portable-stat.sh — Unit tests for portable-stat.sh
#
# Tests cover:
#   - Variant detection (gnu or bsd, never unknown on supported platforms)
#   - _stat_batch with every supported format token (%n %s %Y %y %a %U)
#   - _stat_batch composite format strings
#   - _stat_batch multi-file batch mode
#   - Convenience wrappers (_file_mtime_epoch, _file_size_bytes, _file_perms, _file_owner)
#   - Fallback values on nonexistent files
#   - Consistency between _stat_batch and convenience wrappers
#   - BSD format translation correctness (token map coverage)
#   - Idempotent re-source (_PORTABLE_STAT_LOADED guard)
#
# Usage: bash test-portable-stat.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LIB="${SCRIPT_DIR}/../portable-stat.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
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

# --- Setup -------------------------------------------------------------------

# shellcheck source=../portable-stat.sh
source "$LIB"

TF=$(mktemp)
TF2=$(mktemp)
echo "hello" > "$TF"
echo "hello world" > "$TF2"
chmod 644 "$TF"
chmod 755 "$TF2"

cleanup() {
	rm -f "$TF" "$TF2"
	return 0
}
trap cleanup EXIT

# --- Test: variant detection -------------------------------------------------

if [[ "$_STAT_VARIANT" == "gnu" || "$_STAT_VARIANT" == "bsd" ]]; then
	_pass "variant detection: $_STAT_VARIANT"
else
	_fail "variant detection: got '$_STAT_VARIANT', expected 'gnu' or 'bsd'"
fi

# --- Test: _stat_batch single tokens -----------------------------------------

result=$(_stat_batch '%Y' "$TF")
if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -gt 0 ]]; then
	_pass "_stat_batch %%Y returns epoch ($result)"
else
	_fail "_stat_batch %%Y: expected epoch, got '$result'"
fi

result=$(_stat_batch '%s' "$TF")
if [[ "$result" == "6" ]]; then
	_pass "_stat_batch %%s returns size (6)"
else
	_fail "_stat_batch %%s: expected 6, got '$result'"
fi

result=$(_stat_batch '%n' "$TF")
if [[ "$result" == "$TF" ]]; then
	_pass "_stat_batch %%n returns filename"
else
	_fail "_stat_batch %%n: expected '$TF', got '$result'"
fi

result=$(_stat_batch '%a' "$TF")
if [[ "$result" == "644" ]]; then
	_pass "_stat_batch %%a returns octal perms (644)"
else
	_fail "_stat_batch %%a: expected 644, got '$result'"
fi

result=$(_stat_batch '%U' "$TF")
if [[ -n "$result" ]] && id -un | grep -qF "$result"; then
	_pass "_stat_batch %%U returns owner ($result)"
else
	_fail "_stat_batch %%U: expected current user, got '$result'"
fi

result=$(_stat_batch '%y' "$TF")
if [[ -n "$result" ]] && [[ "$result" =~ [0-9]{4} ]]; then
	_pass "_stat_batch %%y returns human-readable mtime"
else
	_fail "_stat_batch %%y: expected date string, got '$result'"
fi

# --- Test: _stat_batch composite format --------------------------------------

result=$(_stat_batch '%n %s %Y' "$TF")
if [[ "$result" =~ ^"$TF"\ 6\ [0-9]+$ ]]; then
	_pass "_stat_batch composite '%%n %%s %%Y'"
else
	_fail "_stat_batch composite: expected '<name> 6 <epoch>', got '$result'"
fi

# --- Test: _stat_batch multi-file --------------------------------------------

line_count=$(_stat_batch '%n %s' "$TF" "$TF2" | wc -l)
if [[ "$line_count" -eq 2 ]]; then
	_pass "_stat_batch multi-file: 2 lines"
else
	_fail "_stat_batch multi-file: expected 2 lines, got $line_count"
fi

# --- Test: convenience wrappers ----------------------------------------------

result=$(_file_mtime_epoch "$TF")
if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -gt 0 ]]; then
	_pass "_file_mtime_epoch returns epoch ($result)"
else
	_fail "_file_mtime_epoch: expected epoch, got '$result'"
fi

result=$(_file_size_bytes "$TF")
if [[ "$result" == "6" ]]; then
	_pass "_file_size_bytes returns 6"
else
	_fail "_file_size_bytes: expected 6, got '$result'"
fi

result=$(_file_perms "$TF")
if [[ "$result" == "644" ]]; then
	_pass "_file_perms returns 644"
else
	_fail "_file_perms: expected 644, got '$result'"
fi

result=$(_file_owner "$TF")
if [[ -n "$result" ]] && id -un | grep -qF "$result"; then
	_pass "_file_owner returns current user ($result)"
else
	_fail "_file_owner: expected current user, got '$result'"
fi

# --- Test: fallbacks on nonexistent file -------------------------------------

result=$(_file_mtime_epoch /nonexistent/path)
if [[ "$result" == "0" ]]; then
	_pass "fallback: _file_mtime_epoch returns 0"
else
	_fail "fallback: _file_mtime_epoch expected 0, got '$result'"
fi

result=$(_file_size_bytes /nonexistent/path)
if [[ "$result" == "0" ]]; then
	_pass "fallback: _file_size_bytes returns 0"
else
	_fail "fallback: _file_size_bytes expected 0, got '$result'"
fi

result=$(_file_perms /nonexistent/path)
if [[ "$result" == "000" ]]; then
	_pass "fallback: _file_perms returns 000"
else
	_fail "fallback: _file_perms expected 000, got '$result'"
fi

result=$(_file_owner /nonexistent/path)
if [[ "$result" == "unknown" ]]; then
	_pass "fallback: _file_owner returns unknown"
else
	_fail "fallback: _file_owner expected unknown, got '$result'"
fi

# --- Test: consistency between _stat_batch and convenience wrappers ----------

batch_mtime=$(_stat_batch '%Y' "$TF")
conv_mtime=$(_file_mtime_epoch "$TF")
if [[ "$batch_mtime" == "$conv_mtime" ]]; then
	_pass "consistency: mtime batch == convenience"
else
	_fail "consistency: mtime batch='$batch_mtime' != convenience='$conv_mtime'"
fi

batch_size=$(_stat_batch '%s' "$TF")
conv_size=$(_file_size_bytes "$TF")
if [[ "$batch_size" == "$conv_size" ]]; then
	_pass "consistency: size batch == convenience"
else
	_fail "consistency: size batch='$batch_size' != convenience='$conv_size'"
fi

batch_perms=$(_stat_batch '%a' "$TF")
conv_perms=$(_file_perms "$TF")
if [[ "$batch_perms" == "$conv_perms" ]]; then
	_pass "consistency: perms batch == convenience"
else
	_fail "consistency: perms batch='$batch_perms' != convenience='$conv_perms'"
fi

batch_owner=$(_stat_batch '%U' "$TF")
conv_owner=$(_file_owner "$TF")
if [[ "$batch_owner" == "$conv_owner" ]]; then
	_pass "consistency: owner batch == convenience"
else
	_fail "consistency: owner batch='$batch_owner' != convenience='$conv_owner'"
fi

# --- Test: BSD translation map completeness ----------------------------------
# Verify every token documented in the header is present in the translation.

# shellcheck disable=SC2154
_check_token_in_source() {
	local token="$1"
	if grep -q "'${token}'" "$LIB"; then
		_pass "translation map contains $token"
	else
		_fail "translation map missing $token"
	fi
	return 0
}

_check_token_in_source '%n'
_check_token_in_source '%s'
_check_token_in_source '%Y'
_check_token_in_source '%y'
_check_token_in_source '%a'
_check_token_in_source '%U'

# --- Test: idempotent re-source ----------------------------------------------

_PORTABLE_STAT_LOADED_BEFORE="$_PORTABLE_STAT_LOADED"
# shellcheck source=../portable-stat.sh
source "$LIB"
if [[ "$_PORTABLE_STAT_LOADED" == "$_PORTABLE_STAT_LOADED_BEFORE" ]]; then
	_pass "re-source is idempotent (_PORTABLE_STAT_LOADED guard)"
else
	_fail "re-source changed _PORTABLE_STAT_LOADED"
fi

# --- Test: _stat_batch with nonexistent file returns non-zero ----------------

if result=$(_stat_batch '%s' /nonexistent/path 2>/dev/null); then
	_fail "_stat_batch nonexistent file: expected failure, got rc=0 result='$result'"
else
	_pass "_stat_batch nonexistent file: returns non-zero (correct)"
fi

# --- Summary -----------------------------------------------------------------

echo
echo "=============================="
echo "  Passed: $pass_count"
echo "  Failed: $fail_count"
echo "=============================="

if [[ $fail_count -gt 0 ]]; then
	exit 1
fi
exit 0
