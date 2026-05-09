#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../output-sandbox-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export AIDEVOPS_OUTPUT_SANDBOX_DIR="${TMPDIR_TEST}/sandbox"

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

# shellcheck disable=SC2016 # Inner bash expands $i, not this test harness.
run_output=$("$HELPER" run --summary-lines 4 -- bash -c 'for i in 1 2 3 4 5 6; do printf "line%s\n" "$i"; done')
assert_contains "run prints output id" "output_id: out_" "$run_output"
assert_contains "run prints raw path" "raw_path:" "$run_output"
assert_contains "run summarizes omission" "omitted" "$run_output"

output_id=$(printf '%s\n' "$run_output" | awk '/^output_id:/ {print $2; exit}')
show_output=$("$HELPER" show "$output_id" --offset 2 --limit 2)
assert_contains "show returns exact numbered slice" "2: line2" "$show_output"
assert_contains "show respects limit" "3: line3" "$show_output"

sensitive_output=$(printf 'api_key=abcdefghijklmnopqrstuvwxyz123456\n' | "$HELPER" store --command "fixture" --tag secret-test)
assert_contains "sensitive output is flagged" "sensitive_redacted: 1" "$sensitive_output"
sensitive_id=$(printf '%s\n' "$sensitive_output" | awk '/^output_id:/ {print $2; exit}')
sensitive_show=$("$HELPER" show "$sensitive_id" 2>&1 || true)
assert_contains "sensitive value redacted" "[REDACTED]" "$sensitive_show"

bypass_output=$("$HELPER" run -- git diff --no-index /dev/null /dev/null 2>&1 || true)
assert_contains "exact diff bypasses sandbox" "output_sandbox: bypass exact/verbatim command" "$bypass_output"

cleanup_output=$("$HELPER" cleanup --max-age-days 0)
assert_contains "cleanup reports deletion count" "deleted:" "$cleanup_output"

stats_output=$("$HELPER" stats)
assert_contains "stats prints output count" "outputs:" "$stats_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
