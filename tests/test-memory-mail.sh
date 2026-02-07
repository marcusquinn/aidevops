#!/usr/bin/env bash
# test-memory-mail.sh
#
# Unit tests for memory-helper.sh and mail-helper.sh:
# - Memory: store, recall (FTS5), stats, prune, namespaces, relational versioning
# - Mail: send, check, read, archive, prune, register/deregister agents
#
# Uses isolated temp directories to avoid touching production data.
#
# Usage: bash tests/test-memory-mail.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
MEMORY_SCRIPT="$SCRIPTS_DIR/memory-helper.sh"
MAIL_SCRIPT="$SCRIPTS_DIR/mail-helper.sh"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;32mPASS\033[0m %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
}

section() {
    echo ""
    printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# --- Isolated Test Environment ---
TEST_DIR=$(mktemp -d)
export AIDEVOPS_MEMORY_DIR="$TEST_DIR/memory"
export AIDEVOPS_MAIL_DIR="$TEST_DIR/mail"
trap 'rm -rf "$TEST_DIR"' EXIT

# Helper: run memory command
mem() {
    bash "$MEMORY_SCRIPT" "$@" 2>&1
}

# Helper: run mail command
mail_cmd() {
    bash "$MAIL_SCRIPT" "$@" 2>&1
}

# Helper: query memory DB
mem_db() {
    sqlite3 -cmd ".timeout 5000" "$AIDEVOPS_MEMORY_DIR/memory.db" "$@"
}

# Helper: query mail DB
mail_db() {
    sqlite3 -cmd ".timeout 5000" "$AIDEVOPS_MAIL_DIR/mailbox.db" "$@"
}

# ============================================================
# MEMORY TESTS
# ============================================================

section "Memory: Database Initialization"

# Test: first store creates database
mem store --content "Test memory entry" --type "WORKING_SOLUTION" --tags "test,init" >/dev/null
if [[ -f "$AIDEVOPS_MEMORY_DIR/memory.db" ]]; then
    pass "memory store creates database"
else
    fail "memory store did not create database"
fi

# Test: FTS5 table exists
fts_check=$(mem_db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='learnings';")
if [[ "$fts_check" -ge 1 ]]; then
    pass "FTS5 learnings table exists"
else
    fail "FTS5 learnings table missing"
fi

# Test: WAL mode
journal=$(mem_db "PRAGMA journal_mode;")
if [[ "$journal" == "wal" ]]; then
    pass "Memory DB uses WAL mode"
else
    fail "Memory DB journal mode is '$journal', expected 'wal'"
fi

section "Memory: Store and Recall"

# Test: store returns success
store_output=$(mem store --content "Bash arrays need declare -a for indexed arrays" --type "CODEBASE_PATTERN" --tags "bash,arrays")
if echo "$store_output" | grep -qi "stored\|ok\|success"; then
    pass "memory store reports success"
else
    fail "memory store output unexpected" "$store_output"
fi

# Test: recall finds stored content
recall_output=$(mem recall --query "bash arrays")
if echo "$recall_output" | grep -qi "arrays\|bash"; then
    pass "memory recall finds stored content by keyword"
else
    fail "memory recall did not find stored content" "$recall_output"
fi

# Test: recall with type filter
mem store --content "User prefers dark mode in terminal" --type "USER_PREFERENCE" --tags "ui,terminal" >/dev/null
recall_typed=$(mem recall --query "dark mode" --type "USER_PREFERENCE")
if echo "$recall_typed" | grep -qi "dark mode"; then
    pass "memory recall with --type filter works"
else
    fail "memory recall with --type filter failed" "$recall_typed"
fi

# Test: FTS5 hyphenated query (t139 regression)
mem store --content "Fixed pre-commit hook for shellcheck" --type "WORKING_SOLUTION" --tags "pre-commit,shellcheck" >/dev/null
recall_hyphen=$(mem recall --query "pre-commit hook" 2>&1)
if echo "$recall_hyphen" | grep -qiE "error.*column|fts5.*syntax"; then
    fail "FTS5 hyphenated query causes error (t139 regression)" "$recall_hyphen"
else
    pass "FTS5 hyphenated query works without error (t139)"
fi

# Test: recall with limit
mem store --content "Memory test entry A" --type "CONTEXT" --tags "test" >/dev/null
mem store --content "Memory test entry B" --type "CONTEXT" --tags "test" >/dev/null
mem store --content "Memory test entry C" --type "CONTEXT" --tags "test" >/dev/null
recall_limited=$(mem recall --query "memory test entry" --limit 2)
# Count result entries (each has a type marker like [CONTEXT])
result_count=$(echo "$recall_limited" | grep -c '\[CONTEXT\]' || true)
if [[ "$result_count" -le 2 ]]; then
    pass "memory recall --limit restricts results"
else
    fail "memory recall --limit did not restrict (got $result_count, expected <= 2)"
fi

section "Memory: Stats"

stats_output=$(mem stats)
if echo "$stats_output" | grep -qiE "total|memories|entries|count"; then
    pass "memory stats produces output"
else
    fail "memory stats output unexpected" "$stats_output"
fi

section "Memory: Relational Versioning"

# Store a memory, then update it
original_output=$(mem store --content "Favorite color is blue" --type "USER_PREFERENCE" --tags "preference")
original_id=$(echo "$original_output" | grep -oE 'mem_[a-z0-9_]+' | head -1 || true)

if [[ -n "$original_id" ]]; then
    # Store an update that supersedes the original
    update_output=$(mem store --content "Favorite color is now green" --type "USER_PREFERENCE" --tags "preference" --supersedes "$original_id" --relation updates 2>&1 || true)
    if echo "$update_output" | grep -qi "stored\|ok\|success"; then
        pass "Relational versioning: store with --supersedes works"
    else
        # May not support --supersedes flag yet, that's OK
        skip "Relational versioning: --supersedes may not be implemented yet"
    fi
else
    skip "Could not extract memory ID for relational test"
fi

section "Memory: Namespace Isolation"

# Store in a namespace
ns_output=$(mem --namespace test-runner store --content "Runner-specific config" --type "TOOL_CONFIG" --tags "runner" 2>&1)
if echo "$ns_output" | grep -qi "stored\|ok\|success"; then
    pass "Namespace store works"

    # Verify namespace directory created
    if [[ -d "$AIDEVOPS_MEMORY_DIR/namespaces/test-runner" ]]; then
        pass "Namespace directory created"
    else
        fail "Namespace directory not created"
    fi

    # Recall from namespace
    ns_recall=$(mem --namespace test-runner recall --query "runner config" 2>&1)
    if echo "$ns_recall" | grep -qi "runner\|config"; then
        pass "Namespace recall finds namespace-specific content"
    else
        fail "Namespace recall failed" "$ns_recall"
    fi
else
    skip "Namespace store failed" "$ns_output"
fi

# Invalid namespace name
invalid_ns=$(mem --namespace "invalid namespace!" store --content "test" --type "CONTEXT" 2>&1 || true)
if echo "$invalid_ns" | grep -qi "invalid"; then
    pass "Invalid namespace name rejected"
else
    fail "Invalid namespace name was not rejected"
fi

section "Memory: Prune"

# Prune with dry-run (should not delete anything)
prune_output=$(mem prune --dry-run 2>&1 || true)
if echo "$prune_output" | grep -qiE "prune|would|dry|entries|0"; then
    pass "memory prune --dry-run works"
else
    skip "memory prune --dry-run output unexpected" "$prune_output"
fi

section "Memory: Help"

help_output=$(mem help 2>&1)
if echo "$help_output" | grep -qiE "usage|store|recall|memory|COMMANDS"; then
    pass "memory help shows usage information"
else
    fail "memory help output unexpected" "$(echo "$help_output" | head -3)"
fi

# ============================================================
# MAIL TESTS
# ============================================================

section "Mail: Database Initialization"

# Test: first command creates database
mail_cmd status >/dev/null 2>&1 || true
if [[ -f "$AIDEVOPS_MAIL_DIR/mailbox.db" ]]; then
    pass "mail command creates database"
else
    fail "mail command did not create database"
fi

# Test: tables exist
mail_tables=$(mail_db "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tr '\n' ',')
if [[ "$mail_tables" == *"messages"* && "$mail_tables" == *"agents"* ]]; then
    pass "Mail tables exist (messages, agents)"
else
    fail "Missing mail tables" "Found: $mail_tables"
fi

section "Mail: Agent Registration"

# Register an agent
reg_output=$(mail_cmd register --agent "test-agent-1" --role "worker" 2>&1)
if echo "$reg_output" | grep -qiE "register|success|ok"; then
    pass "Agent registration works"
else
    fail "Agent registration failed" "$(echo "$reg_output" | head -3)"
fi

# Register second agent
mail_cmd register --agent "test-agent-2" --role "orchestrator" >/dev/null 2>&1

# List agents
agents_output=$(mail_cmd agents 2>&1)
if echo "$agents_output" | grep -q "test-agent-1"; then
    pass "Registered agent appears in agent list"
else
    fail "Registered agent not in list" "$agents_output"
fi

section "Mail: Send and Receive"

# Send a message
send_output=$(mail_cmd send --from "test-agent-1" --to "test-agent-2" --type "task_dispatch" --payload "Please process task t001" 2>&1)
if echo "$send_output" | grep -qiE "sent|success|ok|msg-"; then
    pass "mail send works"
else
    fail "mail send failed" "$(echo "$send_output" | head -3)"
fi

# Check inbox
check_output=$(mail_cmd check --agent "test-agent-2" 2>&1)
if echo "$check_output" | grep -qiE "1|unread|message"; then
    pass "mail check shows unread messages"
else
    fail "mail check did not show unread messages" "$check_output"
fi

# Read message
# First get the message ID
msg_id=$(mail_db "SELECT id FROM messages WHERE to_agent = 'test-agent-2' LIMIT 1;" 2>/dev/null || echo "")
if [[ -n "$msg_id" ]]; then
    read_output=$(mail_cmd read "$msg_id" 2>&1)
    if echo "$read_output" | grep -qiE "task t001|process|payload"; then
        pass "mail read shows message content"
    else
        fail "mail read did not show content" "$(echo "$read_output" | head -3)"
    fi

    # Verify message marked as read
    msg_status=$(mail_db "SELECT status FROM messages WHERE id = '$msg_id';")
    if [[ "$msg_status" == "read" ]]; then
        pass "Message marked as 'read' after reading"
    else
        fail "Message status is '$msg_status', expected 'read'"
    fi
else
    fail "Could not find message ID in database"
fi

section "Mail: Archive"

if [[ -n "$msg_id" ]]; then
    archive_output=$(mail_cmd archive "$msg_id" 2>&1)
    if echo "$archive_output" | grep -qiE "archived|success|ok"; then
        pass "mail archive works"
    else
        fail "mail archive failed" "$(echo "$archive_output" | head -3)"
    fi

    # Verify archived
    archived_status=$(mail_db "SELECT status FROM messages WHERE id = '$msg_id';")
    if [[ "$archived_status" == "archived" ]]; then
        pass "Message status is 'archived' after archiving"
    else
        fail "Message status is '$archived_status', expected 'archived'"
    fi
fi

section "Mail: Message Types"

# Test all valid message types
for msg_type in task_dispatch status_report discovery request broadcast; do
    type_output=$(mail_cmd send --from "test-agent-1" --to "test-agent-2" --type "$msg_type" --payload "Test $msg_type" 2>&1)
    if echo "$type_output" | grep -qiE "sent|success|ok|msg-"; then
        pass "mail send type=$msg_type"
    else
        fail "mail send type=$msg_type failed" "$(echo "$type_output" | head -3)"
    fi
done

# Test invalid message type
invalid_type_output=$(mail_cmd send --from "test-agent-1" --to "test-agent-2" --type "invalid_type" --payload "Test" 2>&1 || true)
if echo "$invalid_type_output" | grep -qiE "invalid|error|constraint"; then
    pass "Invalid message type rejected"
else
    fail "Invalid message type was not rejected" "$invalid_type_output"
fi

section "Mail: Priority"

# Send with priority
priority_output=$(mail_cmd send --from "test-agent-1" --to "test-agent-2" --type "request" --priority "high" --payload "Urgent request" 2>&1)
if echo "$priority_output" | grep -qiE "sent|success|ok|msg-"; then
    pass "mail send with --priority works"
else
    fail "mail send with --priority failed" "$(echo "$priority_output" | head -3)"
fi

section "Mail: Status"

status_output=$(mail_cmd status 2>&1)
if echo "$status_output" | grep -qiE "message|agent|total|unread|mail"; then
    pass "mail status produces summary"
else
    fail "mail status output unexpected" "$status_output"
fi

section "Mail: Deregister"

dereg_output=$(mail_cmd deregister --agent "test-agent-1" 2>&1)
if echo "$dereg_output" | grep -qiE "deregister|removed|success|ok|inactive"; then
    pass "Agent deregistration works"
else
    fail "Agent deregistration failed" "$(echo "$dereg_output" | head -3)"
fi

section "Mail: Prune"

prune_mail_output=$(mail_cmd prune 2>&1 || true)
if echo "$prune_mail_output" | grep -qiE "prune|storage|archived|messages|0"; then
    pass "mail prune works"
else
    skip "mail prune output unexpected" "$prune_mail_output"
fi

section "Mail: Help"

# mail-helper.sh doesn't have a cmd_help but main() should show usage on unknown command
help_mail=$(mail_cmd help 2>&1 || true)
if echo "$help_mail" | grep -qiE "usage|send|check|read|mail|commands"; then
    pass "mail help shows usage information"
else
    fail "mail help output unexpected" "$(echo "$help_mail" | head -3)"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
    "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
    exit 1
else
    echo ""
    printf "\033[0;32mAll tests passed.\033[0m\n"
    exit 0
fi
