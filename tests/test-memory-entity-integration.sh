#!/usr/bin/env bash
# test-memory-entity-integration.sh
#
# Tests for memory-entity integration (t1363.3):
# - Store with --entity flag links memory to entity
# - Recall with --entity flag filters by entity
# - Cross-query: --entity + --project
# - Backward compatibility: store/recall without --entity unchanged
# - Entity validation: store fails for nonexistent entity
# - learning_entities table migration
#
# Uses isolated temp directories to avoid touching production data.
#
# Usage: bash tests/test-memory-entity-integration.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
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

summary() {
	echo ""
	echo "=== Results ==="
	echo "  Total: $TOTAL_COUNT | Pass: $PASS_COUNT | Fail: $FAIL_COUNT | Skip: $SKIP_COUNT"
	if [[ $FAIL_COUNT -gt 0 ]]; then
		echo "  STATUS: FAILED"
		return 1
	else
		echo "  STATUS: PASSED"
		return 0
	fi
}

# --- Setup ---
TEST_DIR=$(mktemp -d)
export AIDEVOPS_MEMORY_DIR="$TEST_DIR/memory"
mkdir -p "$AIDEVOPS_MEMORY_DIR"

cleanup() {
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Check prerequisites
if ! command -v sqlite3 &>/dev/null; then
	echo "SKIP: sqlite3 not found"
	exit 0
fi

echo ""
echo "=== Memory-Entity Integration Tests (t1363.3) ==="
echo "  Test dir: $TEST_DIR"
echo ""

# --- Helper: create entity directly in DB ---
create_test_entity() {
	local entity_id="$1"
	local name="$2"
	local entity_type="${3:-person}"

	sqlite3 -cmd ".timeout 5000" "$AIDEVOPS_MEMORY_DIR/memory.db" <<EOF
INSERT OR IGNORE INTO entities (id, name, type)
VALUES ('$entity_id', '$name', '$entity_type');
EOF
}

# --- Test 1: Schema migration creates learning_entities table ---
echo "--- Schema & Migration ---"

# Initialize DB by running store (which calls init_db)
output=$("$SCRIPTS_DIR/memory-helper.sh" store --content "Schema init test" --type WORKING_SOLUTION 2>&1) || true

# Check learning_entities table exists
table_exists=$(sqlite3 "$AIDEVOPS_MEMORY_DIR/memory.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='learning_entities';" 2>/dev/null || echo "0")
if [[ "$table_exists" == "1" ]]; then
	pass "learning_entities table created on init"
else
	fail "learning_entities table not created" "Expected table to exist after init_db"
fi

# Check entity tables also exist (from t1363.1 migration)
entities_exists=$(sqlite3 "$AIDEVOPS_MEMORY_DIR/memory.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='entities';" 2>/dev/null || echo "0")
if [[ "$entities_exists" == "1" ]]; then
	pass "entities table exists (t1363.1 prerequisite)"
else
	fail "entities table missing" "Entity tables from t1363.1 not created"
fi

# --- Test 2: Store without --entity (backward compatibility) ---
echo ""
echo "--- Backward Compatibility ---"

output=$("$SCRIPTS_DIR/memory-helper.sh" store --content "No entity learning" --type DECISION 2>&1)
mem_id=$(echo "$output" | grep -o 'mem_[a-z0-9_]*' | tail -1)

if [[ -n "$mem_id" ]]; then
	pass "Store without --entity succeeds"
else
	fail "Store without --entity failed" "$output"
fi

# Verify no learning_entities row created
le_count=$(sqlite3 "$AIDEVOPS_MEMORY_DIR/memory.db" "SELECT COUNT(*) FROM learning_entities WHERE learning_id = '$mem_id';" 2>/dev/null || echo "0")
if [[ "$le_count" == "0" ]]; then
	pass "No entity link created when --entity not used"
else
	fail "Unexpected entity link created" "Found $le_count rows for $mem_id"
fi

# --- Test 3: Store with --entity links memory to entity ---
echo ""
echo "--- Store with --entity ---"

# Create a test entity
create_test_entity "ent_test001" "Test Person"

output=$("$SCRIPTS_DIR/memory-helper.sh" store --content "Entity-linked learning about deployment" --type WORKING_SOLUTION --entity ent_test001 2>&1)
entity_mem_id=$(echo "$output" | grep -o 'mem_[a-z0-9_]*' | tail -1)

if [[ -n "$entity_mem_id" ]]; then
	pass "Store with --entity succeeds"
else
	fail "Store with --entity failed" "$output"
fi

# Verify learning_entities row created
le_count=$(sqlite3 "$AIDEVOPS_MEMORY_DIR/memory.db" "SELECT COUNT(*) FROM learning_entities WHERE learning_id = '$entity_mem_id' AND entity_id = 'ent_test001';" 2>/dev/null || echo "0")
if [[ "$le_count" == "1" ]]; then
	pass "Entity link created in learning_entities"
else
	fail "Entity link not created" "Expected 1 row, got $le_count"
fi

# --- Test 4: Store with nonexistent entity fails ---
output=$("$SCRIPTS_DIR/memory-helper.sh" store --content "Should fail" --type DECISION --entity ent_nonexistent 2>&1) && rc=$? || rc=$?
if [[ $rc -ne 0 ]]; then
	pass "Store with nonexistent entity fails"
else
	fail "Store with nonexistent entity should have failed" "$output"
fi

# --- Test 5: Recall without --entity (backward compatibility) ---
echo ""
echo "--- Recall Backward Compatibility ---"

output=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "deployment" 2>&1)
if echo "$output" | grep -q "deployment"; then
	pass "Recall without --entity returns results"
else
	fail "Recall without --entity returned no results" "$output"
fi

# --- Test 6: Recall with --entity filters correctly ---
echo ""
echo "--- Recall with --entity ---"

# Store another memory for a different entity
create_test_entity "ent_test002" "Other Person"
"$SCRIPTS_DIR/memory-helper.sh" store --content "Different entity learning about deployment" --type WORKING_SOLUTION --entity ent_test002 >/dev/null 2>&1

# Recall for ent_test001 should only return its memory
output=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "deployment" --entity ent_test001 2>&1)
if echo "$output" | grep -q "Entity-linked learning"; then
	pass "Recall --entity returns entity's memory"
else
	fail "Recall --entity did not return entity's memory" "$output"
fi

# Check that the other entity's memory is NOT in the results
if echo "$output" | grep -q "Different entity learning"; then
	fail "Recall --entity returned wrong entity's memory" "Should not contain 'Different entity learning'"
else
	pass "Recall --entity excludes other entities' memories"
fi

# --- Test 7: Recall --entity with --recent ---
echo ""
echo "--- Recall --entity --recent ---"

output=$("$SCRIPTS_DIR/memory-helper.sh" recall --recent --entity ent_test001 2>&1)
if echo "$output" | grep -q "Entity-linked learning"; then
	pass "Recall --recent --entity returns entity's memories"
else
	fail "Recall --recent --entity failed" "$output"
fi

# --- Test 8: Cross-query: --entity + --project ---
echo ""
echo "--- Cross-query: --entity + --project ---"

# Store a memory with entity + specific project
"$SCRIPTS_DIR/memory-helper.sh" store --content "Project-specific entity memory about testing" --type WORKING_SOLUTION --entity ent_test001 --project "/tmp/myproject" >/dev/null 2>&1

# Cross-query should find it
output=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "testing" --entity ent_test001 --project "/tmp/myproject" 2>&1)
if echo "$output" | grep -q "Project-specific entity memory"; then
	pass "Cross-query (entity + project) returns correct result"
else
	fail "Cross-query (entity + project) failed" "$output"
fi

# Cross-query with wrong project should not find it
output=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "testing" --entity ent_test001 --project "/tmp/otherproject" 2>&1)
if echo "$output" | grep -q "Project-specific entity memory"; then
	fail "Cross-query with wrong project returned result" "Should not match /tmp/otherproject"
else
	pass "Cross-query with wrong project correctly excludes"
fi

# --- Test 9: Entity header in text output ---
echo ""
echo "--- Output formatting ---"

output=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "deployment" --entity ent_test001 2>&1)
if echo "$output" | grep -q "\[entity: ent_test001\]"; then
	pass "Entity shown in recall header"
else
	fail "Entity not shown in recall header" "$output"
fi

# --- Test 10: Multiple entities on same memory (edge case) ---
echo ""
echo "--- Edge cases ---"

# Manually insert a second entity link for the same memory
sqlite3 "$AIDEVOPS_MEMORY_DIR/memory.db" "INSERT OR IGNORE INTO learning_entities (learning_id, entity_id) VALUES ('$entity_mem_id', 'ent_test002');"

# Both entities should find this memory
output1=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "Entity-linked" --entity ent_test001 2>&1)
output2=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "Entity-linked" --entity ent_test002 2>&1)

if echo "$output1" | grep -q "Entity-linked learning" && echo "$output2" | grep -q "Entity-linked learning"; then
	pass "Memory linked to multiple entities found by both"
else
	fail "Multi-entity linking failed" "ent_test001 found: $(echo "$output1" | grep -c 'Entity-linked'), ent_test002 found: $(echo "$output2" | grep -c 'Entity-linked')"
fi

# --- Test 11: JSON output with --entity ---
output=$("$SCRIPTS_DIR/memory-helper.sh" recall --query "deployment" --entity ent_test001 --json 2>&1)
if echo "$output" | grep -q '"id"'; then
	pass "JSON output with --entity works"
else
	fail "JSON output with --entity failed" "$output"
fi

# --- Summary ---
summary
