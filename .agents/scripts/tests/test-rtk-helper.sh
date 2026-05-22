#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../rtk-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected ${needle}"
	fi
	return 0
}

cat >"${TMPDIR_TEST}/rtk" <<'STUB'
#!/usr/bin/env bash
printf '[rtk] /!\ No hook installed — run `rtk init -g` for automatic token savings\n'
if [[ "${1:-}" == "fail" ]]; then
  printf 'failure body\n'
  exit 7
fi
if [[ "${1:-}" == "samplecmd" ]]; then
  printf 'short\n'
  exit 0
fi
printf 'payload: %s\n' "$*"
STUB
chmod +x "${TMPDIR_TEST}/rtk"

cat >"${TMPDIR_TEST}/samplecmd" <<'STUB'
#!/usr/bin/env bash
printf 'long raw payload with extra diagnostic detail\n'
STUB
chmod +x "${TMPDIR_TEST}/samplecmd"

cat >"${TMPDIR_TEST}/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" ]]; then
  printf 'raw git status\n'
  exit 0
fi
printf 'git %s\n' "$*"
STUB
chmod +x "${TMPDIR_TEST}/git"

session_db="${TMPDIR_TEST}/opencode.db"
python3 - "$session_db" <<'PY'
import json
import sqlite3
import sys

db = sys.argv[1]
conn = sqlite3.connect(db)
conn.execute("create table session (id text primary key, title text, time_created integer)")
conn.execute("create table part (id text primary key, session_id text, time_created integer, data text)")
now = 1778340000000
conn.execute("insert into session values ('s1', 'adoption test', ?)", (now,))
commands = [
    "rtk-helper.sh gh issue list --repo owner/repo --limit 5",
    "gh issue list --repo owner/repo --limit 5",
    "gh pr list --repo owner/repo --json number,title",
]
for idx, command in enumerate(commands):
    data = {"type": "tool", "tool": "bash", "state": {"input": {"command": command}}}
    conn.execute("insert into part values (?, 's1', ?, ?)", (f"p{idx}", now + idx, json.dumps(data)))
conn.commit()
PY

PATH="${TMPDIR_TEST}:$PATH" output=$("$HELPER" git status)
assert_not_contains "strips no-hook advisory" "No hook installed" "$output"
assert_contains "preserves useful output" "payload: git status" "$output"

set +e
PATH="${TMPDIR_TEST}:$PATH" fail_output=$("$HELPER" fail 2>&1)
fail_rc=$?
set -e
if [[ "$fail_rc" -eq 7 ]]; then
	pass "preserves rtk exit code"
else
	fail "preserves rtk exit code" "got ${fail_rc}"
fi
assert_contains "preserves failure output" "failure body" "$fail_output"
assert_not_contains "strips advisory on failure" "No hook installed" "$fail_output"

PATH="${TMPDIR_TEST}:$PATH" compare_output=$("$HELPER" --compare samplecmd)
assert_contains "compare emits diagnostic heading" "RTK output comparison" "$compare_output"
assert_contains "compare records same exit code" "Same exit code: yes" "$compare_output"
assert_contains "compare emits decision guidance" "Decision guidance" "$compare_output"
assert_not_contains "compare strips advisory" "No hook installed" "$compare_output"

PATH="${TMPDIR_TEST}:$PATH" git_status_compare_output=$("$HELPER" --compare git status)
assert_contains "git status compare flags upstream compact fix" "drops \`-uall\`" "$git_status_compare_output"

export OPENCODE_DB_PATH="$session_db"
adoption_output=$("$HELPER" --adoption-report "2026-05-08 00:00:00")
unset OPENCODE_DB_PATH
assert_contains "adoption report heading" "RTK adoption report" "$adoption_output"
assert_contains "adoption counts rtk helper" "| RTK helper calls | 1 |" "$adoption_output"
raw_eligible_needle="Raw eligible \`gh issue/pr list\` calls | 1"
assert_contains "adoption counts raw eligible" "$raw_eligible_needle" "$adoption_output"
assert_contains "adoption counts structured bypass" "| Structured/exact list bypasses | 1 |" "$adoption_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
