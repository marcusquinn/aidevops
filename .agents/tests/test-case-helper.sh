#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for the t2851 case dossier contract:
#   - init / open / sequential IDs
#   - ID counter atomicity (lock-protected, no collisions)
#   - Year rollover (sequence resets to 0001)
#   - Schema validation (dossier.toon validates against case-dossier-schema.json)
#   - chasers_enabled field present in new dossiers
#   - Personal plane mode (_cases/ at alternate path)
#
# Usage: bash .agents/tests/test-case-helper.sh
# Requires: jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CASE_HELPER="${SCRIPT_DIR}/../scripts/case-helper.sh"
SCHEMA="${SCRIPT_DIR}/../templates/case-dossier-schema.json"

# =============================================================================
# Test framework (minimal — mirrors test-case-cli.sh style)
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	git -C "$TEST_TMPDIR" init -q
	git -C "$TEST_TMPDIR" config user.email "test@test.local"
	git -C "$TEST_TMPDIR" config user.name "Test User"
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

_assert_dir_exists() {
	local name="$1" path="$2"
	if [[ -d "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "dir not found: ${path}"
		return 0
	fi
}

_assert_json_field() {
	local name="$1" file="$2" query="$3" expected="$4"
	local actual
	actual="$(jq -r "$query" "$file" 2>/dev/null)" || actual=""
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected '${expected}', got '${actual}'"
		return 0
	fi
}

_assert_contains() {
	local name="$1" file="$2" pattern="$3"
	if grep -q "$pattern" "$file" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "pattern '${pattern}' not found in ${file}"
		return 0
	fi
}

# =============================================================================
# test_init — skeleton provisioning
# =============================================================================

test_init() {
	echo ""
	echo "=== init ==="
	local repo="$TEST_TMPDIR"

	_assert_exit_0 "init provisions _cases/" \
		bash "$CASE_HELPER" init "$repo"

	_assert_dir_exists "init creates _cases/" "${repo}/_cases"
	_assert_dir_exists "init creates archived/" "${repo}/_cases/archived"
	_assert_file_exists "init creates .gitignore" "${repo}/_cases/.gitignore"
	_assert_file_exists "init creates .case-counter" "${repo}/_cases/.case-counter"
	_assert_file_exists "init creates README.md" "${repo}/_cases/README.md"

	# Gitignore content check: drafts/ should be excluded
	_assert_contains "gitignore excludes drafts/" "${repo}/_cases/.gitignore" "drafts/"

	# Counter file initial content: YYYY:0
	local year
	year="$(date -u '+%Y')"
	_assert_contains "counter file has current year" \
		"${repo}/_cases/.case-counter" "${year}:"

	# Idempotent: running init a second time is safe
	_assert_exit_0 "init is idempotent" \
		bash "$CASE_HELPER" init "$repo"
	return 0
}

# =============================================================================
# test_open_contract — dossier.toon schema contract
# =============================================================================

test_open_contract() {
	echo ""
	echo "=== open contract (dossier.toon fields) ==="
	local repo="$TEST_TMPDIR"
	local year
	year="$(date -u '+%Y')"

	bash "$CASE_HELPER" init "$repo" >/dev/null 2>&1

	bash "$CASE_HELPER" open "acme-dispute" \
		--kind "dispute" \
		--party "ACME Ltd" \
		--party-role "client" \
		--deadline "2026-08-31" \
		--deadline-label "filing deadline" \
		--repo "$repo" >/dev/null 2>&1

	local case_dir="${repo}/_cases/case-${year}-0001-acme-dispute"

	# Directory structure
	_assert_dir_exists "open creates case directory" "$case_dir"
	_assert_file_exists "open creates dossier.toon" "${case_dir}/dossier.toon"
	_assert_file_exists "open creates timeline.jsonl" "${case_dir}/timeline.jsonl"
	_assert_file_exists "open creates sources.toon" "${case_dir}/sources.toon"
	_assert_dir_exists "open creates notes/" "${case_dir}/notes"
	_assert_dir_exists "open creates comms/" "${case_dir}/comms"
	_assert_dir_exists "open creates drafts/" "${case_dir}/drafts"

	# Dossier fields
	_assert_json_field "dossier.id correct" \
		"${case_dir}/dossier.toon" '.id' "case-${year}-0001-acme-dispute"
	_assert_json_field "dossier.slug correct" \
		"${case_dir}/dossier.toon" '.slug' "acme-dispute"
	_assert_json_field "dossier.kind correct" \
		"${case_dir}/dossier.toon" '.kind' "dispute"
	_assert_json_field "dossier.status is open" \
		"${case_dir}/dossier.toon" '.status' "open"
	_assert_json_field "dossier.parties[0].name" \
		"${case_dir}/dossier.toon" '.parties[0].name' "ACME Ltd"
	_assert_json_field "dossier.parties[0].role" \
		"${case_dir}/dossier.toon" '.parties[0].role' "client"
	_assert_json_field "dossier.deadlines[0].date" \
		"${case_dir}/dossier.toon" '.deadlines[0].date' "2026-08-31"
	_assert_json_field "dossier.deadlines[0].label" \
		"${case_dir}/dossier.toon" '.deadlines[0].label' "filing deadline"

	# chasers_enabled must be present and false by default (t2858 opt-in gate)
	local chasers_val
	chasers_val="$(jq -r '.chasers_enabled' "${case_dir}/dossier.toon" 2>/dev/null)" || chasers_val=""
	if [[ "$chasers_val" == "false" ]]; then
		_pass "chasers_enabled defaults to false"
	else
		_fail "chasers_enabled defaults to false" "got: ${chasers_val}"
	fi

	# sources.toon initialised as empty array
	_assert_json_field "sources.toon initialised as empty array" \
		"${case_dir}/sources.toon" 'length' "0"

	# timeline has initial open event
	_assert_contains "timeline has open event" \
		"${case_dir}/timeline.jsonl" '"kind":"open"'
	_assert_contains "timeline open event references case id" \
		"${case_dir}/timeline.jsonl" "case-${year}-0001-acme-dispute"
	return 0
}

# =============================================================================
# test_open_minimal — open without optional flags (kind defaults to "general")
# =============================================================================

test_open_minimal() {
	echo ""
	echo "=== open (minimal — no optional flags) ==="
	local repo="$TEST_TMPDIR"
	local year
	year="$(date -u '+%Y')"

	_assert_exit_0 "open with slug only succeeds" \
		bash "$CASE_HELPER" open "minimal-case" --repo "$repo"

	local case_dir="${repo}/_cases/case-${year}-0002-minimal-case"
	_assert_dir_exists "minimal case directory created" "$case_dir"
	_assert_json_field "kind defaults to general" \
		"${case_dir}/dossier.toon" '.kind' "general"
	_assert_json_field "related_cases is empty array" \
		"${case_dir}/dossier.toon" '.related_cases | length' "0"
	_assert_json_field "related_repos is empty array" \
		"${case_dir}/dossier.toon" '.related_repos | length' "0"
	return 0
}

# =============================================================================
# test_schema_validation — validate dossier.toon against JSON Schema
# Uses jq to check required fields and enum constraints (no ajv required)
# =============================================================================

test_schema_validation() {
	echo ""
	echo "=== schema validation ==="
	local repo="$TEST_TMPDIR"
	local year
	year="$(date -u '+%Y')"
	local case_dir="${repo}/_cases/case-${year}-0001-acme-dispute"
	local dossier="${case_dir}/dossier.toon"

	# Verify schema file exists
	if [[ ! -f "$SCHEMA" ]]; then
		_fail "schema file exists" "not found: ${SCHEMA}"
		return 0
	fi
	_pass "schema file exists"

	# Verify schema is valid JSON
	if jq '.' "$SCHEMA" >/dev/null 2>&1; then
		_pass "schema file is valid JSON"
	else
		_fail "schema file is valid JSON"
		return 0
	fi

	# Verify dossier is valid JSON
	if jq '.' "$dossier" >/dev/null 2>&1; then
		_pass "dossier.toon is valid JSON"
	else
		_fail "dossier.toon is valid JSON"
		return 0
	fi

	# Check required fields are present (schema: required: [id, slug, kind, opened_at, status, parties])
	local missing_fields=""
	for field in id slug kind opened_at status parties; do
		local val
		val="$(jq -r --arg f "$field" '.[$f] // empty' "$dossier" 2>/dev/null)" || val=""
		[[ -z "$val" ]] && missing_fields="${missing_fields} ${field}"
	done
	if [[ -z "$missing_fields" ]]; then
		_pass "dossier has all required fields"
	else
		_fail "dossier has all required fields" "missing:${missing_fields}"
	fi

	# Check status enum value
	local status_val
	status_val="$(jq -r '.status' "$dossier" 2>/dev/null)" || status_val=""
	case "$status_val" in
	open | hold | closed)
		_pass "dossier.status is valid enum value"
		;;
	*)
		_fail "dossier.status is valid enum value" "got: ${status_val}"
		;;
	esac

	# Verify id pattern: case-YYYY-NNNN-slug (4-digit year, 4-digit seq)
	local id_val
	id_val="$(jq -r '.id' "$dossier" 2>/dev/null)" || id_val=""
	if echo "$id_val" | grep -qE '^case-[0-9]{4}-[0-9]{4}-.+$'; then
		_pass "dossier.id matches pattern case-YYYY-NNNN-slug"
	else
		_fail "dossier.id matches pattern case-YYYY-NNNN-slug" "got: ${id_val}"
	fi

	# Verify parties is array with at least one item (minItems: 1 in schema)
	local parties_count
	parties_count="$(jq '.parties | length' "$dossier" 2>/dev/null)" || parties_count="0"
	if [[ "$parties_count" -ge 1 ]]; then
		_pass "dossier.parties has at least one entry"
	else
		_fail "dossier.parties has at least one entry" "count=${parties_count}"
	fi

	# Schema allows chasers_enabled (boolean or "false-with-force-allowed")
	local ce_type
	ce_type="$(jq -r '.chasers_enabled | type' "$dossier" 2>/dev/null)" || ce_type=""
	if [[ "$ce_type" == "boolean" || "$ce_type" == "string" ]]; then
		_pass "chasers_enabled is valid type (boolean or string)"
	else
		_fail "chasers_enabled is valid type (boolean or string)" "type=${ce_type}"
	fi
	return 0
}

# =============================================================================
# test_id_counter_atomicity — sequential IDs and lock-protected counter
# =============================================================================

test_id_counter_atomicity() {
	echo ""
	echo "=== ID counter atomicity ==="
	local repo="$TEST_TMPDIR"
	local year
	year="$(date -u '+%Y')"

	# Open several cases concurrently (background processes)
	local -a pids=()
	local i
	for i in 1 2 3 4 5; do
		bash "$CASE_HELPER" open "concurrent-case-${i}" \
			--kind "test" --repo "$repo" >/dev/null 2>&1 &
		pids+=($!)
	done

	# Wait for all background jobs
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	# Count actual case directories created
	local created_count
	created_count="$(find "${repo}/_cases" -maxdepth 1 -name 'case-*' -type d | wc -l)"
	created_count="${created_count//[[:space:]]/}"

	# We previously opened 2 cases (0001, 0002) + 5 concurrent = 7 total
	if [[ "$created_count" -eq 7 ]]; then
		_pass "all 7 concurrent open calls created unique directories"
	else
		_fail "all 7 concurrent open calls created unique directories" \
			"found ${created_count} directories"
	fi

	# Read counter — should be 7
	local counter_seq
	counter_seq="$(cut -d: -f2 "${repo}/_cases/.case-counter" 2>/dev/null)" || counter_seq="0"
	if [[ "$counter_seq" -eq 7 ]]; then
		_pass "counter reflects 7 sequential claims"
	else
		_fail "counter reflects 7 sequential claims" "counter_seq=${counter_seq}"
	fi

	# Check no duplicate IDs exist (each directory name is unique)
	local all_ids dir_count unique_count
	all_ids="$(find "${repo}/_cases" -maxdepth 1 -name 'case-*' -type d -exec basename {} \;)"
	dir_count="$(echo "$all_ids" | wc -l)"
	unique_count="$(echo "$all_ids" | sort -u | wc -l)"
	dir_count="${dir_count//[[:space:]]/}"
	unique_count="${unique_count//[[:space:]]/}"
	if [[ "$dir_count" -eq "$unique_count" ]]; then
		_pass "no duplicate case IDs (lock-protected counter)"
	else
		_fail "no duplicate case IDs (lock-protected counter)" \
			"dir_count=${dir_count}, unique=${unique_count}"
	fi
	return 0
}

# =============================================================================
# test_year_rollover — opening in a new year resets sequence to 0001
# =============================================================================

test_year_rollover() {
	echo ""
	echo "=== year rollover ==="
	local rollover_dir
	rollover_dir="$(mktemp -d)"
	git -C "$rollover_dir" init -q
	git -C "$rollover_dir" config user.email "test@test.local"
	git -C "$rollover_dir" config user.name "Test"

	bash "$CASE_HELPER" init "$rollover_dir" >/dev/null 2>&1

	# Manually set counter to simulate previous year
	printf '2025:0042\n' >"${rollover_dir}/_cases/.case-counter"

	# Open a case — current year differs from stored year, should reset to 0001
	bash "$CASE_HELPER" open "new-year-case" \
		--kind "test" --repo "$rollover_dir" >/dev/null 2>&1

	local year
	year="$(date -u '+%Y')"
	local expected_dir="${rollover_dir}/_cases/case-${year}-0001-new-year-case"

	if [[ -d "$expected_dir" ]]; then
		_pass "year rollover resets sequence to 0001"
	else
		_fail "year rollover resets sequence to 0001" \
			"expected dir: ${expected_dir}"
	fi

	# Counter should now be YYYY:1
	local counter_year counter_seq
	counter_year="$(cut -d: -f1 "${rollover_dir}/_cases/.case-counter" 2>/dev/null)" || counter_year=""
	counter_seq="$(cut -d: -f2 "${rollover_dir}/_cases/.case-counter" 2>/dev/null)" || counter_seq=""
	if [[ "$counter_year" == "$year" && "$counter_seq" == "1" ]]; then
		_pass "counter updated to current year after rollover"
	else
		_fail "counter updated to current year after rollover" \
			"got ${counter_year}:${counter_seq}"
	fi

	rm -rf "$rollover_dir"
	return 0
}

# =============================================================================
# test_personal_plane_mode — _cases/ at alternate path
# =============================================================================

test_personal_plane_mode() {
	echo ""
	echo "=== personal plane mode ==="
	local personal_dir
	personal_dir="$(mktemp -d)"
	git -C "$personal_dir" init -q
	git -C "$personal_dir" config user.email "test@test.local"
	git -C "$personal_dir" config user.name "Test"

	# init and open using explicit alternate repo path
	_assert_exit_0 "personal plane init succeeds" \
		bash "$CASE_HELPER" init "$personal_dir"

	_assert_dir_exists "personal _cases/ created" "${personal_dir}/_cases"

	_assert_exit_0 "personal plane open succeeds" \
		bash "$CASE_HELPER" open "personal-test" --kind "personal" --repo "$personal_dir"

	local year
	year="$(date -u '+%Y')"
	_assert_dir_exists "personal case directory created" \
		"${personal_dir}/_cases/case-${year}-0001-personal-test"

	rm -rf "$personal_dir"
	return 0
}

# =============================================================================
# test_open_without_init — error path
# =============================================================================

test_open_without_init() {
	echo ""
	echo "=== error: open without init ==="
	local fresh
	fresh="$(mktemp -d)"

	_assert_exit_nonzero "open without init fails with helpful error" \
		bash "$CASE_HELPER" open some-slug --repo "$fresh"

	rm -rf "$fresh"
	return 0
}

# =============================================================================
# Runner
# =============================================================================

main() {
	echo "Running test-case-helper.sh (t2851 contract tests)..."

	if ! command -v jq >/dev/null 2>&1; then
		echo "SKIP: jq not found. Install: brew install jq"
		exit 0
	fi

	_setup

	test_init
	test_open_contract
	test_open_minimal
	test_schema_validation
	test_id_counter_atomicity
	test_year_rollover
	test_personal_plane_mode
	test_open_without_init

	_teardown

	echo ""
	echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
	if [[ $TESTS_FAILED -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
