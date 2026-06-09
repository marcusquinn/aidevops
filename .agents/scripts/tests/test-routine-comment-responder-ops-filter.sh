#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected NOT to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_equals() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual: $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== routine-comment-responder ops/audit filter regression ==="
echo ""

TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d -t routine-comments)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

STUB_DIR="${TMPDIR_TEST}/stub-bin"
mkdir -p "$STUB_DIR"

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	printf '%s\n' 'maintainer'
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '%s\n' '42'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/42/comments" ]]; then
	cat <<'JSON'
{"id":101,"author":"maintainer","is_bot":false,"created":"2026-01-01T00:00:00Z","body":"<!-- routine-description -->\nRoutine dashboard"}
{"id":102,"author":"maintainer","is_bot":false,"created":"2026-01-01T00:01:00Z","body":"DISPATCH_CLAIM worker=abc"}
{"id":103,"author":"maintainer","is_bot":false,"created":"2026-01-01T00:02:00Z","body":"CLAIM_RELEASED reason=worker_failed"}
{"id":104,"author":"maintainer","is_bot":false,"created":"2026-01-01T00:03:00Z","body":"## Cascade Tier Escalation\nEscalating worker"}
{"id":105,"author":"maintainer","is_bot":false,"created":"2026-01-01T00:04:00Z","body":"<!-- ops: pulse audit -->"}
{"id":107,"author":"maintainer","is_bot":false,"created":"2026-01-01T00:04:30Z","body":"Can this be clarified?\nBLOCKED by missing context"}
{"id":108,"author":"user","is_bot":false,"created":"2026-01-01T00:04:45Z"}
{"id":106,"author":"user","is_bot":false,"created":"2026-01-01T00:05:00Z","body":"Can this routine run hourly?"}
JSON
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "repos/owner/repo/issues/42/comments/999" ]]; then
	printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
	exit 1
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "${STUB_DIR}/gh"

export PATH="${STUB_DIR}:$PATH"
export ROUTINE_COMMENT_STATE_DIR="${TMPDIR_TEST}/state"
export ROUTINE_COMMENT_LOGFILE="${TMPDIR_TEST}/responder.log"
mkdir -p "$ROUTINE_COMMENT_STATE_DIR"

scan_output=$(bash "${PARENT_DIR}/routine-comment-responder.sh" scan "owner/repo" "$TMPDIR_TEST")
assert_contains "real user question emitted" "42|106|user|Can this routine run hourly?" "$scan_output"
assert_contains "missing body normalized" "42|108|user|" "$scan_output"
assert_contains "multiline non-ops owner comment emitted" "42|107|maintainer|Can this be clarified?" "$scan_output"
assert_not_contains "CLAIM_RELEASED ignored" "103|" "$scan_output"
assert_not_contains "cascade escalation ignored" "104|" "$scan_output"
assert_not_contains "ops marker ignored" "105|" "$scan_output"

if ROUTINE_COMMENT_LOGFILE="$ROUTINE_COMMENT_LOGFILE" ROUTINE_COMMENT_STATE_DIR="$ROUTINE_COMMENT_STATE_DIR" bash -c 'source "$1"; _is_routine_ops_comment $'"'"'Can this be clarified?\nBLOCKED by missing context'"'"'' bash "${PARENT_DIR}/routine-comment-responder.sh"; then
	assert_equals "multiline helper does not match later marker" "non-ops" "ops"
else
	assert_equals "multiline helper does not match later marker" "non-ops" "non-ops"
fi

bash "${PARENT_DIR}/routine-comment-responder.sh" dispatch "owner/repo" "$TMPDIR_TEST" 42 999
bash "${PARENT_DIR}/routine-comment-responder.sh" dispatch "owner/repo" "$TMPDIR_TEST" 42 999

responded_file="${ROUTINE_COMMENT_STATE_DIR}/owner_repo_responded.txt"
responded_count=$(grep -c '^999$' "$responded_file" || true)
assert_equals "missing comment recorded once" "1" "$responded_count"

already_count=$(grep -c 'already responded to' "$ROUTINE_COMMENT_LOGFILE" || true)
assert_equals "second dispatch skipped from state" "1" "$already_count"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
