#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for conversation-helper.sh (t1363.2)
# Validates conversation lifecycle, context loading, summarisation,
# idle detection, tone extraction, and message management.
#
# Uses a temporary SQLite database — no side effects on real memory.db.
#
# Usage: bash tests/test-conversation-helper.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
CONV_HELPER="${REPO_DIR}/.agents/scripts/conversation-helper.sh"
ENTITY_HELPER="${REPO_DIR}/.agents/scripts/entity-helper.sh"
WORK_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

setup() {
	WORK_DIR=$(mktemp -d)
	# Point both helpers at the temp directory
	export AIDEVOPS_MEMORY_DIR="$WORK_DIR"
	# Initialize entity tables first (conversation-helper depends on them)
	"$ENTITY_HELPER" migrate 2>/dev/null || true
	return 0
}

teardown() {
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
	return 0
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" == "$expected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected '$expected', got '$actual')"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"

	if echo "$haystack" | grep -qF "$needle"; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description ('$needle' not found in output)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_empty() {
	local value="$1"
	local description="$2"

	if [[ -n "$value" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (value is empty)"
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

# Helper: create a test entity via entity-helper.sh
create_test_entity() {
	local name="${1:-Test User}"
	local type="${2:-person}"
	local channel="${3:-cli}"
	local channel_id="${4:-test-user-1}"

	"$ENTITY_HELPER" create --name "$name" --type "$type" \
		--channel "$channel" --channel-id "$channel_id" 2>/dev/null | tail -1
}

# ---------------------------------------------------------------------------
# Test: Help command
# ---------------------------------------------------------------------------
test_help() {
	echo -e "\n${YELLOW}Test: Help command${NC}"

	local output
	output=$("$CONV_HELPER" help 2>&1)

	assert_contains "$output" "conversation-helper.sh" "Help shows script name"
	assert_contains "$output" "LIFECYCLE" "Help shows lifecycle section"
	assert_contains "$output" "CONTEXT" "Help shows context section"
	assert_contains "$output" "INTELLIGENCE" "Help shows intelligence section"
	assert_contains "$output" "idle-check" "Help shows idle-check command"
	assert_contains "$output" "summarise" "Help shows summarise command"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Migrate command (schema creation)
# ---------------------------------------------------------------------------
test_migrate() {
	echo -e "\n${YELLOW}Test: Migrate command${NC}"

	local output
	output=$("$CONV_HELPER" migrate 2>&1)

	assert_contains "$output" "migration complete" "Migrate reports completion"

	# Verify tables exist
	local tables
	tables=$(sqlite3 "$WORK_DIR/memory.db" ".tables" 2>/dev/null)
	assert_contains "$tables" "conversations" "conversations table exists"
	assert_contains "$tables" "conversation_summaries" "conversation_summaries table exists"
	assert_contains "$tables" "entities" "entities table exists"
	assert_contains "$tables" "interactions" "interactions table exists"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Create conversation
# ---------------------------------------------------------------------------
test_create() {
	echo -e "\n${YELLOW}Test: Create conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Alice" "person" "matrix" "@alice:server.com")
	assert_not_empty "$entity_id" "Entity created"

	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "!room:server.com" --topic "Test conversation" 2>/dev/null | tail -1)
	assert_not_empty "$conv_id" "Conversation ID returned"
	assert_contains "$conv_id" "conv_" "Conversation ID has correct prefix"

	# Verify in database
	local status
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Conversation status is active"

	local topic
	topic=$(sqlite3 "$WORK_DIR/memory.db" "SELECT topic FROM conversations WHERE id = '$conv_id';")
	assert_eq "Test conversation" "$topic" "Conversation topic stored correctly"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Create conversation — duplicate detection
# ---------------------------------------------------------------------------
test_create_duplicate() {
	echo -e "\n${YELLOW}Test: Create duplicate conversation returns existing${NC}"

	local entity_id
	entity_id=$(create_test_entity "Bob" "person" "simplex" "~bob123")

	local conv_id1
	conv_id1=$("$CONV_HELPER" create --entity "$entity_id" --channel simplex \
		--channel-id "~bob123" 2>/dev/null | tail -1)

	local conv_id2
	conv_id2=$("$CONV_HELPER" create --entity "$entity_id" --channel simplex \
		--channel-id "~bob123" 2>/dev/null | tail -1)

	assert_eq "$conv_id1" "$conv_id2" "Duplicate create returns same conversation ID"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Create conversation — validation errors
# ---------------------------------------------------------------------------
test_create_validation() {
	echo -e "\n${YELLOW}Test: Create conversation validation${NC}"

	# Missing entity
	local rc=0
	"$CONV_HELPER" create --channel matrix 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Missing entity returns error"

	# Missing channel
	rc=0
	"$CONV_HELPER" create --entity "ent_nonexistent" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Missing channel returns error"

	# Invalid channel
	rc=0
	"$CONV_HELPER" create --entity "ent_nonexistent" --channel "invalid_channel" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Invalid channel returns error"

	# Nonexistent entity
	rc=0
	"$CONV_HELPER" create --entity "ent_nonexistent_xxx" --channel matrix 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Nonexistent entity returns error"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Get conversation
# ---------------------------------------------------------------------------
test_get() {
	echo -e "\n${YELLOW}Test: Get conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Charlie" "person" "email" "charlie@test.com")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel email \
		--channel-id "charlie@test.com" --topic "Email thread" 2>/dev/null | tail -1)

	# Text format
	local output
	output=$("$CONV_HELPER" get "$conv_id" 2>&1)
	assert_contains "$output" "Charlie" "Get shows entity name"
	assert_contains "$output" "email" "Get shows channel"
	assert_contains "$output" "Email thread" "Get shows topic"
	assert_contains "$output" "active" "Get shows status"

	# JSON format
	local json_output
	json_output=$("$CONV_HELPER" get "$conv_id" --json 2>/dev/null)
	assert_contains "$json_output" "\"id\"" "JSON output has id field"
	assert_contains "$json_output" "\"entity_name\"" "JSON output has entity_name field"
	return 0
}

# ---------------------------------------------------------------------------
# Test: List conversations
# ---------------------------------------------------------------------------
test_list() {
	echo -e "\n${YELLOW}Test: List conversations${NC}"

	# List all (should include previously created conversations)
	local output
	output=$("$CONV_HELPER" list 2>&1)
	assert_contains "$output" "Conversations" "List shows header"

	# List with filters
	local json_output
	json_output=$("$CONV_HELPER" list --status active --json 2>/dev/null)
	assert_contains "$json_output" "active" "Filtered list shows active conversations"

	# List with channel filter
	json_output=$("$CONV_HELPER" list --channel email --json 2>/dev/null)
	assert_contains "$json_output" "email" "Channel filter works"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Add message
# ---------------------------------------------------------------------------
test_add_message() {
	echo -e "\n${YELLOW}Test: Add message${NC}"

	local entity_id
	entity_id=$(create_test_entity "Dave" "person" "cli" "dave-cli")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel cli \
		--channel-id "dave-cli" 2>/dev/null | tail -1)

	# Add inbound message
	local int_id
	int_id=$("$CONV_HELPER" add-message "$conv_id" --content "Hello, how are you?" \
		--direction inbound 2>/dev/null | tail -1)
	assert_not_empty "$int_id" "Inbound message ID returned"

	# Add outbound message
	int_id=$("$CONV_HELPER" add-message "$conv_id" --content "I'm doing well, thanks!" \
		--direction outbound 2>/dev/null | tail -1)
	assert_not_empty "$int_id" "Outbound message ID returned"

	# Verify interaction count updated
	local count
	count=$(sqlite3 "$WORK_DIR/memory.db" "SELECT interaction_count FROM conversations WHERE id = '$conv_id';")
	assert_eq "2" "$count" "Interaction count is 2"

	# Verify last_interaction_at is set
	local last_at
	last_at=$(sqlite3 "$WORK_DIR/memory.db" "SELECT last_interaction_at FROM conversations WHERE id = '$conv_id';")
	assert_not_empty "$last_at" "last_interaction_at is set"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Add message — auto-resume idle conversation
# ---------------------------------------------------------------------------
test_add_message_auto_resume() {
	echo -e "\n${YELLOW}Test: Add message auto-resumes idle conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Eve" "person" "matrix" "@eve:server")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "@eve:server" 2>/dev/null | tail -1)

	# Archive the conversation
	"$CONV_HELPER" archive "$conv_id" 2>/dev/null

	local status
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "idle" "$status" "Conversation is idle after archive"

	# Add a message — should auto-resume
	"$CONV_HELPER" add-message "$conv_id" --content "Hey, I'm back!" 2>/dev/null

	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Conversation auto-resumed to active"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Context loading
# ---------------------------------------------------------------------------
test_context() {
	echo -e "\n${YELLOW}Test: Context loading${NC}"

	local entity_id
	entity_id=$(create_test_entity "Frank" "person" "cli" "frank-cli")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel cli \
		--channel-id "frank-cli" --topic "Deployment discussion" 2>/dev/null | tail -1)

	# Add some messages
	"$CONV_HELPER" add-message "$conv_id" --content "How is the deployment going?" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "All services are green." --direction outbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Great, what about the database migration?" --direction inbound 2>/dev/null

	# Text context
	local output
	output=$("$CONV_HELPER" context "$conv_id" 2>&1)
	assert_contains "$output" "CONVERSATION CONTEXT" "Context has header"
	assert_contains "$output" "Frank" "Context shows entity name"
	assert_contains "$output" "Deployment discussion" "Context shows topic"
	assert_contains "$output" "Recent messages" "Context shows recent messages section"
	assert_contains "$output" "deployment" "Context includes message content"

	# JSON context
	local json_output
	json_output=$("$CONV_HELPER" context "$conv_id" --json 2>/dev/null)
	assert_contains "$json_output" "\"conversation\"" "JSON context has conversation field"
	assert_contains "$json_output" "\"recent_messages\"" "JSON context has recent_messages field"
	assert_contains "$json_output" "\"entity_profile\"" "JSON context has entity_profile field"

	# Privacy filter
	output=$("$CONV_HELPER" context "$conv_id" --privacy-filter 2>&1)
	assert_contains "$output" "CONVERSATION CONTEXT" "Privacy-filtered context has header"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Archive conversation
# ---------------------------------------------------------------------------
test_archive() {
	echo -e "\n${YELLOW}Test: Archive conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Grace" "person" "simplex" "~grace")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel simplex \
		--channel-id "~grace" 2>/dev/null | tail -1)

	"$CONV_HELPER" archive "$conv_id" 2>/dev/null

	local status
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "idle" "$status" "Archived conversation has idle status"

	# Archive again — should be idempotent
	local rc=0
	"$CONV_HELPER" archive "$conv_id" 2>/dev/null || rc=$?
	assert_exit_code 0 "$rc" "Re-archiving is idempotent"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Close conversation
# ---------------------------------------------------------------------------
test_close() {
	echo -e "\n${YELLOW}Test: Close conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Heidi" "person" "email" "heidi@test.com")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel email \
		--channel-id "heidi@test.com" 2>/dev/null | tail -1)

	"$CONV_HELPER" close "$conv_id" 2>/dev/null

	local status
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "closed" "$status" "Closed conversation has closed status"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Resume conversation
# ---------------------------------------------------------------------------
test_resume() {
	echo -e "\n${YELLOW}Test: Resume conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Ivan" "person" "cli" "ivan-cli")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel cli \
		--channel-id "ivan-cli" 2>/dev/null | tail -1)

	# Close then resume
	"$CONV_HELPER" close "$conv_id" 2>/dev/null
	"$CONV_HELPER" resume "$conv_id" 2>/dev/null

	local status
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Resumed conversation is active"

	# Resume already active — should be idempotent
	local output
	output=$("$CONV_HELPER" resume "$conv_id" 2>&1 | tail -1)
	assert_eq "$conv_id" "$output" "Resuming active conversation returns same ID"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Summarise conversation
# ---------------------------------------------------------------------------
test_summarise() {
	echo -e "\n${YELLOW}Test: Summarise conversation${NC}"

	local entity_id
	entity_id=$(create_test_entity "Judy" "person" "matrix" "@judy:server")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "@judy:server" --topic "Project planning" 2>/dev/null | tail -1)

	# Add messages for summarisation
	"$CONV_HELPER" add-message "$conv_id" --content "Let's plan the Q2 roadmap" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Sure, I suggest we focus on performance" --direction outbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Agreed, and also improve the onboarding flow" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "I'll draft a proposal by Friday" --direction outbound 2>/dev/null

	# Generate summary (will use fallback since AI research script likely unavailable in test)
	local sum_id
	sum_id=$("$CONV_HELPER" summarise "$conv_id" 2>/dev/null | tail -1)
	assert_not_empty "$sum_id" "Summary ID returned"
	assert_contains "$sum_id" "sum_" "Summary ID has correct prefix"

	# Verify summary stored in database
	local summary_count
	summary_count=$(sqlite3 "$WORK_DIR/memory.db" "SELECT COUNT(*) FROM conversation_summaries WHERE conversation_id = '$conv_id';")
	assert_eq "1" "$summary_count" "One summary stored"

	# Verify source range
	local range_count
	range_count=$(sqlite3 "$WORK_DIR/memory.db" "SELECT source_interaction_count FROM conversation_summaries WHERE id = '$sum_id';")
	assert_eq "4" "$range_count" "Summary covers 4 interactions"

	# Summarise again — should report no unsummarised interactions
	local output
	output=$("$CONV_HELPER" summarise "$conv_id" 2>&1)
	assert_contains "$output" "No unsummarised" "Second summarise reports no new interactions"

	# Force re-summarise
	local sum_id2
	sum_id2=$("$CONV_HELPER" summarise "$conv_id" --force 2>/dev/null | tail -1)
	assert_not_empty "$sum_id2" "Force summarise returns new summary ID"

	# Verify supersedes chain
	local supersedes
	supersedes=$(sqlite3 "$WORK_DIR/memory.db" "SELECT supersedes_id FROM conversation_summaries WHERE id = '$sum_id2';")
	assert_eq "$sum_id" "$supersedes" "New summary supersedes old one"
	return 0
}

# ---------------------------------------------------------------------------
# Test: List summaries
# ---------------------------------------------------------------------------
test_summaries() {
	echo -e "\n${YELLOW}Test: List summaries${NC}"

	# Use the conversation from test_summarise (Judy's)
	# Find Judy's conversation
	local conv_id
	conv_id=$(sqlite3 "$WORK_DIR/memory.db" "SELECT c.id FROM conversations c JOIN entities e ON c.entity_id = e.id WHERE e.name = 'Judy' LIMIT 1;")

	if [[ -z "$conv_id" ]]; then
		echo -e "  ${YELLOW}SKIP${NC}: No Judy conversation found (test_summarise may not have run)"
		SKIP=$((SKIP + 1))
		return 0
	fi

	# Text format
	local output
	output=$("$CONV_HELPER" summaries "$conv_id" 2>&1)
	assert_contains "$output" "Summaries for" "Summaries header shown"
	assert_contains "$output" "CURRENT" "Current summary marked"

	# JSON format
	local json_output
	json_output=$("$CONV_HELPER" summaries "$conv_id" --json 2>/dev/null)
	assert_contains "$json_output" "\"is_current\"" "JSON has is_current field"
	assert_contains "$json_output" "\"source_range_start\"" "JSON has source_range_start field"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Idle check — heuristic fallback
# ---------------------------------------------------------------------------
test_idle_check_heuristic() {
	echo -e "\n${YELLOW}Test: Idle check (heuristic fallback)${NC}"

	local entity_id
	entity_id=$(create_test_entity "Karl" "person" "cli" "karl-cli")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel cli \
		--channel-id "karl-cli" 2>/dev/null | tail -1)

	# Fresh conversation with no messages — should be idle (no last_activity)
	local result
	result=$("$CONV_HELPER" idle-check "$conv_id" 2>/dev/null || true)
	assert_eq "idle" "$result" "Conversation with no messages is idle"

	# Add a recent message — should be active
	"$CONV_HELPER" add-message "$conv_id" --content "Just checking in" --direction inbound 2>/dev/null
	result=$("$CONV_HELPER" idle-check "$conv_id" 2>/dev/null || true)
	assert_eq "active" "$result" "Conversation with recent message is active"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Idle check --all
# ---------------------------------------------------------------------------
test_idle_check_all() {
	echo -e "\n${YELLOW}Test: Idle check --all${NC}"

	local output
	output=$("$CONV_HELPER" idle-check --all 2>&1)
	assert_contains "$output" "Checked" "Idle check --all reports checked count"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Tone extraction
# ---------------------------------------------------------------------------
test_tone() {
	echo -e "\n${YELLOW}Test: Tone extraction${NC}"

	local entity_id
	entity_id=$(create_test_entity "Laura" "person" "matrix" "@laura:server")
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "@laura:server" 2>/dev/null | tail -1)

	# No messages — should report no data (returns early with log message)
	local output
	output=$("$CONV_HELPER" tone "$conv_id" 2>&1)
	assert_contains "$output" "No messages" "Tone reports no messages for empty conversation"

	# Add messages and test with data
	"$CONV_HELPER" add-message "$conv_id" --content "Hey, quick question about the API" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Sure, what do you need?" --direction outbound 2>/dev/null

	# Text format with messages (AI unavailable in test, so tone_data will be {})
	output=$("$CONV_HELPER" tone "$conv_id" 2>&1)
	assert_contains "$output" "Tone Profile" "Tone shows header with messages"

	# JSON format
	local json_output
	json_output=$("$CONV_HELPER" tone "$conv_id" --json 2>/dev/null)
	assert_not_empty "$json_output" "Tone JSON output is not empty"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Stats command
# ---------------------------------------------------------------------------
test_stats() {
	echo -e "\n${YELLOW}Test: Stats command${NC}"

	local output
	output=$("$CONV_HELPER" stats 2>&1)
	assert_contains "$output" "Conversation Statistics" "Stats shows header"
	assert_contains "$output" "Total conversations" "Stats shows total count"
	assert_contains "$output" "Active" "Stats shows active count"
	assert_contains "$output" "Conversations by channel" "Stats shows channel distribution"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Error handling — nonexistent conversation
# ---------------------------------------------------------------------------
test_error_nonexistent() {
	echo -e "\n${YELLOW}Test: Error handling for nonexistent conversation${NC}"

	local rc=0
	"$CONV_HELPER" get "conv_nonexistent_xxx" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Get nonexistent conversation returns error"

	rc=0
	"$CONV_HELPER" resume "conv_nonexistent_xxx" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Resume nonexistent conversation returns error"

	rc=0
	"$CONV_HELPER" archive "conv_nonexistent_xxx" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Archive nonexistent conversation returns error"

	rc=0
	"$CONV_HELPER" context "conv_nonexistent_xxx" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Context nonexistent conversation returns error"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Unknown command
# ---------------------------------------------------------------------------
test_unknown_command() {
	echo -e "\n${YELLOW}Test: Unknown command${NC}"

	local rc=0
	"$CONV_HELPER" nonexistent_command 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Unknown command returns error"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Full lifecycle — create, message, summarise, archive, resume, close
# ---------------------------------------------------------------------------
test_full_lifecycle() {
	echo -e "\n${YELLOW}Test: Full lifecycle${NC}"

	# Create entity
	local entity_id
	entity_id=$(create_test_entity "Lifecycle User" "person" "matrix" "@lifecycle:server")

	# Create conversation
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "@lifecycle:server" --topic "Full lifecycle test" 2>/dev/null | tail -1)
	assert_not_empty "$conv_id" "Lifecycle: conversation created"

	# Add messages
	"$CONV_HELPER" add-message "$conv_id" --content "Starting the lifecycle test" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Acknowledged, proceeding" --direction outbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Please check the logs" --direction inbound 2>/dev/null

	# Load context
	local context
	context=$("$CONV_HELPER" context "$conv_id" 2>&1)
	assert_contains "$context" "lifecycle test" "Lifecycle: context includes message"

	# Generate summary
	local sum_id
	sum_id=$("$CONV_HELPER" summarise "$conv_id" 2>/dev/null | tail -1)
	assert_not_empty "$sum_id" "Lifecycle: summary generated"

	# Archive (should be idempotent with summary)
	"$CONV_HELPER" archive "$conv_id" 2>/dev/null
	local status
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "idle" "$status" "Lifecycle: archived"

	# Resume
	"$CONV_HELPER" resume "$conv_id" 2>/dev/null
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Lifecycle: resumed"

	# Add more messages
	"$CONV_HELPER" add-message "$conv_id" --content "Back from break" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Welcome back" --direction outbound 2>/dev/null

	# Close
	"$CONV_HELPER" close "$conv_id" 2>/dev/null
	status=$(sqlite3 "$WORK_DIR/memory.db" "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "closed" "$status" "Lifecycle: closed"

	# Verify final interaction count
	local count
	count=$(sqlite3 "$WORK_DIR/memory.db" "SELECT interaction_count FROM conversations WHERE id = '$conv_id';")
	assert_eq "5" "$count" "Lifecycle: 5 total interactions"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	echo "============================================"
	echo "Conversation Helper Test Suite (t1363.2)"
	echo "============================================"

	# Check dependencies
	if [[ ! -x "$CONV_HELPER" ]]; then
		echo -e "${RED}ERROR${NC}: conversation-helper.sh not found or not executable at $CONV_HELPER"
		exit 1
	fi

	if [[ ! -x "$ENTITY_HELPER" ]]; then
		echo -e "${RED}ERROR${NC}: entity-helper.sh not found or not executable at $ENTITY_HELPER"
		exit 1
	fi

	if ! command -v sqlite3 &>/dev/null; then
		echo -e "${RED}ERROR${NC}: sqlite3 not found"
		exit 1
	fi

	setup

	# Run tests in dependency order
	test_help
	test_migrate
	test_create
	test_create_duplicate
	test_create_validation
	test_get
	test_list
	test_add_message
	test_add_message_auto_resume
	test_context
	test_archive
	test_close
	test_resume
	test_summarise
	test_summaries
	test_idle_check_heuristic
	test_idle_check_all
	test_tone
	test_stats
	test_error_nonexistent
	test_unknown_command
	test_full_lifecycle

	teardown

	# Summary
	echo ""
	echo "============================================"
	echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
