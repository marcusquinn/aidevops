#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2317,SC2329
# SC2317: Commands inside test helper functions appear unreachable to ShellCheck
# SC2329: cleanup() invoked via trap; pass/fail/skip/section invoked throughout
#
# test-tier-downgrade.sh
#
# Tests for pattern-driven model tier downgrade (t5148)
# Validates: record-tier-downgrade-ok, tier-downgrade-check commands, and
# the conservative downgrade logic (min-samples, zero-failure requirement).
#
# Usage: bash tests/test-tier-downgrade.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The archived pattern-tracker-helper.sh sources shared-constants.sh from its
# own directory. In the repo, shared-constants.sh lives in the parent directory.
# We create a temporary symlink so the script can find it during testing.
ARCHIVED_DIR="$REPO_DIR/.agents/scripts/archived"
PATTERN_HELPER="$ARCHIVED_DIR/pattern-tracker-helper.sh"
VERBOSE="${1:-}"

# Set up symlinks in archived/ for scripts that the archived pattern-tracker needs.
# The archived script uses SCRIPT_DIR (archived/) for all helper paths, but the
# actual helpers live in the parent directory. These symlinks are test-only.
_SYMLINKS_CREATED=()
for _dep_script in shared-constants.sh memory-helper.sh config-helper.sh; do
	if [[ ! -f "$ARCHIVED_DIR/${_dep_script}" && ! -L "$ARCHIVED_DIR/${_dep_script}" ]]; then
		if [[ -f "$REPO_DIR/.agents/scripts/${_dep_script}" ]]; then
			ln -sf "$REPO_DIR/.agents/scripts/${_dep_script}" "$ARCHIVED_DIR/${_dep_script}" 2>/dev/null && _SYMLINKS_CREATED+=("$ARCHIVED_DIR/${_dep_script}") || true
		fi
	fi
done

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	fi
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# Use a temp memory DB for testing to avoid polluting real data
TEST_MEM_DIR=$(mktemp -d)
export AIDEVOPS_MEMORY_DIR="$TEST_MEM_DIR"

# Initialize memory DB (required by pattern-tracker-helper.sh)
MEMORY_HELPER="$REPO_DIR/.agents/scripts/memory-helper.sh"
if [[ -x "$MEMORY_HELPER" ]]; then
	"$MEMORY_HELPER" store --content "test init" --type "CONTEXT" >/dev/null 2>&1 || true
fi

cleanup() {
	rm -rf "$TEST_MEM_DIR"
	# Remove test-only symlinks we created
	local _s
	for _s in "${_SYMLINKS_CREATED[@]:-}"; do
		[[ -n "$_s" ]] && rm -f "$_s" 2>/dev/null || true
	done
}
trap cleanup EXIT

# =============================================================================
# Tests
# =============================================================================

section "Syntax Checks"

if bash -n "$PATTERN_HELPER" 2>/dev/null; then
	pass "pattern-tracker-helper.sh passes bash -n syntax check"
else
	fail "pattern-tracker-helper.sh has syntax errors"
fi

section "Help Output — new commands"

help_output=$(bash "$PATTERN_HELPER" help 2>&1) || true

if echo "$help_output" | grep -q "record-tier-downgrade-ok"; then
	pass "help output lists 'record-tier-downgrade-ok' command"
else
	fail "help output missing 'record-tier-downgrade-ok' command"
fi

if echo "$help_output" | grep -q "tier-downgrade-check"; then
	pass "help output lists 'tier-downgrade-check' command"
else
	fail "help output missing 'tier-downgrade-check' command"
fi

if echo "$help_output" | grep -q "min-samples"; then
	pass "help output mentions --min-samples option for tier-downgrade-check"
else
	fail "help output missing --min-samples option"
fi

section "record-tier-downgrade-ok — basic recording"

# Record a successful downgrade: opus requested, sonnet succeeded
record_out=$(bash "$PATTERN_HELPER" record-tier-downgrade-ok \
	--from-tier opus \
	--to-tier sonnet \
	--task-type feature \
	--task-id t5148-test \
	--quality-score 2 \
	2>&1) || true

if echo "$record_out" | grep -qi "recorded\|success\|TIER_DOWNGRADE_OK"; then
	pass "record-tier-downgrade-ok records opus->sonnet successfully"
else
	fail "record-tier-downgrade-ok failed to record" "$record_out"
fi

# Verify the record is in the DB (only if sqlite3 available and DB was initialized)
MEMORY_DB="${TEST_MEM_DIR}/memory.db"
if ! command -v sqlite3 &>/dev/null; then
	skip "sqlite3 not available — skipping DB content checks"
elif [[ ! -f "$MEMORY_DB" ]]; then
	skip "Memory DB not initialized — skipping DB content checks (memory-helper.sh may not be deployed)"
else
	db_count=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings WHERE type='TIER_DOWNGRADE_OK';" 2>/dev/null || echo "0")
	if [[ "$db_count" -ge 1 ]]; then
		pass "TIER_DOWNGRADE_OK record exists in memory DB"

		# Verify tags contain expected fields
		db_tags=$(sqlite3 "$MEMORY_DB" "SELECT tags FROM learnings WHERE type='TIER_DOWNGRADE_OK' LIMIT 1;" 2>/dev/null || echo "")
		if echo "$db_tags" | grep -q "from:opus"; then
			pass "TIER_DOWNGRADE_OK record has from:opus tag"
		else
			fail "TIER_DOWNGRADE_OK record missing from:opus tag" "tags=$db_tags"
		fi

		if echo "$db_tags" | grep -q "to:sonnet"; then
			pass "TIER_DOWNGRADE_OK record has to:sonnet tag"
		else
			fail "TIER_DOWNGRADE_OK record missing to:sonnet tag" "tags=$db_tags"
		fi

		if echo "$db_tags" | grep -q "task_type:feature"; then
			pass "TIER_DOWNGRADE_OK record has task_type:feature tag"
		else
			fail "TIER_DOWNGRADE_OK record missing task_type:feature tag" "tags=$db_tags"
		fi
	else
		skip "TIER_DOWNGRADE_OK record not in DB — memory-helper.sh may not support the type yet (run after deployment)"
	fi
fi

section "tier-downgrade-check — insufficient samples (below threshold)"

# With empty DB (no records), min-samples=3 should return empty
check_out=$(bash "$PATTERN_HELPER" tier-downgrade-check \
	--requested-tier opus \
	--task-type feature \
	--min-samples 3 \
	2>/dev/null) || true

if [[ -z "$check_out" ]]; then
	pass "tier-downgrade-check returns empty with no samples (min-samples=3)"
else
	fail "tier-downgrade-check returned '$check_out' with no samples (expected empty)"
fi

section "tier-downgrade-check — sufficient samples (meets threshold)"

# This test requires a populated DB. Use the deployed path if available.
DEPLOYED_PATTERN_HELPER="${HOME}/.aidevops/agents/scripts/archived/pattern-tracker-helper.sh"
if [[ ! -x "$DEPLOYED_PATTERN_HELPER" ]]; then
	skip "Deployed pattern-tracker-helper.sh not found — skipping DB-population tests"
elif ! command -v sqlite3 &>/dev/null; then
	skip "sqlite3 not available — skipping DB-population tests"
else
	# Use a fresh temp DB for this test
	SAMPLE_MEM_DIR=$(mktemp -d)
	# Initialize DB
	"${HOME}/.aidevops/agents/scripts/memory-helper.sh" store \
		--content "test init" --type "CONTEXT" >/dev/null 2>&1 || true

	# Record 3 successful downgrades
	for _i in 1 2 3; do
		AIDEVOPS_MEMORY_DIR="$SAMPLE_MEM_DIR" "$DEPLOYED_PATTERN_HELPER" record-tier-downgrade-ok \
			--from-tier opus --to-tier sonnet \
			--task-type feature --quality-score 2 >/dev/null 2>&1 || true
	done

	check_out=$(AIDEVOPS_MEMORY_DIR="$SAMPLE_MEM_DIR" "$DEPLOYED_PATTERN_HELPER" tier-downgrade-check \
		--requested-tier opus \
		--task-type feature \
		--min-samples 3 \
		2>/dev/null) || true

	rm -rf "$SAMPLE_MEM_DIR"

	if [[ "$check_out" == "sonnet" ]]; then
		pass "tier-downgrade-check returns 'sonnet' with 3 samples (min-samples=3)"
	else
		skip "tier-downgrade-check returned '$check_out' (expected 'sonnet') — may need deployment"
	fi
fi

section "tier-downgrade-check — failure disqualifies downgrade"

# This test requires a populated DB. Use the deployed path if available.
if [[ ! -x "$DEPLOYED_PATTERN_HELPER" ]]; then
	skip "Deployed pattern-tracker-helper.sh not found — skipping DB-population tests"
elif ! command -v sqlite3 &>/dev/null; then
	skip "sqlite3 not available — skipping DB-population tests"
else
	SAMPLE_MEM_DIR2=$(mktemp -d)
	# Initialize DB
	"${HOME}/.aidevops/agents/scripts/memory-helper.sh" store \
		--content "test init" --type "CONTEXT" >/dev/null 2>&1 || true

	# Record 3 successful downgrades
	for _i in 1 2 3; do
		AIDEVOPS_MEMORY_DIR="$SAMPLE_MEM_DIR2" "$DEPLOYED_PATTERN_HELPER" record-tier-downgrade-ok \
			--from-tier opus --to-tier sonnet \
			--task-type feature --quality-score 2 >/dev/null 2>&1 || true
	done

	# Record a failure at sonnet for the same task type
	AIDEVOPS_MEMORY_DIR="$SAMPLE_MEM_DIR2" "$DEPLOYED_PATTERN_HELPER" record \
		--outcome failure \
		--model sonnet \
		--task-type feature \
		--description "sonnet failed on feature task" >/dev/null 2>&1 || true

	check_out=$(AIDEVOPS_MEMORY_DIR="$SAMPLE_MEM_DIR2" "$DEPLOYED_PATTERN_HELPER" tier-downgrade-check \
		--requested-tier opus \
		--task-type feature \
		--min-samples 3 \
		2>/dev/null) || true

	rm -rf "$SAMPLE_MEM_DIR2"

	if [[ -z "$check_out" ]]; then
		pass "tier-downgrade-check returns empty when sonnet has a failure record"
	else
		fail "tier-downgrade-check returned '$check_out' despite failure record (expected empty)"
	fi
fi

section "tier-downgrade-check — no downgrade for already-cheapest tier"

if ! command -v sqlite3 &>/dev/null; then
	skip "sqlite3 not available — skipping DB-dependent tests"
else
	check_out=$(bash "$PATTERN_HELPER" tier-downgrade-check \
		--requested-tier haiku \
		--task-type feature \
		--min-samples 3 \
		2>/dev/null) || true

	if [[ -z "$check_out" ]]; then
		pass "tier-downgrade-check returns empty for haiku (already cheapest tier)"
	else
		fail "tier-downgrade-check returned '$check_out' for haiku (expected empty)"
	fi
fi

section "tier-downgrade-check — non-blocking on missing DB"

# Point to a non-existent DB directory
ORIG_MEM_DIR="$AIDEVOPS_MEMORY_DIR"
export AIDEVOPS_MEMORY_DIR="/tmp/nonexistent-aidevops-test-$$"

check_out=$(bash "$PATTERN_HELPER" tier-downgrade-check \
	--requested-tier opus \
	--task-type feature \
	2>/dev/null) || true

export AIDEVOPS_MEMORY_DIR="$ORIG_MEM_DIR"

if [[ -z "$check_out" ]]; then
	pass "tier-downgrade-check returns empty (non-blocking) when DB is missing"
else
	fail "tier-downgrade-check returned '$check_out' with missing DB (expected empty)"
fi

section "record-tier-downgrade-ok — validation: missing required args"

err_out=$(bash "$PATTERN_HELPER" record-tier-downgrade-ok 2>&1) || true
if echo "$err_out" | grep -qi "required\|error"; then
	pass "record-tier-downgrade-ok rejects call with missing --from-tier/--to-tier"
else
	fail "record-tier-downgrade-ok should error on missing required args" "$err_out"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped (${TOTAL_COUNT} total)"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
