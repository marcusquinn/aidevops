#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression test for IP Hub provider field documentation.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PROVIDER_PATH="${SCRIPT_DIR}/../providers/ip-rep-iphub.sh"

PASS=0
FAIL=0

assert_contains() {
	local test_name="$1"
	local pattern="$2"
	if grep -Fq -- "$pattern" "$PROVIDER_PATH"; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected pattern: $pattern"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== ip-rep-iphub provider documentation regression ==="
echo ""

assert_contains "is_proxy docs match block=1 implementation" "#   is_proxy      bool    true if block=1 (non-residential/hosting; block=2 is caution only)"
assert_contains "block=1 branch sets is_proxy true" 'is_proxy="true"'
assert_contains "non-block=1 branch sets is_proxy false" 'is_proxy="false"'

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
