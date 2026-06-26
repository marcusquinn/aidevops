#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_DIR="${SCRIPT_DIR}/.."
VAULT_HELPER="${HELPER_DIR}/vault-helper.sh"
TEST_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-setup-test)"
PASS=0
FAIL=0

cleanup() {
	AIDEVOPS_VAULT_DIR="$TEST_ROOT/vault" AIDEVOPS_VAULT_RUNTIME_DIR="$TEST_ROOT/run" "$VAULT_HELPER" lock >/dev/null 2>&1 || true
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

strong_pass="vault-${RANDOM}-$(date +%s)-strong"

set +e
run_with_tty "I UNDERSTAND\nshort\nshort\n" "$VAULT_HELPER" init >/dev/null 2>"$TEST_ROOT/weak.err"
weak_rc=$?
set -e
assert_nonzero "first-use setup rejects passphrases shorter than 12 characters" "$weak_rc"

set +e
run_with_tty "I UNDERSTAND\n${strong_pass}\n${strong_pass}\n" "$VAULT_HELPER" init >/dev/null 2>"$TEST_ROOT/init.err"
init_rc=$?
set -e
assert_eq "first-use setup succeeds with acknowledgement and strong passphrase" "0" "$init_rc"
assert_eq "setup creates restart-required state" "restart-required" "$($VAULT_HELPER setup-state)"

set +e
printf 'real data' | "$VAULT_HELPER" update real-entry >/dev/null 2>"$TEST_ROOT/preverify.err"
preverify_rc=$?
set -e
assert_nonzero "real data migration is unavailable before restart unlock" "$preverify_rc"

set +e
run_with_tty "${strong_pass}\n" "$VAULT_HELPER" unlock >/dev/null 2>"$TEST_ROOT/unlock.err"
unlock_rc=$?
set -e
assert_eq "fresh unlock verifies harmless test record" "0" "$unlock_rc"
assert_eq "restart verification reaches migration-ready" "migration-ready" "$($VAULT_HELPER setup-state)"

printf 'real data' | "$VAULT_HELPER" update real-entry >/dev/null
assert_eq "real data update succeeds after restart verification" "real data" "$($VAULT_HELPER read real-entry)"
"$VAULT_HELPER" lock >/dev/null

"$VAULT_HELPER" lost-passphrase archive-and-start-fresh >/dev/null
assert_eq "archive flow resets active setup" "uninitialized" "$($VAULT_HELPER setup-state 2>/dev/null || true)"

archive_count=0
archive_dir=""
for candidate in "$AIDEVOPS_VAULT_DIR"/archives/lost-passphrase-*; do
	if [[ -d "$candidate" ]]; then
		archive_count=$((archive_count + 1))
		archive_dir="$candidate"
	fi
done
assert_eq "archive flow preserves one encrypted archive directory" "1" "$archive_count"
if [[ -f "$archive_dir/vault.json" && -f "$archive_dir/vault-store.json" && -f "$archive_dir/README.txt" ]]; then
	pass "archive flow keeps encrypted metadata, store, and recovery README"
else
	fail "archive flow keeps encrypted metadata, store, and recovery README"
fi
if grep -q "$strong_pass" "$archive_dir/README.txt" "$archive_dir/vault.json" "$archive_dir/vault-store.json" 2>/dev/null; then
	fail "archive files do not contain plaintext passphrase"
else
	pass "archive files do not contain plaintext passphrase"
fi

set +e
"$VAULT_HELPER" export >/dev/null 2>"$TEST_ROOT/export.err"
export_rc=$?
"$VAULT_HELPER" import >/dev/null 2>"$TEST_ROOT/import.err"
import_rc=$?
"$VAULT_HELPER" rekey >/dev/null 2>"$TEST_ROOT/rekey.err"
rekey_rc=$?
set -e
assert_nonzero "export placeholder fails safely" "$export_rc"
assert_nonzero "import placeholder fails safely" "$import_rc"
assert_nonzero "rekey placeholder fails safely" "$rekey_rc"

printf '\nVault setup flow test summary: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
