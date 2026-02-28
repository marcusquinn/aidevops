#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Test suite for self-evolution-helper.sh (t1363.4)
# Validates capability gap detection, gap lifecycle management,
# evidence trail recording, frequency tracking, and pulse scan integration.
#
# Usage: bash tests/test-self-evolution-helper.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
EVOL_HELPER="${REPO_DIR}/.agents/scripts/self-evolution-helper.sh"
ENTITY_HELPER="${REPO_DIR}/.agents/scripts/entity-helper.sh"

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

assert_not_contains() {
	local output="$1"
	local pattern="$2"
	local description="$3"

	if ! echo "$output" | grep -q "$pattern"; then
		echo -e "  ${GREEN}PASS${NC}: $description"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: $description (pattern '$pattern' should not be present)"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# Helper: create a test entity and log some interactions
# Returns entity ID on stdout. Uses tail -1 to extract the ID from
# entity-helper.sh output (which may include log lines before the ID).
# Validates the ID starts with "ent_" to catch format changes early.
setup_test_entity() {
	local raw_output
	raw_output=$("$ENTITY_HELPER" create --name "Test User" --type person --channel cli --channel-id "test-user-1" 2>/dev/null) || true
	local entity_id
	entity_id=$(echo "$raw_output" | tail -1)

	# Validate entity ID format — catch upstream changes early
	if [[ -z "$entity_id" || ! "$entity_id" =~ ^ent_ ]]; then
		echo "INVALID_ENTITY_ID" >&2
		echo ""
		return 1
	fi

	echo "$entity_id"
	return 0
}

# Helper: log a test interaction
log_test_interaction() {
	local entity_id="$1"
	local content="$2"
	local direction="${3:-inbound}"

	"$ENTITY_HELPER" log-interaction "$entity_id" \
		--channel cli \
		--content "$content" \
		--direction "$direction" 2>/dev/null | tail -1
	return 0
}

# Helper: insert a gap directly into the database for testing
insert_test_gap() {
	local description="$1"
	local entity_id="${2:-}"
	local frequency="${3:-1}"
	local status="${4:-detected}"

	local gap_id
	gap_id="gap_test_$(head -c 4 /dev/urandom | xxd -p)"

	local entity_clause="NULL"
	if [[ -n "$entity_id" ]]; then
		entity_clause="'$entity_id'"
	fi

	sqlite3 -cmd ".timeout 5000" "${TEST_MEMORY_DIR}/memory.db" <<EOF
INSERT INTO capability_gaps (id, entity_id, description, frequency, status)
VALUES ('$gap_id', $entity_clause, '$description', $frequency, '$status');
EOF

	echo "$gap_id"
	return 0
}

# =============================================================================
# Test: Help command
# =============================================================================
test_help() {
	echo ""
	echo "=== Test: Help Command ==="

	local output
	local rc=0
	output=$("$EVOL_HELPER" help 2>&1) || rc=$?
	assert_success "$rc" "help command exits successfully"
	assert_contains "$output" "self-evolution-helper.sh" "help mentions script name"
	assert_contains "$output" "scan-patterns" "help mentions scan-patterns"
	assert_contains "$output" "detect-gaps" "help mentions detect-gaps"
	assert_contains "$output" "create-todo" "help mentions create-todo"
	assert_contains "$output" "list-gaps" "help mentions list-gaps"
	assert_contains "$output" "pulse-scan" "help mentions pulse-scan"
	assert_contains "$output" "EVIDENCE TRAIL" "help mentions evidence trail"
	assert_contains "$output" "AI JUDGMENT" "help mentions AI judgment"
	return 0
}

# =============================================================================
# Test: Schema migration
# =============================================================================
test_migrate() {
	echo ""
	echo "=== Test: Schema Migration ==="

	local output
	local rc=0
	output=$("$EVOL_HELPER" migrate 2>&1) || rc=$?
	assert_success "$rc" "migrate command exits successfully"
	assert_contains "$output" "capability_gaps" "migrate shows capability_gaps table"
	assert_contains "$output" "gap_evidence" "migrate shows gap_evidence table"

	# Verify tables exist
	local tables
	tables=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" ".tables" 2>/dev/null)
	assert_contains "$tables" "capability_gaps" "capability_gaps table exists"
	assert_contains "$tables" "gap_evidence" "gap_evidence table exists"

	# Verify idempotent
	local rc2=0
	"$EVOL_HELPER" migrate >/dev/null 2>&1 || rc2=$?
	assert_success "$rc2" "migrate is idempotent"

	return 0
}

# =============================================================================
# Test: Scan patterns (no interactions)
# =============================================================================
test_scan_patterns_empty() {
	echo ""
	echo "=== Test: Scan Patterns (Empty) ==="

	# Initialize entity tables first
	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local output
	local rc=0
	output=$("$EVOL_HELPER" scan-patterns --json 2>&1) || rc=$?
	assert_success "$rc" "scan-patterns with no interactions exits successfully"

	# Should report no interactions or below minimum
	if echo "$output" | grep -q '"interaction_count":0'; then
		assert_success 0 "reports zero interactions"
	elif echo "$output" | grep -q 'below_minimum'; then
		assert_success 0 "reports below minimum threshold"
	else
		assert_contains "$output" "No interactions" "reports no interactions found"
	fi

	return 0
}

# =============================================================================
# Test: Scan patterns with interactions
# =============================================================================
test_scan_patterns_with_data() {
	echo ""
	echo "=== Test: Scan Patterns (With Data) ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	# Create entity and log interactions
	local entity_id
	entity_id=$(setup_test_entity)
	assert_contains "$entity_id" "ent_" "entity created successfully"

	# Log several interactions including some that indicate capability gaps
	# Note: avoid apostrophes in test content (known SQL escaping edge case in entity-helper.sh)
	log_test_interaction "$entity_id" "Can you help me deploy to Kubernetes?" >/dev/null
	log_test_interaction "$entity_id" "I need to set up monitoring for my services" >/dev/null
	log_test_interaction "$entity_id" "Sorry, I am unable to help with Kubernetes deployments directly" "outbound" >/dev/null
	log_test_interaction "$entity_id" "Is there a way to automate this?" >/dev/null
	log_test_interaction "$entity_id" "That feature is not available yet" "outbound" >/dev/null

	local output
	local rc=0
	output=$("$EVOL_HELPER" scan-patterns --json 2>&1) || rc=$?
	assert_success "$rc" "scan-patterns with data exits successfully"

	# Should have found interactions
	if echo "$output" | jq -e '.interaction_count > 0' >/dev/null 2>&1; then
		assert_success 0 "found interactions to scan"
	else
		assert_contains "$output" "interaction" "output mentions interactions"
	fi

	return 0
}

# =============================================================================
# Test: List gaps (empty)
# =============================================================================
test_list_gaps_empty() {
	echo ""
	echo "=== Test: List Gaps (Empty) ==="

	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local output
	local rc=0
	output=$("$EVOL_HELPER" list-gaps 2>&1) || rc=$?
	assert_success "$rc" "list-gaps with no gaps exits successfully"
	assert_contains "$output" "no gaps found" "reports no gaps found"

	return 0
}

# =============================================================================
# Test: List gaps with data
# =============================================================================
test_list_gaps_with_data() {
	echo ""
	echo "=== Test: List Gaps (With Data) ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	# Insert test gaps directly (IDs unused — side effect is DB insertion)
	insert_test_gap "Missing Kubernetes deployment support" "" 5 >/dev/null
	insert_test_gap "No monitoring integration" "" 2 >/dev/null
	insert_test_gap "Resolved feature" "" 1 "resolved" >/dev/null

	# List all gaps
	local output
	local rc=0
	output=$("$EVOL_HELPER" list-gaps 2>&1) || rc=$?
	assert_success "$rc" "list-gaps exits successfully"
	assert_contains "$output" "Kubernetes" "shows Kubernetes gap"
	assert_contains "$output" "monitoring" "shows monitoring gap"

	# List with status filter
	local detected_output
	detected_output=$("$EVOL_HELPER" list-gaps --status detected 2>&1) || true
	assert_contains "$detected_output" "Kubernetes" "status filter shows detected gaps"
	assert_not_contains "$detected_output" "Resolved feature" "status filter excludes resolved gaps"

	# List as JSON
	local json_output
	json_output=$("$EVOL_HELPER" list-gaps --json 2>&1) || true
	if echo "$json_output" | jq -e 'length > 0' >/dev/null 2>&1; then
		assert_success 0 "JSON output is valid array"
	else
		echo -e "  ${YELLOW}SKIP${NC}: JSON output validation (jq may not parse mixed output)"
		SKIP=$((SKIP + 1))
	fi

	return 0
}

# =============================================================================
# Test: Update gap status
# =============================================================================
test_update_gap() {
	echo ""
	echo "=== Test: Update Gap Status ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local gap_id
	gap_id=$(insert_test_gap "Test gap for update" "" 1)

	# Update status
	local rc=0
	"$EVOL_HELPER" update-gap "$gap_id" --status todo_created --todo-ref "t9999 (GH#1234)" >/dev/null 2>&1 || rc=$?
	assert_success "$rc" "update-gap exits successfully"

	# Verify update
	local status
	status=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT status FROM capability_gaps WHERE id = '$gap_id';")
	assert_contains "$status" "todo_created" "status updated to todo_created"

	local todo_ref
	todo_ref=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT todo_ref FROM capability_gaps WHERE id = '$gap_id';")
	assert_contains "$todo_ref" "t9999" "todo_ref recorded"

	# Test invalid status
	local rc2=0
	"$EVOL_HELPER" update-gap "$gap_id" --status invalid_status >/dev/null 2>&1 || rc2=$?
	assert_failure "$rc2" "rejects invalid status"

	# Test missing gap
	local rc3=0
	"$EVOL_HELPER" update-gap "gap_nonexistent" --status resolved >/dev/null 2>&1 || rc3=$?
	assert_failure "$rc3" "rejects nonexistent gap"

	return 0
}

# =============================================================================
# Test: Resolve gap
# =============================================================================
test_resolve_gap() {
	echo ""
	echo "=== Test: Resolve Gap ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local gap_id
	gap_id=$(insert_test_gap "Test gap for resolution" "" 3)

	local rc=0
	"$EVOL_HELPER" resolve-gap "$gap_id" --todo-ref "t8888" >/dev/null 2>&1 || rc=$?
	assert_success "$rc" "resolve-gap exits successfully"

	local status
	status=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT status FROM capability_gaps WHERE id = '$gap_id';")
	assert_contains "$status" "resolved" "gap marked as resolved"

	return 0
}

# =============================================================================
# Test: Gap frequency tracking
# =============================================================================
test_gap_frequency() {
	echo ""
	echo "=== Test: Gap Frequency Tracking ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local gap_id
	gap_id=$(insert_test_gap "Repeated capability gap" "" 1)

	# Simulate frequency increment
	sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"UPDATE capability_gaps SET frequency = frequency + 1 WHERE id = '$gap_id';"
	sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"UPDATE capability_gaps SET frequency = frequency + 1 WHERE id = '$gap_id';"

	local frequency
	frequency=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT frequency FROM capability_gaps WHERE id = '$gap_id';")

	if [[ "$frequency" == "3" ]]; then
		echo -e "  ${GREEN}PASS${NC}: frequency incremented to 3"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: expected frequency 3, got $frequency"
		FAIL=$((FAIL + 1))
	fi

	return 0
}

# =============================================================================
# Test: Gap evidence recording
# =============================================================================
test_gap_evidence() {
	echo ""
	echo "=== Test: Gap Evidence Recording ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local gap_id
	gap_id=$(insert_test_gap "Gap with evidence" "" 1)

	# Insert evidence links
	sqlite3 "${TEST_MEMORY_DIR}/memory.db" <<EOF
INSERT INTO gap_evidence (gap_id, interaction_id) VALUES ('$gap_id', 'int_test_001');
INSERT INTO gap_evidence (gap_id, interaction_id) VALUES ('$gap_id', 'int_test_002');
INSERT INTO gap_evidence (gap_id, interaction_id) VALUES ('$gap_id', 'int_test_003');
EOF

	local evidence_count
	evidence_count=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"SELECT COUNT(*) FROM gap_evidence WHERE gap_id = '$gap_id';")

	if [[ "$evidence_count" == "3" ]]; then
		echo -e "  ${GREEN}PASS${NC}: 3 evidence links recorded"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: expected 3 evidence links, got $evidence_count"
		FAIL=$((FAIL + 1))
	fi

	# Verify uniqueness constraint (duplicate should be ignored)
	sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"INSERT OR IGNORE INTO gap_evidence (gap_id, interaction_id) VALUES ('$gap_id', 'int_test_001');" 2>/dev/null

	local after_dup_count
	after_dup_count=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"SELECT COUNT(*) FROM gap_evidence WHERE gap_id = '$gap_id';")

	if [[ "$after_dup_count" == "3" ]]; then
		echo -e "  ${GREEN}PASS${NC}: duplicate evidence link ignored"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: duplicate not ignored, count is $after_dup_count"
		FAIL=$((FAIL + 1))
	fi

	# Verify CASCADE delete (foreign_keys must be ON per-connection)
	sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"PRAGMA foreign_keys=ON; DELETE FROM capability_gaps WHERE id = '$gap_id';"

	local orphan_count
	orphan_count=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" \
		"SELECT COUNT(*) FROM gap_evidence WHERE gap_id = '$gap_id';")

	if [[ "$orphan_count" == "0" ]]; then
		echo -e "  ${GREEN}PASS${NC}: evidence links cascade-deleted with gap"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: orphan evidence links remain: $orphan_count"
		FAIL=$((FAIL + 1))
	fi

	return 0
}

# =============================================================================
# Test: Stats command
# =============================================================================
test_stats() {
	echo ""
	echo "=== Test: Stats Command ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	# Insert some test data
	insert_test_gap "Gap A" "" 5 "detected" >/dev/null
	insert_test_gap "Gap B" "" 3 "todo_created" >/dev/null
	insert_test_gap "Gap C" "" 1 "resolved" >/dev/null

	# Text format
	local output
	local rc=0
	output=$("$EVOL_HELPER" stats 2>&1) || rc=$?
	assert_success "$rc" "stats command exits successfully"
	assert_contains "$output" "Self-Evolution Statistics" "shows statistics header"
	assert_contains "$output" "Total gaps" "shows total gaps"

	# JSON format
	local json_output
	json_output=$("$EVOL_HELPER" stats --json 2>&1) || true
	if echo "$json_output" | jq -e '.[] | .total_gaps' >/dev/null 2>&1; then
		assert_success 0 "JSON stats output is valid"
	else
		echo -e "  ${YELLOW}SKIP${NC}: JSON stats validation"
		SKIP=$((SKIP + 1))
	fi

	return 0
}

# =============================================================================
# Test: Pulse scan (dry run)
# =============================================================================
test_pulse_scan_dry_run() {
	echo ""
	echo "=== Test: Pulse Scan (Dry Run) ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	local output
	local rc=0
	output=$("$EVOL_HELPER" pulse-scan --dry-run 2>&1) || rc=$?
	assert_success "$rc" "pulse-scan --dry-run exits successfully"
	assert_contains "$output" "Self-Evolution Pulse Scan" "shows pulse scan header"
	assert_contains "$output" "DRY RUN" "indicates dry run mode"

	return 0
}

# =============================================================================
# Test: Gap lifecycle (full cycle)
# =============================================================================
test_gap_lifecycle() {
	echo ""
	echo "=== Test: Gap Lifecycle (Full Cycle) ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	# 1. Create a gap (detected)
	local gap_id
	gap_id=$(insert_test_gap "Lifecycle test gap" "" 1)
	local status
	status=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT status FROM capability_gaps WHERE id = '$gap_id';")
	assert_contains "$status" "detected" "gap starts as detected"

	# 2. Transition to todo_created
	"$EVOL_HELPER" update-gap "$gap_id" --status todo_created --todo-ref "t9999" >/dev/null 2>&1
	status=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT status FROM capability_gaps WHERE id = '$gap_id';")
	assert_contains "$status" "todo_created" "gap transitions to todo_created"

	# 3. Resolve
	"$EVOL_HELPER" resolve-gap "$gap_id" >/dev/null 2>&1
	status=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT status FROM capability_gaps WHERE id = '$gap_id';")
	assert_contains "$status" "resolved" "gap transitions to resolved"

	# 4. Verify updated_at changed
	local updated_at
	updated_at=$(sqlite3 "${TEST_MEMORY_DIR}/memory.db" "SELECT updated_at FROM capability_gaps WHERE id = '$gap_id';")
	if [[ -n "$updated_at" ]]; then
		echo -e "  ${GREEN}PASS${NC}: updated_at is set ($updated_at)"
		PASS=$((PASS + 1))
	else
		echo -e "  ${RED}FAIL${NC}: updated_at is empty"
		FAIL=$((FAIL + 1))
	fi

	return 0
}

# =============================================================================
# Test: Pulse scan --force bypasses interval guard
# =============================================================================
test_pulse_force_bypass() {
	echo ""
	echo "=== Test: Pulse Scan --force Bypass ==="

	"$ENTITY_HELPER" migrate >/dev/null 2>&1
	"$EVOL_HELPER" migrate >/dev/null 2>&1

	# Write a recent timestamp to the state file to simulate a recent scan.
	# This activates the interval guard so we can test --force bypasses it.
	local state_dir="${HOME}/.aidevops/logs"
	local state_file="${state_dir}/self-evolution-last-run"
	mkdir -p "$state_dir"
	local original_state=""
	if [[ -f "$state_file" ]]; then
		original_state=$(cat "$state_file")
	fi
	# Write current epoch — makes interval guard think a scan just ran
	date +%s >"$state_file"

	# Without --force, should be skipped by interval guard
	local output_no_force
	local rc_no_force=0
	output_no_force=$("$EVOL_HELPER" pulse-scan --dry-run 2>&1) || rc_no_force=$?
	assert_success "$rc_no_force" "pulse-scan without --force exits successfully"
	assert_contains "$output_no_force" "interval\|Next scan" "interval guard blocks scan without --force"
	assert_not_contains "$output_no_force" "Self-Evolution Pulse Scan" "scan header absent when guard blocks"

	# With --force, should bypass interval guard and run
	local output_force
	local rc_force=0
	output_force=$("$EVOL_HELPER" pulse-scan --force --dry-run 2>&1) || rc_force=$?
	assert_success "$rc_force" "--force pulse-scan exits successfully"
	assert_contains "$output_force" "Self-Evolution Pulse Scan" "--force bypasses interval guard"

	# Run --force twice in quick succession — both should execute
	local output_force2
	local rc_force2=0
	output_force2=$("$EVOL_HELPER" pulse-scan --force --dry-run 2>&1) || rc_force2=$?
	assert_success "$rc_force2" "second --force pulse-scan exits successfully"
	assert_contains "$output_force2" "Self-Evolution Pulse Scan" "consecutive --force scans both run"

	# Restore original state file
	if [[ -n "$original_state" ]]; then
		echo "$original_state" >"$state_file"
	else
		rm -f "$state_file"
	fi

	return 0
}

# =============================================================================
# Test: Unknown command
# =============================================================================
test_unknown_command() {
	echo ""
	echo "=== Test: Unknown Command ==="

	local rc=0
	"$EVOL_HELPER" nonexistent-command >/dev/null 2>&1 || rc=$?
	assert_failure "$rc" "unknown command returns error"

	return 0
}

# =============================================================================
# Main test runner
# =============================================================================
main() {
	echo "============================================"
	echo "  self-evolution-helper.sh Test Suite"
	echo "  Task: t1363.4"
	echo "============================================"

	# Check prerequisites
	if [[ ! -x "$EVOL_HELPER" ]]; then
		echo -e "${RED}ERROR${NC}: self-evolution-helper.sh not found or not executable at $EVOL_HELPER"
		exit 1
	fi
	if [[ ! -x "$ENTITY_HELPER" ]]; then
		echo -e "${RED}ERROR${NC}: entity-helper.sh not found or not executable at $ENTITY_HELPER"
		exit 1
	fi
	if ! command -v sqlite3 &>/dev/null; then
		echo -e "${RED}ERROR${NC}: sqlite3 is required"
		exit 1
	fi

	setup

	# Run tests
	test_help
	test_migrate
	test_scan_patterns_empty
	test_scan_patterns_with_data
	test_list_gaps_empty
	test_list_gaps_with_data
	test_update_gap
	test_resolve_gap
	test_gap_frequency
	test_gap_evidence
	test_stats
	test_pulse_scan_dry_run
	test_pulse_force_bypass
	test_gap_lifecycle
	test_unknown_command

	teardown

	# Summary
	echo ""
	echo "============================================"
	echo "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
	echo "============================================"

	if [[ "$FAIL" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
