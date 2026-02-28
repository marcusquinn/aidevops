#!/usr/bin/env bash
# test-entity-helper.sh - Tests for entity-helper.sh (t1363.1)
#
# Tests entity CRUD, identity resolution, privacy-filtered context,
# interaction logging, profile management, and capability gaps.
#
# Usage: bash tests/test-entity-helper.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITY_HELPER="$REPO_DIR/.agents/scripts/entity-helper.sh"

# Use a temporary directory for test database
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export AIDEVOPS_MEMORY_DIR="$TEST_DIR"

# Counters
PASS=0
FAIL=0
TOTAL=0

#######################################
# Test assertion helpers
#######################################
assert_success() {
	local desc="$1"
	shift
	TOTAL=$((TOTAL + 1))
	if "$@" >/dev/null 2>&1; then
		PASS=$((PASS + 1))
		echo "  PASS: $desc"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: $desc (exit code: $?)"
	fi
	return 0
}

assert_fail() {
	local desc="$1"
	shift
	TOTAL=$((TOTAL + 1))
	if ! "$@" >/dev/null 2>&1; then
		PASS=$((PASS + 1))
		echo "  PASS: $desc"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: $desc (expected failure, got success)"
	fi
	return 0
}

assert_output_contains() {
	local desc="$1"
	local expected="$2"
	shift 2
	TOTAL=$((TOTAL + 1))
	local output
	output=$("$@" 2>&1) || true
	if echo "$output" | grep -q "$expected"; then
		PASS=$((PASS + 1))
		echo "  PASS: $desc"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: $desc (expected '$expected' in output)"
		echo "    Got: $(echo "$output" | head -3)"
	fi
	return 0
}

assert_output_not_empty() {
	local desc="$1"
	shift
	TOTAL=$((TOTAL + 1))
	local output
	output=$("$@" 2>&1) || true
	if [[ -n "$output" ]]; then
		PASS=$((PASS + 1))
		echo "  PASS: $desc"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: $desc (output was empty)"
	fi
	return 0
}

echo "=== Entity Helper Tests (t1363.1) ==="
echo ""

# =============================================================================
echo "--- Schema Initialization ---"
# =============================================================================

# Create entity to trigger init_db
ENTITY_ID=$("$ENTITY_HELPER" create --name "Test Person" --type person 2>/dev/null | tail -1)
assert_success "Create entity initializes database" test -f "$TEST_DIR/memory.db"

# Verify all entity tables exist
for table in entities entity_channels interactions conversations entity_profiles capability_gaps; do
	TOTAL=$((TOTAL + 1))
	if sqlite3 "$TEST_DIR/memory.db" "SELECT COUNT(*) FROM $table;" >/dev/null 2>&1; then
		PASS=$((PASS + 1))
		echo "  PASS: Table '$table' exists"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: Table '$table' missing"
	fi
done

# Verify FTS5 table
TOTAL=$((TOTAL + 1))
if sqlite3 "$TEST_DIR/memory.db" "SELECT COUNT(*) FROM interactions_fts;" >/dev/null 2>&1; then
	PASS=$((PASS + 1))
	echo "  PASS: FTS5 table 'interactions_fts' exists"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: FTS5 table 'interactions_fts' missing"
fi

# Verify indexes exist
for idx in idx_entity_channels_entity idx_entity_channels_lookup idx_interactions_entity idx_interactions_conversation idx_interactions_created idx_conversations_entity idx_conversations_status idx_entity_profiles_entity idx_entity_profiles_type idx_capability_gaps_status idx_capability_gaps_entity; do
	TOTAL=$((TOTAL + 1))
	if sqlite3 "$TEST_DIR/memory.db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='$idx';" | grep -q "1"; then
		PASS=$((PASS + 1))
		echo "  PASS: Index '$idx' exists"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: Index '$idx' missing"
	fi
done

echo ""

# =============================================================================
echo "--- Entity CRUD ---"
# =============================================================================

# Entity was already created above
assert_output_contains "Get entity returns data" "Test Person" "$ENTITY_HELPER" get "$ENTITY_ID"

# Create with different types
AGENT_ID=$("$ENTITY_HELPER" create --name "Test Agent" --type agent 2>/dev/null | tail -1)
assert_output_contains "Create agent entity" "agent" "$ENTITY_HELPER" get "$AGENT_ID"

SERVICE_ID=$("$ENTITY_HELPER" create --name "Test Service" --type service --privacy sensitive 2>/dev/null | tail -1)
assert_output_contains "Create service entity with privacy" "sensitive" "$ENTITY_HELPER" get "$SERVICE_ID"

# List entities
assert_output_contains "List entities shows all" "Test Person" "$ENTITY_HELPER" list
assert_output_contains "List entities by type" "Test Agent" "$ENTITY_HELPER" list --type agent

# Update entity
assert_success "Update entity name" "$ENTITY_HELPER" update "$ENTITY_ID" --name "Updated Person"
assert_output_contains "Updated name persists" "Updated Person" "$ENTITY_HELPER" get "$ENTITY_ID"

assert_success "Update entity privacy" "$ENTITY_HELPER" update "$ENTITY_ID" --privacy sensitive
assert_output_contains "Updated privacy persists" "sensitive" "$ENTITY_HELPER" get "$ENTITY_ID"

# Search
assert_output_contains "Search by name" "Updated Person" "$ENTITY_HELPER" search --query "Updated"

# Delete (without confirm should fail)
assert_fail "Delete without confirm fails" "$ENTITY_HELPER" delete "$SERVICE_ID"
assert_success "Delete with confirm succeeds" "$ENTITY_HELPER" delete "$SERVICE_ID" --confirm

# Verify deletion
assert_fail "Deleted entity not found" "$ENTITY_HELPER" get "$SERVICE_ID"

# Validation
assert_fail "Create with invalid type fails" "$ENTITY_HELPER" create --name "Bad" --type invalid_type
assert_fail "Create without name fails" "$ENTITY_HELPER" create

echo ""

# =============================================================================
echo "--- Identity Resolution ---"
# =============================================================================

# Link channel identities
LINK_ID=$("$ENTITY_HELPER" link "$ENTITY_ID" --channel matrix --identifier "@test:server.com" 2>/dev/null | tail -1)
assert_output_not_empty "Link returns link ID" echo "$LINK_ID"

LINK_ID2=$("$ENTITY_HELPER" link "$ENTITY_ID" --channel email --identifier "test@example.com" 2>/dev/null | tail -1)
assert_output_not_empty "Link email returns link ID" echo "$LINK_ID2"

# Duplicate link should warn but succeed
assert_success "Duplicate link warns" "$ENTITY_HELPER" link "$ENTITY_ID" --channel matrix --identifier "@test:server.com"

# Link to different entity should fail
assert_fail "Link same identity to different entity fails" "$ENTITY_HELPER" link "$AGENT_ID" --channel matrix --identifier "@test:server.com"

# Resolve
assert_output_contains "Resolve finds entity" "Updated Person" "$ENTITY_HELPER" resolve --channel matrix --identifier "@test:server.com"
assert_fail "Resolve unknown identity returns empty" "$ENTITY_HELPER" resolve --channel matrix --identifier "@unknown:server.com"

# Suggest
assert_output_contains "Suggest finds cross-channel match" "Updated Person" "$ENTITY_HELPER" suggest --channel simplex --identifier "test"

# Verify
assert_success "Verify link succeeds" "$ENTITY_HELPER" verify "$LINK_ID" --by "test-admin"

# Unlink
assert_success "Unlink succeeds" "$ENTITY_HELPER" unlink "$LINK_ID2"
assert_fail "Unlink nonexistent fails" "$ENTITY_HELPER" unlink "nonexistent_id"

# Validation
assert_fail "Link with invalid channel fails" "$ENTITY_HELPER" link "$ENTITY_ID" --channel invalid_channel --identifier "test"

echo ""

# =============================================================================
echo "--- Interaction Logging ---"
# =============================================================================

INT_ID=$("$ENTITY_HELPER" interact "$ENTITY_ID" --channel matrix --direction inbound --summary "Asked about deployment status" 2>/dev/null | tail -1)
assert_output_not_empty "Interact returns interaction ID" echo "$INT_ID"

INT_ID2=$("$ENTITY_HELPER" interact "$ENTITY_ID" --channel matrix --direction outbound --summary "Deployment is running on v2.1" 2>/dev/null | tail -1)
assert_output_not_empty "Second interaction logged" echo "$INT_ID2"

# Verify interaction count
TOTAL=$((TOTAL + 1))
INT_COUNT=$(sqlite3 "$TEST_DIR/memory.db" "SELECT COUNT(*) FROM interactions WHERE entity_id = '$ENTITY_ID';")
if [[ "$INT_COUNT" == "2" ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: Interaction count is 2"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: Expected 2 interactions, got $INT_COUNT"
fi

# Verify FTS index
TOTAL=$((TOTAL + 1))
FTS_COUNT=$(sqlite3 "$TEST_DIR/memory.db" "SELECT COUNT(*) FROM interactions_fts WHERE interactions_fts MATCH 'deployment';")
if [[ "$FTS_COUNT" -ge 1 ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: FTS index contains interaction content"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: FTS index missing interaction content (count: $FTS_COUNT)"
fi

# Privacy filter: secrets should be rejected
assert_fail "Interaction with secret rejected" "$ENTITY_HELPER" interact "$ENTITY_ID" --channel matrix --direction inbound --summary "My API key is sk-1234567890abcdefghijklmnop"

# Validation
assert_fail "Interact with invalid direction fails" "$ENTITY_HELPER" interact "$ENTITY_ID" --channel matrix --direction sideways --summary "test"
assert_fail "Interact with nonexistent entity fails" "$ENTITY_HELPER" interact "nonexistent" --channel matrix --direction inbound --summary "test"

echo ""

# =============================================================================
echo "--- Profile Management ---"
# =============================================================================

PROF_ID=$("$ENTITY_HELPER" profile "$ENTITY_ID" --type preference --content "Prefers concise responses" 2>/dev/null | tail -1)
assert_output_not_empty "Profile creation returns ID" echo "$PROF_ID"

PROF_ID2=$("$ENTITY_HELPER" profile "$ENTITY_ID" --type style --content "Technical communication style" --confidence high 2>/dev/null | tail -1)
assert_output_not_empty "Second profile created" echo "$PROF_ID2"

# View profiles
assert_output_contains "View profiles shows content" "concise" "$ENTITY_HELPER" profile "$ENTITY_ID"
assert_output_contains "Filter profiles by type" "Technical" "$ENTITY_HELPER" profile "$ENTITY_ID" --type style

# Supersede a profile
PROF_ID3=$("$ENTITY_HELPER" profile "$ENTITY_ID" --type preference --content "Prefers detailed explanations" --supersedes "$PROF_ID" 2>/dev/null | tail -1)
assert_output_not_empty "Superseding profile created" echo "$PROF_ID3"

echo ""

# =============================================================================
echo "--- Capability Gaps ---"
# =============================================================================

GAP_ID=$("$ENTITY_HELPER" gap create --description "No deployment status dashboard" --type missing_feature 2>/dev/null | tail -1)
assert_output_not_empty "Gap creation returns ID" echo "$GAP_ID"

# Duplicate gap should increment frequency
"$ENTITY_HELPER" gap create --description "No deployment status dashboard" --type missing_feature >/dev/null 2>&1 || true
TOTAL=$((TOTAL + 1))
FREQ=$(sqlite3 "$TEST_DIR/memory.db" "SELECT frequency FROM capability_gaps WHERE id = '$GAP_ID';")
if [[ "$FREQ" == "2" ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: Duplicate gap increments frequency to 2"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: Expected frequency 2, got $FREQ"
fi

# List gaps
assert_output_contains "List gaps shows description" "dashboard" "$ENTITY_HELPER" gap list

# Update gap
assert_success "Update gap status" "$ENTITY_HELPER" gap update "$GAP_ID" --status todo_created --todo t1400

# List by status
assert_output_contains "List gaps by status" "t1400" "$ENTITY_HELPER" gap list --status todo_created

echo ""

# =============================================================================
echo "--- Privacy-Filtered Context ---"
# =============================================================================

# Reset entity privacy to standard for context test
"$ENTITY_HELPER" update "$ENTITY_ID" --privacy standard >/dev/null 2>&1

assert_output_contains "Context loads entity info" "Updated Person" "$ENTITY_HELPER" context "$ENTITY_ID"
assert_output_contains "Context includes interactions" "deployment" "$ENTITY_HELPER" context "$ENTITY_ID"
assert_output_contains "Context includes profiles" "preference" "$ENTITY_HELPER" context "$ENTITY_ID"
assert_output_contains "Context includes channels" "matrix" "$ENTITY_HELPER" context "$ENTITY_ID"

# Create a restricted entity and test privacy filtering
RESTRICTED_ID=$("$ENTITY_HELPER" create --name "Restricted Person" --type person --privacy restricted 2>/dev/null | tail -1)
assert_fail "Context with insufficient clearance fails" "$ENTITY_HELPER" context "$RESTRICTED_ID" --privacy-filter standard

echo ""

# =============================================================================
echo "--- Statistics ---"
# =============================================================================

assert_output_contains "Stats shows entity count" "Total entities" "$ENTITY_HELPER" stats
assert_output_contains "Stats shows interaction count" "Total interactions" "$ENTITY_HELPER" stats

echo ""

# =============================================================================
echo "--- Schema Migration (existing DB) ---"
# =============================================================================

# Create a memory DB without entity tables, then trigger migration
MIGRATE_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR" "$MIGRATE_DIR"' EXIT

sqlite3 "$MIGRATE_DIR/memory.db" <<'EOF'
PRAGMA journal_mode=WAL;
CREATE VIRTUAL TABLE IF NOT EXISTS learnings USING fts5(
    id UNINDEXED, session_id UNINDEXED, content, type, tags,
    confidence UNINDEXED, created_at UNINDEXED, event_date UNINDEXED,
    project_path UNINDEXED, source UNINDEXED, tokenize='porter unicode61'
);
CREATE TABLE IF NOT EXISTS learning_access (
    id TEXT PRIMARY KEY, last_accessed_at TEXT, access_count INTEGER DEFAULT 0, auto_captured INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS learning_relations (
    id TEXT PRIMARY KEY, supersedes_id TEXT,
    relation_type TEXT CHECK(relation_type IN ('updates', 'extends', 'derives')),
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS pattern_metadata (
    id TEXT PRIMARY KEY, strategy TEXT DEFAULT 'normal',
    quality TEXT DEFAULT NULL, failure_mode TEXT DEFAULT NULL,
    tokens_in INTEGER DEFAULT NULL, tokens_out INTEGER DEFAULT NULL,
    estimated_cost REAL DEFAULT NULL
);
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('mem_test1', 'sess1', 'Test memory', 'WORKING_SOLUTION', 'test', 'high', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '/tmp', 'manual');
EOF

# Run entity-helper against this DB — should trigger migration
AIDEVOPS_MEMORY_DIR="$MIGRATE_DIR" "$ENTITY_HELPER" create --name "Migration Test" --type person >/dev/null 2>&1

# Verify entity tables were created by migration
TOTAL=$((TOTAL + 1))
if sqlite3 "$MIGRATE_DIR/memory.db" "SELECT COUNT(*) FROM entities;" >/dev/null 2>&1; then
	PASS=$((PASS + 1))
	echo "  PASS: Migration created entity tables in existing DB"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: Migration did not create entity tables"
fi

# Verify existing data preserved
TOTAL=$((TOTAL + 1))
EXISTING=$(sqlite3 "$MIGRATE_DIR/memory.db" "SELECT COUNT(*) FROM learnings;")
if [[ "$EXISTING" == "1" ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: Existing memory data preserved after migration"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: Existing memory data lost (expected 1, got $EXISTING)"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================

echo "=== Results ==="
echo "  Total: $TOTAL"
echo "  Pass:  $PASS"
echo "  Fail:  $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
	echo "FAILED: $FAIL test(s) failed"
	exit 1
else
	echo "ALL TESTS PASSED"
	exit 0
fi
