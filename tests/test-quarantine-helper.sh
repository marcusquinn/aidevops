#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2317

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUARANTINE_HELPER="${REPO_DIR}/.agents/scripts/quarantine-helper.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf "PASS %s\n" "$message"
	return 0
}

fail() {
	local message="$1"
	local details="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf "FAIL %s\n" "$message"
	if [[ -n "$details" ]]; then
		printf "  %s\n" "$details"
	fi
	return 0
}

cleanup() {
	if [[ -n "${TEST_HOME:-}" ]] && [[ -d "$TEST_HOME" ]]; then
		rm -rf "$TEST_HOME"
	fi
	return 0
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP jq is required for quarantine stats checks"
	exit 0
fi

if bash -n "$QUARANTINE_HELPER" 2>/dev/null; then
	pass "quarantine-helper.sh passes bash -n"
else
	fail "quarantine-helper.sh has syntax errors"
fi

TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
mkdir -p "$HOME/.aidevops/.agent-workspace/security/quarantine"

reviewed_file="$HOME/.aidevops/.agent-workspace/security/quarantine/reviewed.jsonl"

printf '{"id":"q1","timestamp":"2026-01-01T00:00:00Z"}\n' >"$reviewed_file"

stats_output="$(bash "$QUARANTINE_HELPER" stats 2>&1 || true)"
if printf '%s\n' "$stats_output" | grep -qE 'False positive rate:[[:space:]]+0%'; then
	pass "stats keeps false-positive rate safe at 0 when no decisions exist"
else
	fail "stats did not report 0% false-positive rate for decisionless records" "$stats_output"
fi

printf '{"id":"q2","decision":"dismiss"}\n{"id":"q3","decision":"allow"}\n' >"$reviewed_file"

stats_output="$(bash "$QUARANTINE_HELPER" stats 2>&1 || true)"
if printf '%s\n' "$stats_output" | grep -qE 'False positive rate:[[:space:]]+50%'; then
	pass "stats computes false-positive rate from reviewed decisions"
else
	fail "stats did not report expected 50% false-positive rate" "$stats_output"
fi

echo ""
printf "Passed: %s\n" "$PASS_COUNT"
printf "Failed: %s\n" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi

exit 0
