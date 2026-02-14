#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for generate-manifest command in document-creation-helper.sh
# Validates _index.toon generation with document, thread, and contact indexes.
#
# Usage: bash tests/test-collection-manifest.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
HELPER="${REPO_DIR}/.agents/scripts/document-creation-helper.sh"
TEST_COLLECTION=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

setup() {
	TEST_COLLECTION=$(mktemp -d)

	# Create sample email markdown files with frontmatter
	cat >"${TEST_COLLECTION}/email1.md" <<'EOF'
---
title: "Meeting tomorrow"
description: "Hi team, let's meet tomorrow at 10am."
from: alice@example.com
to: bob@example.com
date_sent: "2026-01-15T10:30:00Z"
subject: "Meeting tomorrow"
size: "2.1 KB"
message_id: "<msg001@example.com>"
attachment_count: 0
attachments: []
tokens_estimate: 45
thread_id: "thread-001"
thread_position: "1"
thread_length: "3"
---

Hi team, let's meet tomorrow at 10am.
EOF

	cat >"${TEST_COLLECTION}/email2.md" <<'EOF'
---
title: "Re: Meeting tomorrow"
description: "Sounds good."
from: bob@example.com
to: alice@example.com
date_sent: "2026-01-15T11:00:00Z"
subject: "Re: Meeting tomorrow"
size: "1.8 KB"
message_id: "<msg002@example.com>"
in_reply_to: "<msg001@example.com>"
attachment_count: 0
attachments: []
tokens_estimate: 30
thread_id: "thread-001"
thread_position: "2"
thread_length: "3"
---

Sounds good.
EOF

	cat >"${TEST_COLLECTION}/email3.md" <<'EOF'
---
title: "Project update"
description: "Here is the latest update."
from: charlie@example.com
to: alice@example.com
date_sent: "2026-01-16T09:00:00Z"
subject: "Project update"
size: "15.3 KB"
message_id: "<msg003@example.com>"
attachment_count: 2
attachments:
  - filename: report.pdf
    size: "12.1 KB"
  - filename: data.xlsx
    size: "3.2 KB"
tokens_estimate: 120
---

Here is the latest update.
EOF

	# Create contacts
	mkdir -p "${TEST_COLLECTION}/contacts"

	cat >"${TEST_COLLECTION}/contacts/alice-at-example-com.toon" <<'EOF'
contact:
  email: alice@example.com
  name: Alice Smith
  title: Project Manager
  company: Example Corp
  phone: +1-555-0101
  website: https://example.com
  address: 123 Main St
  source: email-signature
  first_seen: 2026-01-15T10:30:00Z
  last_seen: 2026-01-16T09:00:00Z
  confidence: high
EOF

	cat >"${TEST_COLLECTION}/contacts/bob-at-example-com.toon" <<'EOF'
contact:
  email: bob@example.com
  name: Bob Jones
  title: Developer
  company: Example Corp
  phone:
  website:
  address:
  source: email-signature
  first_seen: 2026-01-15T11:00:00Z
  last_seen: 2026-01-15T11:00:00Z
  confidence: medium
EOF

	return 0
}

teardown() {
	if [[ -n "$TEST_COLLECTION" && -d "$TEST_COLLECTION" ]]; then
		rm -rf "$TEST_COLLECTION"
	fi
	return 0
}

assert_contains() {
	local file="$1"
	local pattern="$2"
	local description="$3"

	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (pattern '$pattern' not found)"
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

# ============================================================================
# Tests
# ============================================================================

test_basic_manifest_generation() {
	echo "Test: Basic manifest generation"
	setup

	"$HELPER" generate-manifest "$TEST_COLLECTION" >/dev/null 2>&1
	local rc=$?
	assert_exit_code 0 "$rc" "generate-manifest exits 0"

	local index="${TEST_COLLECTION}/_index.toon"
	assert_contains "$index" "^# Collection manifest" "Has manifest header"
	assert_contains "$index" "^# Generated:" "Has generation timestamp"
	assert_contains "$index" "^documents\[3\]" "Documents count is 3"
	assert_contains "$index" "^threads\[1\]" "Threads count is 1"
	assert_contains "$index" "^contacts\[2\]" "Contacts count is 2"

	teardown
}

test_document_index_fields() {
	echo "Test: Document index contains correct fields"
	setup

	"$HELPER" generate-manifest "$TEST_COLLECTION" >/dev/null 2>&1
	local index="${TEST_COLLECTION}/_index.toon"

	assert_contains "$index" "email1\.md" "Contains email1.md path"
	assert_contains "$index" "email2\.md" "Contains email2.md path"
	assert_contains "$index" "email3\.md" "Contains email3.md path"
	assert_contains "$index" "alice@example\.com" "Contains alice email"
	assert_contains "$index" "bob@example\.com" "Contains bob email"
	assert_contains "$index" "charlie@example\.com" "Contains charlie email"
	assert_contains "$index" "<msg001@example\.com>" "Contains message_id"
	assert_contains "$index" "<msg002@example\.com>" "Contains reply message_id"

	teardown
}

test_thread_index() {
	echo "Test: Thread index groups messages correctly"
	setup

	"$HELPER" generate-manifest "$TEST_COLLECTION" >/dev/null 2>&1
	local index="${TEST_COLLECTION}/_index.toon"

	assert_contains "$index" "thread-001" "Contains thread ID"
	assert_contains "$index" "Meeting tomorrow" "Thread has subject"
	# Thread has 2 messages (email1 and email2 have thread_id)
	assert_contains "$index" "thread-001.*2" "Thread has 2 messages"

	teardown
}

test_contact_index() {
	echo "Test: Contact index extracts metadata"
	setup

	"$HELPER" generate-manifest "$TEST_COLLECTION" >/dev/null 2>&1
	local index="${TEST_COLLECTION}/_index.toon"

	assert_contains "$index" "Alice Smith" "Contains Alice's name"
	assert_contains "$index" "Bob Jones" "Contains Bob's name"
	assert_contains "$index" "Project Manager" "Contains Alice's title"
	assert_contains "$index" "Example Corp" "Contains company"
	assert_contains "$index" "high" "Contains confidence level"

	teardown
}

test_empty_directory() {
	echo "Test: Empty directory produces valid manifest"
	local empty_dir
	empty_dir=$(mktemp -d)

	"$HELPER" generate-manifest "$empty_dir" >/dev/null 2>&1
	local rc=$?
	assert_exit_code 0 "$rc" "Empty dir exits 0"

	local index="${empty_dir}/_index.toon"
	assert_contains "$index" "^documents\[0\]" "Documents count is 0"
	assert_contains "$index" "^threads\[0\]" "Threads count is 0"
	assert_contains "$index" "^contacts\[0\]" "Contacts count is 0"

	rm -rf "$empty_dir"
}

test_custom_output_path() {
	echo "Test: Custom output path with --output flag"
	setup

	local custom_output
	custom_output=$(mktemp)
	"$HELPER" generate-manifest "$TEST_COLLECTION" --output "$custom_output" >/dev/null 2>&1
	local rc=$?
	assert_exit_code 0 "$rc" "Custom output exits 0"
	assert_contains "$custom_output" "^documents\[3\]" "Custom output has documents"

	rm -f "$custom_output"
	teardown
}

test_missing_directory_error() {
	echo "Test: Missing directory returns error"
	local rc=0
	"$HELPER" generate-manifest /nonexistent/path >/dev/null 2>&1 || rc=$?
	assert_exit_code 1 "$rc" "Missing dir exits 1"
}

test_no_args_error() {
	echo "Test: No arguments returns error"
	local rc=0
	"$HELPER" generate-manifest >/dev/null 2>&1 || rc=$?
	assert_exit_code 1 "$rc" "No args exits 1"
}

test_no_thread_data() {
	echo "Test: Documents without thread_id produce empty threads index"
	local no_thread_dir
	no_thread_dir=$(mktemp -d)

	cat >"${no_thread_dir}/standalone.md" <<'EOF'
---
title: "Standalone email"
from: user@example.com
to: other@example.com
date_sent: "2026-01-20T12:00:00Z"
message_id: "<standalone@example.com>"
attachment_count: 0
tokens_estimate: 20
---

A standalone email with no thread.
EOF

	"$HELPER" generate-manifest "$no_thread_dir" >/dev/null 2>&1
	local index="${no_thread_dir}/_index.toon"
	assert_contains "$index" "^documents\[1\]" "Has 1 document"
	assert_contains "$index" "^threads\[0\]" "Has 0 threads"

	rm -rf "$no_thread_dir"
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=== Collection Manifest Test Suite ==="
echo ""

test_basic_manifest_generation
test_document_index_fields
test_thread_index
test_contact_index
test_empty_directory
test_custom_output_path
test_missing_directory_error
test_no_args_error
test_no_thread_data

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
