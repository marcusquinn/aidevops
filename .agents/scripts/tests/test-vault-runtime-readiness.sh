#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
VAULT_HELPER="${HELPER_DIR}/vault-helper.sh"
TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-runtime-readiness)"
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

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
	else
		printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
		fail "$name"
	fi
	return 0
}

export AIDEVOPS_VAULT_DIR="${TEST_ROOT}/vault"
export AIDEVOPS_VAULT_RUNTIME_DIR="${TEST_ROOT}/run"
AIDEVOPS_VAULT_PYTHON="$(command -v python3)"
export AIDEVOPS_VAULT_PYTHON

set +e
initial_status="$($VAULT_HELPER status 2>"${TEST_ROOT}/initial.err")"
initial_rc=$?
set -e
assert_eq "dependency-free status reports uninitialized" "uninitialized" "$initial_status"
assert_eq "uninitialized status preserves documented exit" "2" "$initial_rc"
[[ ! -e "${AIDEVOPS_VAULT_DIR}/audit.log" ]] && pass "status read creates no audit file" || fail "status read creates no audit file"

mkdir -p "$AIDEVOPS_VAULT_DIR"
cat >"${AIDEVOPS_VAULT_DIR}/vault.json" <<'JSON'
{
  "schema_version": 1,
  "setup_state": "migration-ready",
  "kdf": {"name": "scrypt", "salt": "fixture", "params": {}},
  "wrapped_root_key": {}
}
JSON

assert_eq "metadata-only status reports locked" "locked" "$($VAULT_HELPER status)"
assert_eq "metadata-only setup state is readable" "migration-ready" "$($VAULT_HELPER setup-state)"
[[ ! -e "${AIDEVOPS_VAULT_DIR}/audit.log" ]] && pass "metadata reads remain audit side-effect free" || fail "metadata reads remain audit side-effect free"

missing_code=$(python3 -S - "$HELPER_DIR" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from vault_crypto_core import VaultError, _crypto_primitives

try:
    _crypto_primitives()
except VaultError as exc:
    print(exc.code)
    raise SystemExit(0)
raise SystemExit(1)
PY
)
assert_eq "missing crypto emits stable redacted class" "VAULT_DEPENDENCY_MISSING" "$missing_code"

if grep -q '^cryptography==49\.0\.0$' "${REPO_ROOT}/.agents/configs/vault-requirements.txt" &&
	grep -q 'setup_vault_python_env' "${REPO_ROOT}/setup.sh"; then
	pass "setup wires the exact-pinned Vault runtime"
else
	fail "setup wires the exact-pinned Vault runtime"
fi

printf '\nVault runtime readiness summary: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
