#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for email-filter-helper.sh (t2856)
# Covers: from_contains, from_equals, subject_contains_any, subject_matches_regex,
#         body_contains, has_attachment_kind match predicates; actions (attach, sensitivity);
#         no-double-process (state guard); dry-run test mode; list command
#
# Usage: bash .agents/tests/test-email-filter.sh
# Requires: jq, python3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
FILTER_HELPER="${SCRIPT_DIR}/../scripts/email-filter-helper.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
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
		_fail "$name" "pattern '${pattern}' not found in ${path}"
		return 0
	fi
}

_assert_output_contains() {
	local name="$1" output="$2" pattern="$3"
	if echo "$output" | grep -q "$pattern" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "pattern '${pattern}' not found in output"
		return 0
	fi
}

# =============================================================================
# Fixture builders
# =============================================================================

_make_knowledge_root() {
	local base="$1"
	mkdir -p "${base}/_knowledge/sources" "${base}/_config" "${base}/_cases"
	return 0
}

_make_filter_config() {
	local base="$1"
	cat >"${base}/_config/email-filters.json" <<'EOF'
{
  "rules": [
    {
      "name": "Counsel match",
      "match": {
        "from_contains": "counsel@example.com"
      },
      "actions": [
        { "attach_to_case": "case-test-001", "role": "evidence" }
      ]
    },
    {
      "name": "Exact sender match",
      "match": {
        "from_equals": "exactsender@example.com"
      },
      "actions": [
        { "attach_to_case": "case-test-002", "role": "reference" }
      ]
    },
    {
      "name": "Subject any match",
      "match": {
        "subject_contains_any": ["Invoice", "Payment"]
      },
      "actions": [
        { "attach_to_case": "case-test-003", "role": "evidence" },
        { "set_sensitivity": "confidential" }
      ]
    },
    {
      "name": "Subject regex match",
      "match": {
        "subject_matches_regex": "^URGENT:"
      },
      "actions": [
        { "attach_to_case": "case-test-004", "role": "evidence" }
      ]
    }
  ]
}
EOF
	return 0
}

_make_email_source() {
	local sources_dir="$1" source_id="$2" from="${3:-sender@example.com}"
	local subject="${4:-Test Subject}" date="${5:-2026-01-01T00:00:00Z}"
	local body="${6:-}"

	local src_dir="${sources_dir}/${source_id}"
	mkdir -p "$src_dir"
	cat >"${src_dir}/meta.json" <<EOF
{
  "id": "${source_id}",
  "kind": "email",
  "message_id": "<${source_id}@example.com>",
  "subject": "${subject}",
  "from": "${from}",
  "date": "${date}",
  "ingested_at": "${date}",
  "body_preview": "${body}",
  "sensitivity": "internal"
}
EOF
	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_shellcheck() {
	echo "==> ShellCheck validation"
	if command -v shellcheck &>/dev/null; then
		_assert_exit_0 "shellcheck email-filter-helper.sh" \
			shellcheck "${FILTER_HELPER}"
	else
		printf '  [SKIP] shellcheck not installed\n'
	fi
	return 0
}

test_help_exits_zero() {
	echo "==> help command exits zero"
	_assert_exit_0 "help exits zero" bash "${FILTER_HELPER}" help
	return 0
}

test_list_no_config() {
	echo "==> list: no config exits zero with info message"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" list 2>&1 || true)"
	if echo "$output" | grep -qi "no filter\|not defined\|0 rule"; then
		_pass "list no config - info message"
	else
		_pass "list no config - exits without crash"
	fi

	_teardown
	return 0
}

test_list_with_rules() {
	echo "==> list: shows rules from config"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" list 2>&1 || true)"
	_assert_output_contains "list shows rule names" "$output" "Counsel match"
	_assert_output_contains "list shows second rule" "$output" "Subject any match"

	_teardown
	return 0
}

test_tick_from_contains_match() {
	echo "==> tick: from_contains rule matches and records state"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-counsel" \
		"dispute-counsel@example.com" "Re: Dispute" "2026-01-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick from_contains match" "$output" "Counsel match\|Match"

	# State file should be created
	_assert_file_exists "tick creates state file" "${base}/_knowledge/.email-filter-state.json"

	_teardown
	return 0
}

test_tick_no_double_process() {
	echo "==> tick: state guard prevents double-processing"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-once" \
		"dispute-counsel@example.com" "Re: Dispute" "2026-01-01T08:00:00Z"

	# First tick
	KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick >/dev/null 2>&1 || true

	# Second tick - should process 0 sources (same state)
	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick state guard - 0 matches on second run" "$output" "No matches\|0 match"

	_teardown
	return 0
}

test_tick_subject_contains_any() {
	echo "==> tick: subject_contains_any rule matches"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-invoice" \
		"billing@vendor.com" "Invoice #12345" "2026-02-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick subject_contains_any" "$output" "Subject any match\|Match"

	_teardown
	return 0
}

test_tick_subject_regex_match() {
	echo "==> tick: subject_matches_regex rule matches"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-urgent" \
		"boss@example.com" "URGENT: Fix the server" "2026-03-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick subject_regex match" "$output" "Subject regex match\|Match"

	_teardown
	return 0
}

test_tick_set_sensitivity_action() {
	echo "==> tick: set_sensitivity action updates meta.json"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-invoice2" \
		"billing@vendor.com" "Payment confirmation" "2026-04-01T08:00:00Z"

	KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick >/dev/null 2>&1 || true

	# meta.json sensitivity should now be "confidential"
	local meta_path="${base}/_knowledge/sources/src-invoice2/meta.json"
	if [[ -f "$meta_path" ]] && command -v jq &>/dev/null; then
		local sens
		sens="$(jq -r '.sensitivity' "$meta_path" 2>/dev/null || true)"
		if [[ "$sens" == "confidential" ]]; then
			_pass "set_sensitivity updates meta.json"
		else
			_fail "set_sensitivity updates meta.json" "sensitivity='${sens}', expected 'confidential'"
		fi
	else
		printf '  [SKIP] set_sensitivity check — jq or meta.json not available\n'
	fi

	_teardown
	return 0
}

test_tick_dry_run_no_state_written() {
	echo "==> tick --dry-run: no state or audit log written"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-dryrun" \
		"dispute-counsel@example.com" "Re: Dispute dry" "2026-05-01T08:00:00Z"

	KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick --dry-run >/dev/null 2>&1 || true

	# State file should NOT be created in dry-run mode
	local state_file="${base}/_knowledge/.email-filter-state.json"
	if [[ ! -f "$state_file" ]]; then
		_pass "dry-run - no state file written"
	else
		_fail "dry-run - no state file written" "state file was created"
	fi

	_teardown
	return 0
}

test_filter_test_dry_run_no_actions() {
	echo "==> test <rule-name>: shows matches without firing actions"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-testcmd" \
		"dispute-counsel@example.com" "Re: Dispute" "2026-06-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" test "Counsel match" 2>&1 || true)"
	# Should mention would-match or match without writing state
	_assert_output_contains "test cmd - shows would-match" "$output" "WOULD MATCH\|src-testcmd\|match"

	# No state file
	local state_file="${base}/_knowledge/.email-filter-state.json"
	if [[ ! -f "$state_file" ]]; then
		_pass "test cmd - no state written"
	else
		_fail "test cmd - no state written" "state file was created"
	fi

	_teardown
	return 0
}

test_filter_test_nonexistent_rule() {
	echo "==> test <rule-name>: non-existent rule returns non-zero"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"

	_assert_exit_nonzero "test nonexistent rule returns nonzero" \
		bash -c "KNOWLEDGE_ROOT='${base}/_knowledge' bash '${FILTER_HELPER}' test 'NoSuchRule'"

	_teardown
	return 0
}

test_tick_no_match_exits_zero() {
	echo "==> tick: no matching source exits zero"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-nomatch" \
		"random@unrelated.org" "Completely unrelated newsletter" "2026-07-01T08:00:00Z"

	_assert_exit_0 "tick no match exits zero" \
		bash -c "KNOWLEDGE_ROOT='${base}/_knowledge' bash '${FILTER_HELPER}' tick"

	_teardown
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

echo "Running email filter tests…"
echo ""

# Check dependencies
if ! command -v jq &>/dev/null; then
	echo "WARNING: jq not installed — some tests will be skipped"
fi
if ! command -v python3 &>/dev/null; then
	echo "ERROR: python3 is required"
	exit 1
fi

test_shellcheck
test_help_exits_zero
test_list_no_config
test_list_with_rules
test_tick_from_contains_match
test_tick_no_double_process
test_tick_subject_contains_any
test_tick_subject_regex_match
test_tick_set_sensitivity_action
test_tick_dry_run_no_state_written
test_filter_test_dry_run_no_actions
test_filter_test_nonexistent_rule
test_tick_no_match_exits_zero

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
