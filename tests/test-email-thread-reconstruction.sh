#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test email thread reconstruction functionality
# Part of aidevops framework test suite

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit
source "${PROJECT_ROOT}/.agents/scripts/shared-constants.sh"

readonly THREAD_RECON_SCRIPT="${PROJECT_ROOT}/.agents/scripts/email-thread-reconstruction.py"
readonly TEST_DIR="/tmp/test-email-threads-$$"

# =============================================================================
# Test Setup
# =============================================================================

setup_test_data() {
	mkdir -p "$TEST_DIR"

	# Create test email 1 (root)
	cat >"${TEST_DIR}/email1.md" <<'EOF'
---
title: "Test thread root"
from: "alice@test.com"
to: "team@test.com"
date_sent: "2026-02-10T09:00:00+0000"
subject: "Test thread root"
message_id: "<test-001@test.com>"
tokens_estimate: 10
---

Root message
EOF

	# Create test email 2 (reply to 1)
	cat >"${TEST_DIR}/email2.md" <<'EOF'
---
title: "Re: Test thread root"
from: "bob@test.com"
to: "team@test.com"
date_sent: "2026-02-10T10:00:00+0000"
subject: "Re: Test thread root"
message_id: "<test-002@test.com>"
in_reply_to: "<test-001@test.com>"
tokens_estimate: 10
---

Reply 1
EOF

	# Create test email 3 (reply to 2)
	cat >"${TEST_DIR}/email3.md" <<'EOF'
---
title: "Re: Test thread root"
from: "charlie@test.com"
to: "team@test.com"
date_sent: "2026-02-10T11:00:00+0000"
subject: "Re: Test thread root"
message_id: "<test-003@test.com>"
in_reply_to: "<test-002@test.com>"
tokens_estimate: 10
---

Reply 2
EOF

	# Create standalone email (different thread)
	cat >"${TEST_DIR}/email4.md" <<'EOF'
---
title: "Standalone message"
from: "dave@test.com"
to: "team@test.com"
date_sent: "2026-02-11T09:00:00+0000"
subject: "Standalone message"
message_id: "<test-004@test.com>"
tokens_estimate: 10
---

Standalone
EOF
}

cleanup_test_data() {
	rm -rf "$TEST_DIR"
}

# =============================================================================
# Tests
# =============================================================================

test_thread_reconstruction() {
	print_info "Test: Thread reconstruction"

	# Run thread reconstruction
	if ! python3 "$THREAD_RECON_SCRIPT" "$TEST_DIR" >/dev/null 2>&1; then
		print_error "Thread reconstruction failed"
		return 1
	fi

	# Verify thread index was created
	if [[ ! -f "${TEST_DIR}/thread-index.md" ]]; then
		print_error "Thread index file not created"
		return 1
	fi

	print_success "Thread reconstruction succeeded"
	return 0
}

test_frontmatter_updates() {
	print_info "Test: Frontmatter updates"

	# Check email1 (root)
	if ! grep -q "thread_id: \"<test-001@test.com>\"" "${TEST_DIR}/email1.md"; then
		print_error "email1: thread_id not set correctly"
		return 1
	fi
	if ! grep -q "thread_position: 0" "${TEST_DIR}/email1.md"; then
		print_error "email1: thread_position should be 0"
		return 1
	fi
	if ! grep -q "thread_length: 3" "${TEST_DIR}/email1.md"; then
		print_error "email1: thread_length should be 3"
		return 1
	fi

	# Check email2 (first reply)
	if ! grep -q "thread_id: \"<test-001@test.com>\"" "${TEST_DIR}/email2.md"; then
		print_error "email2: thread_id not set correctly"
		return 1
	fi
	if ! grep -q "thread_position: 1" "${TEST_DIR}/email2.md"; then
		print_error "email2: thread_position should be 1"
		return 1
	fi
	if ! grep -q "thread_length: 3" "${TEST_DIR}/email2.md"; then
		print_error "email2: thread_length should be 3"
		return 1
	fi

	# Check email3 (second reply)
	if ! grep -q "thread_position: 2" "${TEST_DIR}/email3.md"; then
		print_error "email3: thread_position should be 2"
		return 1
	fi

	# Check email4 (standalone)
	if ! grep -q "thread_id: \"<test-004@test.com>\"" "${TEST_DIR}/email4.md"; then
		print_error "email4: thread_id should be its own message_id"
		return 1
	fi
	if ! grep -q "thread_position: 0" "${TEST_DIR}/email4.md"; then
		print_error "email4: thread_position should be 0"
		return 1
	fi
	if ! grep -q "thread_length: 1" "${TEST_DIR}/email4.md"; then
		print_error "email4: thread_length should be 1"
		return 1
	fi

	print_success "Frontmatter updates correct"
	return 0
}

test_thread_index_content() {
	print_info "Test: Thread index content"

	local index_file="${TEST_DIR}/thread-index.md"

	# Check for 2 threads
	local thread_count
	thread_count=$(grep -c "^## Thread:" "$index_file" || true)
	if [[ "$thread_count" -ne 2 ]]; then
		print_error "Expected 2 threads, found $thread_count"
		return 1
	fi

	# Check for thread with 3 messages
	if ! grep -q "Test thread root (3 messages)" "$index_file"; then
		print_error "Thread with 3 messages not found"
		return 1
	fi

	# Check for standalone thread with 1 message
	if ! grep -q "Standalone message (1 messages)" "$index_file"; then
		print_error "Standalone thread not found"
		return 1
	fi

	print_success "Thread index content correct"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	print_info "Starting email thread reconstruction tests"

	setup_test_data

	local failed=0

	test_thread_reconstruction || failed=$((failed + 1))
	test_frontmatter_updates || failed=$((failed + 1))
	test_thread_index_content || failed=$((failed + 1))

	cleanup_test_data

	if [[ "$failed" -eq 0 ]]; then
		print_success "All tests passed"
		return 0
	else
		print_error "$failed test(s) failed"
		return 1
	fi
}

main "$@"
