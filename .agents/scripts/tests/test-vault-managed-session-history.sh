#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../vault-managed-session-history-helper.sh"
RUNTIME_REGISTRY="${SCRIPT_DIR}/../runtime-registry.sh"
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

if [[ ! -x "$HELPER" ]]; then
	printf 'FAIL: helper not executable at %s\n' "$HELPER" >&2
	exit 1
fi

# shellcheck source=.agents/scripts/runtime-registry.sh
source "$RUNTIME_REGISTRY"

if rt_validate_registry; then
	pass "runtime registry arrays remain aligned"
else
	fail "runtime registry arrays remain aligned"
fi

assert_eq "OpenCode mode is managed" "managed" "$(rt_vault_session_history_mode opencode)"
assert_eq "Claude Code mode is managed" "managed" "$(rt_vault_session_history_mode claude-code)"
assert_eq "Amp mode is external" "external" "$(rt_vault_session_history_mode amp)"

TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-managed-history)"
cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

export AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY=1
export AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT="$TEST_ROOT/managed-history"

set +e
locked_output="$(AIDEVOPS_VAULT_STATUS_OVERRIDE=locked "$HELPER" require-read opencode 2>&1 >/dev/null)"
locked_rc=$?
set -e
assert_nonzero "locked managed read fails closed" "$locked_rc"
case "$locked_output" in
*VAULT_LOCKED*) pass "locked denial has deterministic marker" ;;
*) fail "locked denial has deterministic marker" ;;
esac

unlocked_path="$(AIDEVOPS_VAULT_STATUS_OVERRIDE=unlocked "$HELPER" require-read opencode)"
assert_eq "unlocked OpenCode read resolves broker path" "$TEST_ROOT/managed-history/opencode/opencode.db" "$unlocked_path"

claude_path="$(AIDEVOPS_VAULT_STATUS_OVERRIDE=unlocked "$HELPER" require-read claude-code)"
assert_eq "unlocked Claude read resolves broker path" "$TEST_ROOT/managed-history/claude-code/projects" "$claude_path"

set +e
unsupported_output="$(AIDEVOPS_VAULT_STATUS_OVERRIDE=unlocked "$HELPER" require-read codex 2>&1 >/dev/null)"
unsupported_rc=$?
set -e
assert_eq "unsupported runtime returns policy rc" "2" "$unsupported_rc"
case "$unsupported_output" in
*VAULT_UNSUPPORTED_RUNTIME*) pass "unsupported runtime warns explicitly" ;;
*) fail "unsupported runtime warns explicitly" ;;
esac

unset AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY
default_path="$(HOME="$TEST_ROOT/home" "$HELPER" require-read opencode)"
assert_eq "disabled managed history keeps default runtime path" "$TEST_ROOT/home/.local/share/opencode/opencode.db" "$default_path"

printf '\nVault managed session/history tests: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
