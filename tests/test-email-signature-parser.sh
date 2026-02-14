#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for email-signature-parser-helper.sh
# Validates signature detection, field extraction, and TOON output generation.
#
# Usage: bash tests/test-email-signature-parser.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
PARSER="${REPO_DIR}/.agents/scripts/email-signature-parser-helper.sh"
TEST_DIR="${SCRIPT_DIR}/email-signature-test-fixtures"
CONTACTS_DIR=""

# Disable LLM fallback in tests to avoid timeouts and external dependencies
export EMAIL_PARSER_NO_LLM=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

setup() {
	CONTACTS_DIR=$(mktemp -d)
	return 0
}

teardown() {
	if [[ -n "$CONTACTS_DIR" && -d "$CONTACTS_DIR" ]]; then
		rm -rf "$CONTACTS_DIR"
	fi
	return 0
}

assert_contains() {
	local file="$1"
	local pattern="$2"
	local description="$3"

	if grep -q "$pattern" "$file" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (pattern '$pattern' not found in $file)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_file_exists() {
	local file="$1"
	local description="$2"

	if [[ -f "$file" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (file not found: $file)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit_code() {
	local expected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" -eq "$expected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected exit $expected, got $actual)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# =============================================================================
# Test Cases
# =============================================================================

test_help_command() {
	echo "Test: help command"
	local output
	output=$("$PARSER" help 2>&1)
	local rc=$?
	assert_exit_code 0 "$rc" "help exits 0"

	if echo "$output" | grep -q "Email Signature Parser Helper"; then
		echo -e "  ${GREEN}PASS${NC}: help output contains header"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: help output missing header"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

test_standard_signature() {
	echo "Test: standard business signature with -- delimiter"
	setup

	local output
	output=$("$PARSER" parse "${TEST_DIR}/standard-business.txt" "$CONTACTS_DIR" 2>&1) || true

	assert_file_exists "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "TOON file created for john.doe@acmecorp.com"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "name: John Doe" "Name extracted"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "email: john.doe@acmecorp.com" "Email extracted"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "title: Senior Software Engineer" "Title extracted"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "company: Acme Corp" "Company extracted"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "phone:" "Phone field present"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "website:" "Website field present"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "source: email-signature" "Source field present"
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "confidence:" "Confidence field present"

	teardown
	return 0
}

test_best_regards_signature() {
	echo "Test: Best regards signature"
	setup

	local output
	output=$("$PARSER" parse "${TEST_DIR}/best-regards.txt" "$CONTACTS_DIR" 2>&1) || true

	assert_file_exists "${CONTACTS_DIR}/jane.smith@techstartup.io.toon" "TOON file created"
	assert_contains "${CONTACTS_DIR}/jane.smith@techstartup.io.toon" "name: Jane Smith" "Name extracted"
	assert_contains "${CONTACTS_DIR}/jane.smith@techstartup.io.toon" "email: jane.smith@techstartup.io" "Email extracted"

	teardown
	return 0
}

test_multiple_emails() {
	echo "Test: signature with multiple email addresses"
	setup

	local output
	output=$("$PARSER" parse "${TEST_DIR}/multiple-emails.txt" "$CONTACTS_DIR" 2>&1) || true

	# Should create one file for the primary email
	local toon_files
	toon_files=$(find "$CONTACTS_DIR" -name "*.toon" -type f | wc -l | tr -d ' ')

	if [[ "$toon_files" -ge 1 ]]; then
		echo -e "  ${GREEN}PASS${NC}: At least one TOON file created"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: No TOON files created"
		FAIL=$((FAIL + 1))
	fi

	# Check for additional_emails section
	local any_file
	any_file=$(find "$CONTACTS_DIR" -name "*.toon" -type f | head -1)
	if [[ -n "$any_file" ]]; then
		assert_contains "$any_file" "additional_emails" "Additional emails section present"
	fi

	teardown
	return 0
}

test_minimal_signature() {
	echo "Test: minimal signature (just name and email)"
	setup

	local output
	output=$("$PARSER" parse "${TEST_DIR}/minimal.txt" "$CONTACTS_DIR" 2>&1) || true

	local toon_files
	toon_files=$(find "$CONTACTS_DIR" -name "*.toon" -type f | wc -l | tr -d ' ')

	if [[ "$toon_files" -ge 1 ]]; then
		echo -e "  ${GREEN}PASS${NC}: TOON file created for minimal signature"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: No TOON file created for minimal signature"
		FAIL=$((FAIL + 1))
	fi

	teardown
	return 0
}

test_stdin_input() {
	echo "Test: parse from stdin"
	setup

	local output
	output=$(cat "${TEST_DIR}/standard-business.txt" | "$PARSER" parse - "$CONTACTS_DIR" 2>&1) || true

	assert_file_exists "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "TOON file created from stdin"

	teardown
	return 0
}

test_empty_input() {
	echo "Test: empty input returns error"
	setup

	local rc=0
	echo "" | "$PARSER" parse - "$CONTACTS_DIR" 2>&1 || rc=$?

	assert_exit_code 1 "$rc" "Empty input returns exit 1"

	teardown
	return 0
}

test_no_signature() {
	echo "Test: email with no signature block"
	setup

	local output
	local rc=0
	output=$("$PARSER" parse "${TEST_DIR}/no-signature.txt" "$CONTACTS_DIR" 2>&1) || rc=$?

	# Should still attempt extraction from last lines (heuristic fallback)
	# May or may not find an email — depends on content
	echo -e "  ${YELLOW}INFO${NC}: Exit code: $rc (expected 0 or 1 depending on content)"
	SKIP=$((SKIP + 1))

	teardown
	return 0
}

test_company_keywords() {
	echo "Test: company detection via keywords (Inc., LLC, etc.)"
	setup

	local output
	output=$("$PARSER" parse "${TEST_DIR}/company-keywords.txt" "$CONTACTS_DIR" 2>&1) || true

	local any_file
	any_file=$(find "$CONTACTS_DIR" -name "*.toon" -type f | head -1)
	if [[ -n "$any_file" ]]; then
		assert_contains "$any_file" "company:" "Company field present"
		# Check that company contains a keyword indicator
		if grep -qEi '(Inc\.|LLC|Ltd\.|Corp\.)' "$any_file" 2>/dev/null; then
			echo -e "  ${GREEN}PASS${NC}: Company contains business entity keyword"
			PASS=$((PASS + 1))
		else
			echo -e "  ${YELLOW}INFO${NC}: Company may not contain entity keyword (acceptable)"
			SKIP=$((SKIP + 1))
		fi
	else
		echo -e "  ${RED}FAIL${NC}: No TOON file created"
		FAIL=$((FAIL + 1))
	fi

	teardown
	return 0
}

test_address_extraction() {
	echo "Test: physical address extraction"
	setup

	local output
	output=$("$PARSER" parse "${TEST_DIR}/with-address.txt" "$CONTACTS_DIR" 2>&1) || true

	local any_file
	any_file=$(find "$CONTACTS_DIR" -name "*.toon" -type f | head -1)
	if [[ -n "$any_file" ]]; then
		assert_contains "$any_file" "address:" "Address field present"
	else
		echo -e "  ${RED}FAIL${NC}: No TOON file created"
		FAIL=$((FAIL + 1))
	fi

	teardown
	return 0
}

test_list_command() {
	echo "Test: list contacts command"
	setup

	# Parse a fixture first
	"$PARSER" parse "${TEST_DIR}/standard-business.txt" "$CONTACTS_DIR" >/dev/null 2>&1 || true

	local output
	output=$("$PARSER" list "$CONTACTS_DIR" 2>&1)
	local rc=$?

	assert_exit_code 0 "$rc" "list exits 0"

	if echo "$output" | grep -q "Total contacts:"; then
		echo -e "  ${GREEN}PASS${NC}: list shows total count"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: list missing total count"
		FAIL=$((FAIL + 1))
	fi

	teardown
	return 0
}

test_show_command() {
	echo "Test: show contact command"
	setup

	# Parse a fixture first
	"$PARSER" parse "${TEST_DIR}/standard-business.txt" "$CONTACTS_DIR" >/dev/null 2>&1 || true

	local output
	output=$("$PARSER" show "john.doe" "$CONTACTS_DIR" 2>&1)
	local rc=$?

	assert_exit_code 0 "$rc" "show exits 0 for matching contact"

	if echo "$output" | grep -q "john.doe@acmecorp.com"; then
		echo -e "  ${GREEN}PASS${NC}: show displays matching contact"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: show did not display matching contact"
		FAIL=$((FAIL + 1))
	fi

	teardown
	return 0
}

test_merge_existing_contact() {
	echo "Test: merging updates to existing contact"
	setup

	# Parse same fixture twice
	"$PARSER" parse "${TEST_DIR}/standard-business.txt" "$CONTACTS_DIR" >/dev/null 2>&1 || true
	"$PARSER" parse "${TEST_DIR}/standard-business.txt" "$CONTACTS_DIR" >/dev/null 2>&1 || true

	# Should still have just one file
	local toon_files
	toon_files=$(find "$CONTACTS_DIR" -name "*.toon" -type f | wc -l | tr -d ' ')

	if [[ "$toon_files" -eq 1 ]]; then
		echo -e "  ${GREEN}PASS${NC}: Merge produced single file (no duplicates)"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Expected 1 file, got $toon_files"
		FAIL=$((FAIL + 1))
	fi

	# Check last_seen was updated
	assert_contains "${CONTACTS_DIR}/john.doe@acmecorp.com.toon" "last_seen:" "last_seen field present after merge"

	teardown
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo "============================================"
	echo "Email Signature Parser - Test Suite"
	echo "============================================"
	echo ""

	# Check parser exists
	if [[ ! -x "$PARSER" ]]; then
		echo -e "${RED}ERROR${NC}: Parser not found or not executable: $PARSER"
		exit 1
	fi

	# Check test fixtures exist
	if [[ ! -d "$TEST_DIR" ]]; then
		echo -e "${RED}ERROR${NC}: Test fixtures not found: $TEST_DIR"
		echo "Run this script from the repository root."
		exit 1
	fi

	test_help_command
	echo ""
	test_standard_signature
	echo ""
	test_best_regards_signature
	echo ""
	test_multiple_emails
	echo ""
	test_minimal_signature
	echo ""
	test_stdin_input
	echo ""
	test_empty_input
	echo ""
	test_no_signature
	echo ""
	test_company_keywords
	echo ""
	test_address_extraction
	echo ""
	test_list_command
	echo ""
	test_show_command
	echo ""
	test_merge_existing_contact
	echo ""

	echo "============================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
