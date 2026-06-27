#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
PASS=0
FAIL=0

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

assert_file_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	if grep -Eq "$pattern" "${ROOT_DIR}/${file}"; then
		pass "$name"
	else
		printf '  missing pattern: %s in %s\n' "$pattern" "$file" >&2
		fail "$name"
	fi
	return 0
}

assert_file_contains "vault agent exists" ".agents/vault.md" '^name: vault$'
assert_file_contains "vault agent points to setup workflow" ".agents/vault.md" 'workflows/vault-setup\.md'
assert_file_contains "vault agent refuses passphrase in chat" ".agents/vault.md" 'never request, accept, log, store, or repeat passphrases'
assert_file_contains "command docs describe hidden prompt" ".agents/scripts/commands/vault.md" 'hidden prompt'
assert_file_contains "command docs include dispatch metadata" ".agents/scripts/commands/vault.md" 'needs_vault:'
assert_file_contains "AGENTS pointer includes Vault" ".agents/AGENTS.md" 'Vault/security setup'
assert_file_contains "routing table includes Vault" ".agents/reference/agent-routing.md" '\| Vault \|'
assert_file_contains "domain index includes Vault" ".agents/reference/domain-index.md" 'Vault/Protected Data'
assert_file_contains "setup workflow includes questioning" ".agents/workflows/vault-setup.md" 'Setup intake questions'
assert_file_contains "fleet workflow includes management questions" ".agents/workflows/vault-fleet.md" 'Fleet management questions'

printf '\nVault agent guidance test summary: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
