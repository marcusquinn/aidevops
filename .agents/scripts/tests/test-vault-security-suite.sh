#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-security-suite)"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	printf 'FAIL: %s\n' "$name" >&2
	FAIL=$((FAIL + 1))
	return 0
}

run_child_test() {
	local name="$1"
	local path="$2"
	if bash "$path"; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

test_no_public_plaintext_fixtures() {
	local public_scan="$TEST_ROOT/public-scan.out"
	if git -C "$REPO_ROOT" grep -n -E 'BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|vault passphrase|recovery key' -- \
		'.agents/scripts/tests/test-vault*.sh' '.agents/reference/vault-security-review.md' >"$public_scan" 2>/dev/null; then
		printf 'Plaintext secret-like fixture matches:\n' >&2
		sed -n '1,80p' "$public_scan" >&2 || true
		fail "Vault security fixtures avoid plaintext secret material"
	else
		pass "Vault security fixtures avoid plaintext secret material"
	fi
	return 0
}

run_child_test "vault helper local broker and wrong-passphrase tests" "$SCRIPT_DIR/test-vault-helper.sh"
run_child_test "vault data migration locked-state tests" "$SCRIPT_DIR/test-vault-data-migration.sh"
run_child_test "vault sync replay, tamper, revoked-device tests" "$SCRIPT_DIR/test-vault-sync-helper.sh"
run_child_test "vault remote lock, replay, stale-grant tests" "$SCRIPT_DIR/test-vault-remote-control-helper.sh"
run_child_test "vault message ciphertext and revoked-device tests" "$SCRIPT_DIR/test-vault-message-helper.sh"
run_child_test "vault audit tamper and receipt tests" "$SCRIPT_DIR/test-vault-audit-helper.sh"
test_no_public_plaintext_fixtures

printf '\nVault security suite summary: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
