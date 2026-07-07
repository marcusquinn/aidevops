#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#26761 and GH#26763 / t2863 pulse prefetch set -u safety.
# The CI failure miner observed repeated Pulse Unbound-Var Lint failures in
# pulse-prefetch-orchestration.sh and pulse-prefetch-repo.sh. The concrete
# declarations were fixed by initialising every variable at declaration time;
# this test keeps those two high-churn prefetch modules in the focused gate.

set -u

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
TEST_REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)"

fail() {
	local message="${1:-}"
	printf '[FAIL] %s\n' "$message" >&2
	return 1
}

pass() {
	local message="${1:-}"
	printf '[PASS] %s\n' "$message"
	return 0
}

main() {
	local bash_bin="${BASH:-bash}"
	local checker="${TEST_REPO_ROOT}/.agents/scripts/pulse-unbound-var-check.sh"
	local orchestration="${TEST_REPO_ROOT}/.agents/scripts/pulse-prefetch-orchestration.sh"
	local repo="${TEST_REPO_ROOT}/.agents/scripts/pulse-prefetch-repo.sh"
	local output=""

	if [[ ! -f "$checker" ]]; then
		fail "pulse unbound-var checker is missing: ${checker}"
		return 1
	fi

	output=$("$bash_bin" "$checker" --scan-files "$orchestration" "$repo" 2>&1) || {
		printf '%s\n' "$output" >&2
		fail "pulse prefetch modules contain uninitialised multi-var locals"
		return 1
	}

	if [[ "$output" != *"No violations found."* ]]; then
		printf '%s\n' "$output" >&2
		fail "pulse unbound-var checker did not report a clean focused scan"
		return 1
	fi

	pass "pulse prefetch modules keep local declarations initialised"
	return 0
}

main "$@"
