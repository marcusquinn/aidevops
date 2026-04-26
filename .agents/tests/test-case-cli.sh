#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for case-helper.sh (t2852)
# Covers each subcommand happy path + failure paths
#
# Usage: bash .agents/tests/test-case-cli.sh
# Requires: jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CASE_HELPER="${SCRIPT_DIR}/../scripts/case-helper.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	# Initialize a minimal git repo for git mv support
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
# Tests
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

	# Idempotent: running again is safe
	_assert_exit_0 "init is idempotent" \
		bash "$CASE_HELPER" init "$repo"
	return 0
}

test_open_happy() {
	echo ""
	echo "=== open (happy path) ==="
	local repo="$TEST_TMPDIR"

	bash "$CASE_HELPER" init "$repo" >/dev/null 2>&1

	# Open with all flags
	_assert_exit_0 "open with all flags" \
		bash "$CASE_HELPER" open acme-dispute \
		--kind dispute \
		--party "ACME Ltd" \
		--party-role "client" \
		--deadline "2026-08-31" \
		--deadline-label "filing deadline" \
		--repo "$repo"

	local case_dir="${repo}/_cases/case-2026-0001-acme-dispute"
	_assert_dir_exists "open creates case directory" "$case_dir"
	_assert_file_exists "open creates dossier.toon" "${case_dir}/dossier.toon"
	_assert_file_exists "open creates timeline.jsonl" "${case_dir}/timeline.jsonl"
	_assert_file_exists "open creates sources.toon" "${case_dir}/sources.toon"
	_assert_dir_exists "open creates notes/" "${case_dir}/notes"
	_assert_dir_exists "open creates comms/" "${case_dir}/comms"
	_assert_dir_exists "open creates drafts/" "${case_dir}/drafts"

	_assert_json_field "dossier has correct id" \
		"${case_dir}/dossier.toon" '.id' "case-2026-0001-acme-dispute"
	_assert_json_field "dossier has correct slug" \
		"${case_dir}/dossier.toon" '.slug' "acme-dispute"
	_assert_json_field "dossier has correct kind" \
		"${case_dir}/dossier.toon" '.kind' "dispute"
	_assert_json_field "dossier status is open" \
		"${case_dir}/dossier.toon" '.status' "open"
	_assert_json_field "dossier has party" \
		"${case_dir}/dossier.toon" '.parties[0].name' "ACME Ltd"
	_assert_json_field "dossier has deadline" \
		"${case_dir}/dossier.toon" '.deadlines[0].date' "2026-08-31"

	# sources.toon initialised as empty array
	_assert_json_field "sources.toon is empty array" \
		"${case_dir}/sources.toon" 'length' "0"

	# timeline has open event
	_assert_contains "timeline has open event" \
		"${case_dir}/timeline.jsonl" '"kind":"open"'
	return 0
}

test_open_sequential_ids() {
	echo ""
	echo "=== open (sequential IDs) ==="
	local repo="$TEST_TMPDIR"

	bash "$CASE_HELPER" open second-case --kind contract --repo "$repo" >/dev/null 2>&1

	local case2_dir="${repo}/_cases/case-2026-0002-second-case"
	_assert_dir_exists "second case gets 0002" "$case2_dir"
	return 0
}

test_open_json_mode() {
	echo ""
	echo "=== open (--json) ==="
	local repo="$TEST_TMPDIR"

	local output
	output="$(bash "$CASE_HELPER" open json-test-case --kind inquiry --repo "$repo" --json 2>/dev/null)"
	local valid
	valid="$(echo "$output" | jq '.id' 2>/dev/null)" || valid=""
	if [[ -n "$valid" ]]; then
		_pass "open --json returns valid JSON with id field"
	else
		_fail "open --json returns valid JSON with id field" "got: ${output}"
	fi
	return 0
}

test_list() {
	echo ""
	echo "=== list ==="
	local repo="$TEST_TMPDIR"

	_assert_exit_0 "list works with open cases" \
		bash "$CASE_HELPER" list --repo "$repo"

	local json_out
	json_out="$(bash "$CASE_HELPER" list --json --repo "$repo" --status open 2>/dev/null)"
	local count
	count="$(echo "$json_out" | jq 'length' 2>/dev/null)" || count="0"
	if [[ "$count" -ge 1 ]]; then
		_pass "list --json returns array with open cases"
	else
		_fail "list --json returns array with open cases" "got count=${count}"
	fi

	# list with no matches
	_assert_exit_0 "list with no matches exits 0" \
		bash "$CASE_HELPER" list --status closed --repo "$repo"
	return 0
}

test_list_filter_party() {
	echo ""
	echo "=== list --party filter ==="
	local repo="$TEST_TMPDIR"

	local json_out
	json_out="$(bash "$CASE_HELPER" list --party "ACME" --json --repo "$repo" 2>/dev/null)"
	local count
	count="$(echo "$json_out" | jq 'length' 2>/dev/null)" || count="0"
	if [[ "$count" -ge 1 ]]; then
		_pass "list --party filters to matching cases"
	else
		_fail "list --party filters to matching cases" "got count=${count}"
	fi

	# Non-matching party
	json_out="$(bash "$CASE_HELPER" list --party "NoSuchParty999" --json --repo "$repo" 2>/dev/null)"
	count="$(echo "$json_out" | jq 'length' 2>/dev/null)" || count="0"
	if [[ "$count" -eq 0 ]]; then
		_pass "list --party returns empty for no-match"
	else
		_fail "list --party returns empty for no-match" "got count=${count}"
	fi
	return 0
}

test_show() {
	echo ""
	echo "=== show ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"

	_assert_exit_0 "show exits 0 for valid case" \
		bash "$CASE_HELPER" show "$case_id" --repo "$repo"

	local json_out
	json_out="$(bash "$CASE_HELPER" show "$case_id" --json --repo "$repo" 2>/dev/null)"
	local has_dossier
	has_dossier="$(echo "$json_out" | jq '.dossier.id' 2>/dev/null)" || has_dossier=""
	if [[ -n "$has_dossier" ]]; then
		_pass "show --json includes dossier"
	else
		_fail "show --json includes dossier"
	fi

	# Failure: non-existent case
	_assert_exit_nonzero "show exits non-zero for missing case" \
		bash "$CASE_HELPER" show no-such-case-id-xyz --repo "$repo"
	return 0
}

test_status() {
	echo ""
	echo "=== status ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"
	local case_dir="${repo}/_cases/${case_id}"

	_assert_exit_0 "status hold succeeds" \
		bash "$CASE_HELPER" status "$case_id" hold \
		--reason "awaiting client response" --repo "$repo"
	_assert_json_field "dossier status updated to hold" \
		"${case_dir}/dossier.toon" '.status' "hold"
	_assert_contains "timeline has status_change event" \
		"${case_dir}/timeline.jsonl" '"kind":"status_change"'

	# status back to open
	_assert_exit_0 "status open succeeds" \
		bash "$CASE_HELPER" status "$case_id" open --repo "$repo"
	_assert_json_field "dossier status updated to open" \
		"${case_dir}/dossier.toon" '.status' "open"

	# Failure: trying to set status=closed via status command
	_assert_exit_nonzero "status closed is rejected (use close instead)" \
		bash "$CASE_HELPER" status "$case_id" closed --repo "$repo"
	return 0
}

test_close() {
	echo ""
	echo "=== close ==="
	local repo="$TEST_TMPDIR"
	# Use the second case for close test (leave acme open for other tests)
	local case_id="case-2026-0002-second-case"
	local case_dir="${repo}/_cases/${case_id}"

	# Failure: close without --outcome
	_assert_exit_nonzero "close without --outcome fails" \
		bash "$CASE_HELPER" close "$case_id" --repo "$repo"

	# Happy: close with outcome
	_assert_exit_0 "close with --outcome succeeds" \
		bash "$CASE_HELPER" close "$case_id" --outcome "settled" \
		--summary "Agreed in mediation" --repo "$repo"
	_assert_json_field "dossier status is closed" \
		"${case_dir}/dossier.toon" '.status' "closed"
	_assert_json_field "dossier outcome is set" \
		"${case_dir}/dossier.toon" '.outcome' "settled"
	return 0
}

test_attach() {
	echo ""
	echo "=== attach ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"
	local case_dir="${repo}/_cases/${case_id}"

	# Create a fake knowledge source directory
	mkdir -p "${repo}/_knowledge/sources/src-001"

	_assert_exit_0 "attach valid source" \
		bash "$CASE_HELPER" attach "$case_id" "src-001" \
		--role "evidence" --repo "$repo"
	_assert_json_field "sources.toon has 1 entry" \
		"${case_dir}/sources.toon" 'length' "1"
	_assert_json_field "sources.toon has correct id" \
		"${case_dir}/sources.toon" '.[0].id' "src-001"
	_assert_json_field "sources.toon has correct role" \
		"${case_dir}/sources.toon" '.[0].role' "evidence"
	_assert_contains "timeline has attach event" \
		"${case_dir}/timeline.jsonl" '"kind":"attach"'

	# Failure: attach non-existent source
	_assert_exit_nonzero "attach non-existent source fails" \
		bash "$CASE_HELPER" attach "$case_id" "src-nonexistent-xyz" --repo "$repo"

	# Failure: attach already-attached source
	_assert_exit_nonzero "attach duplicate source fails" \
		bash "$CASE_HELPER" attach "$case_id" "src-001" --repo "$repo"
	return 0
}

test_note() {
	echo ""
	echo "=== note ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"
	local case_dir="${repo}/_cases/${case_id}"
	local notes_file="${case_dir}/notes/notes.md"

	_assert_exit_0 "note appends to notes.md" \
		bash "$CASE_HELPER" note "$case_id" \
		--message "Reviewed contract terms carefully" --repo "$repo"
	_assert_file_exists "notes.md exists" "$notes_file"
	_assert_contains "notes.md has content" "$notes_file" "Reviewed contract terms"
	_assert_contains "timeline has note event" \
		"${case_dir}/timeline.jsonl" '"kind":"note"'

	# Failure: note without --message
	_assert_exit_nonzero "note without --message fails" \
		bash "$CASE_HELPER" note "$case_id" --repo "$repo"
	return 0
}

test_deadline() {
	echo ""
	echo "=== deadline ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"
	local case_dir="${repo}/_cases/${case_id}"

	_assert_exit_0 "deadline add succeeds" \
		bash "$CASE_HELPER" deadline add "$case_id" \
		--date "2026-10-01" --label "response deadline" --repo "$repo"

	# dossier should have 2 deadlines now (1 from open + 1 added)
	local count
	count="$(jq '.deadlines | length' "${case_dir}/dossier.toon" 2>/dev/null)" || count="0"
	if [[ "$count" -ge 2 ]]; then
		_pass "deadline add adds to dossier"
	else
		_fail "deadline add adds to dossier" "count=${count}"
	fi

	_assert_exit_0 "deadline remove succeeds" \
		bash "$CASE_HELPER" deadline remove "$case_id" \
		--label "response deadline" --repo "$repo"

	count="$(jq '.deadlines | length' "${case_dir}/dossier.toon" 2>/dev/null)" || count="0"
	if [[ "$count" -lt 2 ]]; then
		_pass "deadline remove removes from dossier"
	else
		_fail "deadline remove removes from dossier" "count=${count}"
	fi
	return 0
}

test_party() {
	echo ""
	echo "=== party ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"
	local case_dir="${repo}/_cases/${case_id}"

	_assert_exit_0 "party add succeeds" \
		bash "$CASE_HELPER" party add "$case_id" \
		--name "Opposing Counsel" --role "opponent" --repo "$repo"

	_assert_json_field "party added to dossier" \
		"${case_dir}/dossier.toon" \
		'.parties[] | select(.name == "Opposing Counsel") | .role' \
		"opponent"
	_assert_contains "timeline has party event" \
		"${case_dir}/timeline.jsonl" '"kind":"party"'

	_assert_exit_0 "party remove succeeds" \
		bash "$CASE_HELPER" party remove "$case_id" \
		--name "Opposing Counsel" --repo "$repo"

	local still_there
	still_there="$(jq -r '.parties[] | select(.name == "Opposing Counsel") | .name' \
		"${case_dir}/dossier.toon" 2>/dev/null)" || still_there=""
	if [[ -z "$still_there" ]]; then
		_pass "party removed from dossier"
	else
		_fail "party removed from dossier" "still present"
	fi
	return 0
}

test_comm() {
	echo ""
	echo "=== comm ==="
	local repo="$TEST_TMPDIR"
	local case_id="case-2026-0001-acme-dispute"
	local case_dir="${repo}/_cases/${case_id}"

	_assert_exit_0 "comm log succeeds" \
		bash "$CASE_HELPER" comm log "$case_id" \
		--direction in --channel email \
		--summary "Received settlement offer from ACME" --repo "$repo"

	_assert_file_exists "comms.log exists" "${case_dir}/comms/comms.log"
	_assert_contains "comms.log has content" \
		"${case_dir}/comms/comms.log" "Received settlement offer"
	_assert_contains "timeline has comm event" \
		"${case_dir}/timeline.jsonl" '"kind":"comm"'

	# Failure: comm log without required fields
	_assert_exit_nonzero "comm log without --direction fails" \
		bash "$CASE_HELPER" comm log "$case_id" \
		--channel email --summary "test" --repo "$repo"

	# Failure: invalid direction
	_assert_exit_nonzero "comm log with invalid direction fails" \
		bash "$CASE_HELPER" comm log "$case_id" \
		--direction sideways --channel email --summary "test" --repo "$repo"
	return 0
}

test_archive() {
	echo ""
	echo "=== archive ==="
	local repo="$TEST_TMPDIR"
	# Use the json-test-case (3rd one opened)
	local case_id="case-2026-0003-json-test-case"
	local case_dir="${repo}/_cases/${case_id}"
	local archived_dir="${repo}/_cases/archived/${case_id}"

	_assert_exit_0 "archive moves case directory" \
		bash "$CASE_HELPER" archive "$case_id" --repo "$repo"

	_assert_dir_exists "archived case exists in archived/" "$archived_dir"

	if [[ ! -d "$case_dir" ]]; then
		_pass "active case directory removed after archive"
	else
		_fail "active case directory removed after archive" "dir still exists"
	fi

	# list should not show archived case by default
	local list_out
	list_out="$(bash "$CASE_HELPER" list --json --repo "$repo" 2>/dev/null)"
	local found
	found="$(echo "$list_out" | jq -r '.[] | select(.id == "case-2026-0003-json-test-case") | .id' 2>/dev/null)" || found=""
	if [[ -z "$found" ]]; then
		_pass "archived case excluded from default list"
	else
		_fail "archived case excluded from default list" "found in list"
	fi

	# list --status archived should show it
	list_out="$(bash "$CASE_HELPER" list --status archived --json --repo "$repo" 2>/dev/null)"
	found="$(echo "$list_out" | jq -r '.[] | select(.id == "case-2026-0003-json-test-case") | .id' 2>/dev/null)" || found=""
	if [[ -n "$found" ]]; then
		_pass "archived case visible with --status archived"
	else
		_fail "archived case visible with --status archived" "not found"
	fi

	# Failure: archive already-archived case
	_assert_exit_nonzero "archive already-archived case fails" \
		bash "$CASE_HELPER" archive "$case_id" --repo "$repo"

	# Failure: mutate archived case without --unarchive
	_assert_exit_nonzero "note on archived case fails without --unarchive" \
		bash "$CASE_HELPER" note "$case_id" --message "test" --repo "$repo"
	return 0
}

test_missing_prereq() {
	echo ""
	echo "=== error paths ==="
	local repo="$TEST_TMPDIR"

	# open on non-provisioned repo
	local fresh_dir
	fresh_dir="$(mktemp -d)"
	_assert_exit_nonzero "open without init fails" \
		bash "$CASE_HELPER" open some-case --repo "$fresh_dir"
	rm -rf "$fresh_dir"

	# list on non-provisioned repo
	fresh_dir="$(mktemp -d)"
	_assert_exit_nonzero "list without init fails" \
		bash "$CASE_HELPER" list --repo "$fresh_dir"
	rm -rf "$fresh_dir"

	# show non-existent case
	_assert_exit_nonzero "show non-existent case fails" \
		bash "$CASE_HELPER" show no-such-case-xyz999 --repo "$repo"
	return 0
}

# =============================================================================
# Runner
# =============================================================================

main() {
	echo "Running case-helper.sh tests..."

	if ! command -v jq >/dev/null 2>&1; then
		echo "SKIP: jq not found. Install: brew install jq"
		exit 0
	fi

	_setup

	test_init
	test_open_happy
	test_open_sequential_ids
	test_open_json_mode
	test_list
	test_list_filter_party
	test_show
	test_status
	test_close
	test_attach
	test_note
	test_deadline
	test_party
	test_comm
	test_archive
	test_missing_prereq

	_teardown

	echo ""
	echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
	if [[ $TESTS_FAILED -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
