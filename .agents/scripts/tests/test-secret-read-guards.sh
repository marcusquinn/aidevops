#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

test_opencode_guard_blocks_private_key_paths() {
	local output
	set +e
	output=$(node --input-type=module <<'NODE' 2>&1
import { secretReadBlockReason } from './.agents/plugins/opencode-aidevops/quality-hooks-secret-read.mjs';
if (!secretReadBlockReason('/tmp/.ssh/id_ed25519')) process.exit(1);
if (!secretReadBlockReason('/tmp/private.pem')) process.exit(2);
if (secretReadBlockReason('/tmp/id_ed25519.pub')) process.exit(3);
if (!secretReadBlockReason('/home/test/.config/opencode/opencode.json')) process.exit(4);
if (!secretReadBlockReason('/home/test/.config/opencode/opencode.jsonc')) process.exit(5);
if (secretReadBlockReason('/workspace/opencode.json')) process.exit(6);
if (secretReadBlockReason('/home/test/.config/opencode/AGENTS.md')) process.exit(7);
NODE
)
	local rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		pass "opencode guard blocks keys and host runtime config without blocking safe OpenCode files"
	else
		fail "opencode guard blocks keys and host runtime config without blocking safe OpenCode files" "exit=$rc output=$output"
	fi
	return 0
}

test_claude_guard_denies_read_payload() {
	local output
	output=$(printf '%s' '{"tool_name":"Read","tool_input":{"filePath":"/tmp/id_rsa"}}' | python3 "$REPO_DIR/.agents/hooks/secret_file_read_guard.py")
	if [[ "$output" == *'"permissionDecision": "deny"'* ]]; then
		pass "claude guard denies private-key read payload"
	else
		fail "claude guard denies private-key read payload" "$output"
	fi
	return 0
}

test_claude_guard_allows_public_key_payload() {
	local output
	output=$(printf '%s' '{"tool_name":"Read","tool_input":{"filePath":"/tmp/id_rsa.pub"}}' | python3 "$REPO_DIR/.agents/hooks/secret_file_read_guard.py")
	if [[ -z "$output" ]]; then
		pass "claude guard allows public-key read payload"
	else
		fail "claude guard allows public-key read payload" "$output"
	fi
	return 0
}

test_transcript_scrub_redacts_pem_blocks() {
	local payload output
	payload='{"tool_response":"before -----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY----- after"}'
	output=$(printf '%s' "$payload" | python3 "$REPO_DIR/.agents/hooks/credential-transcript-scrub.py")
	if [[ "$output" == *'[redacted-private-key]'* ]] && [[ "$output" != *'fake'* ]]; then
		pass "transcript scrub redacts private-key PEM blocks"
	else
		fail "transcript scrub redacts private-key PEM blocks" "$output"
	fi
	return 0
}

test_privacy_helper_detects_secret_material() {
	# shellcheck source=/dev/null
	source "$REPO_DIR/.agents/scripts/privacy-guard-helper.sh"
	local output
	set +e
	output=$(privacy_scan_secret_material_text $'-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----')
	local rc=$?
	set -e
	if [[ "$rc" -eq 1 && "$output" == *"private-key PEM block"* ]]; then
		pass "privacy helper detects private-key material"
	else
		fail "privacy helper detects private-key material" "exit=$rc output=$output"
	fi
	return 0
}

test_privacy_helper_detects_secret_material_diff() {
	# shellcheck source=/dev/null
	source "$REPO_DIR/.agents/scripts/privacy-guard-helper.sh"
	local tmp old_pwd output rc
	tmp=$(mktemp -d)
	old_pwd=$(pwd)
	trap 'cd "$old_pwd"; rm -rf "$tmp"' RETURN
	cd "$tmp"
	git init -q
	git config user.email test@example.invalid
	git config user.name Test
	git config commit.gpgsign false
	printf 'safe\n' >sample.txt
	git add sample.txt
	git commit -q -m init
	local base
	base=$(git rev-parse HEAD)
	printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'fake' '-----END PRIVATE KEY-----' >leak.txt
	git add leak.txt
	git commit -q -m leak
	set +e
	output=$(privacy_scan_secret_material_diff "$base" HEAD)
	rc=$?
	set -e
	cd "$old_pwd"
	rm -rf "$tmp"
	trap - RETURN
	if [[ "$rc" -eq 1 && "$output" == *"leak.txt"* && "$output" == *"private-key PEM block"* ]]; then
		pass "privacy diff scan detects private-key material for pre-push"
	else
		fail "privacy diff scan detects private-key material for pre-push" "exit=$rc output=$output"
	fi
	return 0
}

main() {
	test_opencode_guard_blocks_private_key_paths
	test_claude_guard_denies_read_payload
	test_claude_guard_allows_public_key_payload
	test_transcript_scrub_redacts_pem_blocks
	test_privacy_helper_detects_secret_material
	test_privacy_helper_detects_secret_material_diff

	printf '\nTests passed: %d\nTests failed: %d\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]]
	return $?
}

main "$@"
