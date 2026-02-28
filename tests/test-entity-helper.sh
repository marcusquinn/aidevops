#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for entity-helper.sh (t1363.1)
# Validates entity CRUD, identity resolution, interaction logging,
# profile management, capability gaps, and privacy-filtered context.
#
# Usage: bash tests/test-entity-helper.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
ENTITY_HELPER="${REPO_DIR}/.agents/scripts/entity-helper.sh"
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

assert_contains() {
	local output="$1"
	local pattern="$2"
	local description="$3"

	if echo "$output" | grep -q "$pattern"; then
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

assert_db_table_exists() {
	local db_path="$1"
	local table_name="$2"
	local description="$3"

	local exists
	exists=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table_name';" 2>/dev/null || echo "0")
	if [[ "$exists" -gt 0 ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (table '$table_name' not found)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_db_count() {
	local db_path="$1"
	local query="$2"
	local expected="$3"
	local description="$4"

	local actual
	actual=$(sqlite3 "$db_path" "$query" 2>/dev/null || echo "-1")
	if [[ "$actual" == "$expected" ]]; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (expected $expected, got $actual)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: Schema creation
# ---------------------------------------------------------------------------
test_schema_creation() {
	echo -e "\n${YELLOW}Test: Schema creation — all entity tables exist${NC}"

	# Trigger DB init by running stats
	local output
	output=$(bash "$ENTITY_HELPER" stats 2>&1) || true

	local db_path="$TEST_MEMORY_DIR/memory.db"

	assert_db_table_exists "$db_path" "entities" "entities table exists"
	assert_db_table_exists "$db_path" "entity_channels" "entity_channels table exists"
	assert_db_table_exists "$db_path" "interactions" "interactions table exists"
	assert_db_table_exists "$db_path" "conversations" "conversations table exists"
	assert_db_table_exists "$db_path" "entity_profiles" "entity_profiles table exists"
	assert_db_table_exists "$db_path" "capability_gaps" "capability_gaps table exists"

	# Verify FTS5 table
	local fts_exists
	fts_exists=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='interactions_fts';" 2>/dev/null || echo "0")
	if [[ "$fts_exists" -gt 0 ]]; then
		echo -e "  ${GREEN}PASS${NC}: interactions_fts FTS5 table exists"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: interactions_fts FTS5 table not found"
		FAIL=$((FAIL + 1))
	fi

	# Verify existing memory tables still exist
	assert_db_table_exists "$db_path" "learnings" "learnings FTS5 table still exists"
	assert_db_table_exists "$db_path" "learning_access" "learning_access table still exists"
	assert_db_table_exists "$db_path" "learning_relations" "learning_relations table still exists"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Entity CRUD
# ---------------------------------------------------------------------------
test_entity_create() {
	echo -e "\n${YELLOW}Test: Entity create${NC}"

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" create --name "Test User" --type person 2>&1) || rc=$?
	assert_success "$rc" "Create entity succeeds"
	assert_contains "$output" "ent_" "Output contains entity ID"

	# Extract entity ID
	local entity_id
	entity_id=$(echo "$output" | grep -o 'ent_[a-z0-9_]*' | tail -1)
	assert_not_empty "$entity_id" "Entity ID extracted"

	# Verify in DB
	local db_path="$TEST_MEMORY_DIR/memory.db"
	assert_db_count "$db_path" "SELECT COUNT(*) FROM entities WHERE id = '$entity_id';" "1" "Entity exists in DB"

	return 0
}

test_entity_create_validation() {
	echo -e "\n${YELLOW}Test: Entity create validation${NC}"

	local rc=0
	bash "$ENTITY_HELPER" create 2>/dev/null || rc=$?
	assert_failure "$rc" "Create without name fails"

	rc=0
	bash "$ENTITY_HELPER" create --name "Test" --type invalid 2>/dev/null || rc=$?
	assert_failure "$rc" "Create with invalid type fails"

	return 0
}

test_entity_get() {
	echo -e "\n${YELLOW}Test: Entity get${NC}"

	# Create entity first
	local create_output
	create_output=$(bash "$ENTITY_HELPER" create --name "Get Test" 2>&1)
	local entity_id
	entity_id=$(echo "$create_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" get "$entity_id" 2>&1) || rc=$?
	assert_success "$rc" "Get entity succeeds"
	assert_contains "$output" "Get Test" "Output contains entity name"

	# Non-existent entity
	rc=0
	bash "$ENTITY_HELPER" get "ent_nonexistent" 2>/dev/null || rc=$?
	assert_failure "$rc" "Get non-existent entity fails"

	return 0
}

test_entity_list() {
	echo -e "\n${YELLOW}Test: Entity list${NC}"

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" list 2>&1) || rc=$?
	assert_success "$rc" "List entities succeeds"

	# JSON output
	output=$(bash "$ENTITY_HELPER" list --json 2>&1) || rc=$?
	assert_success "$rc" "List entities JSON succeeds"

	return 0
}

test_entity_update() {
	echo -e "\n${YELLOW}Test: Entity update${NC}"

	local create_output
	create_output=$(bash "$ENTITY_HELPER" create --name "Update Test" 2>&1)
	local entity_id
	entity_id=$(echo "$create_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local rc=0
	bash "$ENTITY_HELPER" update "$entity_id" --name "Updated Name" 2>&1 || rc=$?
	assert_success "$rc" "Update entity succeeds"

	local db_path="$TEST_MEMORY_DIR/memory.db"
	local name
	name=$(sqlite3 "$db_path" "SELECT display_name FROM entities WHERE id = '$entity_id';")
	if [[ "$name" == "Updated Name" ]]; then
		echo -e "  ${GREEN}PASS${NC}: Entity name updated in DB"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Entity name not updated (got: $name)"
		FAIL=$((FAIL + 1))
	fi

	return 0
}

test_entity_search() {
	echo -e "\n${YELLOW}Test: Entity search${NC}"

	bash "$ENTITY_HELPER" create --name "Searchable Person" 2>/dev/null

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" search --query "Searchable" 2>&1) || rc=$?
	assert_success "$rc" "Search entities succeeds"
	assert_contains "$output" "Searchable Person" "Search finds entity by name"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Channel management
# ---------------------------------------------------------------------------
test_channel_add() {
	echo -e "\n${YELLOW}Test: Channel add${NC}"

	local create_output
	create_output=$(bash "$ENTITY_HELPER" create --name "Channel Test" 2>&1)
	local entity_id
	entity_id=$(echo "$create_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" channel add "$entity_id" --type matrix --handle "@test:server" 2>&1) || rc=$?
	assert_success "$rc" "Add channel succeeds"
	assert_contains "$output" "ech_" "Output contains channel ID"

	# Duplicate handle should fail
	rc=0
	bash "$ENTITY_HELPER" channel add "$entity_id" --type matrix --handle "@test:server" 2>/dev/null || rc=$?
	assert_failure "$rc" "Duplicate channel handle fails"

	return 0
}

test_channel_list() {
	echo -e "\n${YELLOW}Test: Channel list${NC}"

	local create_output
	create_output=$(bash "$ENTITY_HELPER" create --name "Channel List Test" 2>&1)
	local entity_id
	entity_id=$(echo "$create_output" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	bash "$ENTITY_HELPER" channel add "$entity_id" --type email --handle "test@example.com" 2>/dev/null

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" channel list "$entity_id" 2>&1) || rc=$?
	assert_success "$rc" "List channels succeeds"
	assert_contains "$output" "test@example.com" "Channel handle in output"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Identity resolution
# ---------------------------------------------------------------------------
test_identity_link() {
	echo -e "\n${YELLOW}Test: Identity link (merge entities)${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Person A" 2>&1)
	local id1
	id1=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local out2
	out2=$(bash "$ENTITY_HELPER" create --name "Person A Duplicate" 2>&1)
	local id2
	id2=$(echo "$out2" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Add channels to both
	bash "$ENTITY_HELPER" channel add "$id1" --type matrix --handle "@persona:server" 2>/dev/null
	bash "$ENTITY_HELPER" channel add "$id2" --type email --handle "persona@example.com" 2>/dev/null

	# Link (merge id2 into id1)
	local rc=0
	bash "$ENTITY_HELPER" link "$id1" "$id2" 2>&1 || rc=$?
	assert_success "$rc" "Link entities succeeds"

	# Verify source entity deleted
	local db_path="$TEST_MEMORY_DIR/memory.db"
	assert_db_count "$db_path" "SELECT COUNT(*) FROM entities WHERE id = '$id2';" "0" "Source entity deleted after merge"

	# Verify channels moved to target
	assert_db_count "$db_path" "SELECT COUNT(*) FROM entity_channels WHERE entity_id = '$id1';" "2" "Both channels now on target entity"

	return 0
}

test_identity_unlink() {
	echo -e "\n${YELLOW}Test: Identity unlink (detach channel)${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Unlink Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local ch_out
	ch_out=$(bash "$ENTITY_HELPER" channel add "$entity_id" --type simplex --handle "simplex-contact-123" 2>&1)
	local channel_id
	channel_id=$(echo "$ch_out" | grep -o 'ech_[a-z0-9_]*' | tail -1)

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" unlink "$channel_id" 2>&1) || rc=$?
	assert_success "$rc" "Unlink channel succeeds"
	assert_contains "$output" "ent_" "New entity ID in output"

	return 0
}

test_identity_verify() {
	echo -e "\n${YELLOW}Test: Identity verify${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Verify Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local ch_out
	ch_out=$(bash "$ENTITY_HELPER" channel add "$entity_id" --type cli --handle "local-user" 2>&1)
	local channel_id
	channel_id=$(echo "$ch_out" | grep -o 'ech_[a-z0-9_]*' | tail -1)

	local rc=0
	bash "$ENTITY_HELPER" verify "$channel_id" 2>&1 || rc=$?
	assert_success "$rc" "Verify channel succeeds"

	local db_path="$TEST_MEMORY_DIR/memory.db"
	assert_db_count "$db_path" "SELECT verified FROM entity_channels WHERE id = '$channel_id';" "1" "Channel marked as verified"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Interaction logging (Layer 0)
# ---------------------------------------------------------------------------
test_interaction_log() {
	echo -e "\n${YELLOW}Test: Interaction logging (Layer 0 — immutable)${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Interaction Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" interact \
		--entity "$entity_id" \
		--channel-type matrix \
		--channel-id "!testroom:server" \
		--direction inbound \
		--content "Hello, how are you?" 2>&1) || rc=$?
	assert_success "$rc" "Log interaction succeeds"
	assert_contains "$output" "int_" "Output contains interaction ID"

	# Log outbound
	output=$(bash "$ENTITY_HELPER" interact \
		--entity "$entity_id" \
		--channel-type matrix \
		--channel-id "!testroom:server" \
		--direction outbound \
		--content "I am doing well, thank you!" 2>&1) || rc=$?
	assert_success "$rc" "Log outbound interaction succeeds"

	# Verify in DB
	local db_path="$TEST_MEMORY_DIR/memory.db"
	assert_db_count "$db_path" "SELECT COUNT(*) FROM interactions WHERE entity_id = '$entity_id';" "2" "Two interactions in DB"

	# Verify FTS index
	local fts_count
	fts_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'hello';" 2>/dev/null || echo "0")
	if [[ "$fts_count" -gt 0 ]]; then
		echo -e "  ${GREEN}PASS${NC}: FTS5 index contains interaction content"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: FTS5 index missing interaction content"
		FAIL=$((FAIL + 1))
	fi

	return 0
}

test_interaction_validation() {
	echo -e "\n${YELLOW}Test: Interaction validation${NC}"

	local rc=0
	bash "$ENTITY_HELPER" interact 2>/dev/null || rc=$?
	assert_failure "$rc" "Interact without required fields fails"

	rc=0
	bash "$ENTITY_HELPER" interact --entity "ent_fake" --channel-type matrix --channel-id "!room" --direction inbound --content "test" 2>/dev/null || rc=$?
	assert_failure "$rc" "Interact with non-existent entity fails"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Entity profiles (Layer 2)
# ---------------------------------------------------------------------------
test_profile_add() {
	echo -e "\n${YELLOW}Test: Entity profile add${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Profile Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" profile add "$entity_id" \
		--type needs \
		--content "Needs deployment status updates" \
		--confidence high \
		--evidence '["int_xxx","int_yyy"]' 2>&1) || rc=$?
	assert_success "$rc" "Add profile succeeds"
	assert_contains "$output" "ep_" "Output contains profile ID"

	# Verify evidence and confidence stored
	local db_path="$TEST_MEMORY_DIR/memory.db"
	local profile_id
	profile_id=$(echo "$output" | grep -o 'ep_[a-z0-9_]*' | tail -1)
	local confidence
	confidence=$(sqlite3 "$db_path" "SELECT confidence FROM entity_profiles WHERE id = '$profile_id';")
	if [[ "$confidence" == "high" ]]; then
		echo -e "  ${GREEN}PASS${NC}: Profile confidence stored correctly"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Profile confidence wrong (got: $confidence)"
		FAIL=$((FAIL + 1))
	fi

	local evidence
	evidence=$(sqlite3 "$db_path" "SELECT evidence FROM entity_profiles WHERE id = '$profile_id';")
	assert_contains "$evidence" "int_xxx" "Evidence contains interaction IDs"

	return 0
}

test_profile_versioning() {
	echo -e "\n${YELLOW}Test: Entity profile versioning (supersedes chain)${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Version Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Create initial profile
	local p1_out
	p1_out=$(bash "$ENTITY_HELPER" profile add "$entity_id" \
		--type preferences \
		--content "Prefers verbose responses" 2>&1)
	local p1_id
	p1_id=$(echo "$p1_out" | grep -o 'ep_[a-z0-9_]*' | tail -1)

	# Create superseding profile
	local p2_out
	p2_out=$(bash "$ENTITY_HELPER" profile add "$entity_id" \
		--type preferences \
		--content "Prefers concise responses" \
		--supersedes "$p1_id" 2>&1)
	local p2_id
	p2_id=$(echo "$p2_out" | grep -o 'ep_[a-z0-9_]*' | tail -1)

	# List should show only latest (not superseded)
	local list_output
	list_output=$(bash "$ENTITY_HELPER" profile list "$entity_id" --type preferences 2>&1)
	assert_contains "$list_output" "concise" "Latest profile shown"

	# Verify supersedes chain in DB
	local db_path="$TEST_MEMORY_DIR/memory.db"
	local supersedes
	supersedes=$(sqlite3 "$db_path" "SELECT supersedes_id FROM entity_profiles WHERE id = '$p2_id';")
	if [[ "$supersedes" == "$p1_id" ]]; then
		echo -e "  ${GREEN}PASS${NC}: Supersedes chain correct"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: Supersedes chain wrong (got: $supersedes, expected: $p1_id)"
		FAIL=$((FAIL + 1))
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test: Capability gaps
# ---------------------------------------------------------------------------
test_gap_lifecycle() {
	echo -e "\n${YELLOW}Test: Capability gap lifecycle${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Gap Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Add gap
	local gap_out
	local rc=0
	gap_out=$(bash "$ENTITY_HELPER" gap add \
		--description "Cannot generate PDF reports" \
		--entity "$entity_id" \
		--evidence '["int_aaa"]' 2>&1) || rc=$?
	assert_success "$rc" "Add gap succeeds"
	local gap_id
	gap_id=$(echo "$gap_out" | grep -o 'gap_[a-z0-9_]*' | tail -1)

	# Duplicate gap should increment frequency
	local gap_out2
	gap_out2=$(bash "$ENTITY_HELPER" gap add \
		--description "Cannot generate PDF reports" 2>&1)
	assert_contains "$gap_out2" "$gap_id" "Duplicate gap returns existing ID"

	local db_path="$TEST_MEMORY_DIR/memory.db"
	assert_db_count "$db_path" "SELECT frequency FROM capability_gaps WHERE id = '$gap_id';" "2" "Gap frequency incremented"

	# List gaps
	local list_out
	list_out=$(bash "$ENTITY_HELPER" gap list 2>&1)
	assert_contains "$list_out" "PDF reports" "Gap listed"

	# Resolve gap with task
	rc=0
	bash "$ENTITY_HELPER" gap resolve "$gap_id" --task "t1234" 2>&1 || rc=$?
	assert_success "$rc" "Resolve gap succeeds"
	assert_db_count "$db_path" "SELECT COUNT(*) FROM capability_gaps WHERE id = '$gap_id' AND status = 'task_created' AND todo_task_id = 't1234';" "1" "Gap marked as task_created with task ID"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Privacy-filtered context loading
# ---------------------------------------------------------------------------
test_context_loading() {
	echo -e "\n${YELLOW}Test: Privacy-filtered context loading${NC}"

	local out1
	out1=$(bash "$ENTITY_HELPER" create --name "Context Test" 2>&1)
	local entity_id
	entity_id=$(echo "$out1" | grep -o 'ent_[a-z0-9_]*' | tail -1)

	# Add channels with different privacy levels
	bash "$ENTITY_HELPER" channel add "$entity_id" --type matrix --handle "@ctx:server" --privacy public 2>/dev/null
	bash "$ENTITY_HELPER" channel add "$entity_id" --type simplex --handle "simplex-ctx-123" --privacy private 2>/dev/null

	# Add interactions on different channels
	bash "$ENTITY_HELPER" interact --entity "$entity_id" --channel-type matrix --channel-id "!public:server" --direction inbound --content "Public message" 2>/dev/null
	bash "$ENTITY_HELPER" interact --entity "$entity_id" --channel-type simplex --channel-id "simplex-ctx-123" --direction inbound --content "Private message" 2>/dev/null

	# Add profile
	bash "$ENTITY_HELPER" profile add "$entity_id" --type preferences --content "Prefers technical detail" 2>/dev/null

	# Load context (admin view — no channel filter)
	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" context "$entity_id" 2>&1) || rc=$?
	assert_success "$rc" "Context loading succeeds"
	assert_contains "$output" "Context Test" "Context shows entity name"
	assert_contains "$output" "Profile" "Context includes profile section"
	assert_contains "$output" "Interactions" "Context includes interactions section"

	# Load context with private channel filter
	output=$(bash "$ENTITY_HELPER" context "$entity_id" --channel-type simplex 2>&1) || rc=$?
	assert_success "$rc" "Private channel context loading succeeds"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Entity stats
# ---------------------------------------------------------------------------
test_stats() {
	echo -e "\n${YELLOW}Test: Entity stats${NC}"

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" stats 2>&1) || rc=$?
	assert_success "$rc" "Stats command succeeds"
	assert_contains "$output" "Entity Memory Statistics" "Stats header present"
	assert_contains "$output" "Total entities" "Stats shows entity count"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Existing memory system still works
# ---------------------------------------------------------------------------
test_existing_memory_unaffected() {
	echo -e "\n${YELLOW}Test: Existing memory system unaffected${NC}"

	# Store a memory using the existing system
	local rc=0
	bash "$MEMORY_HELPER" store --content "Test memory for entity integration" --type WORKING_SOLUTION 2>&1 || rc=$?
	assert_success "$rc" "Existing memory store still works"

	# Recall
	local output
	rc=0
	output=$(bash "$MEMORY_HELPER" recall --query "entity integration" --limit 1 2>&1) || rc=$?
	assert_success "$rc" "Existing memory recall still works"

	return 0
}

# ---------------------------------------------------------------------------
# Test: Help output
# ---------------------------------------------------------------------------
test_help() {
	echo -e "\n${YELLOW}Test: Help output${NC}"

	local output
	local rc=0
	output=$(bash "$ENTITY_HELPER" help 2>&1) || rc=$?
	assert_success "$rc" "Help command succeeds"
	assert_contains "$output" "entity-helper.sh" "Help shows script name"
	assert_contains "$output" "IDENTITY RESOLUTION" "Help shows identity resolution section"
	assert_contains "$output" "PRIVACY LEVELS" "Help shows privacy levels"

	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	echo "============================================"
	echo "Entity Helper Test Suite (t1363.1)"
	echo "============================================"

	# Check dependencies
	if ! command -v sqlite3 &>/dev/null; then
		echo -e "${RED}ERROR${NC}: sqlite3 not found"
		exit 1
	fi

	if [[ ! -f "$ENTITY_HELPER" ]]; then
		echo -e "${RED}ERROR${NC}: entity-helper.sh not found at $ENTITY_HELPER"
		exit 1
	fi

	setup

	# Run tests
	test_schema_creation
	test_entity_create
	test_entity_create_validation
	test_entity_get
	test_entity_list
	test_entity_update
	test_entity_search
	test_channel_add
	test_channel_list
	test_identity_link
	test_identity_unlink
	test_identity_verify
	test_interaction_log
	test_interaction_validation
	test_profile_add
	test_profile_versioning
	test_gap_lifecycle
	test_context_loading
	test_stats
	test_existing_memory_unaffected
	test_help

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
