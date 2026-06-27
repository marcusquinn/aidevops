#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
VAULT_HELPER="${HELPER_DIR}/vault-helper.sh"
TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-test)"
PASS=0
FAIL=0

cleanup() {
	AIDEVOPS_VAULT_DIR="$TEST_ROOT/vault" "$VAULT_HELPER" lock >/dev/null 2>&1 || true
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

run_with_tty() {
	local input="$1"
	shift
	python3 - "$input" "$@" <<'PY'
import os
import pty
import select
import subprocess
import sys
import time

inputs = sys.argv[1].encode().decode("unicode_escape").splitlines()
cmd = sys.argv[2:]
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=subprocess.PIPE, stderr=slave)
os.close(slave)
sent = 0
stderr_chunks = []
deadline = time.time() + 20
while time.time() < deadline:
    reads = [master]
    if proc.stdout is not None:
        reads.append(proc.stdout.fileno())
    ready, _, _ = select.select(reads, [], [], 0.1)
    for fd in ready:
        if fd == master:
            try:
                chunk = os.read(master, 4096)
                stderr_chunks.append(chunk)
                prompt_count = b"".join(stderr_chunks).count(b": ")
                while sent < len(inputs) and sent < prompt_count:
                    os.write(master, (inputs[sent] + "\n").encode())
                    sent += 1
            except OSError:
                pass
        elif proc.stdout is not None:
            proc.stdout.read1(4096)
    if proc.poll() is not None:
        break
if proc.poll() is None:
    proc.terminate()
    proc.wait(timeout=5)
sys.stderr.buffer.write(b''.join(stderr_chunks))
raise SystemExit(proc.returncode)
PY
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		return 0
	fi
	return 1
}

export AIDEVOPS_VAULT_DIR="$TEST_ROOT/vault"
export AIDEVOPS_VAULT_RUNTIME_DIR="$TEST_ROOT/run"

generated_pass="pw-${RANDOM}-$(date +%s)-vault"
wrong_pass="wrong-${RANDOM}-vault"

status_output="$($VAULT_HELPER status 2>/dev/null || true)"
assert_eq "missing metadata reports uninitialized" "uninitialized" "$status_output"

set +e
read_locked_output="$($VAULT_HELPER read sample 2>&1 >/dev/null)"
read_locked_rc=$?
set -e
assert_nonzero "locked read fails closed" "$read_locked_rc"
case "$read_locked_output" in
*VAULT_LOCKED*) pass "locked read has deterministic error" ;;
*) fail "locked read has deterministic error" ;;
esac

set +e
run_with_tty "I UNDERSTAND\n${generated_pass}\n${generated_pass}\n" "$VAULT_HELPER" init >/dev/null 2>"$TEST_ROOT/init.err"
init_rc=$?
set -e
assert_eq "init succeeds through tty prompt" "0" "$init_rc"
assert_eq "init requires restart verification before migration" "restart-required" "$($VAULT_HELPER setup-state)"
if grep -q "$generated_pass" "$TEST_ROOT/init.err"; then
	fail "hidden init prompt does not echo passphrase"
else
	pass "hidden init prompt does not echo passphrase"
fi

if python3 -m json.tool "$AIDEVOPS_VAULT_DIR/vault.json" >/dev/null; then
	pass "metadata parses as json"
else
	fail "metadata parses as json"
fi
if grep -q "$generated_pass" "$AIDEVOPS_VAULT_DIR/vault.json"; then
	fail "metadata omits plaintext passphrase"
else
	pass "metadata omits plaintext passphrase"
fi

set +e
run_with_tty "${wrong_pass}\n" "$VAULT_HELPER" unlock >/dev/null 2>"$TEST_ROOT/wrong.err"
wrong_rc=$?
set -e
assert_nonzero "wrong passphrase fails" "$wrong_rc"
if grep -q "$wrong_pass" "$TEST_ROOT/wrong.err"; then
	fail "wrong passphrase is not printed"
else
	pass "wrong passphrase is not printed"
fi

set +e
printf '%s\n' "$generated_pass" | "$VAULT_HELPER" unlock >/dev/null 2>"$TEST_ROOT/stdin.err"
stdin_rc=$?
set -e
assert_nonzero "unlock refuses non-tty stdin" "$stdin_rc"

set +e
run_with_tty "${generated_pass}\n" "$VAULT_HELPER" unlock >/dev/null 2>"$TEST_ROOT/unlock.err"
unlock_rc=$?
set -e
assert_eq "unlock succeeds through tty prompt" "0" "$unlock_rc"
assert_eq "status reports unlocked" "unlocked" "$($VAULT_HELPER status)"
assert_eq "unlock verifies restart test and enables migration" "migration-ready" "$($VAULT_HELPER setup-state)"

printf 'protected value' | "$VAULT_HELPER" update sample >/dev/null
assert_eq "read returns encrypted entry after unlock" "protected value" "$($VAULT_HELPER read sample)"
broker_pid_file="$AIDEVOPS_VAULT_RUNTIME_DIR/broker.pid"
if [[ -s "$broker_pid_file" ]]; then
	broker_pid="$(sed -n '1p' "$broker_pid_file")"
	kill -9 "$broker_pid" >/dev/null 2>&1 || true
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[[ "$($VAULT_HELPER status 2>/dev/null || true)" == "locked" ]] && break
		sleep 0.2
	done
	assert_eq "broker crash returns Vault to locked state" "locked" "$($VAULT_HELPER status 2>/dev/null || true)"
	set +e
	crash_read_output="$($VAULT_HELPER read sample 2>&1 >/dev/null)"
	crash_read_rc=$?
	set -e
	assert_nonzero "broker crash denies plaintext read" "$crash_read_rc"
	case "$crash_read_output" in
	*VAULT_LOCKED*) pass "broker crash read reports VAULT_LOCKED" ;;
	*) fail "broker crash read reports VAULT_LOCKED" ;;
	esac
else
	fail "broker crash drill has broker pid"
fi
"$VAULT_HELPER" lock >/dev/null
assert_eq "status reports locked after lock" "locked" "$($VAULT_HELPER status)"

cp "$AIDEVOPS_VAULT_DIR/vault.json" "$AIDEVOPS_VAULT_DIR/vault.json.good"
printf '{not-json' >"$AIDEVOPS_VAULT_DIR/vault.json"
set +e
corrupt_status="$($VAULT_HELPER status 2>/dev/null)"
corrupt_rc=$?
set -e
assert_eq "damaged metadata reports corrupted" "corrupted" "$corrupt_status"
assert_nonzero "damaged metadata exits nonzero" "$corrupt_rc"
mv "$AIDEVOPS_VAULT_DIR/vault.json.good" "$AIDEVOPS_VAULT_DIR/vault.json"

printf '\nVault helper test summary: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
