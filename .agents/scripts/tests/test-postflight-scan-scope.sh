#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# test-postflight-scan-scope.sh — GH#22437 regression guard.
#
# Verifies the postflight scan excludes the intentional transcript scrubber
# fixture without disabling blocking detection for production-like files.

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

postflight_scan_targets() {
	secretlint \
		"**/*" \
		"!.agents/scripts/tests/test-credential-transcript-scrub.sh" \
		--secretlintrc .secretlintrc.json \
		--secretlintignore .secretlintignore \
		--format compact >/tmp/postflight-scan-fixture.out 2>&1
	return $?
}

test_scrubber_fixture_is_excluded() {
	if postflight_scan_targets; then
		pass 'postflight scan ignores transcript scrubber fixture'
		return 0
	fi
	fail 'postflight scan reported the transcript scrubber fixture'
}

test_production_like_private_key_blocks() {
	TEST_TMP_DIR="$(mktemp -d "$ROOT_DIR/postflight-scan.XXXXXX")"
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
	test_scrubber_fixture_is_excluded
	test_production_like_private_key_blocks
	return 0
}

main "$@"
