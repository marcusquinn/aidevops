#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
MIGRATION_HELPER="${HELPER_DIR}/vault-migration-helper.sh"
MEMORY_HELPER="${HELPER_DIR}/memory-helper.sh"
EMBEDDINGS_HELPER="${HELPER_DIR}/memory-embeddings-helper.sh"
TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-migration-test)"
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

assert_nonzero() {
	local name="$1"
	local rc="$2"
	if [[ "$rc" -ne 0 ]]; then
		pass "$name"
	else
		fail "$name"
	fi
	return 0
}

write_mock_vault_helper() {
	local path="$1"
	mkdir -p "$(dirname "$path")"
	cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
store_dir="${MOCK_VAULT_STORE_DIR:?}"
state_file="${MOCK_VAULT_STATE_FILE:?}"
command="${1:-status}"
shift || true
case "$command" in
status)
	cat "$state_file"
	;;
update)
	name="${1:?}"
	mkdir -p "$store_dir"
	cat >"${store_dir}/${name//\//_}"
	;;
read)
	name="${1:?}"
	cat "${store_dir}/${name//\//_}"
	;;
*) exit 2 ;;
esac
MOCK
	chmod +x "$path"
	return 0
}

export AIDEVOPS_VAULT_REQUIRE=1
export AIDEVOPS_MEMORY_DIR="$TEST_ROOT/memory"
export AIDEVOPS_VAULT_MIGRATION_ROOT="$TEST_ROOT/workspace"
export AIDEVOPS_VAULT_MIGRATION_MANIFEST_DIR="$TEST_ROOT/manifest"
export MOCK_VAULT_STORE_DIR="$TEST_ROOT/mock-store"
export MOCK_VAULT_STATE_FILE="$TEST_ROOT/mock-state"
export AIDEVOPS_VAULT_HELPER="$TEST_ROOT/bin/mock-vault-helper.sh"
write_mock_vault_helper "$AIDEVOPS_VAULT_HELPER"

printf '%s\n' locked >"$MOCK_VAULT_STATE_FILE"

set +e
locked_output="$($MEMORY_HELPER recall --query test 2>&1 >/dev/null)"
locked_rc=$?
set -e
assert_nonzero "locked memory recall fails closed" "$locked_rc"
case "$locked_output" in
*VAULT_LOCKED*) pass "locked memory recall reports VAULT_LOCKED" ;;
*) fail "locked memory recall reports VAULT_LOCKED" ;;
esac

set +e
embeddings_output="$($EMBEDDINGS_HELPER status 2>&1 >/dev/null)"
embeddings_rc=$?
set -e
assert_nonzero "locked embeddings status fails closed" "$embeddings_rc"
case "$embeddings_output" in
*VAULT_LOCKED*) pass "locked embeddings status reports VAULT_LOCKED" ;;
*) fail "locked embeddings status reports VAULT_LOCKED" ;;
esac

mkdir -p "$AIDEVOPS_VAULT_MIGRATION_ROOT/memory" "$AIDEVOPS_VAULT_MIGRATION_ROOT/knowledge/sources/a"
printf '%s' 'memory plaintext' >"$AIDEVOPS_VAULT_MIGRATION_ROOT/memory/memory.db"
printf '%s' 'knowledge plaintext' >"$AIDEVOPS_VAULT_MIGRATION_ROOT/knowledge/sources/a/source.md"

plan_path="$($MIGRATION_HELPER plan)"
if grep -q 'memory.db' "$plan_path" && grep -q 'source.md' "$plan_path"; then
	pass "plan records memory and knowledge files"
else
	fail "plan records memory and knowledge files"
fi

set +e
$MIGRATION_HELPER migrate >/dev/null 2>"$TEST_ROOT/locked-migrate.err"
migrate_locked_rc=$?
set -e
assert_nonzero "locked migration fails before plaintext removal" "$migrate_locked_rc"
if [[ -f "$AIDEVOPS_VAULT_MIGRATION_ROOT/memory/memory.db" ]]; then
	pass "locked migration preserves plaintext source"
else
	fail "locked migration preserves plaintext source"
fi

printf '%s\n' unlocked >"$MOCK_VAULT_STATE_FILE"
$MIGRATION_HELPER migrate
$MIGRATION_HELPER verify
if [[ ! -f "$AIDEVOPS_VAULT_MIGRATION_ROOT/memory/memory.db" ]]; then
	pass "verified migration removes plaintext memory db"
else
	fail "verified migration removes plaintext memory db"
fi
if grep -q 'verified-scrubbed' "$plan_path"; then
	pass "manifest records verified scrub state"
else
	fail "manifest records verified scrub state"
fi

$MIGRATION_HELPER rollback
assert_eq "rollback restores memory content" "memory plaintext" "$(cat "$AIDEVOPS_VAULT_MIGRATION_ROOT/memory/memory.db")"

if [[ "$FAIL" -ne 0 ]]; then
	printf 'FAILED: %s failures, %s passes\n' "$FAIL" "$PASS" >&2
	exit 1
fi
printf 'OK: %s assertions passed\n' "$PASS"
