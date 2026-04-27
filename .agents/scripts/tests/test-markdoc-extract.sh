#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for markdoc-extract.sh (t2970).
#
# Covers:
#   1. Well-formed file → .txt + -tags.json written, exit 0, tags.json valid JSON.
#   2. File with unknown tag → validator stops it, exit 1, no output files written.
#   3. --tree flag → -tree.json written, valid JSON.
#   4. --output-dir option → artefacts written to specified directory.
#
# These tests exercise the extractor in isolation using real fixture files
# and a real (deployed) validator. No network calls, no gh operations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
EXTRACT_SH="${SCRIPT_DIR}/../markdoc-extract.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$(( TESTS_RUN + 1 ))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$(( TESTS_FAILED + 1 ))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export TEST_ROOT
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Write a well-formed fixture with known good tags from the schema set.
write_good_fixture() {
	local _dest="$1"
	cat >"$_dest" <<'FIXTURE'
# Example knowledge document

Some introductory text here.

{% sensitivity tier="internal" %}
This section contains internal information.

{% citation source-id="acme-report-2025" /%}

More content in the section.
{% /sensitivity %}

Final paragraph with a standalone tag.

{% draft-status status="draft" /%}
FIXTURE
	return 0
}

# Write a fixture with an unknown tag — validator will reject it.
write_bad_fixture() {
	local _dest="$1"
	cat >"$_dest" <<'FIXTURE'
# Bad document

{% nonexistent-tag foo="bar" %}
This tag is not in the schema.
{% /nonexistent-tag %}
FIXTURE
	return 0
}

# Write a minimal well-formed fixture with multiple block nesting levels.
write_nested_fixture() {
	local _dest="$1"
	cat >"$_dest" <<'FIXTURE'
# Nested document

{% sensitivity tier="confidential" %}
Top-level block.

{% redaction reason="pii" /%}

Trailing content.
{% /sensitivity %}
FIXTURE
	return 0
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# Case 1: Well-formed file → .txt and -tags.json written, exit 0
test_wellformed_produces_artefacts() {
	local _fixture="${TEST_ROOT}/good.md"
	write_good_fixture "$_fixture"

	local _result=0
	"$EXTRACT_SH" extract "$_fixture" || _result=$?

	if [[ "$_result" -ne 0 ]]; then
		print_result "Case 1: well-formed file — exits 0" 1 \
			"Expected exit 0, got ${_result}"
		return 0
	fi

	# Check .txt written
	local _txt="${TEST_ROOT}/good.txt"
	if [[ ! -f "$_txt" ]]; then
		print_result "Case 1: well-formed file — .txt written" 1 \
			"Expected ${_txt} to exist"
		return 0
	fi

	# Check -tags.json written
	local _tags="${TEST_ROOT}/good-tags.json"
	if [[ ! -f "$_tags" ]]; then
		print_result "Case 1: well-formed file — -tags.json written" 1 \
			"Expected ${_tags} to exist"
		return 0
	fi

	# Check tags.json is valid JSON
	if ! jq . "$_tags" >/dev/null 2>&1; then
		print_result "Case 1: well-formed file — tags.json is valid JSON" 1 \
			"jq parse failed on ${_tags}"
		return 0
	fi

	# Check .txt does not contain tag markers
	if grep -qF '{%' "$_txt" 2>/dev/null; then
		print_result "Case 1: well-formed file — .txt has no tag markers" 1 \
			"Found '{% ' in stripped text file"
		return 0
	fi

	# Check tags array is non-empty (our fixture has several tags)
	local _tag_count
	_tag_count=$(jq 'length' "$_tags" 2>/dev/null || echo "0")
	if [[ "${_tag_count:-0}" -lt 1 ]]; then
		print_result "Case 1: well-formed file — tags.json non-empty" 1 \
			"Expected at least 1 tag in ${_tags}, got ${_tag_count}"
		return 0
	fi

	# Check each tag object has required fields
	local _missing_fields
	_missing_fields=$(jq -r '
		.[] | select(
			(.tag == null) or (.attrs == null) or (.scope == null) or
			(.char_start == null) or (.char_end == null) or
			(.line_start == null) or (.line_end == null)
		) | .tag // "unknown"
	' "$_tags" 2>/dev/null)
	if [[ -n "$_missing_fields" ]]; then
		print_result "Case 1: well-formed file — tag objects have all required fields" 1 \
			"Tags with missing fields: ${_missing_fields}"
		return 0
	fi

	print_result "Case 1: well-formed file — all artefacts correct" 0
	return 0
}

# Case 2: Unknown tag → validator stops, exit 1, no output files written
test_invalid_tag_rejected() {
	local _fixture="${TEST_ROOT}/bad.md"
	write_bad_fixture "$_fixture"

	local _result=0
	"$EXTRACT_SH" extract "$_fixture" 2>/dev/null || _result=$?

	if [[ "$_result" -ne 1 ]]; then
		print_result "Case 2: unknown tag — exits 1" 1 \
			"Expected exit 1, got ${_result}"
		return 0
	fi

	# Confirm no artefacts written
	if [[ -f "${TEST_ROOT}/bad.txt" ]]; then
		print_result "Case 2: unknown tag — no .txt written" 1 \
			"Expected ${TEST_ROOT}/bad.txt to not exist (validation should have stopped it)"
		return 0
	fi

	if [[ -f "${TEST_ROOT}/bad-tags.json" ]]; then
		print_result "Case 2: unknown tag — no -tags.json written" 1 \
			"Expected ${TEST_ROOT}/bad-tags.json to not exist"
		return 0
	fi

	print_result "Case 2: unknown tag — exits 1, no artefacts written" 0
	return 0
}

# Case 3: --tree flag → -tree.json written, valid JSON
test_tree_flag_writes_tree_json() {
	local _fixture="${TEST_ROOT}/nested.md"
	write_nested_fixture "$_fixture"

	local _result=0
	"$EXTRACT_SH" extract "$_fixture" --tree || _result=$?

	if [[ "$_result" -ne 0 ]]; then
		print_result "Case 3: --tree flag — exits 0" 1 \
			"Expected exit 0, got ${_result}"
		return 0
	fi

	local _tree="${TEST_ROOT}/nested-tree.json"
	if [[ ! -f "$_tree" ]]; then
		print_result "Case 3: --tree flag — -tree.json written" 1 \
			"Expected ${_tree} to exist"
		return 0
	fi

	if ! jq . "$_tree" >/dev/null 2>&1; then
		print_result "Case 3: --tree flag — -tree.json is valid JSON" 1 \
			"jq parse failed on ${_tree}"
		return 0
	fi

	# Tree should be an array
	local _is_array
	_is_array=$(jq 'type' "$_tree" 2>/dev/null || echo '"unknown"')
	if [[ "$_is_array" != '"array"' ]]; then
		print_result "Case 3: --tree flag — -tree.json is JSON array" 1 \
			"Expected array type, got ${_is_array}"
		return 0
	fi

	print_result "Case 3: --tree flag — -tree.json written and is valid JSON array" 0
	return 0
}

# Case 4: --output-dir option → artefacts written to specified directory
test_output_dir_option() {
	local _fixture="${TEST_ROOT}/good2.md"
	local _outdir="${TEST_ROOT}/out"
	mkdir -p "$_outdir"
	write_good_fixture "$_fixture"

	local _result=0
	"$EXTRACT_SH" extract "$_fixture" --output-dir "$_outdir" || _result=$?

	if [[ "$_result" -ne 0 ]]; then
		print_result "Case 4: --output-dir — exits 0" 1 \
			"Expected exit 0, got ${_result}"
		return 0
	fi

	if [[ ! -f "${_outdir}/good2.txt" ]]; then
		print_result "Case 4: --output-dir — .txt in output dir" 1 \
			"Expected ${_outdir}/good2.txt to exist"
		return 0
	fi

	if [[ ! -f "${_outdir}/good2-tags.json" ]]; then
		print_result "Case 4: --output-dir — -tags.json in output dir" 1 \
			"Expected ${_outdir}/good2-tags.json to exist"
		return 0
	fi

	# Confirm artefacts NOT in source file's directory
	if [[ -f "${TEST_ROOT}/good2.txt" ]]; then
		print_result "Case 4: --output-dir — .txt NOT in source dir" 1 \
			"Found ${TEST_ROOT}/good2.txt — should be in output-dir only"
		return 0
	fi

	print_result "Case 4: --output-dir — artefacts in specified directory" 0
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if [[ ! -x "$EXTRACT_SH" ]]; then
		printf 'FATAL: extractor not found or not executable: %s\n' "$EXTRACT_SH" >&2
		exit 2
	fi

	test_wellformed_produces_artefacts
	test_invalid_tag_rejected
	test_tree_flag_writes_tree_json
	test_output_dir_option

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
