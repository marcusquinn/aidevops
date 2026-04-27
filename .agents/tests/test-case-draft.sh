#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for case-draft-helper.sh (t2857)
# Covers: happy path (mocked LLM), tier escalation, cross-case access audit,
# provenance footer, revise mode, dry-run, and no-auto-send enforcement.
#
# Usage: bash .agents/tests/test-case-draft.sh
# Requires: jq
#
# All tests use LLM_ROUTING_DRY_RUN=1 so no real LLM calls are made.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
DRAFT_HELPER="${SCRIPT_DIR}/../scripts/case-draft-helper.sh"
CASE_HELPER="${SCRIPT_DIR}/../scripts/case-helper.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	# Initialize a minimal git repo
	git -C "$TEST_TMPDIR" init -q 2>/dev/null || true
	git -C "$TEST_TMPDIR" config user.email "test@test.local" 2>/dev/null || true
	git -C "$TEST_TMPDIR" config user.name "Test User" 2>/dev/null || true

	# Provision cases plane
	bash "$CASE_HELPER" init "$TEST_TMPDIR" >/dev/null 2>&1

	# Provision knowledge plane (minimal)
	mkdir -p "${TEST_TMPDIR}/_knowledge/sources"

	# Create a test source with metadata
	local src_dir="${TEST_TMPDIR}/_knowledge/sources/src-invoice-001"
	mkdir -p "$src_dir"
	printf '{"version":1,"id":"src-invoice-001","kind":"document","source_uri":"local","sha256":"abc123def456","ingested_at":"2026-04-01T00:00:00Z","ingested_by":"test","sensitivity":"internal","trust":"reviewed","blob_path":null,"size_bytes":1234}\n' \
		>"${src_dir}/meta.json"
	printf 'Invoice #1234 from ACME Ltd dated 2026-03-15. Amount: 5000.00. Due: 2026-04-15. Status: OVERDUE.\nServices rendered: consulting on project Alpha.\n' \
		>"${src_dir}/content.txt"

	# Create a second source (privileged sensitivity)
	local src_dir2="${TEST_TMPDIR}/_knowledge/sources/src-contract-002"
	mkdir -p "$src_dir2"
	printf '{"version":1,"id":"src-contract-002","kind":"document","source_uri":"local","sha256":"789xyz000111","ingested_at":"2026-04-02T00:00:00Z","ingested_by":"test","sensitivity":"restricted","trust":"trusted","blob_path":null,"size_bytes":5678}\n' \
		>"${src_dir2}/meta.json"
	printf 'Service Agreement between Us and ACME Ltd. Clause 4.2: Payment due within 30 days of invoice. Clause 7: Dispute resolution via arbitration.\n' \
		>"${src_dir2}/content.txt"

	# Create a third source (public)
	local src_dir3="${TEST_TMPDIR}/_knowledge/sources/src-public-003"
	mkdir -p "$src_dir3"
	printf '{"version":1,"id":"src-public-003","kind":"reference","source_uri":"local","sha256":"000aaa111bbb","ingested_at":"2026-04-03T00:00:00Z","ingested_by":"test","sensitivity":"public","trust":"unverified","blob_path":null,"size_bytes":100}\n' \
		>"${src_dir3}/meta.json"
	printf 'Public reference material about standard payment terms.\n' \
		>"${src_dir3}/content.txt"

	# Open a test case
	bash "$CASE_HELPER" open acme-dispute --kind dispute --party "ACME Ltd" \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1

	# Find the case directory (use glob, not ls|grep per SC2010)
	local _d
	TEST_CASE_ID=""
	for _d in "${TEST_TMPDIR}/_cases"/case-*; do
		[[ -d "$_d" ]] || continue
		TEST_CASE_ID="$(basename "$_d")"
		break
	done
	TEST_CASE_DIR="${TEST_TMPDIR}/_cases/${TEST_CASE_ID}"

	# Attach sources to the case
	bash "$CASE_HELPER" attach "$TEST_CASE_ID" src-invoice-001 --role evidence \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1
	bash "$CASE_HELPER" attach "$TEST_CASE_ID" src-contract-002 --role reference \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1

	# Open a second case for cross-case testing
	bash "$CASE_HELPER" open related-matter --kind compliance \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1
	TEST_CASE2_ID=""
	for _d in "${TEST_TMPDIR}/_cases"/case-*-related*; do
		[[ -d "$_d" ]] || continue
		TEST_CASE2_ID="$(basename "$_d")"
		break
	done
	bash "$CASE_HELPER" attach "$TEST_CASE2_ID" src-public-003 --role background \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1

	export LLM_ROUTING_DRY_RUN=1
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	unset LLM_ROUTING_DRY_RUN
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_assert_exit_0() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected exit 0, got non-zero"
		return 0
	fi
}

_assert_exit_nonzero() {
	local name="$1"
	shift
	if ! "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected non-zero exit, got 0"
		return 0
	fi
}

_assert_file_exists() {
	local name="$1" path="$2"
	if [[ -f "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "file not found: ${path}"
		return 0
	fi
}

_assert_file_contains() {
	local name="$1" path="$2" pattern="$3"
	if grep -q "$pattern" "$path" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "pattern not found: ${pattern}"
		return 0
	fi
}

_assert_output_contains() {
	local name="$1" output="$2" pattern="$3"
	if echo "$output" | grep -q "$pattern" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "pattern not found in output: ${pattern}"
		return 0
	fi
}

_assert_dir_empty() {
	local name="$1" dir_path="$2"
	if [[ -d "$dir_path" ]]; then
		local count
		count="$(find "$dir_path" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
		if [[ "$count" -eq 0 ]]; then
			_pass "$name"
		else
			_fail "$name" "directory not empty: ${count} files"
		fi
	else
		_pass "$name" # dir doesn't exist = effectively empty
	fi
	return 0
}

# =============================================================================
# Test cases
# =============================================================================

test_draft_happy_path() {
	echo "## Draft: happy path"

	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "request payment of overdue invoice" \
		--repo "$TEST_TMPDIR" 2>&1)" || true

	_assert_output_contains "draft succeeds" "$output" "Draft generated"

	# Check draft file was created
	local draft_files
	draft_files="$(find "${TEST_CASE_DIR}/drafts" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "$draft_files" -gt 0 ]]; then
		_pass "draft file created"
	else
		_fail "draft file created" "no .md files in drafts/"
	fi

	# Check draft content
	local draft_file
	draft_file="$(find "${TEST_CASE_DIR}/drafts" -name "*.md" -type f 2>/dev/null | head -1)"
	if [[ -n "$draft_file" ]]; then
		_assert_file_contains "frontmatter has case_id" "$draft_file" "case_id:"
		_assert_file_contains "frontmatter has intent" "$draft_file" "intent:"
		_assert_file_contains "frontmatter has tone" "$draft_file" "tone:"
		_assert_file_contains "frontmatter has sources" "$draft_file" "sources_consulted:"
		_assert_file_contains "frontmatter has generated_at" "$draft_file" "generated_at:"
		_assert_file_contains "provenance footer present" "$draft_file" "Drafted with reference to:"
		_assert_file_contains "provenance has source kind" "$draft_file" "kind:"
		_assert_file_contains "provenance has sensitivity" "$draft_file" "sensitivity:"
		_assert_file_contains "provenance has sha" "$draft_file" "sha:"
	fi
	return 0
}

test_draft_tier_escalation() {
	echo "## Draft: tier escalation with privileged source"

	# src-contract-002 has sensitivity=restricted which maps to privileged tier
	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "review contract terms" \
		--repo "$TEST_TMPDIR" --json 2>/dev/null)" || true

	# Check tier is escalated to privileged
	local tier
	tier="$(echo "$output" | jq -r '.tier // empty' 2>/dev/null)" || tier=""
	if [[ "$tier" == "privileged" ]]; then
		_pass "tier escalated to privileged"
	else
		_fail "tier escalated to privileged" "got tier: ${tier}"
	fi
	return 0
}

test_draft_cross_case_access() {
	echo "## Draft: cross-case access"

	# Draft with --include-case should succeed
	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "comprehensive review" \
		--include-case "$TEST_CASE2_ID" \
		--repo "$TEST_TMPDIR" --json 2>/dev/null)" || true

	# Check cross-case audit log was created
	local access_log="${TEST_CASE_DIR}/comms/cross-case-access.jsonl"
	_assert_file_exists "cross-case access log created" "$access_log"
	if [[ -f "$access_log" ]]; then
		_assert_file_contains "access log has included case" "$access_log" "$TEST_CASE2_ID"
	fi

	# Check cross_case_includes in output
	local cross
	cross="$(echo "$output" | jq -r '.cross_case_includes // empty' 2>/dev/null)" || cross=""
	if [[ "$cross" == *"$TEST_CASE2_ID"* ]]; then
		_pass "cross_case_includes in output"
	else
		_fail "cross_case_includes in output" "got: ${cross}"
	fi
	return 0
}

test_draft_no_cross_case_without_flag() {
	echo "## Draft: no cross-case without --include-case flag"

	# Draft without --include-case should only use own sources
	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "check own sources only" \
		--repo "$TEST_TMPDIR" --json 2>&1)" || true

	local sources
	sources="$(echo "$output" | jq -r '.sources_consulted // ""' 2>/dev/null)" || sources=""

	# Should NOT contain src-public-003 (belongs to case 2 only)
	if echo "$sources" | grep -q "src-public-003" 2>/dev/null; then
		_fail "own sources only (no cross-case)" "found src-public-003 without --include-case"
	else
		_pass "own sources only (no cross-case)"
	fi
	return 0
}

test_draft_tone_formal() {
	echo "## Draft: --tone formal"

	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "formal notice" --tone formal \
		--repo "$TEST_TMPDIR" --json 2>/dev/null)" || true

	local tone
	tone="$(echo "$output" | jq -r '.tone // empty' 2>/dev/null)" || tone=""
	if [[ "$tone" == "formal" ]]; then
		_pass "tone=formal in output"
	else
		_fail "tone=formal in output" "got: ${tone}"
	fi
	return 0
}

test_draft_tone_conciliatory() {
	echo "## Draft: --tone conciliatory"

	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "settlement discussion" --tone conciliatory \
		--repo "$TEST_TMPDIR" --json 2>/dev/null)" || true

	local tone
	tone="$(echo "$output" | jq -r '.tone // empty' 2>/dev/null)" || tone=""
	if [[ "$tone" == "conciliatory" ]]; then
		_pass "tone=conciliatory in output"
	else
		_fail "tone=conciliatory in output" "got: ${tone}"
	fi
	return 0
}

test_draft_dry_run() {
	echo "## Draft: --dry-run"

	# Count drafts before
	local before_count
	before_count="$(find "${TEST_CASE_DIR}/drafts" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')" || before_count=0

	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "dry run test" --dry-run \
		--repo "$TEST_TMPDIR" 2>&1)" || true

	# Count drafts after — should be same (dry-run doesn't write)
	local after_count
	after_count="$(find "${TEST_CASE_DIR}/drafts" -name "*dry-run*" -type f 2>/dev/null | wc -l | tr -d ' ')" || after_count=0

	if [[ "$after_count" -eq 0 ]]; then
		_pass "dry-run does not write file"
	else
		_fail "dry-run does not write file" "found ${after_count} dry-run files"
	fi

	# Output should still contain draft content
	_assert_output_contains "dry-run prints to stdout" "$output" "case_id:"
	return 0
}

test_draft_provenance_always_present() {
	echo "## Draft: provenance footer always present"

	local output
	output="$(bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "provenance test" \
		--repo "$TEST_TMPDIR" 2>&1)" || true

	local draft_file
	draft_file="$(find "${TEST_CASE_DIR}/drafts" -name "*provenance*" -type f 2>/dev/null | head -1)"
	if [[ -n "$draft_file" ]]; then
		_assert_file_contains "provenance: Drafted with reference to" "$draft_file" "Drafted with reference to"
		_assert_file_contains "provenance: Generated by" "$draft_file" "Generated by"
		_assert_file_contains "provenance: src-invoice-001" "$draft_file" "src-invoice-001"
	else
		_fail "provenance test draft file exists" "no draft file found"
	fi
	return 0
}

test_revise_mode() {
	echo "## Revise: happy path"

	# First create a draft
	bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "original for revision" \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1

	local original_draft
	original_draft="$(find "${TEST_CASE_DIR}/drafts" -name "*original-for-revision*" -type f 2>/dev/null | head -1)"

	if [[ -z "$original_draft" ]]; then
		_fail "revise: original draft exists" "no draft to revise"
		return 0
	fi

	_pass "revise: original draft exists"

	# Revise it
	local output
	output="$(bash "$DRAFT_HELPER" revise \
		--revise "$original_draft" \
		--feedback "soften the language in paragraph 2" \
		--repo "$TEST_TMPDIR" 2>&1)" || true

	_assert_output_contains "revise succeeds" "$output" "Revision generated"

	# Check revision file exists
	local rev_files
	rev_files="$(find "${TEST_CASE_DIR}/drafts" -name "*rev*" -type f 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "$rev_files" -gt 0 ]]; then
		_pass "revision file created"
	else
		_fail "revision file created" "no rev files found"
	fi
	return 0
}

test_no_auto_send_flag() {
	echo "## Enforcement: no auto-send flag exists"

	# Check that the helper has no --send or --auto-send CLI option
	# (prose mentioning "never auto-send" is fine — we check for flags only)
	local help_output
	help_output="$(bash "$DRAFT_HELPER" help 2>&1)" || true

	if echo "$help_output" | grep -qE '^\s+--send\b|^\s+--auto-send\b' 2>/dev/null; then
		_fail "no auto-send flag" "found --send or --auto-send CLI option in help"
	else
		_pass "no auto-send flag"
	fi
	return 0
}

test_missing_intent() {
	echo "## Validation: missing --intent"

	_assert_exit_nonzero "draft fails without intent" \
		bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" --repo "$TEST_TMPDIR"
	return 0
}

test_missing_case_id() {
	echo "## Validation: missing case-id"

	_assert_exit_nonzero "draft fails without case-id" \
		bash "$DRAFT_HELPER" draft --intent "test" --repo "$TEST_TMPDIR"
	return 0
}

test_invalid_tone() {
	echo "## Validation: invalid tone"

	_assert_exit_nonzero "draft fails with invalid tone" \
		bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "test" --tone aggressive --repo "$TEST_TMPDIR"
	return 0
}

test_timeline_entry_after_draft() {
	echo "## Audit: timeline entry after draft"

	bash "$DRAFT_HELPER" draft "$TEST_CASE_ID" \
		--intent "timeline check" \
		--repo "$TEST_TMPDIR" >/dev/null 2>&1

	local timeline="${TEST_CASE_DIR}/timeline.jsonl"
	if grep -q "draft" "$timeline" 2>/dev/null; then
		_pass "timeline has draft event"
	else
		_fail "timeline has draft event" "no draft event in timeline"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

main() {
	echo "=== Case Draft Helper Tests (t2857) ==="
	echo ""

	_setup

	test_draft_happy_path
	echo ""
	test_draft_tier_escalation
	echo ""
	test_draft_cross_case_access
	echo ""
	test_draft_no_cross_case_without_flag
	echo ""
	test_draft_tone_formal
	echo ""
	test_draft_tone_conciliatory
	echo ""
	test_draft_dry_run
	echo ""
	test_draft_provenance_always_present
	echo ""
	test_revise_mode
	echo ""
	test_no_auto_send_flag
	echo ""
	test_missing_intent
	echo ""
	test_missing_case_id
	echo ""
	test_invalid_tone
	echo ""
	test_timeline_entry_after_draft
	echo ""

	_teardown

	echo "=== Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
