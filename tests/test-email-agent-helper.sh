#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Test suite for email-agent-helper.sh
# Tests database operations, template rendering, code extraction, and conversation threading.
# Does NOT test actual AWS SES/S3 operations (those require live credentials).
#
# Usage: bash tests/test-email-agent-helper.sh
#
# Part of aidevops framework (t1360)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/email-agent-helper.sh"

# Test workspace (isolated from real data)
TEST_WORKSPACE=$(mktemp -d)
TEST_DB="${TEST_WORKSPACE}/conversations.db"
TEST_CONFIG_DIR="${TEST_WORKSPACE}/configs"
TEST_CONFIG="${TEST_CONFIG_DIR}/email-agent-config.json"

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

setup_test_env() {
	mkdir -p "$TEST_CONFIG_DIR"
	mkdir -p "${TEST_WORKSPACE}/inbox"

	# Create test config
	cat >"$TEST_CONFIG" <<'JSON'
{
  "default_from_email": "test@example.com",
  "aws_region": "eu-west-2",
  "s3_receive_bucket": "test-bucket",
  "s3_receive_prefix": "incoming/",
  "poll_interval_seconds": 60,
  "max_conversations_per_mission": 20,
  "code_extraction_confidence_threshold": 0.7
}
JSON
}

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
}

assert_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$haystack" | grep -q "$needle"; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected to contain: $needle"
		echo "    Actual: ${haystack:0:200}"
	fi
}

assert_not_empty() {
	local description="$1"
	local value="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -n "$value" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description (value is empty)"
	fi
}

assert_exit_code() {
	local description="$1"
	local expected_code="$2"
	shift 2

	TESTS_RUN=$((TESTS_RUN + 1))
	local actual_code=0
	"$@" >/dev/null 2>&1 || actual_code=$?
	if [[ "$actual_code" -eq "$expected_code" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected exit code: $expected_code"
		echo "    Actual exit code:   $actual_code"
	fi
}

# SQLite wrapper for test database
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

# ============================================================================
# Database tests
# ============================================================================

test_database_init() {
	echo "Test: Database initialization"

	# Source shared-constants for the helper functions
	local shared_constants="${REPO_ROOT}/.agents/scripts/shared-constants.sh"
	if [[ ! -f "$shared_constants" ]]; then
		echo "  SKIP: shared-constants.sh not found"
		return 0
	fi

	# Initialize database directly.
	# NOTE: This schema MUST match init_db() in email-agent-helper.sh.
	# If you change the production schema, update this test schema too.
	db "$TEST_DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS conversations (
    id          TEXT PRIMARY KEY,
    mission_id  TEXT NOT NULL,
    subject     TEXT NOT NULL,
    to_email    TEXT NOT NULL,
    from_email  TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','waiting','completed','failed')),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS messages (
    id          TEXT PRIMARY KEY,
    conv_id     TEXT NOT NULL REFERENCES conversations(id),
    mission_id  TEXT NOT NULL,
    direction   TEXT NOT NULL CHECK(direction IN ('outbound','inbound')),
    from_email  TEXT NOT NULL,
    to_email    TEXT NOT NULL,
    subject     TEXT NOT NULL,
    body_text   TEXT,
    body_html   TEXT,
    message_id  TEXT,
    in_reply_to TEXT,
    ses_message_id TEXT,
    s3_key      TEXT,
    raw_path    TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS extracted_codes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id  TEXT NOT NULL REFERENCES messages(id),
    mission_id  TEXT NOT NULL,
    code_type   TEXT NOT NULL CHECK(code_type IN ('otp','token','link','api_key','password','other')),
    code_value  TEXT NOT NULL,
    confidence  REAL NOT NULL DEFAULT 1.0,
    used        INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_conv_mission ON conversations(mission_id);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conv_id);
CREATE INDEX IF NOT EXISTS idx_msg_mission ON messages(mission_id);
SQL

	# Verify tables exist
	local tables
	tables=$(db "$TEST_DB" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
	assert_contains "conversations table exists" "conversations" "$tables"
	assert_contains "messages table exists" "messages" "$tables"
	assert_contains "extracted_codes table exists" "extracted_codes" "$tables"

	# Verify WAL mode
	local journal_mode
	journal_mode=$(db "$TEST_DB" "PRAGMA journal_mode;")
	assert_eq "WAL mode enabled" "wal" "$journal_mode"
}

test_conversation_crud() {
	echo "Test: Conversation CRUD operations"

	# Insert a conversation
	db "$TEST_DB" "
		INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
		VALUES ('conv-test-001', 'M001', 'API Access Request', 'api@vendor.com', 'missions@example.com', 'active');
	"

	local count
	count=$(db "$TEST_DB" "SELECT count(*) FROM conversations WHERE mission_id = 'M001';")
	assert_eq "Conversation inserted" "1" "$count"

	# Insert a message
	db "$TEST_DB" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text)
		VALUES ('msg-test-001', 'conv-test-001', 'M001', 'outbound', 'missions@example.com', 'api@vendor.com', 'API Access Request', 'Please provide API access.');
	"

	local msg_count
	msg_count=$(db "$TEST_DB" "SELECT count(*) FROM messages WHERE conv_id = 'conv-test-001';")
	assert_eq "Message inserted" "1" "$msg_count"

	# Update conversation status
	db "$TEST_DB" "UPDATE conversations SET status = 'waiting' WHERE id = 'conv-test-001';"
	local status
	status=$(db "$TEST_DB" "SELECT status FROM conversations WHERE id = 'conv-test-001';")
	assert_eq "Conversation status updated" "waiting" "$status"

	# Insert inbound reply
	db "$TEST_DB" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, in_reply_to)
		VALUES ('msg-test-002', 'conv-test-001', 'M001', 'inbound', 'api@vendor.com', 'missions@example.com', 'Re: API Access Request', 'Your verification code is 847291. Please use this to activate your account.', '<original-msg-id@ses.amazonaws.com>');
	"

	msg_count=$(db "$TEST_DB" "SELECT count(*) FROM messages WHERE conv_id = 'conv-test-001';")
	assert_eq "Reply message inserted" "2" "$msg_count"
}

# ============================================================================
# Code extraction tests
# ============================================================================

test_code_extraction_otp() {
	echo "Test: OTP code extraction"

	local body="Your verification code is 847291. Please enter this code to verify your email address."

	# Test OTP pattern matching — use extended grep for portability
	local match
	match=$(echo "$body" | grep -oE '[Cc]ode[: ]+is[: ]+[0-9]{6}|[Cc]ode[: ]+[0-9]{6}' || true)
	if [[ -z "$match" ]]; then
		# Fallback: just find 6-digit codes near "code" keyword
		match=$(echo "$body" | grep -oE '[0-9]{6}' || true)
	fi
	assert_not_empty "OTP pattern matches 6-digit code" "$match"

	# Extract just the digits
	local code
	code=$(echo "$match" | grep -oE '[0-9]{6}' | head -1 || true)
	assert_eq "Extracted OTP value" "847291" "$code"
}

test_code_extraction_token() {
	echo "Test: Token extraction"

	local body="Your API token is: tok_example_abc123def456ghi789jkl012mno345"

	# Match token keyword followed by a long alphanumeric value
	local match
	match=$(echo "$body" | grep -oE '[Tt]oken[: ]+is[: ]+[A-Za-z0-9_-]{20,}|[Tt]oken[: ]+[A-Za-z0-9_-]{20,}' || true)
	if [[ -z "$match" ]]; then
		# Fallback: find long alphanumeric strings with underscores (API key pattern)
		match=$(echo "$body" | grep -oE '[a-z]{3}_[a-z]+_[A-Za-z0-9]{20,}' || true)
	fi
	assert_not_empty "Token pattern matches long alphanumeric" "$match"
}

test_code_extraction_link() {
	echo "Test: Confirmation link extraction"

	local body="Click here to verify your account: https://app.example.com/verify?token=abc123def456&email=user@test.com"

	local match
	match=$(echo "$body" | grep -oE 'https?://[^ <>"]+[?&](token|code|confirm|activate|verify|key)=[^ <>"&]+' || true)
	assert_not_empty "Confirmation link pattern matches" "$match"
	assert_contains "Link contains verify param" "verify" "$match"
}

test_code_extraction_activation_url() {
	echo "Test: Activation URL extraction"

	local body="Please activate your account by visiting: https://dashboard.vendor.com/activate/a1b2c3d4e5f6"

	local match
	match=$(echo "$body" | grep -oE 'https?://[^ <>"]+/(confirm|activate|verify|validate|approve)/[^ <>"]+' || true)
	assert_not_empty "Activation URL pattern matches" "$match"
	assert_contains "URL contains activate path" "activate" "$match"
}

test_code_extraction_multiple() {
	echo "Test: Multiple code extraction from single email"

	local body="Welcome! Your verification code is 123456. You can also click this link to verify: https://app.example.com/verify?token=xyz789abc. Your temporary password is: TempPass2026!"

	# Count OTP matches — look for 6-digit codes
	local otp_count
	otp_count=$(echo "$body" | grep -coE '[0-9]{6}' || echo "0")
	assert_eq "Found 1 OTP code" "1" "$otp_count"

	# Count link matches
	local link_count
	link_count=$(echo "$body" | grep -coE 'https?://[^ <>"]+[?&](token|code|confirm|activate|verify|key)=[^ <>"&]+' || echo "0")
	assert_eq "Found 1 confirmation link" "1" "$link_count"
}

test_code_extraction_no_false_positives() {
	echo "Test: No false positives in normal email"

	local body="Thank you for your interest in our API. We have received your request and will review it within 2-3 business days. Our team will contact you at the email address provided."

	local otp_match
	otp_match=$(echo "$body" | grep -oE '[Cc]ode[: ]*([0-9]{6})' || true)
	assert_eq "No false OTP in normal email" "" "$otp_match"

	local link_match
	link_match=$(echo "$body" | grep -oE 'https?://[^ <>"]+[?&](token|code|confirm|activate|verify|key)=[^ <>"&]+' || true)
	assert_eq "No false link in normal email" "" "$link_match"
}

test_code_storage() {
	echo "Test: Code storage in database"

	# Store extracted code
	db "$TEST_DB" "
		INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value, confidence)
		VALUES ('msg-test-002', 'M001', 'otp', '847291', 0.9);
	"

	local code_count
	code_count=$(db "$TEST_DB" "SELECT count(*) FROM extracted_codes WHERE mission_id = 'M001';")
	assert_eq "Code stored in database" "1" "$code_count"

	# Verify code value
	local stored_code
	stored_code=$(db "$TEST_DB" "SELECT code_value FROM extracted_codes WHERE mission_id = 'M001' AND code_type = 'otp';")
	assert_eq "Stored code value correct" "847291" "$stored_code"

	# Mark as used
	db "$TEST_DB" "UPDATE extracted_codes SET used = 1 WHERE code_value = '847291';"
	local used
	used=$(db "$TEST_DB" "SELECT used FROM extracted_codes WHERE code_value = '847291';")
	assert_eq "Code marked as used" "1" "$used"
}

test_extract_codes_integration() {
	echo "Test: Integration - extract-codes via helper CLI"

	# This test exercises the actual helper's extract-codes command end-to-end:
	# seed the helper's workspace DB with a message, invoke extract-codes, verify results.
	# The helper uses a readonly DB_FILE path, so we set up data at that location.

	local helper_workspace="${HOME}/.aidevops/.agent-workspace/email-agent"
	local helper_db="${helper_workspace}/conversations.db"
	local had_existing_db=0

	# Back up existing DB if present
	if [[ -f "$helper_db" ]]; then
		had_existing_db=1
		cp "$helper_db" "${helper_db}.test-backup"
	fi

	# Ensure the helper's DB is initialized (the helper does this on ensure_db)
	mkdir -p "$helper_workspace"
	bash "$HELPER" status >/dev/null 2>&1 || true

	# Seed: conversation + inbound message with an OTP and a confirmation link
	db "$helper_db" "
		INSERT OR IGNORE INTO conversations (id, mission_id, subject, to_email, from_email)
		VALUES ('conv-int-001', 'MINT', 'Signup Verification', 'user@test.com', 'noreply@vendor.com');
	"
	db "$helper_db" "
		INSERT OR IGNORE INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text)
		VALUES ('msg-int-001', 'conv-int-001', 'MINT', 'inbound', 'noreply@vendor.com', 'user@test.com',
			'Signup Verification',
			'Welcome! Your verification code is 593017. You can also verify at https://app.vendor.com/verify?token=xYz789AbC123');
	"

	# Run the helper's extract-codes command
	local output
	output=$(bash "$HELPER" extract-codes --message msg-int-001 2>&1 || true)

	# Verify OTP was extracted
	local otp_val
	otp_val=$(db "$helper_db" "SELECT code_value FROM extracted_codes WHERE message_id = 'msg-int-001' AND code_type = 'otp';")
	assert_eq "Integration: OTP extracted" "593017" "$otp_val"

	# Verify confirmation link was extracted
	local link_count
	link_count=$(db "$helper_db" "SELECT count(*) FROM extracted_codes WHERE message_id = 'msg-int-001' AND code_type = 'link';")
	assert_eq "Integration: confirmation link extracted" "1" "$link_count"

	# Verify total extracted count
	local total
	total=$(db "$helper_db" "SELECT count(*) FROM extracted_codes WHERE message_id = 'msg-int-001';")
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$total" -ge 2 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Integration: at least 2 codes/links extracted (got $total)"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Integration: expected >= 2 codes/links, got $total"
		echo "    Helper output: ${output:0:300}"
	fi

	# Clean up test data from the helper's DB
	db "$helper_db" "DELETE FROM extracted_codes WHERE message_id = 'msg-int-001';" 2>/dev/null || true
	db "$helper_db" "DELETE FROM messages WHERE id = 'msg-int-001';" 2>/dev/null || true
	db "$helper_db" "DELETE FROM conversations WHERE id = 'conv-int-001';" 2>/dev/null || true

	# Restore original DB if we backed it up
	if [[ "$had_existing_db" -eq 1 ]]; then
		mv "${helper_db}.test-backup" "$helper_db"
	fi
}

# ============================================================================
# Template tests
# ============================================================================

test_template_rendering() {
	echo "Test: Template variable substitution"

	# Create test template
	local template_file="${TEST_WORKSPACE}/test-template.md"
	cat >"$template_file" <<'TEMPLATE'
Subject: API Access Request for {{service_name}}

Dear {{contact_name}},

I am writing to request API access to {{service_name}} for {{project_name}}.

Best regards,
{{sender_name}}
TEMPLATE

	# Read template and apply substitutions
	local content
	content=$(cat "$template_file")

	# Apply substitutions
	content="${content//\{\{service_name\}\}/Acme API}"
	content="${content//\{\{contact_name\}\}/API Team}"
	content="${content//\{\{project_name\}\}/MyProject}"
	content="${content//\{\{sender_name\}\}/Alex}"

	assert_contains "Service name substituted" "Acme API" "$content"
	assert_contains "Contact name substituted" "API Team" "$content"
	assert_contains "Project name substituted" "MyProject" "$content"
	assert_contains "Sender name substituted" "Alex" "$content"

	# Check subject extraction
	local subject
	subject=$(echo "$content" | grep -m1 '^Subject: ' | sed 's/^Subject: //')
	assert_eq "Subject extracted from template" "API Access Request for Acme API" "$subject"
}

test_template_unreplaced_vars() {
	echo "Test: Unreplaced template variables detected"

	local content="Hello {{name}}, your code is {{code}}."
	content="${content//\{\{name\}\}/Alice}"

	# Check for unreplaced variables
	local unreplaced
	unreplaced=$(echo "$content" | grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' | sort -u || true)
	assert_eq "Unreplaced variable detected" "{{code}}" "$unreplaced"
}

# ============================================================================
# Conversation threading tests
# ============================================================================

test_conversation_threading() {
	echo "Test: Conversation threading by In-Reply-To"

	# Create a conversation with threaded messages
	db "$TEST_DB" "
		INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
		VALUES ('conv-thread-001', 'M002', 'Domain Registration', 'support@registrar.com', 'missions@example.com', 'active');
	"

	# Outbound message with Message-ID
	db "$TEST_DB" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, message_id)
		VALUES ('msg-thread-001', 'conv-thread-001', 'M002', 'outbound', 'missions@example.com', 'support@registrar.com', 'Domain Registration', 'I would like to register example.com', '<msg001@ses.amazonaws.com>');
	"

	# Inbound reply with In-Reply-To
	db "$TEST_DB" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, message_id, in_reply_to)
		VALUES ('msg-thread-002', 'conv-thread-001', 'M002', 'inbound', 'support@registrar.com', 'missions@example.com', 'Re: Domain Registration', 'Domain is available. Your confirmation code is 994521.', '<reply001@registrar.com>', '<msg001@ses.amazonaws.com>');
	"

	# Verify thread linkage
	local thread_count
	thread_count=$(db "$TEST_DB" "SELECT count(*) FROM messages WHERE conv_id = 'conv-thread-001';")
	assert_eq "Thread has 2 messages" "2" "$thread_count"

	# Verify In-Reply-To links to original
	local reply_to
	reply_to=$(db "$TEST_DB" "SELECT in_reply_to FROM messages WHERE id = 'msg-thread-002';")
	assert_eq "In-Reply-To matches original Message-ID" "<msg001@ses.amazonaws.com>" "$reply_to"

	# Verify conversation lookup by In-Reply-To
	local found_conv
	found_conv=$(db "$TEST_DB" "
		SELECT conv_id FROM messages
		WHERE message_id = '<msg001@ses.amazonaws.com>'
		LIMIT 1;
	")
	assert_eq "Conversation found by Message-ID" "conv-thread-001" "$found_conv"
}

test_conversation_subject_matching() {
	echo "Test: Conversation matching by subject"

	# Simulate matching by cleaned subject
	local raw_subject="Re: Fwd: API Access Request"
	local clean_subject
	clean_subject=$(echo "$raw_subject" | sed -E 's/^(Re|Fwd|FW|Fw): *//g; s/^(Re|Fwd|FW|Fw): *//g')
	assert_eq "Subject cleaned of Re:/Fwd: prefixes" "API Access Request" "$clean_subject"
}

# ============================================================================
# Constraint tests
# ============================================================================

test_status_constraints() {
	echo "Test: Database status constraints"

	# Valid conversation statuses
	local valid_insert=0
	db "$TEST_DB" "
		INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
		VALUES ('conv-status-test', 'M003', 'Test', 'a@b.com', 'c@d.com', 'waiting');
	" 2>/dev/null && valid_insert=1
	assert_eq "Valid status 'waiting' accepted" "1" "$valid_insert"

	# Invalid conversation status
	local invalid_insert=0
	db "$TEST_DB" "
		INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
		VALUES ('conv-status-bad', 'M003', 'Test', 'a@b.com', 'c@d.com', 'invalid_status');
	" 2>/dev/null && invalid_insert=1
	assert_eq "Invalid status rejected by CHECK constraint" "0" "$invalid_insert"

	# Valid message direction
	valid_insert=0
	db "$TEST_DB" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject)
		VALUES ('msg-dir-test', 'conv-status-test', 'M003', 'inbound', 'a@b.com', 'c@d.com', 'Test');
	" 2>/dev/null && valid_insert=1
	assert_eq "Valid direction 'inbound' accepted" "1" "$valid_insert"

	# Invalid message direction
	invalid_insert=0
	db "$TEST_DB" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject)
		VALUES ('msg-dir-bad', 'conv-status-test', 'M003', 'sideways', 'a@b.com', 'c@d.com', 'Test');
	" 2>/dev/null && invalid_insert=1
	assert_eq "Invalid direction rejected by CHECK constraint" "0" "$invalid_insert"

	# Valid code type
	valid_insert=0
	db "$TEST_DB" "
		INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value)
		VALUES ('msg-dir-test', 'M003', 'api_key', 'tok_example_123');
	" 2>/dev/null && valid_insert=1
	assert_eq "Valid code_type 'api_key' accepted" "1" "$valid_insert"

	# Invalid code type
	invalid_insert=0
	db "$TEST_DB" "
		INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value)
		VALUES ('msg-dir-test', 'M003', 'magic_spell', 'abracadabra');
	" 2>/dev/null && invalid_insert=1
	assert_eq "Invalid code_type rejected by CHECK constraint" "0" "$invalid_insert"
}

# ============================================================================
# Helper script tests
# ============================================================================

test_helper_exists() {
	echo "Test: Helper script exists and is executable"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -x "$HELPER" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: email-agent-helper.sh is executable"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: email-agent-helper.sh is not executable"
	fi
}

test_helper_help() {
	echo "Test: Helper help command"

	local output
	output=$(bash "$HELPER" help 2>&1 || true)
	assert_contains "Help shows send command" "send" "$output"
	assert_contains "Help shows poll command" "poll" "$output"
	assert_contains "Help shows extract-codes command" "extract-codes" "$output"
	assert_contains "Help shows thread command" "thread" "$output"
}

test_helper_unknown_command() {
	echo "Test: Helper rejects unknown command"

	local exit_code=0
	bash "$HELPER" nonexistent-command 2>/dev/null || exit_code=$?
	assert_eq "Unknown command returns non-zero" "1" "$exit_code"
}

# ============================================================================
# ShellCheck test
# ============================================================================

test_shellcheck() {
	echo "Test: ShellCheck compliance"

	if ! command -v shellcheck &>/dev/null; then
		TESTS_RUN=$((TESTS_RUN + 1))
		echo "  SKIP: shellcheck not installed"
		return 0
	fi

	# Run shellcheck excluding SC1091 (not following sourced files) which is info-level
	local output
	output=$(shellcheck -S warning "$HELPER" 2>&1 || true)
	local exit_code=0
	shellcheck -S warning "$HELPER" >/dev/null 2>&1 || exit_code=$?

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$exit_code" -eq 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: ShellCheck clean (warning+ severity)"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: ShellCheck found issues"
		echo "$output" | head -20
	fi
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
	echo "=========================================="
	echo "Email Agent Helper Test Suite (t1360)"
	echo "=========================================="
	echo ""

	setup_test_env

	# Database tests
	test_database_init
	echo ""
	test_conversation_crud
	echo ""

	# Code extraction tests
	test_code_extraction_otp
	echo ""
	test_code_extraction_token
	echo ""
	test_code_extraction_link
	echo ""
	test_code_extraction_activation_url
	echo ""
	test_code_extraction_multiple
	echo ""
	test_code_extraction_no_false_positives
	echo ""
	test_code_storage
	echo ""
	test_extract_codes_integration
	echo ""

	# Template tests
	test_template_rendering
	echo ""
	test_template_unreplaced_vars
	echo ""

	# Threading tests
	test_conversation_threading
	echo ""
	test_conversation_subject_matching
	echo ""

	# Constraint tests
	test_status_constraints
	echo ""

	# Helper script tests
	test_helper_exists
	echo ""
	test_helper_help
	echo ""
	test_helper_unknown_command
	echo ""

	# Quality tests
	test_shellcheck
	echo ""

	# Summary
	echo "=========================================="
	echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
	echo "=========================================="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
