#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tests for mission-email-helper.sh
# Tests: template rendering, code extraction, thread management, email parsing, DB operations
# Does NOT test actual SES sending (requires AWS credentials)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../.agents/scripts/mission-email-helper.sh"
TEMPLATE_DIR="${SCRIPT_DIR}/../.agents/templates/email"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Use a temporary database for testing
export AIDEVOPS_MAIL_DIR
AIDEVOPS_MAIL_DIR=$(mktemp -d)
readonly TEST_DB="$AIDEVOPS_MAIL_DIR/mission-email.db"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

pass() {
	local test_name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	TESTS_RUN=$((TESTS_RUN + 1))
	echo -e "  ${GREEN}PASS${NC} $test_name"
	return 0
}

fail() {
	local test_name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	TESTS_RUN=$((TESTS_RUN + 1))
	echo -e "  ${RED}FAIL${NC} $test_name${reason:+ - $reason}"
	return 0
}

#######################################
# Test: help command
#######################################
test_help() {
	local output
	output=$("$HELPER" help 2>&1)
	if echo "$output" | grep -q "mission-email-helper.sh"; then
		pass "help command"
	else
		fail "help command" "Expected help text"
	fi
	return 0
}

#######################################
# Test: templates list
#######################################
test_templates_list() {
	local output
	output=$("$HELPER" templates --list 2>&1)
	if echo "$output" | grep -q "api-access-request"; then
		pass "templates list"
	else
		fail "templates list" "Expected api-access-request template"
	fi
	return 0
}

#######################################
# Test: templates show
#######################################
test_templates_show() {
	local output
	output=$("$HELPER" templates --show api-access-request 2>&1)
	if echo "$output" | grep -q "{{COMPANY_NAME}}"; then
		pass "templates show"
	else
		fail "templates show" "Expected template placeholders"
	fi
	return 0
}

#######################################
# Test: templates show nonexistent
#######################################
test_templates_show_missing() {
	local output
	output=$("$HELPER" templates --show nonexistent 2>&1) || true
	if echo "$output" | grep -qi "not found"; then
		pass "templates show missing"
	else
		fail "templates show missing" "Expected error for missing template"
	fi
	return 0
}

#######################################
# Test: extract-code numeric
#######################################
test_extract_code_numeric() {
	local output
	output=$(echo "Your verification code is 847291. Please enter it." | "$HELPER" extract-code - 2>/dev/null)
	if echo "$output" | grep -q "847291"; then
		pass "extract-code numeric"
	else
		fail "extract-code numeric" "Expected 847291 in output"
	fi
	return 0
}

#######################################
# Test: extract-code token
#######################################
test_extract_code_token() {
	local output
	# Use a fake token pattern that won't trigger GitHub secret scanning
	output=$(echo "Your API token: testkey_abc123def456ghi789jkl012" | "$HELPER" extract-code - 2>/dev/null)
	if echo "$output" | grep -q "testkey_abc123def456ghi789jkl012"; then
		pass "extract-code token"
	else
		fail "extract-code token" "Expected API token in output"
	fi
	return 0
}

#######################################
# Test: extract-code URL
#######################################
test_extract_code_url() {
	local output
	output=$(echo "Click here to verify: https://example.com/verify?token=abc123" | "$HELPER" extract-code - 2>/dev/null)
	if echo "$output" | grep -q "verification_url"; then
		pass "extract-code URL"
	else
		fail "extract-code URL" "Expected verification_url type"
	fi
	return 0
}

#######################################
# Test: extract-code no codes
#######################################
test_extract_code_none() {
	local output
	output=$(echo "Hello, thank you for your inquiry." | "$HELPER" extract-code - 2>/dev/null)
	if echo "$output" | grep -q '\[\]'; then
		pass "extract-code none"
	else
		fail "extract-code none" "Expected empty array"
	fi
	return 0
}

#######################################
# Test: extract-code multiple
#######################################
test_extract_code_multiple() {
	local input="Your verification code is 123456. Also visit https://example.com/confirm?token=xyz to confirm."
	local output
	output=$(echo "$input" | "$HELPER" extract-code - 2>/dev/null)
	local count
	count=$(echo "$output" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
	if [[ "$count" -ge 2 ]]; then
		pass "extract-code multiple"
	else
		fail "extract-code multiple" "Expected 2+ codes, got $count"
	fi
	return 0
}

#######################################
# Test: thread create
#######################################
test_thread_create() {
	local output
	output=$("$HELPER" thread --create \
		--mission m001 \
		--subject "Test Thread" \
		--counterparty test@example.com \
		--context "Testing thread creation" 2>&1)
	if echo "$output" | grep -q "thread_id=thr-"; then
		pass "thread create"
	else
		fail "thread create" "Expected thread_id in output"
	fi
	return 0
}

#######################################
# Test: thread list
#######################################
test_thread_list() {
	# Create a thread first
	"$HELPER" thread --create \
		--mission m002 \
		--subject "List Test" \
		--counterparty list@example.com 2>/dev/null

	local output
	output=$("$HELPER" thread --list 2>&1)
	if echo "$output" | grep -q "list@example.com"; then
		pass "thread list"
	else
		fail "thread list" "Expected counterparty in list"
	fi
	return 0
}

#######################################
# Test: thread list by mission
#######################################
test_thread_list_by_mission() {
	local output
	output=$("$HELPER" thread --list --mission m002 2>&1)
	if echo "$output" | grep -q "list@example.com"; then
		pass "thread list by mission"
	else
		fail "thread list by mission" "Expected m002 thread"
	fi

	# Should not show m001 threads
	local output2
	output2=$("$HELPER" thread --list --mission m999 2>&1)
	if echo "$output2" | grep -q "no threads"; then
		pass "thread list by mission (empty)"
	else
		fail "thread list by mission (empty)" "Expected no threads for m999"
	fi
	return 0
}

#######################################
# Test: thread show
#######################################
test_thread_show() {
	# Create a thread and capture its ID
	local create_output
	create_output=$("$HELPER" thread --create \
		--mission m003 \
		--subject "Show Test" \
		--counterparty show@example.com 2>/dev/null)
	local thread_id
	thread_id=$(echo "$create_output" | grep "thread_id=" | cut -d= -f2)

	if [[ -z "$thread_id" ]]; then
		fail "thread show" "Could not create thread"
		return 0
	fi

	local output
	output=$("$HELPER" thread --show "$thread_id" 2>&1)
	if echo "$output" | grep -q "show@example.com"; then
		pass "thread show"
	else
		fail "thread show" "Expected counterparty in show output"
	fi
	return 0
}

#######################################
# Test: parse email file
#######################################
test_parse_email() {
	local test_eml
	test_eml=$(mktemp)
	cat >"$test_eml" <<'EML'
From: sender@example.com
To: recipient@example.com
Subject: Test Email
Date: Sat, 28 Feb 2026 12:00:00 +0000
Message-ID: <test-123@example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

Hello, this is a test email body.
Your verification code is 998877.
EML

	local output
	output=$("$HELPER" parse "$test_eml" 2>/dev/null)
	rm -f "$test_eml"

	if echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['subject']=='Test Email'" 2>/dev/null; then
		pass "parse email subject"
	else
		fail "parse email subject" "Expected 'Test Email' subject"
	fi

	if echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'sender@example.com' in d['from']" 2>/dev/null; then
		pass "parse email from"
	else
		fail "parse email from" "Expected sender@example.com"
	fi

	if echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert '998877' in d['body_text']" 2>/dev/null; then
		pass "parse email body"
	else
		fail "parse email body" "Expected body with verification code"
	fi
	return 0
}

#######################################
# Test: parse email from stdin
#######################################
test_parse_email_stdin() {
	local output
	output=$(printf "From: stdin@example.com\nTo: me@example.com\nSubject: Stdin Test\n\nBody text here." | "$HELPER" parse - 2>/dev/null)
	if echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['subject']=='Stdin Test'" 2>/dev/null; then
		pass "parse email stdin"
	else
		fail "parse email stdin" "Expected 'Stdin Test' subject"
	fi
	return 0
}

#######################################
# Test: database initialization
#######################################
test_db_init() {
	if [[ -f "$TEST_DB" ]]; then
		pass "database initialized"
	else
		fail "database initialized" "Expected $TEST_DB to exist"
	fi

	# Check tables exist
	local tables
	tables=$(sqlite3 "$TEST_DB" ".tables" 2>/dev/null)
	if echo "$tables" | grep -q "threads"; then
		pass "database has threads table"
	else
		fail "database has threads table"
	fi
	if echo "$tables" | grep -q "messages"; then
		pass "database has messages table"
	else
		fail "database has messages table"
	fi
	if echo "$tables" | grep -q "extracted_codes"; then
		pass "database has extracted_codes table"
	else
		fail "database has extracted_codes table"
	fi
	return 0
}

#######################################
# Test: send without credentials (should fail gracefully)
#######################################
test_send_missing_args() {
	local output
	output=$("$HELPER" send 2>&1) || true
	if echo "$output" | grep -qi "missing"; then
		pass "send missing args"
	else
		fail "send missing args" "Expected missing argument error"
	fi
	return 0
}

#######################################
# Test: unknown command
#######################################
test_unknown_command() {
	local output
	output=$("$HELPER" foobar 2>&1) || true
	if echo "$output" | grep -qi "unknown"; then
		pass "unknown command"
	else
		fail "unknown command" "Expected unknown command error"
	fi
	return 0
}

#######################################
# Cleanup
#######################################
cleanup() {
	rm -rf "$AIDEVOPS_MAIL_DIR"
	return 0
}

#######################################
# Main
#######################################
main() {
	echo "Mission Email Helper Tests"
	echo "=========================="
	echo ""

	# Check dependencies
	if ! command -v python3 &>/dev/null; then
		echo "SKIP: python3 not available"
		exit 0
	fi
	if ! command -v sqlite3 &>/dev/null; then
		echo "SKIP: sqlite3 not available"
		exit 0
	fi

	echo "Help & Templates:"
	test_help
	test_templates_list
	test_templates_show
	test_templates_show_missing

	echo ""
	echo "Code Extraction:"
	test_extract_code_numeric
	test_extract_code_token
	test_extract_code_url
	test_extract_code_none
	test_extract_code_multiple

	echo ""
	echo "Thread Management:"
	test_thread_create
	test_thread_list
	test_thread_list_by_mission
	test_thread_show

	echo ""
	echo "Email Parsing:"
	test_parse_email
	test_parse_email_stdin

	echo ""
	echo "Database:"
	test_db_init

	echo ""
	echo "Error Handling:"
	test_send_missing_args
	test_unknown_command

	echo ""
	echo "=========================="
	echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

	cleanup

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
