#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SCRIPT_DIR
export HOME="${TMPDIR:-/tmp}/aidevops-idle-debt-borrowing.$$"
mkdir -p "$HOME/.aidevops/logs"
trap 'rm -rf "$HOME"' EXIT

# shellcheck source=../pulse-dispatch-engine.sh
source "$SCRIPT_DIR/pulse-dispatch-engine.sh"

failures=0

assert_order() {
	local name="$1"
	local slots="$2"
	local expected="$3"
	local actual=""

	actual=$(_dispatch_order_idle_borrowing_candidates "$CANDIDATES" "$slots" | jq -r '[.[].number] | join(",")')
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS: %s\n' "$name"
		return 0
	fi
	printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual" >&2
	failures=$((failures + 1))
	return 0
}

CANDIDATES='[
  {"number":1,"labels":["quality-debt","source:review-feedback"]},
  {"number":2,"labels":["quality-debt","source:review-feedback"]},
  {"number":3,"labels":["quality-debt","source:review-feedback"]},
  {"number":4,"labels":["bug"]},
  {"number":5,"labels":["enhancement"]},
  {"number":6,"labels":["quality-debt","source:quality-sweep"]}
]'

QUALITY_DEBT_CAP_PCT=30
assert_order "caps trusted review debt while ordinary candidates wait" 10 "1,2,3,4,5,6"
assert_order "moves excess trusted review debt behind ordinary candidates" 6 "1,4,5,6,2,3"
assert_order "retains excess debt for idle-capacity borrowing" 1 "4,5,6,1,2,3"

QUALITY_DEBT_CAP_PCT=100
assert_order "honours an explicit full debt share" 2 "1,2,4,5,6,3"

if [[ "$failures" -ne 0 ]]; then
	exit 1
fi
printf 'All idle debt borrowing tests passed.\n'
exit 0
