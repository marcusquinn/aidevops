#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Integration test suite for the entity memory system (t1363.7)
# Tests all three layers working together:
#   Layer 0: Raw interaction log (immutable, append-only)
#   Layer 1: Per-conversation context (tactical summaries)
#   Layer 2: Entity relationship model (strategic profiles)
#
# Verifies:
#   - Cross-layer data flow (entity → conversation → interaction → summary)
#   - Immutability constraints (interactions never modified, summaries/profiles superseded)
#   - Privacy filtering on ingest and output
#   - Context loading combines all three layers
#   - Entity deletion cascades correctly
#   - Existing memory system is unaffected
#   - Schema migration is idempotent
#
# Uses a temporary SQLite database — no side effects on production data.
#
# Usage: bash tests/test-entity-memory-integration.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
ENTITY_HELPER="${REPO_DIR}/.agents/scripts/entity-helper.sh"
CONV_HELPER="${REPO_DIR}/.agents/scripts/conversation-helper.sh"
MEMORY_HELPER="${REPO_DIR}/.agents/scripts/memory-helper.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# Temporary directory for test database
WORK_DIR=""

setup() {
	WORK_DIR=$(mktemp -d)
	export AIDEVOPS_MEMORY_DIR="$WORK_DIR"
	# Initialize all schemas — memory-helper first (creates learnings FTS5 table),
	# then entity/conversation (adds entity tables to the same DB).
	# memory-helper.sh stats triggers init_db without requiring content.
	"$MEMORY_HELPER" stats >/dev/null 2>&1 || true
	"$ENTITY_HELPER" migrate >/dev/null 2>&1 || true
	"$CONV_HELPER" migrate >/dev/null 2>&1 || true
	return 0
}

teardown() {
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
	return 0
}

# ---- Assertion helpers ----

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

assert_ne() {
	local unexpected="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" != "$unexpected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (got unexpected value '$actual')"
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
		echo -e "  ${RED}FAIL${NC}: $description ('$needle' not found)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local haystack="$1"
	local needle="$2"
	local description="$3"

	if ! echo "$haystack" | grep -qF "$needle"; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description ('$needle' was found but should not be)"
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

assert_gt() {
	local threshold="$1"
	local actual="$2"
	local description="$3"

	if [[ "$actual" -gt "$threshold" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected > $threshold, got $actual)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

db_query() {
	sqlite3 -cmd ".timeout 5000" "$WORK_DIR/memory.db" "$1" 2>/dev/null || echo ""
}

# ---- Helper functions ----

create_entity() {
	local name="$1"
	local type="${2:-person}"
	local channel="${3:-}"
	local channel_id="${4:-}"

	local args=(create --name "$name" --type "$type")
	if [[ -n "$channel" && -n "$channel_id" ]]; then
		args+=(--channel "$channel" --channel-id "$channel_id")
	fi

	"$ENTITY_HELPER" "${args[@]}" 2>/dev/null | grep -o 'ent_[a-z0-9_]*' | tail -1
}

create_conversation() {
	local entity_id="$1"
	local channel="$2"
	local channel_id="${3:-}"
	local topic="${4:-}"

	local args=(create --entity "$entity_id" --channel "$channel")
	if [[ -n "$channel_id" ]]; then
		args+=(--channel-id "$channel_id")
	fi
	if [[ -n "$topic" ]]; then
		args+=(--topic "$topic")
	fi

	"$CONV_HELPER" "${args[@]}" 2>/dev/null | grep -o 'conv_[a-z0-9_]*' | tail -1
}

# ===========================================================================
# Test: Schema creation and idempotent migration
# ===========================================================================
test_schema_idempotent() {
	echo -e "\n${YELLOW}Test: Schema creation is idempotent${NC}"

	# Run migration twice — should not error
	local rc=0
	"$ENTITY_HELPER" migrate >/dev/null 2>&1 || rc=$?
	assert_exit_code 0 "$rc" "First entity migration succeeds"

	rc=0
	"$ENTITY_HELPER" migrate >/dev/null 2>&1 || rc=$?
	assert_exit_code 0 "$rc" "Second entity migration succeeds (idempotent)"

	rc=0
	"$CONV_HELPER" migrate >/dev/null 2>&1 || rc=$?
	assert_exit_code 0 "$rc" "Conversation migration succeeds after entity migration"

	# Verify all tables exist
	local tables
	tables=$(db_query ".tables")
	for table in entities entity_channels interactions conversations \
		conversation_summaries entity_profiles capability_gaps; do
		assert_contains "$tables" "$table" "Table '$table' exists"
	done

	return 0
}

# ===========================================================================
# Test: Cross-layer data flow — entity → conversation → interaction → summary
# ===========================================================================
test_cross_layer_flow() {
	echo -e "\n${YELLOW}Test: Cross-layer data flow (entity → conversation → interaction → summary)${NC}"

	# Layer 2: Create entity
	local entity_id
	entity_id=$(create_entity "Alice Integration" "person" "matrix" "@alice:test.com")
	assert_not_empty "$entity_id" "Entity created"

	# Layer 2: Add profile
	local prof_id
	prof_id=$("$ENTITY_HELPER" profile-update "$entity_id" \
		--key "communication_style" --value "prefers concise responses" \
		--evidence "observed in 3 conversations" 2>/dev/null | grep -o 'prof_[a-z0-9_]*' | tail -1)
	assert_not_empty "$prof_id" "Profile entry created"

	# Layer 1: Create conversation
	local conv_id
	conv_id=$(create_conversation "$entity_id" "matrix" "@alice:test.com" "Integration test")
	assert_not_empty "$conv_id" "Conversation created"

	# Layer 0: Add messages via conversation helper (delegates to entity-helper)
	local int1 int2 int3
	int1=$("$CONV_HELPER" add-message "$conv_id" --content "Hello, how is the project going?" \
		--direction inbound 2>/dev/null | tail -1)
	int2=$("$CONV_HELPER" add-message "$conv_id" --content "All tests passing, deployment scheduled for tomorrow." \
		--direction outbound 2>/dev/null | tail -1)
	int3=$("$CONV_HELPER" add-message "$conv_id" --content "Great, please send me the deployment checklist." \
		--direction inbound 2>/dev/null | tail -1)

	assert_not_empty "$int1" "First interaction logged"
	assert_not_empty "$int2" "Second interaction logged"
	assert_not_empty "$int3" "Third interaction logged"

	# Verify Layer 0 data in DB
	local int_count
	int_count=$(db_query "SELECT COUNT(*) FROM interactions WHERE conversation_id = '$conv_id';")
	assert_eq "3" "$int_count" "Three interactions in DB for conversation"

	# Verify FTS5 index
	local fts_count
	fts_count=$(db_query "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'deployment';")
	assert_gt 0 "$fts_count" "FTS5 index contains 'deployment'"

	# Layer 1: Generate summary
	local sum_id
	sum_id=$("$CONV_HELPER" summarise "$conv_id" 2>/dev/null | grep -o 'sum_[a-z0-9_]*' | tail -1)
	assert_not_empty "$sum_id" "Summary generated"

	# Verify summary source range
	local range_count
	range_count=$(db_query "SELECT source_interaction_count FROM conversation_summaries WHERE id = '$sum_id';")
	assert_eq "3" "$range_count" "Summary covers 3 interactions"

	# Context loading: combines all three layers
	local context
	context=$("$CONV_HELPER" context "$conv_id" 2>&1)
	assert_contains "$context" "Alice Integration" "Context shows entity name"
	assert_contains "$context" "communication_style" "Context includes profile data"
	assert_contains "$context" "deployment" "Context includes interaction content"
	assert_contains "$context" "CONVERSATION CONTEXT" "Context has header"
	assert_contains "$context" "END CONTEXT" "Context has footer"

	return 0
}

# ===========================================================================
# Test: Layer 0 immutability — interactions cannot be modified
# ===========================================================================
test_layer0_immutability() {
	echo -e "\n${YELLOW}Test: Layer 0 immutability — interactions are append-only${NC}"

	local entity_id
	entity_id=$(create_entity "Immutable Test" "person" "cli" "immutable-user")

	# Log an interaction
	local int_id
	int_id=$("$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Original message" 2>/dev/null | tail -1)
	assert_not_empty "$int_id" "Interaction logged"

	# Verify the interaction exists
	local content
	content=$(db_query "SELECT content FROM interactions WHERE id = '$int_id';")
	assert_eq "Original message" "$content" "Interaction content stored correctly"

	# Verify no updated_at column exists on interactions table
	local has_updated_at
	has_updated_at=$(db_query "SELECT COUNT(*) FROM pragma_table_info('interactions') WHERE name = 'updated_at';")
	assert_eq "0" "$has_updated_at" "interactions table has no updated_at column (immutable)"

	# Verify interaction count only grows
	local count_before
	count_before=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")

	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Second message" 2>/dev/null

	local count_after
	count_after=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	assert_eq "$((count_before + 1))" "$count_after" "Interaction count incremented by 1"

	# Verify original interaction unchanged
	local original_content
	original_content=$(db_query "SELECT content FROM interactions WHERE id = '$int_id';")
	assert_eq "Original message" "$original_content" "Original interaction content unchanged"

	return 0
}

# ===========================================================================
# Test: Layer 1 immutability — summaries use supersedes chain
# ===========================================================================
test_layer1_summary_immutability() {
	echo -e "\n${YELLOW}Test: Layer 1 immutability — summaries supersede, never edit${NC}"

	local entity_id
	entity_id=$(create_entity "Summary Immutable" "person" "matrix" "@sumtest:server")
	local conv_id
	conv_id=$(create_conversation "$entity_id" "matrix" "@sumtest:server" "Summary test")

	# Add messages
	"$CONV_HELPER" add-message "$conv_id" --content "First topic discussion" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Agreed on approach A" --direction outbound 2>/dev/null

	# Generate first summary
	local sum1
	sum1=$("$CONV_HELPER" summarise "$conv_id" 2>/dev/null | grep -o 'sum_[a-z0-9_]*' | tail -1)
	assert_not_empty "$sum1" "First summary created"

	local sum1_text
	sum1_text=$(db_query "SELECT summary FROM conversation_summaries WHERE id = '$sum1';")
	assert_not_empty "$sum1_text" "First summary has content"

	# Force re-summarise to create a second summary (supersedes chain)
	# Note: within the same second, timestamp-based unsummarised detection may
	# report 0 new interactions, so we use --force to guarantee a new summary.
	local sum2
	sum2=$("$CONV_HELPER" summarise "$conv_id" --force 2>/dev/null | grep -o 'sum_[a-z0-9_]*' | tail -1 || true)
	assert_not_empty "$sum2" "Force re-summarise creates new summary"
	assert_ne "$sum1" "$sum2" "Second summary has different ID"

	# Verify original summary still exists unchanged
	local sum1_text_after
	sum1_text_after=$(db_query "SELECT summary FROM conversation_summaries WHERE id = '$sum1';")
	assert_eq "$sum1_text" "$sum1_text_after" "Original summary text unchanged after re-summarise"

	# Verify total summary count grew
	local total_summaries
	total_summaries=$(db_query "SELECT COUNT(*) FROM conversation_summaries WHERE conversation_id = '$conv_id';")
	assert_gt 1 "$total_summaries" "Multiple summaries exist (never deleted)"

	return 0
}

# ===========================================================================
# Test: Layer 2 immutability — profiles use supersedes chain
# ===========================================================================
test_layer2_profile_immutability() {
	echo -e "\n${YELLOW}Test: Layer 2 immutability — profiles supersede, never edit${NC}"

	local entity_id
	entity_id=$(create_entity "Profile Immutable" "person")

	# Create initial profile
	local prof1
	prof1=$("$ENTITY_HELPER" profile-update "$entity_id" \
		--key "response_style" --value "verbose" \
		--evidence "first 3 conversations" 2>/dev/null | grep -o 'prof_[a-z0-9_]*' | tail -1)
	assert_not_empty "$prof1" "First profile created"

	local prof1_value
	prof1_value=$(db_query "SELECT profile_value FROM entity_profiles WHERE id = '$prof1';")
	assert_eq "verbose" "$prof1_value" "First profile value correct"

	# Update profile (should create new version, not modify)
	local prof2
	prof2=$("$ENTITY_HELPER" profile-update "$entity_id" \
		--key "response_style" --value "concise" \
		--evidence "user explicitly requested" 2>/dev/null | grep -o 'prof_[a-z0-9_]*' | tail -1)
	assert_not_empty "$prof2" "Second profile created"
	assert_ne "$prof1" "$prof2" "Second profile has different ID"

	# Verify supersedes chain
	local supersedes
	supersedes=$(db_query "SELECT supersedes_id FROM entity_profiles WHERE id = '$prof2';")
	assert_eq "$prof1" "$supersedes" "New profile supersedes old one"

	# Verify original profile still exists unchanged
	local prof1_value_after
	prof1_value_after=$(db_query "SELECT profile_value FROM entity_profiles WHERE id = '$prof1';")
	assert_eq "verbose" "$prof1_value_after" "Original profile value unchanged"

	# Verify current profile query returns only latest
	local current_value
	current_value=$(db_query "SELECT profile_value FROM entity_profiles WHERE entity_id = '$entity_id' AND profile_key = 'response_style' AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL);")
	assert_eq "concise" "$current_value" "Current profile query returns latest value"

	# Verify both versions exist
	local total_profiles
	total_profiles=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$entity_id' AND profile_key = 'response_style';")
	assert_eq "2" "$total_profiles" "Both profile versions exist"

	return 0
}

# ===========================================================================
# Test: Privacy filtering on ingest
# ===========================================================================
test_privacy_filtering_ingest() {
	echo -e "\n${YELLOW}Test: Privacy filtering on ingest${NC}"

	local entity_id
	entity_id=$(create_entity "Privacy Test" "person" "cli" "privacy-user")

	# Test <private> block stripping
	local int_id
	int_id=$("$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Hello <private>secret stuff</private> world" 2>/dev/null | tail -1)
	assert_not_empty "$int_id" "Interaction with private block logged"

	local stored_content
	stored_content=$(db_query "SELECT content FROM interactions WHERE id = '$int_id';")
	assert_not_contains "$stored_content" "secret stuff" "Private block stripped from stored content"
	assert_contains "$stored_content" "Hello" "Non-private content preserved"
	assert_contains "$stored_content" "world" "Non-private content preserved (after block)"

	# Test secret pattern rejection
	local rc=0
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "My API key is sk-1234567890abcdefghijklmnop" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Interaction with API key pattern rejected"

	# Verify rejected interaction was not stored
	local secret_count
	secret_count=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id' AND content LIKE '%sk-1234%';")
	assert_eq "0" "$secret_count" "Secret content not stored in DB"

	return 0
}

# ===========================================================================
# Test: Privacy filtering on output
# ===========================================================================
test_privacy_filtering_output() {
	echo -e "\n${YELLOW}Test: Privacy filtering on output${NC}"

	local entity_id
	entity_id=$(create_entity "Output Privacy" "person" "email" "user@example.com")
	local conv_id
	conv_id=$(create_conversation "$entity_id" "email" "user@example.com" "Privacy output test")

	# Add message with email and IP
	"$CONV_HELPER" add-message "$conv_id" \
		--content "Contact me at alice@secret.com from 192.168.1.100" \
		--direction inbound 2>/dev/null

	# Load context with privacy filter
	local filtered_context
	filtered_context=$("$CONV_HELPER" context "$conv_id" --privacy-filter 2>&1)
	assert_not_contains "$filtered_context" "alice@secret.com" "Email redacted in privacy-filtered output"
	assert_not_contains "$filtered_context" "192.168.1.100" "IP redacted in privacy-filtered output"
	assert_contains "$filtered_context" "[EMAIL]" "Email replaced with [EMAIL] placeholder"
	assert_contains "$filtered_context" "[IP]" "IP replaced with [IP] placeholder"

	# Load context without privacy filter — should show raw data
	local raw_context
	raw_context=$("$CONV_HELPER" context "$conv_id" 2>&1)
	assert_contains "$raw_context" "alice@secret.com" "Email visible without privacy filter"

	return 0
}

# ===========================================================================
# Test: Cross-channel identity linking
# ===========================================================================
test_cross_channel_identity() {
	echo -e "\n${YELLOW}Test: Cross-channel identity linking${NC}"

	# Create entity with Matrix channel
	local entity_id
	entity_id=$(create_entity "Multi-Channel User" "person" "matrix" "@multi:server.com")
	assert_not_empty "$entity_id" "Entity created with Matrix channel"

	# Link email channel
	local rc=0
	"$ENTITY_HELPER" link "$entity_id" --channel email \
		--channel-id "multi@example.com" --verified 2>/dev/null || rc=$?
	assert_exit_code 0 "$rc" "Email channel linked"

	# Link SimpleX channel (suggested, not verified)
	rc=0
	"$ENTITY_HELPER" link "$entity_id" --channel simplex \
		--channel-id "~simplex-multi" 2>/dev/null || rc=$?
	assert_exit_code 0 "$rc" "SimpleX channel linked (suggested)"

	# Verify channel count
	local channel_count
	channel_count=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id';")
	assert_eq "3" "$channel_count" "Three channels linked"

	# Verify confidence levels
	local confirmed_count
	confirmed_count=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id' AND confidence = 'confirmed';")
	assert_eq "2" "$confirmed_count" "Two confirmed channels (matrix initial + email verified)"

	local suggested_count
	suggested_count=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id' AND confidence = 'suggested';")
	assert_eq "1" "$suggested_count" "One suggested channel (simplex)"

	# Verify identity suggestion
	local suggest_output
	suggest_output=$("$ENTITY_HELPER" suggest matrix "@multi:server.com" 2>&1)
	assert_contains "$suggest_output" "Multi-Channel User" "Suggest finds entity by Matrix ID"

	# Verify channel cannot be linked to two entities
	local entity2
	entity2=$(create_entity "Duplicate Channel" "person")
	rc=0
	"$ENTITY_HELPER" link "$entity2" --channel matrix \
		--channel-id "@multi:server.com" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Cannot link same channel ID to different entity"

	return 0
}

# ===========================================================================
# Test: Conversation lifecycle — full cycle
# ===========================================================================
test_conversation_lifecycle() {
	echo -e "\n${YELLOW}Test: Conversation lifecycle — create → message → archive → resume → close${NC}"

	local entity_id
	entity_id=$(create_entity "Lifecycle User" "person" "matrix" "@lifecycle:server")
	local conv_id
	conv_id=$(create_conversation "$entity_id" "matrix" "@lifecycle:server" "Lifecycle test")

	# Verify initial state
	local status
	status=$(db_query "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Initial status is active"

	# Add messages
	"$CONV_HELPER" add-message "$conv_id" --content "Starting work" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Acknowledged" --direction outbound 2>/dev/null

	local count
	count=$(db_query "SELECT interaction_count FROM conversations WHERE id = '$conv_id';")
	assert_eq "2" "$count" "Interaction count is 2"

	# Archive
	"$CONV_HELPER" archive "$conv_id" 2>/dev/null
	status=$(db_query "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "idle" "$status" "Status is idle after archive"

	# Resume
	"$CONV_HELPER" resume "$conv_id" 2>/dev/null
	status=$(db_query "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Status is active after resume"

	# Add more messages
	"$CONV_HELPER" add-message "$conv_id" --content "Back from break" --direction inbound 2>/dev/null

	count=$(db_query "SELECT interaction_count FROM conversations WHERE id = '$conv_id';")
	assert_eq "3" "$count" "Interaction count is 3 after resume + message"

	# Close
	"$CONV_HELPER" close "$conv_id" 2>/dev/null
	status=$(db_query "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "closed" "$status" "Status is closed"

	return 0
}

# ===========================================================================
# Test: Auto-resume on message to idle conversation
# ===========================================================================
test_auto_resume() {
	echo -e "\n${YELLOW}Test: Auto-resume on message to idle conversation${NC}"

	local entity_id
	entity_id=$(create_entity "Auto Resume" "person" "cli" "auto-resume-user")
	local conv_id
	conv_id=$(create_conversation "$entity_id" "cli" "auto-resume-user")

	# Archive
	"$CONV_HELPER" archive "$conv_id" 2>/dev/null
	local status
	status=$(db_query "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "idle" "$status" "Conversation is idle"

	# Add message — should auto-resume
	"$CONV_HELPER" add-message "$conv_id" --content "I'm back!" --direction inbound 2>/dev/null
	status=$(db_query "SELECT status FROM conversations WHERE id = '$conv_id';")
	assert_eq "active" "$status" "Conversation auto-resumed on new message"

	return 0
}

# ===========================================================================
# Test: Entity deletion cascades correctly
# ===========================================================================
test_entity_deletion_cascade() {
	echo -e "\n${YELLOW}Test: Entity deletion cascades to all related data${NC}"

	local entity_id
	entity_id=$(create_entity "Delete Test" "person" "matrix" "@delete:server")

	# Create related data across all layers
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "preference" --value "test value" 2>/dev/null
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel matrix --content "Test message" 2>/dev/null

	local conv_id
	conv_id=$(create_conversation "$entity_id" "matrix" "@delete:server")
	"$CONV_HELPER" add-message "$conv_id" --content "Conversation message" --direction inbound 2>/dev/null

	# Verify data exists
	local pre_channels pre_interactions pre_profiles pre_conversations
	pre_channels=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id';")
	pre_interactions=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	pre_profiles=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$entity_id';")
	pre_conversations=$(db_query "SELECT COUNT(*) FROM conversations WHERE entity_id = '$entity_id';")

	assert_gt 0 "$pre_channels" "Channels exist before deletion"
	assert_gt 0 "$pre_interactions" "Interactions exist before deletion"
	assert_gt 0 "$pre_profiles" "Profiles exist before deletion"
	assert_gt 0 "$pre_conversations" "Conversations exist before deletion"

	# Delete entity
	"$ENTITY_HELPER" delete "$entity_id" --confirm 2>/dev/null

	# Verify cascade
	local post_entity post_channels post_interactions post_profiles post_conversations
	post_entity=$(db_query "SELECT COUNT(*) FROM entities WHERE id = '$entity_id';")
	post_channels=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id';")
	post_interactions=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	post_profiles=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$entity_id';")
	post_conversations=$(db_query "SELECT COUNT(*) FROM conversations WHERE entity_id = '$entity_id';")

	assert_eq "0" "$post_entity" "Entity deleted"
	assert_eq "0" "$post_channels" "Channels cascaded"
	assert_eq "0" "$post_interactions" "Interactions cascaded"
	assert_eq "0" "$post_profiles" "Profiles cascaded"
	assert_eq "0" "$post_conversations" "Conversations cascaded"

	return 0
}

# ===========================================================================
# Test: Existing memory system unaffected
# ===========================================================================
test_existing_memory_unaffected() {
	echo -e "\n${YELLOW}Test: Existing memory system unaffected by entity tables${NC}"

	# Store a memory using the existing system
	local rc=0
	"$MEMORY_HELPER" store --content "Integration test memory" \
		--type WORKING_SOLUTION --tags "test,integration" 2>/dev/null || rc=$?
	assert_exit_code 0 "$rc" "Existing memory store works alongside entity tables"

	# Recall
	local output
	rc=0
	output=$("$MEMORY_HELPER" recall "integration test" --limit 1 2>&1) || rc=$?
	assert_exit_code 0 "$rc" "Existing memory recall works"
	assert_contains "$output" "integration" "Recalled memory contains expected content"

	# Verify learnings table still exists and has data
	local learnings_count
	learnings_count=$(db_query "SELECT COUNT(*) FROM learnings;")
	assert_gt 0 "$learnings_count" "Learnings table has data"

	return 0
}

# ===========================================================================
# Test: Context loading combines all three layers
# ===========================================================================
test_context_all_layers() {
	echo -e "\n${YELLOW}Test: Context loading combines all three layers${NC}"

	# Create entity with profile (Layer 2)
	local entity_id
	entity_id=$(create_entity "Context All" "person" "matrix" "@contextall:server")
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "technical_level" --value "expert" \
		--evidence "uses advanced terminology" 2>/dev/null

	# Create conversation (Layer 1)
	local conv_id
	conv_id=$(create_conversation "$entity_id" "matrix" "@contextall:server" "All layers test")

	# Add interactions (Layer 0)
	"$CONV_HELPER" add-message "$conv_id" --content "Can you explain the WAL mode?" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "WAL mode enables concurrent reads." --direction outbound 2>/dev/null

	# Generate summary (Layer 1)
	"$CONV_HELPER" summarise "$conv_id" 2>/dev/null

	# Load context — should have data from all layers
	local context
	context=$("$CONV_HELPER" context "$conv_id" 2>&1)

	# Layer 2: Entity profile
	assert_contains "$context" "technical_level" "Context includes Layer 2 profile key"

	# Layer 1: Summary or topic
	assert_contains "$context" "All layers test" "Context includes Layer 1 topic"

	# Layer 0: Recent messages
	assert_contains "$context" "WAL mode" "Context includes Layer 0 message content"

	# JSON context
	local json_context
	json_context=$("$CONV_HELPER" context "$conv_id" --json 2>/dev/null)
	assert_contains "$json_context" "\"entity_profile\"" "JSON context has entity_profile"
	assert_contains "$json_context" "\"latest_summary\"" "JSON context has latest_summary"
	assert_contains "$json_context" "\"recent_messages\"" "JSON context has recent_messages"

	return 0
}

# ===========================================================================
# Test: FTS5 search across interactions
# ===========================================================================
test_fts5_search() {
	echo -e "\n${YELLOW}Test: FTS5 full-text search across interactions${NC}"

	local entity_id
	entity_id=$(create_entity "FTS Test" "person" "cli" "fts-user")

	# Log interactions with distinct content
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "The kubernetes cluster needs scaling" 2>/dev/null
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Database migration completed successfully" 2>/dev/null
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Nginx reverse proxy configuration updated" 2>/dev/null

	# Search via FTS5
	local k8s_count
	k8s_count=$(db_query "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'kubernetes';")
	assert_gt 0 "$k8s_count" "FTS5 finds 'kubernetes'"

	local nginx_count
	nginx_count=$(db_query "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'nginx';")
	assert_gt 0 "$nginx_count" "FTS5 finds 'nginx'"

	local missing_count
	missing_count=$(db_query "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'nonexistent_term_xyz';")
	assert_eq "0" "$missing_count" "FTS5 returns 0 for non-matching term"

	return 0
}

# ===========================================================================
# Test: Entity types — person, agent, service
# ===========================================================================
test_entity_types() {
	echo -e "\n${YELLOW}Test: Entity types — person, agent, service${NC}"

	local person_id agent_id service_id
	person_id=$(create_entity "Human User" "person")
	agent_id=$(create_entity "Bot Agent" "agent")
	service_id=$(create_entity "API Service" "service")

	assert_not_empty "$person_id" "Person entity created"
	assert_not_empty "$agent_id" "Agent entity created"
	assert_not_empty "$service_id" "Service entity created"

	# Verify types in DB
	local person_type agent_type service_type
	person_type=$(db_query "SELECT type FROM entities WHERE id = '$person_id';")
	agent_type=$(db_query "SELECT type FROM entities WHERE id = '$agent_id';")
	service_type=$(db_query "SELECT type FROM entities WHERE id = '$service_id';")

	assert_eq "person" "$person_type" "Person type stored correctly"
	assert_eq "agent" "$agent_type" "Agent type stored correctly"
	assert_eq "service" "$service_type" "Service type stored correctly"

	# Invalid type should fail
	local rc=0
	"$ENTITY_HELPER" create --name "Invalid" --type "robot" 2>/dev/null || rc=$?
	assert_exit_code 1 "$rc" "Invalid entity type rejected"

	return 0
}

# ===========================================================================
# Test: Conversation duplicate detection
# ===========================================================================
test_conversation_dedup() {
	echo -e "\n${YELLOW}Test: Conversation duplicate detection${NC}"

	local entity_id
	entity_id=$(create_entity "Dedup User" "person" "matrix" "@dedup:server")

	local conv1
	conv1=$(create_conversation "$entity_id" "matrix" "@dedup:server" "First topic")
	assert_not_empty "$conv1" "First conversation created"

	# Creating same entity+channel+channel_id should return existing
	local conv2
	conv2=$(create_conversation "$entity_id" "matrix" "@dedup:server" "Second topic")
	assert_eq "$conv1" "$conv2" "Duplicate conversation returns existing ID"

	# Different channel_id should create new conversation
	local conv3
	conv3=$(create_conversation "$entity_id" "matrix" "!different-room:server" "Different room")
	assert_ne "$conv1" "$conv3" "Different channel_id creates new conversation"

	return 0
}

# ===========================================================================
# Test: Stats commands work
# ===========================================================================
test_stats() {
	echo -e "\n${YELLOW}Test: Stats commands${NC}"

	local entity_stats
	entity_stats=$("$ENTITY_HELPER" stats 2>&1)
	assert_contains "$entity_stats" "Entity Memory Statistics" "Entity stats header"
	assert_contains "$entity_stats" "Total entities" "Entity stats shows total"

	local conv_stats
	conv_stats=$("$CONV_HELPER" stats 2>&1)
	assert_contains "$conv_stats" "Conversation Statistics" "Conversation stats header"
	assert_contains "$conv_stats" "Total conversations" "Conversation stats shows total"

	return 0
}

# ===========================================================================
# Test: Idle check heuristic (no AI available in test)
# ===========================================================================
test_idle_check_heuristic() {
	echo -e "\n${YELLOW}Test: Idle check heuristic fallback${NC}"

	local entity_id
	entity_id=$(create_entity "Idle Test" "person" "cli" "idle-user")
	local conv_id
	conv_id=$(create_conversation "$entity_id" "cli" "idle-user")

	# No messages — should be idle
	local result
	result=$("$CONV_HELPER" idle-check "$conv_id" 2>/dev/null || true)
	assert_eq "idle" "$result" "Conversation with no messages is idle"

	# Add recent message — should be active
	"$CONV_HELPER" add-message "$conv_id" --content "Just checking in" --direction inbound 2>/dev/null
	result=$("$CONV_HELPER" idle-check "$conv_id" 2>/dev/null || true)
	assert_eq "active" "$result" "Conversation with recent message is active"

	return 0
}

# ===========================================================================
# Test: Profile history shows version chain
# ===========================================================================
test_profile_history() {
	echo -e "\n${YELLOW}Test: Profile history shows version chain${NC}"

	local entity_id
	entity_id=$(create_entity "History Test" "person")

	# Create three versions of the same key
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "preferred_language" --value "Python" 2>/dev/null
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "preferred_language" --value "Rust" 2>/dev/null
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "preferred_language" --value "Go" 2>/dev/null

	# Verify three versions exist
	local version_count
	version_count=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$entity_id' AND profile_key = 'preferred_language';")
	assert_eq "3" "$version_count" "Three profile versions exist"

	# Verify only latest is current (not superseded by anything)
	local current_value
	current_value=$(db_query "SELECT profile_value FROM entity_profiles WHERE entity_id = '$entity_id' AND profile_key = 'preferred_language' AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL);")
	assert_eq "Go" "$current_value" "Current profile value is latest (Go)"

	# Profile history command should work
	local history
	history=$("$ENTITY_HELPER" profile-history "$entity_id" 2>&1)
	assert_contains "$history" "Python" "History shows first version"
	assert_contains "$history" "Rust" "History shows second version"
	assert_contains "$history" "Go" "History shows third version"
	assert_contains "$history" "CURRENT" "History marks current version"

	return 0
}

# ===========================================================================
# Test: Multiple conversations per entity
# ===========================================================================
test_multiple_conversations() {
	echo -e "\n${YELLOW}Test: Multiple conversations per entity (different channels)${NC}"

	local entity_id
	entity_id=$(create_entity "Multi Conv" "person" "matrix" "@multiconv:server")
	"$ENTITY_HELPER" link "$entity_id" --channel email \
		--channel-id "multiconv@test.com" --verified 2>/dev/null

	# Create conversations on different channels
	local conv_matrix
	conv_matrix=$(create_conversation "$entity_id" "matrix" "@multiconv:server" "Matrix chat")
	local conv_email
	conv_email=$(create_conversation "$entity_id" "email" "multiconv@test.com" "Email thread")

	assert_ne "$conv_matrix" "$conv_email" "Different channels create different conversations"

	# Add messages to each
	"$CONV_HELPER" add-message "$conv_matrix" --content "Matrix message" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_email" --content "Email message" --direction inbound 2>/dev/null

	# Verify each conversation has its own messages
	local matrix_count email_count
	matrix_count=$(db_query "SELECT COUNT(*) FROM interactions WHERE conversation_id = '$conv_matrix';")
	email_count=$(db_query "SELECT COUNT(*) FROM interactions WHERE conversation_id = '$conv_email';")
	assert_eq "1" "$matrix_count" "Matrix conversation has 1 message"
	assert_eq "1" "$email_count" "Email conversation has 1 message"

	# Entity context should show all interactions across channels
	local entity_context
	entity_context=$("$ENTITY_HELPER" context "$entity_id" 2>&1)
	assert_contains "$entity_context" "Matrix message" "Entity context includes Matrix message"
	assert_contains "$entity_context" "Email message" "Entity context includes Email message"

	return 0
}

# ===========================================================================
# Main
# ===========================================================================
main() {
	echo "============================================"
	echo "Entity Memory Integration Test Suite (t1363.7)"
	echo "============================================"

	# Check dependencies
	if ! command -v sqlite3 &>/dev/null; then
		echo -e "${RED}ERROR${NC}: sqlite3 not found"
		exit 1
	fi

	for script in "$ENTITY_HELPER" "$CONV_HELPER" "$MEMORY_HELPER"; do
		if [[ ! -f "$script" ]]; then
			echo -e "${RED}ERROR${NC}: Required script not found: $script"
			exit 1
		fi
	done

	setup

	# Run tests
	test_schema_idempotent
	test_cross_layer_flow
	test_layer0_immutability
	test_layer1_summary_immutability
	test_layer2_profile_immutability
	test_privacy_filtering_ingest
	test_privacy_filtering_output
	test_cross_channel_identity
	test_conversation_lifecycle
	test_auto_resume
	test_entity_deletion_cascade
	test_existing_memory_unaffected
	test_context_all_layers
	test_fts5_search
	test_entity_types
	test_conversation_dedup
	test_stats
	test_idle_check_heuristic
	test_profile_history
	test_multiple_conversations

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
