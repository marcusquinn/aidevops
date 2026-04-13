#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-setup-completion-sentinel.sh — regression guard for GH#18492 / t2026
#
# Ensures the setup.sh completion sentinel contract is intact:
#   (1) setup.sh defines print_setup_complete_sentinel
#   (2) main() calls it exactly once
#   (3) the sentinel line format matches what verify-setup-log.sh greps for
#   (4) verify-setup-log.sh accepts a log containing the sentinel
#   (5) verify-setup-log.sh rejects a log missing the sentinel
#
# This test protects both sides of the contract so the sentinel can't drift
# without a test failure.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SH="${REPO_ROOT}/setup.sh"
VERIFIER="${REPO_ROOT}/.agents/scripts/verify-setup-log.sh"

if [[ ! -f "$SETUP_SH" ]]; then
	echo "ERROR: setup.sh not found at $SETUP_SH" >&2
	exit 1
fi

if [[ ! -x "$VERIFIER" ]]; then
	echo "ERROR: verify-setup-log.sh not executable at $VERIFIER" >&2
	exit 1
fi

# 1. Function is defined
if ! grep -q '^print_setup_complete_sentinel()' "$SETUP_SH"; then
	echo "FAIL: print_setup_complete_sentinel function not defined in setup.sh" >&2
	exit 1
fi
printf 'PASS %s\n' "print_setup_complete_sentinel function defined"

# 2. Called exactly once from a call site (not counting the function definition)
# Match bare invocations on their own line, not the function definition line.
_call_count=$(grep -cE '^[[:space:]]+print_setup_complete_sentinel[[:space:]]*$' "$SETUP_SH" || true)
if [[ "$_call_count" != "1" ]]; then
	echo "FAIL: print_setup_complete_sentinel called $_call_count times, expected 1" >&2
	exit 1
fi
printf 'PASS %s\n' "print_setup_complete_sentinel called exactly once"

# 3. Sentinel format matches verifier prefix (tests the contract end-to-end)
_expected_prefix='[SETUP_COMPLETE] aidevops setup.sh'
if ! grep -Fq "$_expected_prefix" "$SETUP_SH"; then
	echo "FAIL: sentinel format does not contain '$_expected_prefix'" >&2
	exit 1
fi
printf 'PASS %s\n' "sentinel format matches verifier contract"

# 4. End-to-end: synthesise a minimal log with and without the sentinel,
# verify the verifier gives the right answer on each.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

printf '%s\n' "$_expected_prefix v3.7.3 finished all phases (mode=non-interactive)" >"$TMP_DIR/good.log"
if ! bash "$VERIFIER" "$TMP_DIR/good.log" >/dev/null 2>&1; then
	echo "FAIL: verify-setup-log.sh rejected a valid log containing sentinel" >&2
	exit 1
fi
printf 'PASS %s\n' "verify-setup-log.sh accepts valid sentinel log"

# 5. Negative: log missing the sentinel must be rejected
printf '[INFO] Setting up routines repo...\nsome-helper.sh: line 22: GREEN: readonly variable\n' >"$TMP_DIR/bad.log"
if bash "$VERIFIER" "$TMP_DIR/bad.log" >/dev/null 2>&1; then
	echo "FAIL: verify-setup-log.sh accepted a log missing the sentinel" >&2
	exit 1
fi
printf 'PASS %s\n' "verify-setup-log.sh rejects log missing sentinel"

# 6. Usage error: no args returns exit 2 (distinct from absent-sentinel exit 1)
_usage_exit=0
bash "$VERIFIER" </dev/null >/dev/null 2>&1 || _usage_exit=$?
if [[ "$_usage_exit" != "2" ]]; then
	echo "FAIL: verify-setup-log.sh with no args returned exit $_usage_exit, expected 2" >&2
	exit 1
fi
printf 'PASS %s\n' "verify-setup-log.sh returns exit 2 on usage error"

echo "All t2026 sentinel regression tests passed"
