#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329
# SC2034: Variables set for sourced scripts
# SC2317: Commands inside test functions appear unreachable to ShellCheck
# SC2329: test_* functions invoked from main(); ShellCheck cannot trace indirect calls
set -euo pipefail

# Test suite for email-sieve-helper.sh
# Tests Sieve rule generation, pattern management, and validation.
# Does NOT test live ManageSieve deployment (requires a real server).
#
# Usage: bash tests/test-email-sieve-helper.sh
#
# Part of aidevops framework (t1503)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/email-sieve-helper.sh"

# Test workspace (isolated from real data)
TEST_WORKSPACE=$(mktemp -d)
TEST_PATTERNS="${TEST_WORKSPACE}/patterns.json"
TEST_OUTPUT="${TEST_WORKSPACE}/output.sieve"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Test utilities
# ============================================================================

cleanup() {
	rm -rf "$TEST_WORKSPACE"
}
trap cleanup EXIT

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected: $expected"
		echo "    Actual:   $actual"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	# Use grep -F -- to handle needles starting with -- (macOS grep treats them as options otherwise)
	if echo "$haystack" | grep -qF -- "$needle"; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected to contain: $needle"
		echo "    Actual output: $haystack"
	fi
	return 0
}

assert_not_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if ! echo "$haystack" | grep -qF -- "$needle"; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected NOT to contain: $needle"
		echo "    Actual output: $haystack"
	fi
	return 0
}

assert_file_exists() {
	local description="$1"
	local file_path="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -f "$file_path" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    File not found: $file_path"
	fi
	return 0
}

assert_exit_zero() {
	local description="$1"
	local exit_code="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$exit_code" -eq 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description (exit code: $exit_code)"
	fi
	return 0
}

assert_exit_nonzero() {
	local description="$1"
	local exit_code="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$exit_code" -ne 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description (expected non-zero exit, got 0)"
	fi
	return 0
}

# ============================================================================
# Test: help command
# ============================================================================

test_help() {
	echo ""
	echo "--- test_help ---"

	local output
	output=$(bash "$HELPER" help 2>&1)
	local rc=$?

	assert_exit_zero "help exits 0" "$rc"
	assert_contains "help shows USAGE" "USAGE" "$output"
	assert_contains "help shows generate command" "generate" "$output"
	assert_contains "help shows deploy command" "deploy" "$output"
	assert_contains "help shows validate command" "validate" "$output"
	assert_contains "help shows add-pattern command" "add-pattern" "$output"
	assert_contains "help shows Cloudron notes" "CLOUDRON" "$output"
	assert_contains "help shows Fastmail notes" "FASTMAIL" "$output"
	return 0
}

# ============================================================================
# Test: add-pattern command
# ============================================================================

test_add_pattern_sender() {
	echo ""
	echo "--- test_add_pattern_sender ---"

	local output
	output=$(bash "$HELPER" add-pattern \
		--type sender \
		--value "boss@company.com" \
		--folder "INBOX/Priority" \
		--patterns "$TEST_PATTERNS" 2>&1)
	local rc=$?

	assert_exit_zero "add-pattern sender exits 0" "$rc"
	assert_file_exists "patterns file created" "$TEST_PATTERNS"

	local count
	count=$(jq '.patterns | length' "$TEST_PATTERNS")
	assert_eq "patterns file has 1 entry" "1" "$count"

	local ptype
	ptype=$(jq -r '.patterns[0].type' "$TEST_PATTERNS")
	assert_eq "pattern type is sender" "sender" "$ptype"

	local pvalue
	pvalue=$(jq -r '.patterns[0].value' "$TEST_PATTERNS")
	assert_eq "pattern value is correct" "boss@company.com" "$pvalue"

	local pfolder
	pfolder=$(jq -r '.patterns[0].folder' "$TEST_PATTERNS")
	assert_eq "pattern folder is correct" "INBOX/Priority" "$pfolder"
	return 0
}

test_add_pattern_domain() {
	echo ""
	echo "--- test_add_pattern_domain ---"

	local output
	output=$(bash "$HELPER" add-pattern \
		--type domain \
		--value "github.com" \
		--folder "INBOX/GitHub" \
		--patterns "$TEST_PATTERNS" 2>&1)
	local rc=$?

	assert_exit_zero "add-pattern domain exits 0" "$rc"

	local count
	count=$(jq '.patterns | length' "$TEST_PATTERNS")
	assert_eq "patterns file now has 2 entries" "2" "$count"
	return 0
}

test_add_pattern_transaction() {
	echo ""
	echo "--- test_add_pattern_transaction ---"

	local output
	output=$(bash "$HELPER" add-pattern \
		--type transaction \
		--value "" \
		--folder "INBOX/Receipts" \
		--patterns "$TEST_PATTERNS" 2>&1)
	local rc=$?

	assert_exit_zero "add-pattern transaction exits 0" "$rc"
	return 0
}

test_add_pattern_mailing_list() {
	echo ""
	echo "--- test_add_pattern_mailing_list ---"

	local output
	output=$(bash "$HELPER" add-pattern \
		--type mailing-list \
		--value "" \
		--folder "INBOX/Lists" \
		--patterns "$TEST_PATTERNS" 2>&1)
	local rc=$?

	assert_exit_zero "add-pattern mailing-list exits 0" "$rc"
	return 0
}

test_add_pattern_notification() {
	echo ""
	echo "--- test_add_pattern_notification ---"

	local output
	output=$(bash "$HELPER" add-pattern \
		--type notification \
		--value "" \
		--folder "INBOX/Notifications" \
		--patterns "$TEST_PATTERNS" 2>&1)
	local rc=$?

	assert_exit_zero "add-pattern notification exits 0" "$rc"
	return 0
}

test_add_pattern_invalid_type() {
	echo ""
	echo "--- test_add_pattern_invalid_type ---"

	local output rc
	output=$(bash "$HELPER" add-pattern \
		--type invalid-type \
		--value "foo" \
		--folder "INBOX/Foo" \
		--patterns "$TEST_PATTERNS" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "add-pattern with invalid type exits non-zero" "$rc"
	assert_contains "error message mentions invalid type" "Unknown pattern type" "$output"
	return 0
}

test_add_pattern_missing_folder() {
	echo ""
	echo "--- test_add_pattern_missing_folder ---"

	local output rc
	output=$(bash "$HELPER" add-pattern \
		--type sender \
		--value "foo@bar.com" \
		--patterns "$TEST_PATTERNS" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "add-pattern without --folder exits non-zero" "$rc"
	return 0
}

# ============================================================================
# Test: generate command
# ============================================================================

test_generate_sieve() {
	echo ""
	echo "--- test_generate_sieve ---"

	local output
	output=$(bash "$HELPER" generate \
		--patterns "$TEST_PATTERNS" \
		--output "$TEST_OUTPUT" 2>&1)
	local rc=$?

	assert_exit_zero "generate exits 0" "$rc"
	assert_file_exists "output sieve file created" "$TEST_OUTPUT"
	return 0
}

test_generated_sieve_has_require() {
	echo ""
	echo "--- test_generated_sieve_has_require ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve has require fileinto" 'require' "$content"
	assert_contains "generated sieve has fileinto in require" '"fileinto"' "$content"
	return 0
}

test_generated_sieve_has_sender_rule() {
	echo ""
	echo "--- test_generated_sieve_has_sender_rule ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve has sender address match" 'address :is "from" "boss@company.com"' "$content"
	assert_contains "generated sieve has fileinto for priority folder" 'fileinto "INBOX/Priority"' "$content"
	assert_contains "generated sieve has stop after sender rule" "stop;" "$content"
	return 0
}

test_generated_sieve_has_domain_rule() {
	echo ""
	echo "--- test_generated_sieve_has_domain_rule ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve has domain match" 'address :domain :is "from" "github.com"' "$content"
	assert_contains "generated sieve has fileinto for github folder" 'fileinto "INBOX/GitHub"' "$content"
	return 0
}

test_generated_sieve_has_transaction_rules() {
	echo ""
	echo "--- test_generated_sieve_has_transaction_rules ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve has transaction detection" "Transaction email detection" "$content"
	assert_contains "generated sieve matches receipt subject" '"receipt"' "$content"
	assert_contains "generated sieve matches invoice subject" '"invoice"' "$content"
	assert_contains "generated sieve routes to receipts folder" 'fileinto "INBOX/Receipts"' "$content"
	return 0
}

test_generated_sieve_has_mailing_list_rules() {
	echo ""
	echo "--- test_generated_sieve_has_mailing_list_rules ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve has mailing list detection" "Mailing list auto-detection" "$content"
	assert_contains "generated sieve checks list-id header" 'exists "list-id"' "$content"
	assert_contains "generated sieve checks list-unsubscribe" 'exists "list-unsubscribe"' "$content"
	assert_contains "generated sieve routes to lists folder" 'fileinto "INBOX/Lists"' "$content"
	return 0
}

test_generated_sieve_has_notification_rules() {
	echo ""
	echo "--- test_generated_sieve_has_notification_rules ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve has notification detection" "Automated notification detection" "$content"
	assert_contains "generated sieve routes to notifications folder" 'fileinto "INBOX/Notifications"' "$content"
	return 0
}

test_generated_sieve_has_keep() {
	echo ""
	echo "--- test_generated_sieve_has_keep ---"

	local content
	content=$(cat "$TEST_OUTPUT")

	assert_contains "generated sieve ends with keep" "keep;" "$content"
	return 0
}

test_generated_sieve_balanced_braces() {
	echo ""
	echo "--- test_generated_sieve_balanced_braces ---"

	local open_braces close_braces
	open_braces=$(grep -o '{' "$TEST_OUTPUT" | wc -l | tr -d ' ')
	close_braces=$(grep -o '}' "$TEST_OUTPUT" | wc -l | tr -d ' ')

	assert_eq "generated sieve has balanced braces" "$open_braces" "$close_braces"
	return 0
}

# ============================================================================
# Test: generate with flags
# ============================================================================

test_generate_with_flags() {
	echo ""
	echo "--- test_generate_with_flags ---"

	local flagged_patterns="${TEST_WORKSPACE}/flagged-patterns.json"
	local flagged_output="${TEST_WORKSPACE}/flagged.sieve"

	bash "$HELPER" add-pattern \
		--type sender \
		--value "vip@example.com" \
		--folder "INBOX/VIP" \
		--flags "\\Flagged" \
		--patterns "$flagged_patterns" >/dev/null 2>&1

	bash "$HELPER" generate \
		--patterns "$flagged_patterns" \
		--output "$flagged_output" >/dev/null 2>&1

	local content
	content=$(cat "$flagged_output")

	assert_contains "flagged sieve has imap4flags in require" '"imap4flags"' "$content"
	assert_contains "flagged sieve has addflag action" 'addflag' "$content"
	return 0
}

# ============================================================================
# Test: generate with subject pattern
# ============================================================================

test_generate_subject_pattern() {
	echo ""
	echo "--- test_generate_subject_pattern ---"

	local subj_patterns="${TEST_WORKSPACE}/subj-patterns.json"
	local subj_output="${TEST_WORKSPACE}/subj.sieve"

	bash "$HELPER" add-pattern \
		--type subject \
		--value "[JIRA]" \
		--folder "INBOX/Jira" \
		--patterns "$subj_patterns" >/dev/null 2>&1

	bash "$HELPER" generate \
		--patterns "$subj_patterns" \
		--output "$subj_output" >/dev/null 2>&1

	local content
	content=$(cat "$subj_output")

	assert_contains "subject sieve has header contains match" 'header :contains "subject" "[JIRA]"' "$content"
	assert_contains "subject sieve routes to Jira folder" 'fileinto "INBOX/Jira"' "$content"
	return 0
}

# ============================================================================
# Test: generate with list-id pattern
# ============================================================================

test_generate_list_id_pattern() {
	echo ""
	echo "--- test_generate_list_id_pattern ---"

	local list_patterns="${TEST_WORKSPACE}/list-patterns.json"
	local list_output="${TEST_WORKSPACE}/list.sieve"

	bash "$HELPER" add-pattern \
		--type list-id \
		--value "announce.example.com" \
		--folder "INBOX/Lists/Announce" \
		--patterns "$list_patterns" >/dev/null 2>&1

	bash "$HELPER" generate \
		--patterns "$list_patterns" \
		--output "$list_output" >/dev/null 2>&1

	local content
	content=$(cat "$list_output")

	assert_contains "list-id sieve has list-id header match" 'header :contains "list-id" "announce.example.com"' "$content"
	assert_contains "list-id sieve routes to announce folder" 'fileinto "INBOX/Lists/Announce"' "$content"
	return 0
}

# ============================================================================
# Test: generate with header pattern
# ============================================================================

test_generate_header_pattern() {
	echo ""
	echo "--- test_generate_header_pattern ---"

	local hdr_patterns="${TEST_WORKSPACE}/hdr-patterns.json"
	local hdr_output="${TEST_WORKSPACE}/hdr.sieve"

	bash "$HELPER" add-pattern \
		--type header \
		--value "X-Project:myproject" \
		--folder "INBOX/Projects/MyProject" \
		--patterns "$hdr_patterns" >/dev/null 2>&1

	bash "$HELPER" generate \
		--patterns "$hdr_patterns" \
		--output "$hdr_output" >/dev/null 2>&1

	local content
	content=$(cat "$hdr_output")

	assert_contains "header sieve has header contains match" 'header :contains "X-Project" "myproject"' "$content"
	assert_contains "header sieve routes to project folder" 'fileinto "INBOX/Projects/MyProject"' "$content"
	return 0
}

# ============================================================================
# Test: generate with empty patterns file
# ============================================================================

test_generate_empty_patterns() {
	echo ""
	echo "--- test_generate_empty_patterns ---"

	local empty_patterns="${TEST_WORKSPACE}/empty-patterns.json"
	local empty_output="${TEST_WORKSPACE}/empty.sieve"

	# Create empty patterns file
	cat >"$empty_patterns" <<'JSON'
{
  "version": "1.0",
  "description": "Empty patterns",
  "patterns": []
}
JSON

	local output
	output=$(bash "$HELPER" generate \
		--patterns "$empty_patterns" \
		--output "$empty_output" 2>&1)
	local rc=$?

	assert_exit_zero "generate with empty patterns exits 0" "$rc"
	assert_file_exists "empty output sieve file created" "$empty_output"

	local content
	content=$(cat "$empty_output")
	assert_contains "empty sieve still has keep" "keep;" "$content"
	return 0
}

# ============================================================================
# Test: generate with missing patterns file
# ============================================================================

test_generate_missing_patterns() {
	echo ""
	echo "--- test_generate_missing_patterns ---"

	local output rc
	output=$(bash "$HELPER" generate \
		--patterns "${TEST_WORKSPACE}/nonexistent.json" \
		--output "${TEST_WORKSPACE}/nonexistent.sieve" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "generate with missing patterns exits non-zero" "$rc"
	assert_contains "error message mentions patterns file" "Patterns file not found" "$output"
	return 0
}

# ============================================================================
# Test: validate command
# ============================================================================

test_validate_valid_sieve() {
	echo ""
	echo "--- test_validate_valid_sieve ---"

	local output
	output=$(bash "$HELPER" validate --file "$TEST_OUTPUT" 2>&1)
	local rc=$?

	assert_exit_zero "validate valid sieve exits 0" "$rc"
	assert_contains "validate reports passed" "Validation passed" "$output"
	return 0
}

test_validate_missing_file() {
	echo ""
	echo "--- test_validate_missing_file ---"

	local output rc
	output=$(bash "$HELPER" validate --file "${TEST_WORKSPACE}/nonexistent.sieve" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "validate missing file exits non-zero" "$rc"
	assert_contains "error message mentions file not found" "not found" "$output"
	return 0
}

test_validate_unbalanced_braces() {
	echo ""
	echo "--- test_validate_unbalanced_braces ---"

	local bad_sieve="${TEST_WORKSPACE}/bad.sieve"
	cat >"$bad_sieve" <<'SIEVE'
require ["fileinto"];

if address :is "from" "test@example.com" {
    fileinto "INBOX/Test";
    stop;

keep;
SIEVE

	local output rc
	output=$(bash "$HELPER" validate --file "$bad_sieve" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "validate unbalanced braces exits non-zero" "$rc"
	assert_contains "error mentions unbalanced braces" "Unbalanced braces" "$output"
	return 0
}

test_validate_missing_require() {
	echo ""
	echo "--- test_validate_missing_require ---"

	local no_require_sieve="${TEST_WORKSPACE}/no-require.sieve"
	cat >"$no_require_sieve" <<'SIEVE'
# No require statement
if address :is "from" "test@example.com" {
    fileinto "INBOX/Test";
    stop;
}

keep;
SIEVE

	local output rc
	output=$(bash "$HELPER" validate --file "$no_require_sieve" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "validate missing require exits non-zero" "$rc"
	assert_contains "error mentions missing require" "not declared in require" "$output"
	return 0
}

# ============================================================================
# Test: status command
# ============================================================================

test_status() {
	echo ""
	echo "--- test_status ---"

	local output
	output=$(bash "$HELPER" status 2>&1)
	local rc=$?

	assert_exit_zero "status exits 0" "$rc"
	assert_contains "status shows Dependencies section" "Dependencies:" "$output"
	assert_contains "status shows python3" "python3" "$output"
	assert_contains "status shows jq" "jq" "$output"
	return 0
}

# ============================================================================
# Test: deploy requires SIEVE_PASSWORD
# ============================================================================

test_deploy_requires_password() {
	echo ""
	echo "--- test_deploy_requires_password ---"

	# Ensure SIEVE_PASSWORD is not set
	local output rc
	output=$(env -u SIEVE_PASSWORD bash "$HELPER" deploy \
		--server mail.example.com \
		--user user@example.com \
		--file "$TEST_OUTPUT" 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "deploy without SIEVE_PASSWORD exits non-zero" "$rc"
	assert_contains "error mentions SIEVE_PASSWORD" "SIEVE_PASSWORD" "$output"
	return 0
}

test_deploy_requires_server() {
	echo ""
	echo "--- test_deploy_requires_server ---"

	local output rc
	output=$(bash "$HELPER" deploy \
		--user user@example.com 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "deploy without --server exits non-zero" "$rc"
	assert_contains "error mentions --server" "--server" "$output"
	return 0
}

test_deploy_requires_user() {
	echo ""
	echo "--- test_deploy_requires_user ---"

	local output rc
	output=$(bash "$HELPER" deploy \
		--server mail.example.com 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "deploy without --user exits non-zero" "$rc"
	assert_contains "error mentions --user" "--user" "$output"
	return 0
}

# ============================================================================
# Test: list-scripts requires server and user
# ============================================================================

test_list_scripts_requires_server_user() {
	echo ""
	echo "--- test_list_scripts_requires_server_user ---"

	local output rc
	output=$(bash "$HELPER" list-scripts 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "list-scripts without args exits non-zero" "$rc"
	assert_contains "error mentions --server and --user" "--server" "$output"
	return 0
}

# ============================================================================
# Test: priority ordering in generated output
# ============================================================================

test_priority_ordering() {
	echo ""
	echo "--- test_priority_ordering ---"

	local prio_patterns="${TEST_WORKSPACE}/prio-patterns.json"
	local prio_output="${TEST_WORKSPACE}/prio.sieve"

	# Add patterns in reverse priority order
	bash "$HELPER" add-pattern \
		--type domain \
		--value "lowprio.com" \
		--folder "INBOX/Low" \
		--priority 90 \
		--patterns "$prio_patterns" >/dev/null 2>&1

	bash "$HELPER" add-pattern \
		--type sender \
		--value "highprio@example.com" \
		--folder "INBOX/High" \
		--priority 10 \
		--patterns "$prio_patterns" >/dev/null 2>&1

	bash "$HELPER" generate \
		--patterns "$prio_patterns" \
		--output "$prio_output" >/dev/null 2>&1

	local content
	content=$(cat "$prio_output")

	# High priority (10) should appear before low priority (90)
	local high_pos low_pos
	high_pos=$(grep -n "highprio@example.com" "$prio_output" | head -1 | cut -d: -f1)
	low_pos=$(grep -n "lowprio.com" "$prio_output" | head -1 | cut -d: -f1)

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -n "$high_pos" && -n "$low_pos" && "$high_pos" -lt "$low_pos" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: high priority pattern appears before low priority pattern"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: priority ordering incorrect (high=$high_pos, low=$low_pos)"
	fi
	return 0
}

# ============================================================================
# Test: config template files exist
# ============================================================================

test_config_templates_exist() {
	echo ""
	echo "--- test_config_templates_exist ---"

	assert_file_exists "email-sieve-config.json.txt exists" \
		"${REPO_ROOT}/.agents/configs/email-sieve-config.json.txt"

	assert_file_exists "email-sieve-patterns.json.txt exists" \
		"${REPO_ROOT}/.agents/configs/email-sieve-patterns.json.txt"
	return 0
}

# ============================================================================
# Test: unknown command
# ============================================================================

test_unknown_command() {
	echo ""
	echo "--- test_unknown_command ---"

	local output rc
	output=$(bash "$HELPER" unknown-command 2>&1) && rc=0 || rc=$?

	assert_exit_nonzero "unknown command exits non-zero" "$rc"
	assert_contains "error mentions unknown command" "Unknown command" "$output"
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	echo "=== test-email-sieve-helper.sh ==="
	echo "Helper: $HELPER"
	echo ""

	if [[ ! -f "$HELPER" ]]; then
		echo "ERROR: Helper script not found: $HELPER"
		exit 1
	fi

	if ! command -v jq &>/dev/null; then
		echo "ERROR: jq is required for tests"
		exit 1
	fi

	# Run tests in dependency order
	test_help
	test_add_pattern_sender
	test_add_pattern_domain
	test_add_pattern_transaction
	test_add_pattern_mailing_list
	test_add_pattern_notification
	test_add_pattern_invalid_type
	test_add_pattern_missing_folder
	test_generate_sieve
	test_generated_sieve_has_require
	test_generated_sieve_has_sender_rule
	test_generated_sieve_has_domain_rule
	test_generated_sieve_has_transaction_rules
	test_generated_sieve_has_mailing_list_rules
	test_generated_sieve_has_notification_rules
	test_generated_sieve_has_keep
	test_generated_sieve_balanced_braces
	test_generate_with_flags
	test_generate_subject_pattern
	test_generate_list_id_pattern
	test_generate_header_pattern
	test_generate_empty_patterns
	test_generate_missing_patterns
	test_validate_valid_sieve
	test_validate_missing_file
	test_validate_unbalanced_braces
	test_validate_missing_require
	test_status
	test_deploy_requires_password
	test_deploy_requires_server
	test_deploy_requires_user
	test_list_scripts_requires_server_user
	test_priority_ordering
	test_config_templates_exist
	test_unknown_command

	echo ""
	echo "=== Results ==="
	echo "Tests run:    $TESTS_RUN"
	echo "Tests passed: $TESTS_PASSED"
	echo "Tests failed: $TESTS_FAILED"
	echo ""

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		echo "FAIL: $TESTS_FAILED test(s) failed"
		exit 1
	else
		echo "PASS: All $TESTS_PASSED tests passed"
		exit 0
	fi
}

main "$@"
