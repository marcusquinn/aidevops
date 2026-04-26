#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression test for t2861: gh PATH shim must NOT mutate --body-file source
# =============================================================================
#
# Verifies that `gh issue create --body-file <file>` leaves the source file
# byte-identical before and after the shim runs. Uses SHIM_TEST_MODE=1 to
# short-circuit the exec step so no real gh binary is required.
#
# Usage:
#   .agents/scripts/test-gh-shim-body-file-immutable.sh
#   # Expected output: PASS: --body-file source unchanged after shim
#
# =============================================================================
set -euo pipefail

SHIM="$(cd "$(dirname "$0")" && pwd)/gh"

if [[ ! -x "$SHIM" ]]; then
	printf 'SKIP: shim not found at %s\n' "$SHIM"
	exit 0
fi

# ---------------------------------------------------------------------------
# Test 1: --body-file <space-separated> form — source file must be unchanged
# ---------------------------------------------------------------------------
_fixture=$(mktemp -t aidevops-test-brief.XXXXXX)
printf 'Test body\n\nSecond paragraph.\n' >"$_fixture"
_hash_before=$(shasum -a 256 "$_fixture" | awk '{print $1}')

# Run the shim in test mode. SIG_HELPER may emit output — capture to /dev/null.
# REAL_GH is set to a no-op so the shim's _find_real_gh fallback doesn't error
# if the test machine has no gh binary.
_resolved=$(SHIM_TEST_MODE=1 AIDEVOPS_GH_SHIM_DISABLE=0 \
	"$SHIM" issue create --body-file "$_fixture" --title "test" 2>/dev/null) || true

_hash_after=$(shasum -a 256 "$_fixture" | awk '{print $1}')

if [[ "$_hash_before" != "$_hash_after" ]]; then
	printf 'FAIL: --body-file source was mutated (space form)\n'
	printf '  before: %s\n' "$_hash_before"
	printf '  after:  %s\n' "$_hash_after"
	rm -f "$_fixture"
	exit 1
fi

# ---------------------------------------------------------------------------
# Test 2: resolved_body_file must differ from the source (a temp file was used)
# or be empty (sig helper unavailable). It must NOT equal the source path.
# ---------------------------------------------------------------------------
if [[ -n "$_resolved" ]]; then
	_resolved_path="${_resolved#resolved_body_file=}"
	if [[ "$_resolved_path" == "$_fixture" ]]; then
		printf 'FAIL: resolved_body_file is the source file — shim did not use a temp copy\n'
		printf '  resolved: %s\n' "$_resolved_path"
		printf '  source:   %s\n' "$_fixture"
		rm -f "$_fixture"
		exit 1
	fi
fi

rm -f "$_fixture"

# ---------------------------------------------------------------------------
# Test 3: --body-file=<attached> form
# ---------------------------------------------------------------------------
_fixture2=$(mktemp -t aidevops-test-brief.XXXXXX)
printf 'Attached form test\n' >"$_fixture2"
_hash_before2=$(shasum -a 256 "$_fixture2" | awk '{print $1}')

SHIM_TEST_MODE=1 AIDEVOPS_GH_SHIM_DISABLE=0 \
	"$SHIM" issue create "--body-file=${_fixture2}" --title "test" 2>/dev/null || true

_hash_after2=$(shasum -a 256 "$_fixture2" | awk '{print $1}')

if [[ "$_hash_before2" != "$_hash_after2" ]]; then
	printf 'FAIL: --body-file source was mutated (attached = form)\n'
	rm -f "$_fixture2"
	exit 1
fi

rm -f "$_fixture2"

printf 'PASS: --body-file source unchanged after shim\n'
exit 0
