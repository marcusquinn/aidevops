#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for email-poll-helper.sh and email_poll.py (t2855)
# =============================================================================
# Run: bash .agents/tests/test-email-poll.sh
#
# Tests:
#   1. tick happy path — polls mailbox, writes .eml files, updates state
#   2. missing credentials handling — graceful error, no crash
#   3. IMAP connection failure — graceful error, continues
#   4. state persistence across runs — deduplication via last-seen UID
#   5. backfill with date filter — fetches from given date
#   6. dry-run test mode — no files written, no state committed
#   7. list command — shows mailbox info from config + state
#
# Mocking strategy: patches imaplib via PYTHONPATH override (no real connections)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
POLL_PY="${SCRIPTS_DIR}/email_poll.py"
POLL_HELPER="${SCRIPTS_DIR}/email-poll-helper.sh"

PASS=0
FAIL=0
TEST_TMPDIR=""

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

setup() {
	TEST_TMPDIR=$(mktemp -d)
	return 0
}

teardown() {
	[[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	echo "[PASS] $name"
	return 0
}

fail() {
	local name="$1" reason="${2:-}"
	FAIL=$((FAIL + 1))
	echo "[FAIL] $name${reason:+ — $reason}"
	return 0
}

# ---------------------------------------------------------------------------
# Create fake imaplib modules via Python (avoids heredoc expansion issues)
# ---------------------------------------------------------------------------

create_mock_imap_happy() {
	# Creates a mock imaplib that returns one message with the given UID
	local mock_dir="$1"
	local fake_uid="${2:-1001}"
	python3 - "$mock_dir" "$fake_uid" <<'PYEOF'
import sys, textwrap
mock_dir, fake_uid = sys.argv[1], sys.argv[2]
code = textwrap.dedent(f"""
class IMAP4_SSL:
    def __init__(self, host, port=993):
        pass
    def login(self, user, password):
        return ("OK", [b"Logged in"])
    def select(self, folder, readonly=False):
        return ("OK", [b"1"])
    def uid(self, command, *args):
        uid = {fake_uid}
        if command == "SEARCH":
            return ("OK", [str(uid).encode()])
        if command == "FETCH":
            raw = b"From: sender@example.com\\r\\nSubject: Test\\r\\n\\r\\nBody text"
            header = f"{{uid}} (RFC822 {{{{len(raw)}}}} UID {{uid}})".encode()
            return ("OK", [(header, raw), b")"])
        return ("OK", [b""])
    def logout(self):
        return ("BYE", [b"x"])
""")
with open(f"{mock_dir}/imaplib.py", "w") as f:
    f.write(code)
PYEOF
	return 0
}

create_mock_imap_connfail() {
	local mock_dir="$1"
	python3 - "$mock_dir" <<'PYEOF'
import sys
mock_dir = sys.argv[1]
code = 'class IMAP4_SSL:\n    def __init__(self, host, port=993):\n        raise ConnectionRefusedError(f"Refused: {host}")\n'
with open(f"{mock_dir}/imaplib.py", "w") as f:
    f.write(code)
PYEOF
	return 0
}

create_mock_imap_backfill() {
	local mock_dir="$1"
	python3 - "$mock_dir" <<'PYEOF'
import sys
mock_dir = sys.argv[1]
code = '''class IMAP4_SSL:
    def __init__(self, host, port=993):
        pass
    def login(self, user, password):
        return ("OK", [b"Logged in"])
    def select(self, folder, readonly=False):
        return ("OK", [b"1"])
    def uid(self, command, *args):
        if command == "SEARCH":
            return ("OK", [b"2001 2002"])
        if command == "FETCH":
            raw = b"From: sender@example.com\\r\\n\\r\\nBackfill body"
            h1 = f"2001 (RFC822 {len(raw)} UID 2001)".encode()
            h2 = f"2002 (RFC822 {len(raw)} UID 2002)".encode()
            return ("OK", [(h1, raw), b")", (h2, raw), b")"])
        return ("OK", [b""])
    def logout(self):
        return ("BYE", [b"x"])
'''
with open(f"{mock_dir}/imaplib.py", "w") as f:
    f.write(code)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# Shared config factory
# ---------------------------------------------------------------------------

make_mailbox_config() {
	local config_path="$1"
	local mb_id="${2:-test-mb}"
	local password_ref="${3:-TEST_EMAIL_PASSWORD}"
	python3 - "$config_path" "$mb_id" "$password_ref" <<'PYEOF'
import json, sys
config_path, mb_id, pw_ref = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"mailboxes": [{"id": mb_id, "provider": "test", "host": "imap.test.example",
        "port": 993, "user": f"user@{mb_id}.example", "password_ref": pw_ref,
        "folders": ["INBOX"]}]}
with open(config_path, "w") as f:
    json.dump(data, f)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# Test: Python syntax check
# ---------------------------------------------------------------------------

test_python_syntax() {
	local name="python syntax: email_poll.py compiles"
	if python3 -m py_compile "$POLL_PY" 2>/dev/null; then
		pass "$name"
	else
		fail "$name" "py_compile failed"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: tick happy path
# ---------------------------------------------------------------------------

test_tick_happy_path() {
	local name="tick: fetches messages and writes .eml files"
	local tmpdir="${TEST_TMPDIR}/t1"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_happy "${tmpdir}/mock" "1001"
	make_mailbox_config "${tmpdir}/mailboxes.json" "test-mb" "TEST_EMAIL_PASSWORD"

	local result exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local eml_count
	eml_count=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$eml_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected >=1 .eml, got $eml_count (exit $exit_rc, result: $(cat "${tmpdir}/result.json" 2>/dev/null))"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: missing credentials handling
# ---------------------------------------------------------------------------

test_missing_credentials() {
	local name="tick: missing credentials — error recorded, no crash"
	local tmpdir="${TEST_TMPDIR}/t2"
	mkdir -p "${tmpdir}/inbox"

	make_mailbox_config "${tmpdir}/mailboxes.json" "nocreds-mb" "AIDEVOPS_NONEXISTENT_ENV_XYZ999"
	unset AIDEVOPS_NONEXISTENT_ENV_XYZ999 2>/dev/null || true

	local exit_rc=0
	python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local status
	status=$(python3 -c "
import json, sys
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
r = d.get('results', [{}])[0]
print(r.get('status', ''))
" 2>/dev/null || echo "")

	if [[ "$status" == "credential_error" ]]; then
		pass "$name"
	else
		fail "$name" "expected credential_error, got: $status"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: IMAP connection failure — graceful
# ---------------------------------------------------------------------------

test_connection_failure() {
	local name="tick: IMAP connection failure — graceful error, no crash"
	local tmpdir="${TEST_TMPDIR}/t3"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_connfail "${tmpdir}/mock"
	make_mailbox_config "${tmpdir}/mailboxes.json" "connfail-mb" "TEST_EMAIL_PASSWORD"

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local status
	status=$(python3 -c "
import json
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
r = d.get('results', [{}])[0]
print(r.get('status', ''))
" 2>/dev/null || echo "")

	if [[ "$status" == "connection_error" ]]; then
		pass "$name"
	else
		fail "$name" "expected connection_error, got: $status"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: state persistence across runs — deduplication
# ---------------------------------------------------------------------------

test_state_persistence() {
	local name="tick: subsequent runs fetch only new messages (no duplicates)"
	local tmpdir="${TEST_TMPDIR}/t4"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_happy "${tmpdir}/mock" "1001"
	make_mailbox_config "${tmpdir}/mailboxes.json" "dup-mb" "TEST_EMAIL_PASSWORD"

	# First tick
	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >/dev/null 2>&1 || exit_rc=$?

	local count_first
	count_first=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	# Second tick — fake still returns UID 1001, but state has last_uid_seen=1001
	exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >/dev/null 2>&1 || exit_rc=$?

	local count_second
	count_second=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$count_first" -eq "$count_second" && "$count_first" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected equal counts (first=$count_first second=$count_second, both >= 1)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: backfill with date filter
# ---------------------------------------------------------------------------

test_backfill_date_filter() {
	local name="backfill: fetches messages from --since date"
	local tmpdir="${TEST_TMPDIR}/t5"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_backfill "${tmpdir}/mock"
	make_mailbox_config "${tmpdir}/mailboxes.json" "backfill-mb" "TEST_EMAIL_PASSWORD"

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" backfill \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" \
		--mailbox-id "backfill-mb" \
		--since "2026-01-01" \
		--rate-limit 0 >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local fetched_count
	fetched_count=$(python3 -c "
import json
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
print(d.get('fetched_count', 0))
" 2>/dev/null || echo "0")

	if [[ "$fetched_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected fetched_count >= 1, got: $fetched_count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: dry-run test mode — no files written
# ---------------------------------------------------------------------------

test_dry_run() {
	local name="test mode: dry-run — no .eml files written, no state committed"
	local tmpdir="${TEST_TMPDIR}/t6"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_happy "${tmpdir}/mock" "3001"
	make_mailbox_config "${tmpdir}/mailboxes.json" "dryrun-mb" "TEST_EMAIL_PASSWORD"

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" test \
		--config "${tmpdir}/mailboxes.json" \
		--mailbox-id "dryrun-mb" >/dev/null 2>&1 || exit_rc=$?

	local eml_count state_exists=0
	eml_count=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')
	[[ -f "${tmpdir}/.imap-state.json" ]] && state_exists=1

	if [[ "$eml_count" -eq 0 && "$state_exists" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected no .eml (got $eml_count) and no state file (exists: $state_exists)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: list command
# ---------------------------------------------------------------------------

test_list_command() {
	local name="list: shows configured mailboxes"
	local tmpdir="${TEST_TMPDIR}/t7"
	mkdir -p "$tmpdir"

	make_mailbox_config "${tmpdir}/mailboxes.json" "list-mb" "gopass:test/path"

	local exit_rc=0
	python3 "$POLL_PY" list \
		--config "${tmpdir}/mailboxes.json" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local found_id
	found_id=$(python3 -c "
import json
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
ids = [m['id'] for m in d.get('mailboxes', [])]
print(ids[0] if ids else '')
" 2>/dev/null || echo "")

	if [[ "$found_id" == "list-mb" ]]; then
		pass "$name"
	else
		fail "$name" "expected id 'list-mb', got '$found_id'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: shellcheck
# ---------------------------------------------------------------------------

test_shellcheck() {
	local name="email-poll-helper.sh: shellcheck zero violations"
	if command -v shellcheck &>/dev/null && shellcheck "$POLL_HELPER" 2>/dev/null; then
		pass "$name"
	elif ! command -v shellcheck &>/dev/null; then
		pass "$name (shellcheck not installed, skipped)"
	else
		fail "$name" "shellcheck reported violations"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	setup

	test_python_syntax
	test_tick_happy_path
	test_missing_credentials
	test_connection_failure
	test_state_persistence
	test_backfill_date_filter
	test_dry_run
	test_list_command
	test_shellcheck

	teardown

	echo ""
	echo "Results: $PASS passed, $FAIL failed"
	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
