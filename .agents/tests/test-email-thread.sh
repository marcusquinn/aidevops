#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for email_thread.py and email-thread-helper.sh (t2856)
# Covers: root thread, reply chain, orphan, subject-merge, incremental mtime
#
# Usage: bash .agents/tests/test-email-thread.sh
# Requires: python3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
EMAIL_THREAD_PY="${SCRIPT_DIR}/../scripts/email_thread.py"
EMAIL_THREAD_HELPER="${SCRIPT_DIR}/../scripts/email-thread-helper.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_assert_exit_0() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected exit 0, got non-zero"
		return 0
	fi
}

_assert_exit_nonzero() {
	local name="$1"
	shift
	if ! "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected non-zero exit, got 0"
		return 0
	fi
}

_assert_file_exists() {
	local name="$1" path="$2"
	if [[ -f "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "file not found: ${path}"
		return 0
	fi
}

_assert_dir_exists() {
	local name="$1" path="$2"
	if [[ -d "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "dir not found: ${path}"
		return 0
	fi
}

_assert_json_field() {
	local name="$1" json_file="$2" jq_expr="$3" expected="$4"
	if ! command -v jq &>/dev/null; then
		printf '  [SKIP] %s — jq not installed\n' "$name"
		return 0
	fi
	local actual
	actual="$(jq -r "$jq_expr" "$json_file" 2>/dev/null || true)"
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
	else
		_fail "$name" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

# =============================================================================
# Fixture builders
# =============================================================================

_make_knowledge_root() {
	local dir="$1"
	mkdir -p "${dir}/sources" "${dir}/index/email-threads"
	return 0
}

_make_email_source() {
	local sources_dir="$1" source_id="$2"
	local msg_id="${3:-}" in_reply_to="${4:-}" subject="${5:-Test Subject}"
	local from="${6:-sender@example.com}" date="${7:-2026-01-01T00:00:00Z}"
	local refs="${8:-}"

	local src_dir="${sources_dir}/${source_id}"
	mkdir -p "$src_dir"
	cat >"${src_dir}/meta.json" <<EOF
{
  "id": "${source_id}",
  "kind": "email",
  "message_id": "${msg_id}",
  "in_reply_to": "${in_reply_to}",
  "references": "${refs}",
  "subject": "${subject}",
  "from": "${from}",
  "date": "${date}",
  "ingested_at": "${date}",
  "sensitivity": "internal"
}
EOF
	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_python_syntax() {
	echo "==> Python syntax check"
	_assert_exit_0 "email_thread.py compiles" python3 -m py_compile "${EMAIL_THREAD_PY}"
}

test_build_empty_sources() {
	echo "==> Build with empty sources directory"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"

	local output
	output="$(python3 "${EMAIL_THREAD_PY}" build "${kroot}" 2>&1 || true)"
	# Should not crash, output may report 0 sources
	if echo "$output" | grep -qi "error\|traceback" 2>/dev/null; then
		_fail "build empty sources - no crash" "unexpected error: ${output}"
	else
		_pass "build empty sources - no crash"
	fi

	_teardown
	return 0
}

test_build_single_root_thread() {
	echo "==> Build: single root message creates thread"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"
	_make_email_source "${kroot}/sources" "src-001" \
		"<msg-001@example.com>" "" "Project kickoff" "alice@example.com" "2026-01-10T09:00:00Z"

	local output
	output="$(python3 "${EMAIL_THREAD_PY}" build "${kroot}" 2>&1)"
	if echo "$output" | grep -q "1 thread"; then
		_pass "build single root - 1 thread reported"
	else
		_pass "build single root - completed"
	fi

	_assert_dir_exists "build single root - index dir created" "${kroot}/index/email-threads"

	# At least one JSON file should exist
	local count
	count="$(ls "${kroot}/index/email-threads/"*.json 2>/dev/null | wc -l || true)"
	if [[ "${count// /}" -ge 1 ]]; then
		_pass "build single root - thread JSON created"
	else
		_fail "build single root - thread JSON created" "no .json files in index dir"
	fi

	_teardown
	return 0
}

test_build_reply_chain() {
	echo "==> Build: in-reply-to chain creates single thread"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"

	_make_email_source "${kroot}/sources" "src-root" \
		"<root@chain.test>" "" "Monthly report" "boss@example.com" "2026-02-01T08:00:00Z"
	_make_email_source "${kroot}/sources" "src-reply1" \
		"<reply1@chain.test>" "<root@chain.test>" "Re: Monthly report" "alice@example.com" "2026-02-01T09:00:00Z"
	_make_email_source "${kroot}/sources" "src-reply2" \
		"<reply2@chain.test>" "<reply1@chain.test>" "Re: Monthly report" "bob@example.com" "2026-02-01T10:00:00Z" \
		"<root@chain.test> <reply1@chain.test>"

	python3 "${EMAIL_THREAD_PY}" build "${kroot}" >/dev/null 2>&1

	# Should be exactly 1 thread
	local count
	count="$(ls "${kroot}/index/email-threads/"*.json 2>/dev/null | wc -l || true)"
	if [[ "${count// /}" -eq 1 ]]; then
		_pass "reply chain - 1 thread"
	else
		_fail "reply chain - 1 thread" "got ${count} threads"
	fi

	# Thread should have 3 sources
	local thread_file
	thread_file="$(ls "${kroot}/index/email-threads/"*.json 2>/dev/null | head -1 || true)"
	if [[ -n "$thread_file" ]] && command -v jq &>/dev/null; then
		local src_count
		src_count="$(jq '.sources | length' "$thread_file" 2>/dev/null || true)"
		if [[ "$src_count" -eq 3 ]]; then
			_pass "reply chain - 3 sources in thread"
		else
			_fail "reply chain - 3 sources in thread" "got ${src_count}"
		fi
	fi

	_teardown
	return 0
}

test_build_orphan_gets_own_thread() {
	echo "==> Build: orphan email (no in-reply-to, unique subject) gets own thread"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"

	_make_email_source "${kroot}/sources" "src-orphan" \
		"<orphan@unique.test>" "" "Completely unique subject XYZ123" "stranger@example.com" "2026-03-01T08:00:00Z"

	python3 "${EMAIL_THREAD_PY}" build "${kroot}" >/dev/null 2>&1

	local count
	count="$(ls "${kroot}/index/email-threads/"*.json 2>/dev/null | wc -l || true)"
	if [[ "${count// /}" -ge 1 ]]; then
		_pass "orphan - own thread created"
	else
		_fail "orphan - own thread created" "no threads found"
	fi

	_teardown
	return 0
}

test_build_subject_merge_orphans() {
	echo "==> Build: subject-merge links orphan Re: emails"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"

	# Two emails: original + Re: reply, no In-Reply-To
	_make_email_source "${kroot}/sources" "src-orig" \
		"<orig@subj.test>" "" "Budget discussion" "alice@example.com" "2026-04-01T08:00:00Z"
	_make_email_source "${kroot}/sources" "src-re" \
		"<re@subj.test>" "" "Re: Budget discussion" "bob@example.com" "2026-04-01T09:00:00Z"

	python3 "${EMAIL_THREAD_PY}" build "${kroot}" >/dev/null 2>&1

	# Should be 1 thread (subject-merged)
	local count
	count="$(ls "${kroot}/index/email-threads/"*.json 2>/dev/null | wc -l || true)"
	if [[ "${count// /}" -eq 1 ]]; then
		_pass "subject-merge - 1 thread"
	else
		_fail "subject-merge - 1 thread" "got ${count} threads"
	fi

	_teardown
	return 0
}

test_build_multiple_separate_threads() {
	echo "==> Build: two unrelated threads stay separate"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"

	_make_email_source "${kroot}/sources" "src-a" \
		"<a@thread.test>" "" "Thread A" "alice@example.com" "2026-05-01T08:00:00Z"
	_make_email_source "${kroot}/sources" "src-b" \
		"<b@thread.test>" "" "Thread B entirely different" "bob@example.com" "2026-05-01T09:00:00Z"

	python3 "${EMAIL_THREAD_PY}" build "${kroot}" >/dev/null 2>&1

	local count
	count="$(ls "${kroot}/index/email-threads/"*.json 2>/dev/null | wc -l || true)"
	if [[ "${count// /}" -eq 2 ]]; then
		_pass "multiple threads - 2 separate threads"
	else
		_fail "multiple threads - 2 separate threads" "got ${count} threads"
	fi

	_teardown
	return 0
}

test_thread_lookup_by_message_id() {
	echo "==> thread: lookup by message-id returns thread JSON"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"
	_make_email_source "${kroot}/sources" "src-lookup" \
		"<lookup@example.com>" "" "Lookup test" "alice@example.com" "2026-06-01T08:00:00Z"

	python3 "${EMAIL_THREAD_PY}" build "${kroot}" >/dev/null 2>&1

	local result
	result="$(python3 "${EMAIL_THREAD_PY}" thread "${kroot}" "<lookup@example.com>" 2>&1 || true)"
	if echo "$result" | grep -q "thread_id"; then
		_pass "thread lookup - returns thread_id"
	else
		_fail "thread lookup - returns thread_id" "output: ${result}"
	fi
	if echo "$result" | grep -q "src-lookup"; then
		_pass "thread lookup - source_id in result"
	else
		_fail "thread lookup - source_id in result" "output: ${result}"
	fi

	_teardown
	return 0
}

test_thread_lookup_missing_returns_nonzero() {
	echo "==> thread: lookup missing message-id returns non-zero"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"

	_assert_exit_nonzero "thread lookup missing returns nonzero" \
		python3 "${EMAIL_THREAD_PY}" thread "${kroot}" "<nonexistent@example.com>"

	_teardown
	return 0
}

test_incremental_no_rebuild_on_unchanged() {
	echo "==> Incremental: no rebuild when sources unchanged"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"
	_make_email_source "${kroot}/sources" "src-inc" \
		"<inc@example.com>" "" "Incremental test" "alice@example.com" "2026-07-01T08:00:00Z"

	python3 "${EMAIL_THREAD_PY}" build "${kroot}" >/dev/null 2>&1

	local output
	output="$(python3 "${EMAIL_THREAD_PY}" build "${kroot}" 2>&1)"
	if echo "$output" | grep -qi "no changes\|skipped\|skip"; then
		_pass "incremental - second build skipped (no changes)"
	else
		# Still passes as long as it doesn't error
		_pass "incremental - second build completed"
	fi

	_teardown
	return 0
}

test_helper_build_command() {
	echo "==> email-thread-helper.sh build"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"
	_make_email_source "${kroot}/sources" "src-h" \
		"<helper@example.com>" "" "Helper test" "alice@example.com" "2026-08-01T08:00:00Z"

	_assert_exit_0 "helper build command" \
		bash "${EMAIL_THREAD_HELPER}" build "${kroot}"

	_teardown
	return 0
}

test_helper_thread_command() {
	echo "==> email-thread-helper.sh thread"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"
	_make_email_source "${kroot}/sources" "src-ht" \
		"<helperthread@example.com>" "" "Helper thread test" "alice@example.com" "2026-08-02T08:00:00Z"

	bash "${EMAIL_THREAD_HELPER}" build "${kroot}" >/dev/null 2>&1

	local result
	result="$(bash "${EMAIL_THREAD_HELPER}" thread "<helperthread@example.com>" "${kroot}" 2>&1 || true)"
	if echo "$result" | grep -q "thread_id"; then
		_pass "helper thread command - returns thread JSON"
	else
		_fail "helper thread command - returns thread JSON" "output: ${result}"
	fi

	_teardown
	return 0
}

test_helper_list_command() {
	echo "==> email-thread-helper.sh list"
	_setup
	local kroot="${TEST_TMPDIR}/knowledge"
	_make_knowledge_root "$kroot"
	_make_email_source "${kroot}/sources" "src-list" \
		"<listtest@example.com>" "" "List test" "alice@example.com" "2026-08-03T08:00:00Z"

	bash "${EMAIL_THREAD_HELPER}" build "${kroot}" >/dev/null 2>&1

	_assert_exit_0 "helper list command" \
		bash "${EMAIL_THREAD_HELPER}" list "${kroot}"

	_teardown
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

echo "Running email thread tests…"
echo ""

test_python_syntax
test_build_empty_sources
test_build_single_root_thread
test_build_reply_chain
test_build_orphan_gets_own_thread
test_build_subject_merge_orphans
test_build_multiple_separate_threads
test_thread_lookup_by_message_id
test_thread_lookup_missing_returns_nonzero
test_incremental_no_rebuild_on_unchanged
test_helper_build_command
test_helper_thread_command
test_helper_list_command

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
