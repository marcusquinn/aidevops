#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
VAULT_DEVICE_HELPER="${HELPER_DIR}/vault-device-helper.sh"
TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-device-test)"
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

assert_json_no_private_paths() {
	local name="$1"
	local json_file="$2"
	if grep -q "$TEST_ROOT" "$json_file"; then
		fail "$name"
	else
		pass "$name"
	fi
	return 0
}

export AIDEVOPS_VAULT_DEVICE_DIR="$TEST_ROOT/devices"
export AIDEVOPS_VAULT_DEVICE_STALE_SECONDS="1"

status_output="$($VAULT_DEVICE_HELPER status)"
assert_eq "unenrolled status is deterministic" "unenrolled" "$status_output"

device_id="$($VAULT_DEVICE_HELPER enroll --name runner-one --class laptop --capabilities sync,dispatch,audit)"
case "$device_id" in
dev-*) pass "enroll returns opaque device id" ;;
*) fail "enroll returns opaque device id" ;;
esac

list_file="$TEST_ROOT/list.json"
"$VAULT_DEVICE_HELPER" list --json >"$list_file"
if python3 -m json.tool "$list_file" >/dev/null; then
	pass "device list is valid json"
else
	fail "device list is valid json"
fi
assert_json_no_private_paths "device list omits local private paths" "$list_file"
assert_eq "enrolled device is trusted" "trusted" "$(python3 - "$list_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["devices"][0]["trust_state"])
PY
)"

"$VAULT_DEVICE_HELPER" set-local-status --status locked --generation 2 --vector local:2
"$VAULT_DEVICE_HELPER" heartbeat --active-workers 0 --max-workers 2 >/dev/null
set +e
locked_output="$($VAULT_DEVICE_HELPER can-dispatch --needs-unlocked 2>&1 >/dev/null)"
locked_rc=$?
set -e
assert_nonzero "locked device is not dispatchable for unlocked work" "$locked_rc"
case "$locked_output" in
*DEVICE_LOCKED*) pass "locked-state routing reports DEVICE_LOCKED" ;;
*) fail "locked-state routing reports DEVICE_LOCKED" ;;
esac

"$VAULT_DEVICE_HELPER" set-local-status --status unlocked --generation 3 --vector local:3
"$VAULT_DEVICE_HELPER" heartbeat --active-workers 1 --max-workers 2 >/dev/null
assert_eq "unlocked trusted device can dispatch" "ok" "$($VAULT_DEVICE_HELPER can-dispatch --needs-unlocked)"

set +e
sleep 2
stale_output="$($VAULT_DEVICE_HELPER can-dispatch --needs-unlocked 2>&1 >/dev/null)"
stale_rc=$?
set -e
assert_nonzero "stale heartbeat blocks dispatch" "$stale_rc"
case "$stale_output" in
*HEARTBEAT_STALE*) pass "stale heartbeat has deterministic reason" ;;
*) fail "stale heartbeat has deterministic reason" ;;
esac

"$VAULT_DEVICE_HELPER" heartbeat --active-workers 0 --max-workers 2 >/dev/null
assert_eq "control message accepted before revocation" "ok" "$($VAULT_DEVICE_HELPER verify-control --device-id "$device_id" --grant dispatch)"
"$VAULT_DEVICE_HELPER" revoke --device-id "$device_id" --reason stolen >/dev/null
set +e
revoked_output="$($VAULT_DEVICE_HELPER verify-control --device-id "$device_id" --grant dispatch 2>&1 >/dev/null)"
revoked_rc=$?
set -e
assert_nonzero "revoked sender is rejected" "$revoked_rc"
case "$revoked_output" in
*SENDER_REVOKED*) pass "revoked sender has deterministic reason" ;;
*) fail "revoked sender has deterministic reason" ;;
esac

if [[ -s "$AIDEVOPS_VAULT_DEVICE_DIR/revocation-tasks.jsonl" ]]; then
	pass "revocation queues rotation task"
else
	fail "revocation queues rotation task"
fi

rm -f "$AIDEVOPS_VAULT_DEVICE_DIR/registry.json"
missing_registry_heartbeat="$($VAULT_DEVICE_HELPER heartbeat --active-workers 0 --max-workers 1)"
if [[ -s "$missing_registry_heartbeat" ]]; then
	pass "heartbeat tolerates missing registry"
else
	fail "heartbeat tolerates missing registry"
fi

if [[ "$FAIL" -ne 0 ]]; then
	printf 'FAIL: %s failed, %s passed\n' "$FAIL" "$PASS" >&2
	exit 1
fi

printf 'PASS: all %s vault device helper checks passed\n' "$PASS"
