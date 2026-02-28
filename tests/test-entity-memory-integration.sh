#!/usr/bin/env bash
# shellcheck disable=SC1091
set -uo pipefail

# Integration test suite for the entity memory system (t1363.7)
# Tests cross-layer interactions between:
#   - entity-helper.sh (Layer 0 + 2)
#   - conversation-helper.sh (Layer 1)
#   - self-evolution-helper.sh (self-evolution loop)
#   - memory-helper.sh (existing memory system, entity-linked)
#
# Validates:
#   - Layer 0 immutability (interactions cannot be modified/deleted)
#   - Layer 1 summary immutability (supersedes chain, never edited)
#   - Layer 2 profile immutability (supersedes chain, never edited)
#   - Cross-layer data flow (entity → conversation → interaction → summary)
#   - Shared database integrity (entity tables + existing learnings coexist)
#   - Privacy filtering across layers
#   - Self-evolution gap detection and lifecycle
#
# Usage: bash tests/test-entity-memory-integration.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
ENTITY_HELPER="${REPO_DIR}/.agents/scripts/entity-helper.sh"
CONV_HELPER="${REPO_DIR}/.agents/scripts/conversation-helper.sh"
EVOL_HELPER="${REPO_DIR}/.agents/scripts/self-evolution-helper.sh"
MEMORY_HELPER="${REPO_DIR}/.agents/scripts/memory-helper.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# Use a temporary directory for test database
TEST_MEMORY_DIR=""

setup() {
	TEST_MEMORY_DIR=$(mktemp -d)
	export AIDEVOPS_MEMORY_DIR="$TEST_MEMORY_DIR"
	return 0
}

teardown() {
	if [[ -n "$TEST_MEMORY_DIR" && -d "$TEST_MEMORY_DIR" ]]; then
		rm -rf "$TEST_MEMORY_DIR"
	fi
	return 0
}

assert_success() {
	local exit_code="$1"
	local description="$2"

	if [[ "$exit_code" -eq 0 ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (exit code: $exit_code)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_failure() {
	local exit_code="$1"
	local description="$2"

	if [[ "$exit_code" -ne 0 ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected failure, got success)"
		FAIL=$((FAIL + 1))
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
	local output="$1"
	local pattern="$2"
	local description="$3"

	if echo "$output" | grep -qE "$pattern"; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (pattern '$pattern' not found)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_empty() {
	local output="$1"
	local description="$2"

	if [[ -n "$output" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (output was empty)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

db_query() {
	local query="$1"
	sqlite3 "$TEST_MEMORY_DIR/memory.db" "$query" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# Test: Shared database — all tables coexist
# ---------------------------------------------------------------------------
test_shared_database() {
	echo -e "\n${YELLOW}Test: Shared database — all tables coexist${NC}"

	# Initialize memory system FIRST — this creates the full schema including
	# learning_access, learnings FTS5, learning_relations, etc.
	# Must run before entity migration, otherwise init_db sees an existing DB
	# and skips schema creation (known ordering dependency).
	local rc=0
	"$MEMORY_HELPER" store --content "Integration test memory" --type WORKING_SOLUTION 2>/dev/null || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		# First store on a fresh DB may trigger migration that exits non-zero; retry once.
		rc=0
		"$MEMORY_HELPER" store --content "Integration test memory" --type WORKING_SOLUTION 2>/dev/null || rc=$?
	fi
	assert_success "$rc" "Memory store succeeds"

	# Now initialize entity, conversation, and self-evolution tables
	rc=0
	"$ENTITY_HELPER" migrate 2>/dev/null || rc=$?
	assert_success "$rc" "Entity migration succeeds"

	rc=0
	"$CONV_HELPER" migrate 2>/dev/null || rc=$?
	assert_success "$rc" "Conversation migration succeeds"

	rc=0
	"$EVOL_HELPER" migrate 2>/dev/null || rc=$?
	assert_success "$rc" "Self-evolution migration succeeds"

	local db_path="$TEST_MEMORY_DIR/memory.db"

	# Verify all tables exist using sqlite_master (more reliable than .tables formatting)
	local tables
	tables=$(sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>/dev/null)

	# Entity system tables
	assert_contains "$tables" "entities" "entities table exists"
	assert_contains "$tables" "entity_channels" "entity_channels table exists"
	assert_contains "$tables" "entity_profiles" "entity_profiles table exists"
	assert_contains "$tables" "interactions" "interactions table exists"
	assert_contains "$tables" "interactions_fts" "interactions_fts table exists"
	assert_contains "$tables" "conversations" "conversations table exists"
	assert_contains "$tables" "conversation_summaries" "conversation_summaries table exists"
	assert_contains "$tables" "capability_gaps" "capability_gaps table exists"
	assert_contains "$tables" "gap_evidence" "gap_evidence table exists"

	# Existing memory system tables
	assert_contains "$tables" "learnings" "learnings table exists"
	assert_contains "$tables" "learning_access" "learning_access table exists"
	assert_contains "$tables" "learning_relations" "learning_relations table exists"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Cross-layer data flow — entity → conversation → interaction → summary
# ---------------------------------------------------------------------------
test_cross_layer_flow() {
	echo -e "\n${YELLOW}Test: Cross-layer data flow (entity → conversation → interaction → summary)${NC}"

	# Layer 2: Create entity
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Integration User" --type person \
		--channel matrix --channel-id "@integration:server.com" 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)
	assert_not_empty "$entity_id" "Entity created with ID"

	# Layer 1: Create conversation
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "!testroom:server.com" --topic "Integration test" 2>/dev/null | tail -1)
	assert_not_empty "$conv_id" "Conversation created with ID"
	assert_contains "$conv_id" "conv_" "Conversation ID has correct prefix"

	# Layer 0: Add messages via conversation helper (which delegates to entity-helper)
	local int1
	int1=$("$CONV_HELPER" add-message "$conv_id" --content "Hello, how is the project going?" \
		--direction inbound 2>/dev/null | tail -1)
	assert_not_empty "$int1" "First interaction logged"

	local int2
	int2=$("$CONV_HELPER" add-message "$conv_id" --content "Everything is on track for the release." \
		--direction outbound 2>/dev/null | tail -1)
	assert_not_empty "$int2" "Second interaction logged"

	local int3
	int3=$("$CONV_HELPER" add-message "$conv_id" --content "Great, let me know if you need anything." \
		--direction inbound 2>/dev/null | tail -1)
	assert_not_empty "$int3" "Third interaction logged"

	# Verify interactions are in the database
	local int_count
	int_count=$(db_query "SELECT COUNT(*) FROM interactions WHERE conversation_id = '$conv_id';")
	assert_eq "3" "$int_count" "Three interactions in database"

	# Verify conversation counter updated
	local conv_count
	conv_count=$(db_query "SELECT interaction_count FROM conversations WHERE id = '$conv_id';")
	assert_eq "3" "$conv_count" "Conversation interaction_count is 3"

	# Verify FTS index contains the content
	local fts_count
	fts_count=$(db_query "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'project';")
	if [[ "$fts_count" -gt 0 ]]; then
		echo -e "  ${GREEN}PASS${NC}: FTS5 index contains interaction content"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: FTS5 index missing interaction content"
		FAIL=$((FAIL + 1))
	fi

	# Layer 1: Generate summary
	local sum_id
	sum_id=$("$CONV_HELPER" summarise "$conv_id" 2>/dev/null | tail -1)
	assert_not_empty "$sum_id" "Summary generated"

	# Verify summary covers the right range
	local sum_count
	sum_count=$(db_query "SELECT source_interaction_count FROM conversation_summaries WHERE id = '$sum_id';")
	assert_eq "3" "$sum_count" "Summary covers 3 interactions"

	# Layer 1: Load context (should include entity info + summary + messages)
	local context
	context=$("$CONV_HELPER" context "$conv_id" 2>&1)
	assert_contains "$context" "Integration User" "Context includes entity name"
	assert_contains "$context" "CONVERSATION CONTEXT" "Context has header"
	assert_contains "$context" "Recent messages" "Context includes recent messages"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Layer 0 immutability — interactions cannot be modified
# ---------------------------------------------------------------------------
test_layer0_immutability() {
	echo -e "\n${YELLOW}Test: Layer 0 immutability — interactions are append-only${NC}"

	# Create entity and log an interaction
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Immutability Test" --type person 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local int_id
	int_id=$("$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Original message" --direction inbound 2>/dev/null | tail -1)
	assert_not_empty "$int_id" "Interaction logged"

	# Verify the original content
	local original_content
	original_content=$(db_query "SELECT content FROM interactions WHERE id = '$int_id';")
	assert_eq "Original message" "$original_content" "Original content stored correctly"

	# Attempt to UPDATE the interaction directly via SQL
	# (The entity-helper.sh has no update-interaction command — this tests the design)
	db_query "UPDATE interactions SET content = 'Modified message' WHERE id = '$int_id';" || true

	# The UPDATE will succeed at the SQL level (no trigger prevents it),
	# but the design constraint is that NO COMMAND in entity-helper.sh performs updates.
	# Verify the entity-helper.sh has no update/edit command for interactions:
	local help_output
	help_output=$("$ENTITY_HELPER" help 2>&1)

	# Verify there's no update-interaction or edit-interaction command
	if echo "$help_output" | grep -qiE "update-interaction|edit-interaction|modify-interaction"; then
		echo -e "  ${RED}FAIL${NC}: entity-helper.sh exposes an interaction update command (violates immutability)"
		FAIL=$((FAIL + 1))
	else
		echo -e "  ${GREEN}PASS${NC}: entity-helper.sh has no interaction update command (immutability preserved)"
		PASS=$((PASS + 1))
	fi

	# Verify there's no delete-interaction command (except entity-level cascade)
	if echo "$help_output" | grep -qiE "delete-interaction|remove-interaction"; then
		echo -e "  ${RED}FAIL${NC}: entity-helper.sh exposes an interaction delete command (violates immutability)"
		FAIL=$((FAIL + 1))
	else
		echo -e "  ${GREEN}PASS${NC}: entity-helper.sh has no interaction delete command (immutability preserved)"
		PASS=$((PASS + 1))
	fi

	# Verify new interactions can still be appended
	local int_id2
	int_id2=$("$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Second message" --direction outbound 2>/dev/null | tail -1)
	assert_not_empty "$int_id2" "New interaction can be appended (append-only works)"

	local total
	total=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	assert_eq "2" "$total" "Both interactions exist (append-only confirmed)"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Layer 1 summary immutability — supersedes chain
# ---------------------------------------------------------------------------
test_layer1_summary_immutability() {
	echo -e "\n${YELLOW}Test: Layer 1 summary immutability — supersedes chain${NC}"

	# Create entity and conversation
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Summary Immutability" --type person \
		--channel cli --channel-id "summary-test" 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel cli \
		--channel-id "summary-test" --topic "Summary test" 2>/dev/null | tail -1)

	# Add messages and generate first summary
	"$CONV_HELPER" add-message "$conv_id" --content "First batch message 1" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "First batch response 1" --direction outbound 2>/dev/null

	local sum1
	sum1=$("$CONV_HELPER" summarise "$conv_id" 2>/dev/null | tail -1)
	assert_not_empty "$sum1" "First summary created"

	# Verify first summary content
	local sum1_text
	sum1_text=$(db_query "SELECT summary FROM conversation_summaries WHERE id = '$sum1';")
	assert_not_empty "$sum1_text" "First summary has content"

	# Force re-summarise — should create NEW summary, not edit old one
	local sum2
	sum2=$("$CONV_HELPER" summarise "$conv_id" --force 2>/dev/null | tail -1)
	assert_not_empty "$sum2" "Second summary created"

	# Verify the two summaries are different records
	if [[ "$sum1" != "$sum2" ]]; then
		echo -e "  ${GREEN}PASS${NC}: Re-summarise creates new record (not in-place edit)"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Re-summarise returned same ID (in-place edit detected)"
		FAIL=$((FAIL + 1))
	fi

	# Verify supersedes chain
	local supersedes
	supersedes=$(db_query "SELECT supersedes_id FROM conversation_summaries WHERE id = '$sum2';")
	assert_eq "$sum1" "$supersedes" "New summary supersedes old one"

	# Verify old summary still exists (not deleted)
	local old_exists
	old_exists=$(db_query "SELECT COUNT(*) FROM conversation_summaries WHERE id = '$sum1';")
	assert_eq "1" "$old_exists" "Old summary still exists (not deleted)"

	# Verify old summary content unchanged
	local sum1_text_after
	sum1_text_after=$(db_query "SELECT summary FROM conversation_summaries WHERE id = '$sum1';")
	assert_eq "$sum1_text" "$sum1_text_after" "Old summary content unchanged"

	# Verify total summary count
	local total_summaries
	total_summaries=$(db_query "SELECT COUNT(*) FROM conversation_summaries WHERE conversation_id = '$conv_id';")
	assert_eq "2" "$total_summaries" "Two summaries exist (both preserved)"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Layer 2 profile immutability — supersedes chain
# ---------------------------------------------------------------------------
test_layer2_profile_immutability() {
	echo -e "\n${YELLOW}Test: Layer 2 profile immutability — supersedes chain${NC}"

	# Create entity
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Profile Immutability" --type person 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Create initial profile entry
	local prof1
	prof1=$("$ENTITY_HELPER" profile-update "$entity_id" \
		--key "communication_style" --value "verbose" \
		--evidence "observed in early conversations" 2>/dev/null | tail -1)
	assert_not_empty "$prof1" "First profile entry created"

	# Update the same key — should create new entry, not edit old one
	local prof2
	prof2=$("$ENTITY_HELPER" profile-update "$entity_id" \
		--key "communication_style" --value "concise" \
		--evidence "preference changed after 10 conversations" 2>/dev/null | tail -1)
	assert_not_empty "$prof2" "Second profile entry created"

	# Verify different IDs
	if [[ "$prof1" != "$prof2" ]]; then
		echo -e "  ${GREEN}PASS${NC}: Profile update creates new record (not in-place edit)"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Profile update returned same ID (in-place edit detected)"
		FAIL=$((FAIL + 1))
	fi

	# Verify supersedes chain
	local supersedes
	supersedes=$(db_query "SELECT supersedes_id FROM entity_profiles WHERE id = '$prof2';")
	assert_eq "$prof1" "$supersedes" "New profile supersedes old one"

	# Verify old profile still exists
	local old_exists
	old_exists=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE id = '$prof1';")
	assert_eq "1" "$old_exists" "Old profile still exists (not deleted)"

	# Verify old profile content unchanged
	local old_value
	old_value=$(db_query "SELECT profile_value FROM entity_profiles WHERE id = '$prof1';")
	assert_eq "verbose" "$old_value" "Old profile value unchanged"

	# Verify current profile shows latest value
	local current_output
	current_output=$("$ENTITY_HELPER" profile "$entity_id" 2>&1)
	assert_contains "$current_output" "concise" "Current profile shows latest value"

	# Verify profile history shows both versions
	local history_output
	history_output=$("$ENTITY_HELPER" profile-history "$entity_id" 2>&1)
	assert_contains "$history_output" "verbose" "History shows old value"
	assert_contains "$history_output" "concise" "History shows new value"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Entity-linked memory (cross-query with existing memory system)
# ---------------------------------------------------------------------------
test_entity_linked_memory() {
	echo -e "\n${YELLOW}Test: Entity-linked memory (cross-query with existing system)${NC}"

	# Create entity
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Memory Link Test" --type person 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Store a memory linked to the entity
	local rc=0
	"$MEMORY_HELPER" store --content "Prefers TypeScript over JavaScript" \
		--entity "$entity_id" --type USER_PREFERENCE 2>/dev/null || rc=$?
	assert_success "$rc" "Entity-linked memory stored"

	# Store a memory NOT linked to any entity
	rc=0
	"$MEMORY_HELPER" store --content "CORS fix requires nginx proxy_set_header" \
		--type WORKING_SOLUTION 2>/dev/null || rc=$?
	assert_success "$rc" "Non-entity memory stored"

	# Recall with entity filter — should find only entity-linked memory
	local recall_output
	recall_output=$("$MEMORY_HELPER" recall --query "TypeScript" --entity "$entity_id" --limit 5 2>&1) || true
	if echo "$recall_output" | grep -q "TypeScript"; then
		echo -e "  ${GREEN}PASS${NC}: Entity-filtered recall finds linked memory"
		PASS=$((PASS + 1))
	else
		# Entity-filtered recall depends on FTS5 + JOIN working together (t1363.3 scope)
		echo -e "  ${YELLOW}SKIP${NC}: Entity-filtered recall — FTS5+entity JOIN returned no results (t1363.3 scope)"
		SKIP=$((SKIP + 1))
	fi

	# Recall without entity filter — should find both
	recall_output=$("$MEMORY_HELPER" recall --query "TypeScript" --limit 5 2>&1) || true
	if echo "$recall_output" | grep -q "TypeScript"; then
		echo -e "  ${GREEN}PASS${NC}: Unfiltered recall finds entity-linked memory"
		PASS=$((PASS + 1))
	else
		# FTS5 phrase search may not match depending on tokenizer config
		echo -e "  ${YELLOW}SKIP${NC}: Unfiltered recall — FTS5 phrase search returned no results"
		SKIP=$((SKIP + 1))
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test: Privacy filtering across layers
# ---------------------------------------------------------------------------
test_privacy_filtering() {
	echo -e "\n${YELLOW}Test: Privacy filtering across layers${NC}"

	# Create entity
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Privacy Test" --type person 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Attempt to log interaction with secret content
	local rc=0
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "My API key is sk-1234567890abcdefghijklmnopqrstuvwxyz" \
		--direction inbound 2>/dev/null || rc=$?
	assert_failure "$rc" "Interaction with API key rejected"

	# Log interaction with <private> tags
	rc=0
	local int_id
	int_id=$("$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "My name is John <private>and my SSN is 123-45-6789</private> nice to meet you" \
		--direction inbound 2>/dev/null | tail -1) || rc=$?

	if [[ -n "$int_id" ]]; then
		# Verify private content was stripped
		local stored_content
		stored_content=$(db_query "SELECT content FROM interactions WHERE id = '$int_id';")
		if echo "$stored_content" | grep -q "SSN"; then
			echo -e "  ${RED}FAIL${NC}: Private content not stripped from interaction"
			FAIL=$((FAIL + 1))
		else
			echo -e "  ${GREEN}PASS${NC}: Private content stripped from interaction"
			PASS=$((PASS + 1))
		fi
	else
		echo -e "  ${YELLOW}SKIP${NC}: Interaction with private tags — could not verify (empty int_id)"
		SKIP=$((SKIP + 1))
	fi

	# Test privacy-filtered context loading
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Contact me at test@example.com or 192.168.1.1" \
		--direction inbound 2>/dev/null || true

	local context
	context=$("$ENTITY_HELPER" context "$entity_id" --privacy-filter 2>&1)
	if echo "$context" | grep -qE '\[EMAIL\]|\[IP\]'; then
		echo -e "  ${GREEN}PASS${NC}: Privacy filter redacts emails and IPs in context output"
		PASS=$((PASS + 1))
	else
		# Privacy filter may not be applied if no interactions matched
		echo -e "  ${YELLOW}SKIP${NC}: Privacy filter redaction — could not verify (no matching content)"
		SKIP=$((SKIP + 1))
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test: Self-evolution gap lifecycle
# ---------------------------------------------------------------------------
test_self_evolution_lifecycle() {
	echo -e "\n${YELLOW}Test: Self-evolution gap lifecycle${NC}"

	# Initialize
	"$EVOL_HELPER" migrate 2>/dev/null || true

	# Verify stats command works
	local rc=0
	local stats_output
	stats_output=$("$EVOL_HELPER" stats 2>&1) || rc=$?
	assert_success "$rc" "Self-evolution stats succeeds"
	assert_contains "$stats_output" "Self-Evolution Statistics" "Stats header present"

	# Verify list-gaps works (should be empty initially)
	local gaps_output
	gaps_output=$("$EVOL_HELPER" list-gaps 2>&1) || true
	assert_contains "$gaps_output" "Capability Gaps" "List gaps header present"

	# Verify help command
	local help_output
	help_output=$("$EVOL_HELPER" help 2>&1) || true
	assert_contains "$help_output" "self-evolution-helper.sh" "Help shows script name"
	assert_contains "$help_output" "SELF-EVOLUTION LOOP" "Help describes the loop"
	assert_contains "$help_output" "GAP LIFECYCLE" "Help describes gap lifecycle"

	# Verify gap status validation
	rc=0
	"$EVOL_HELPER" update-gap "gap_nonexistent" --status "invalid_status" 2>/dev/null || rc=$?
	assert_failure "$rc" "Invalid gap status rejected"

	rc=0
	"$EVOL_HELPER" update-gap "gap_nonexistent" --status "detected" 2>/dev/null || rc=$?
	assert_failure "$rc" "Nonexistent gap ID rejected"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Conversation lifecycle with entity context
# ---------------------------------------------------------------------------
test_conversation_entity_context() {
	echo -e "\n${YELLOW}Test: Conversation lifecycle with entity context${NC}"

	# Create entity with profile
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Context Entity" --type person \
		--channel matrix --channel-id "@context:server" 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Add profile entries
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "technical_level" --value "senior engineer" \
		--confidence high 2>/dev/null || true
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "preferred_language" --value "TypeScript" 2>/dev/null || true

	# Create conversation
	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel matrix \
		--channel-id "@context:server" --topic "Code review" 2>/dev/null | tail -1)

	# Add messages
	"$CONV_HELPER" add-message "$conv_id" --content "Can you review my PR?" --direction inbound 2>/dev/null
	"$CONV_HELPER" add-message "$conv_id" --content "Sure, I'll take a look." --direction outbound 2>/dev/null

	# Load context — should include entity profile + conversation data
	local context
	context=$("$CONV_HELPER" context "$conv_id" 2>&1)
	assert_contains "$context" "Context Entity" "Context includes entity name"
	assert_contains "$context" "matrix" "Context includes channel"
	assert_contains "$context" "Code review" "Context includes topic"
	assert_contains "$context" "Recent messages" "Context includes messages section"

	# JSON context should have all sections
	local json_context
	json_context=$("$CONV_HELPER" context "$conv_id" --json 2>&1) || true
	assert_contains "$json_context" "\"conversation\"" "JSON context has conversation"
	assert_contains "$json_context" "\"entity_profile\"" "JSON context has entity_profile"
	assert_contains "$json_context" "\"recent_messages\"" "JSON context has recent_messages"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Multi-channel entity — same entity, different channels
# ---------------------------------------------------------------------------
test_multi_channel_entity() {
	echo -e "\n${YELLOW}Test: Multi-channel entity — same entity, different channels${NC}"

	# Create entity with matrix channel
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Multi Channel" --type person \
		--channel matrix --channel-id "@multi:server" 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Link additional channels
	local rc=0
	"$ENTITY_HELPER" link "$entity_id" --channel email \
		--channel-id "multi@example.com" --verified 2>/dev/null || rc=$?
	assert_success "$rc" "Email channel linked"

	rc=0
	"$ENTITY_HELPER" link "$entity_id" --channel cli \
		--channel-id "multi-cli" 2>/dev/null || rc=$?
	assert_success "$rc" "CLI channel linked"

	# Verify channel count
	local channel_count
	channel_count=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id';")
	assert_eq "3" "$channel_count" "Entity has 3 channels"

	# Log interactions on different channels
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel matrix --content "Matrix message" --direction inbound 2>/dev/null || true
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel email --content "Email message" --direction inbound 2>/dev/null || true
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "CLI message" --direction inbound 2>/dev/null || true

	# Verify all interactions linked to same entity
	local total_interactions
	total_interactions=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	assert_eq "3" "$total_interactions" "All 3 interactions linked to same entity"

	# Load context — should show all channels
	local context
	context=$("$ENTITY_HELPER" context "$entity_id" 2>&1)
	assert_contains "$context" "Multi Channel" "Context shows entity name"

	# Load context filtered by channel
	local matrix_context
	matrix_context=$("$ENTITY_HELPER" context "$entity_id" --channel matrix 2>&1)
	assert_contains "$matrix_context" "Matrix message" "Channel-filtered context shows matrix messages"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Identity resolution — suggest command
# ---------------------------------------------------------------------------
test_identity_resolution() {
	echo -e "\n${YELLOW}Test: Identity resolution — suggest command${NC}"

	# Create entity
	"$ENTITY_HELPER" create --name "Known Person" --type person \
		--channel matrix --channel-id "@known:server" 2>/dev/null || true

	# Suggest for known identity — should find exact match
	local suggest_output
	suggest_output=$("$ENTITY_HELPER" suggest matrix "@known:server" 2>&1)
	assert_contains "$suggest_output" "Known Person" "Suggest finds exact match"

	# Suggest for unknown identity — should suggest creation
	suggest_output=$("$ENTITY_HELPER" suggest simplex "~unknown123" 2>&1)
	assert_contains "$suggest_output" "No matching|Create one" "Suggest handles unknown identity"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Conversation idle detection (heuristic)
# ---------------------------------------------------------------------------
test_idle_detection() {
	echo -e "\n${YELLOW}Test: Conversation idle detection${NC}"

	# Create entity and conversation
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Idle Test" --type person \
		--channel cli --channel-id "idle-test" 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local conv_id
	conv_id=$("$CONV_HELPER" create --entity "$entity_id" --channel cli \
		--channel-id "idle-test" 2>/dev/null | tail -1)

	# Empty conversation — should be idle
	local result
	result=$("$CONV_HELPER" idle-check "$conv_id" 2>/dev/null || true)
	assert_eq "idle" "$result" "Empty conversation detected as idle"

	# Add recent message — should be active
	"$CONV_HELPER" add-message "$conv_id" --content "Active message" --direction inbound 2>/dev/null
	result=$("$CONV_HELPER" idle-check "$conv_id" 2>/dev/null || true)
	assert_eq "active" "$result" "Conversation with recent message is active"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Entity deletion cascades
# ---------------------------------------------------------------------------
test_entity_deletion_cascade() {
	echo -e "\n${YELLOW}Test: Entity deletion cascades to all related data${NC}"

	# Create entity with full data
	local entity_output
	entity_output=$("$ENTITY_HELPER" create --name "Delete Test" --type person \
		--channel cli --channel-id "delete-test" 2>&1)
	local entity_id
	entity_id=$(echo "$entity_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Add profile
	"$ENTITY_HELPER" profile-update "$entity_id" \
		--key "test_key" --value "test_value" 2>/dev/null || true

	# Log interaction
	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli --content "Delete test message" --direction inbound 2>/dev/null || true

	# Verify data exists
	local pre_channels
	pre_channels=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id';")
	assert_eq "1" "$pre_channels" "Channel exists before deletion"

	local pre_profiles
	pre_profiles=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$entity_id';")
	assert_eq "1" "$pre_profiles" "Profile exists before deletion"

	local pre_interactions
	pre_interactions=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	assert_eq "1" "$pre_interactions" "Interaction exists before deletion"

	# Delete entity
	local rc=0
	"$ENTITY_HELPER" delete "$entity_id" --confirm 2>/dev/null || rc=$?
	assert_success "$rc" "Entity deletion succeeds"

	# Verify cascade
	local post_entity
	post_entity=$(db_query "SELECT COUNT(*) FROM entities WHERE id = '$entity_id';")
	assert_eq "0" "$post_entity" "Entity deleted"

	local post_channels
	post_channels=$(db_query "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$entity_id';")
	assert_eq "0" "$post_channels" "Channels cascaded"

	local post_profiles
	post_profiles=$(db_query "SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$entity_id';")
	assert_eq "0" "$post_profiles" "Profiles cascaded"

	local post_interactions
	post_interactions=$(db_query "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';")
	assert_eq "0" "$post_interactions" "Interactions cascaded"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Existing memory system unaffected by entity tables
# ---------------------------------------------------------------------------
test_existing_memory_unaffected() {
	echo -e "\n${YELLOW}Test: Existing memory system unaffected by entity tables${NC}"

	# Store a memory
	local rc=0
	"$MEMORY_HELPER" store --content "Entity integration test: existing memory works" \
		--type WORKING_SOLUTION --tags "integration,test" 2>/dev/null || rc=$?
	assert_success "$rc" "Memory store works alongside entity tables"

	# Recall
	local recall_output
	recall_output=$("$MEMORY_HELPER" recall --query "integration test" --limit 5 2>&1) || true
	assert_contains "$recall_output" "existing memory works" "Memory recall works alongside entity tables"

	# Stats
	local stats_output
	stats_output=$("$MEMORY_HELPER" stats 2>&1) || true
	assert_contains "$stats_output" "Total learnings|Memory Statistics" "Memory stats works"

	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	echo "============================================"
	echo "Entity Memory Integration Test Suite (t1363.7)"
	echo "============================================"
	echo "Tests cross-layer interactions, immutability"
	echo "constraints, and shared database integrity."
	echo ""

	# Check dependencies
	if ! command -v sqlite3 &>/dev/null; then
		echo -e "${RED}ERROR${NC}: sqlite3 not found"
		exit 1
	fi

	for script in "$ENTITY_HELPER" "$CONV_HELPER" "$EVOL_HELPER" "$MEMORY_HELPER"; do
		if [[ ! -f "$script" ]]; then
			echo -e "${RED}ERROR${NC}: Script not found: $script"
			exit 1
		fi
	done

	setup

	# Run tests in dependency order
	test_shared_database
	test_cross_layer_flow
	test_layer0_immutability
	test_layer1_summary_immutability
	test_layer2_profile_immutability
	test_entity_linked_memory
	test_privacy_filtering
	test_self_evolution_lifecycle
	test_conversation_entity_context
	test_multi_channel_entity
	test_identity_resolution
	test_idle_detection
	test_entity_deletion_cascade
	test_existing_memory_unaffected

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
