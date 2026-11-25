#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# test-postflight-scan-scope.sh — GH#22437 regression guard.
#
# Verifies routine postflight avoids source rescans (including the intentional
# transcript scrubber fixture), while explicit scanning still detects keys.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

TEST_TMP_DIR=''

cleanup() {
	if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
	return 0
}
trap cleanup EXIT

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	return 1
}

require_scanner() {
	if ! command -v secretlint >/dev/null 2>&1; then
		fail 'secretlint not found'
	fi
	return 0
}

test_scrubber_fixture_is_excluded() {
	# Postflight no longer owns a scanner invocation. Reuse the current contract
	# guard instead of running a historical whole-repository Secretlint command.
	if bash "$ROOT_DIR/.agents/scripts/tests/test-postflight-no-source-rescan.sh"; then
		pass 'routine postflight does not scan the transcript scrubber fixture'
		return 0
	fi
	fail 'routine postflight unexpectedly rescans source fixtures'
	return 1
}

test_production_like_private_key_blocks() {
	local private_key_path="$TEST_TMP_DIR/production-like-key"
	local output_path="$TEST_TMP_DIR/scanner.out"

	if ! command -v ssh-keygen >/dev/null 2>&1; then
		fail 'ssh-keygen not found'
	fi

	ssh-keygen -t ed25519 -N '' -f "$private_key_path" >/dev/null 2>&1

	if secretlint "$private_key_path" --secretlintrc .secretlintrc.json --format compact >"$output_path" 2>&1; then
		fail 'production-like private key was not reported by scan'
	fi

	if grep -q '@secretlint/secretlint-rule-privatekey' "$output_path"; then
		pass 'production-like private key remains blocking'
		return 0
	fi

	fail 'scan failed without private-key rule evidence'
}

main() {
	require_scanner
	TEST_TMP_DIR="$(mktemp -d)"
	test_scrubber_fixture_is_excluded
	test_production_like_private_key_blocks
	return 0
}

main "$@"
