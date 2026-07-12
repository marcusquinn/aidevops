#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../task-identity-lib.sh
source "${REPO_ROOT}/.agents/scripts/task-identity-lib.sh"

PASS_COUNT=0
FAIL_COUNT=0
ORIGIN_ID="o01j2abc3def4gh5jkm6npq7rst"

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf 'FAIL %s\n' "$message" >&2
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$message"
		return 0
	fi
	fail "${message}: expected '${expected}', got '${actual}'"
	return 1
}

assert_valid() {
	local task_id="$1"
	local message="$2"
	if task_identity_validate "$task_id"; then
		pass "$message"
		return 0
	fi
	fail "${message}: rejected '${task_id}'"
	return 1
}

assert_invalid() {
	local task_id="$1"
	local message="$2"
	if task_identity_validate "$task_id"; then
		fail "${message}: accepted '${task_id}'"
		return 1
	fi
	pass "$message"
	return 0
}

test_valid_forms_and_fields() {
	task_identity_parse "t18097" || return 1
	assert_equal "legacy" "$TASK_IDENTITY_KIND" "legacy kind" || return 1
	assert_equal "t18097" "$TASK_IDENTITY_CANONICAL_ID" "legacy canonical ID" || return 1
	assert_equal "" "$TASK_IDENTITY_ORIGIN_ID" "legacy origin empty" || return 1
	assert_equal "18097" "$TASK_IDENTITY_SEQUENCE" "legacy sequence" || return 1
	assert_equal "" "$TASK_IDENTITY_SUBTASK_PATH" "legacy top-level subtask path" || return 1
	assert_equal "" "$TASK_IDENTITY_PARENT_ID" "legacy top-level parent" || return 1

	task_identity_parse "t18097.2.1" || return 1
	assert_equal "2.1" "$TASK_IDENTITY_SUBTASK_PATH" "legacy subtask path" || return 1
	assert_equal "t18097.2" "$TASK_IDENTITY_PARENT_ID" "legacy nested parent" || return 1

	task_identity_parse "t${ORIGIN_ID}-42.3" || return 1
	assert_equal "namespaced" "$TASK_IDENTITY_KIND" "namespaced kind" || return 1
	assert_equal "$ORIGIN_ID" "$TASK_IDENTITY_ORIGIN_ID" "namespaced origin" || return 1
	assert_equal "42" "$TASK_IDENTITY_SEQUENCE" "namespaced sequence" || return 1
	assert_equal "3" "$TASK_IDENTITY_SUBTASK_PATH" "namespaced subtask path" || return 1
	assert_equal "t${ORIGIN_ID}-42" "$TASK_IDENTITY_PARENT_ID" "namespaced parent" || return 1
	return 0
}

test_boundary_forms() {
	local decimal_max="999999999999999999"
	local deepest="1.2.3.4.5.6.7.8"
	local max_path="${decimal_max}.${decimal_max}.${decimal_max}.${decimal_max}.${decimal_max}.${decimal_max}.${decimal_max}.${decimal_max}"
	local max_token="t${ORIGIN_ID}-${decimal_max}.${max_path}"
	local oversized=""
	printf -v oversized 't%0200d' 1

	assert_equal "199" "$TASK_IDENTITY_MAX_BYTES" "published byte limit" || return 1
	assert_equal "18" "$TASK_IDENTITY_MAX_DECIMAL_DIGITS" "published decimal limit" || return 1
	assert_equal "8" "$TASK_IDENTITY_MAX_SUBTASK_DEPTH" "published subtask limit" || return 1
	assert_valid "t${decimal_max}.${deepest}" "legacy maximum digits and depth" || return 1
	assert_valid "$max_token" "namespaced exact maximum shape" || return 1
	assert_equal "199" "${#max_token}" "namespaced maximum is 199 bytes" || return 1
	assert_invalid "$oversized" "reject token over 199 bytes" || return 1
	assert_invalid "t1000000000000000000" "reject 19-digit sequence" || return 1
	assert_invalid "t1.1.2.3.4.5.6.7.8.9" "reject ninth subtask component" || return 1
	return 0
}

test_invalid_forms() {
	local invalid=""
	local invalid_values=(
		"" "t0" "t01" "T1" "t-1" "t1." "t1..2" "t1.0"
		"t${ORIGIN_ID}" "t${ORIGIN_ID}-0" "t${ORIGIN_ID}-01"
		"to81j2abc3def4gh5jkm6npq7rst-1" "to01j2abc3def4gh5jkm6npq7rso-1"
		"TO01J2ABC3DEF4GH5JKM6NPQ7RST-1" "t1/../../2" "t1 2" "t1;true"
		" t1" "t1 " $'t1\t2' $'t1\n2' $'t1\r2' $'t1\0012'
	)
	for invalid in "${invalid_values[@]}"; do
		assert_invalid "$invalid" "reject invalid form" || return 1
	done
	return 0
}

test_formatter_round_trip() {
	local formatted=""
	formatted=$(task_identity_format "legacy" "" "18097" "2.1") || return 1
	assert_equal "t18097.2.1" "$formatted" "format legacy" || return 1
	task_identity_parse "$formatted" || return 1
	assert_equal "$formatted" "$TASK_IDENTITY_CANONICAL_ID" "legacy round trip" || return 1

	formatted=$(task_identity_format "namespaced" "$ORIGIN_ID" "42" "3") || return 1
	assert_equal "t${ORIGIN_ID}-42.3" "$formatted" "format namespaced" || return 1
	task_identity_parse "$formatted" || return 1
	assert_equal "$formatted" "$TASK_IDENTITY_CANONICAL_ID" "namespaced round trip" || return 1

	if task_identity_format "legacy" "$ORIGIN_ID" "1" "" >/dev/null; then
		fail "legacy formatter accepted origin"
		return 1
	fi
	pass "legacy formatter rejects origin"
	if task_identity_format "namespaced" "" "1" "" >/dev/null; then
		fail "namespaced formatter accepted missing origin"
		return 1
	fi
	pass "namespaced formatter rejects missing origin"
	return 0
}

test_failure_clears_fields() {
	task_identity_parse "t7.2" || return 1
	if task_identity_parse "invalid"; then
		fail "invalid parse unexpectedly succeeded"
		return 1
	fi
	assert_equal "" "$TASK_IDENTITY_KIND" "failed parse clears kind" || return 1
	assert_equal "" "$TASK_IDENTITY_CANONICAL_ID" "failed parse clears canonical ID" || return 1
	assert_equal "" "$TASK_IDENTITY_ORIGIN_ID" "failed parse clears origin" || return 1
	assert_equal "" "$TASK_IDENTITY_SEQUENCE" "failed parse clears sequence" || return 1
	assert_equal "" "$TASK_IDENTITY_SUBTASK_PATH" "failed parse clears subtask path" || return 1
	assert_equal "" "$TASK_IDENTITY_PARENT_ID" "failed parse clears parent" || return 1
	return 0
}

test_validator_preserves_parsed_fields() {
	task_identity_parse "t${ORIGIN_ID}-42.3" || return 1
	task_identity_validate "t9" || return 1
	assert_equal "t${ORIGIN_ID}-42.3" "$TASK_IDENTITY_CANONICAL_ID" "valid validation preserves parsed state" || return 1
	if task_identity_validate "invalid"; then
		fail "invalid validation unexpectedly succeeded"
		return 1
	fi
	assert_equal "t${ORIGIN_ID}-42.3" "$TASK_IDENTITY_CANONICAL_ID" "invalid validation preserves parsed state" || return 1
	return 0
}

test_cwd_independence_and_regex_contract() {
	local original_pwd="$PWD"
	local legacy_ere=""
	local namespaced_ere=""
	local any_ere=""
	legacy_ere=$(task_identity_ere legacy) || return 1
	namespaced_ere=$(task_identity_ere namespaced) || return 1
	any_ere=$(task_identity_ere any) || return 1
	cd "$TEST_ROOT" || return 1
	task_identity_parse "t9.1" || return 1
	cd "$original_pwd" || return 1
	assert_equal "legacy" "$TASK_IDENTITY_KIND" "parse independent of cwd" || return 1
	[[ "t9.1" =~ $legacy_ere ]] || {
		fail "legacy ERE rejects valid token"
		return 1
	}
	[[ "t${ORIGIN_ID}-9.1" =~ $namespaced_ere ]] || {
		fail "namespaced ERE rejects valid token"
		return 1
	}
	[[ "t9.1" =~ $any_ere && "t${ORIGIN_ID}-9.1" =~ $any_ere ]] || {
		fail "any ERE rejects valid token"
		return 1
	}
	if [[ "t${ORIGIN_ID}-9.1" =~ $legacy_ere ]] || [[ "t9.1" =~ $namespaced_ere ]] ||
		[[ "xt9.1" =~ $any_ere ]] || [[ "t9.0" =~ $any_ere ]]; then
		fail "published ERE accepted wrong or invalid form"
		return 1
	fi
	if task_identity_ere unknown >/dev/null; then
		fail "ERE API accepted unknown kind"
		return 1
	fi
	pass "published ERE constants match valid tokens"
	return 0
}

test_text_extraction() {
	local namespaced="t${ORIGIN_ID}-42.3"
	local extracted=""

	extracted=$(task_identity_extract_first "fix: complete ${namespaced}-release") || return 1
	assert_equal "$namespaced" "$extracted" "extract namespaced ID from branch-like text" || return 1
	extracted=$(task_identity_extract_first "Refs t18097.2, then ${namespaced}.") || return 1
	assert_equal "t18097.2" "$extracted" "extract first legacy ID" || return 1
	extracted=$(task_identity_extract_all "t7, ${namespaced}; t9.1") || return 1
	assert_equal $'t7\n'"${namespaced}"$'\nt9.1' "$extracted" "extract all IDs in encounter order" || return 1

	if task_identity_extract_first "embeddedxt7value" >/dev/null; then
		fail "extractor accepted embedded ID"
		return 1
	fi
	pass "extractor rejects embedded ID"
	if task_identity_extract_first "malformed t7.0 marker" >/dev/null; then
		fail "extractor accepted valid prefix of malformed ID"
		return 1
	fi
	pass "extractor rejects valid prefix of malformed ID"
	if task_identity_extract_first "t1234567890123456789" >/dev/null; then
		fail "extractor accepted truncated overlong ID"
		return 1
	fi
	pass "extractor rejects truncated overlong ID"
	return 0
}

test_structured_helpers() {
	local namespaced="t${ORIGIN_ID}-42.3"
	local parsed=""

	parsed=$(task_identity_parse_title_prefix "${namespaced}: migrate consumers") || return 1
	assert_equal "$namespaced" "$parsed" "parse namespaced title prefix" || return 1
	if task_identity_parse_title_prefix "${namespaced} migrate consumers" >/dev/null; then
		fail "title parser accepted missing colon"
		return 1
	fi
	pass "title parser requires colon"
	if task_identity_parse_title_prefix "t01: malformed" >/dev/null; then
		fail "title parser accepted malformed ID"
		return 1
	fi
	pass "title parser rejects malformed ID"

	parsed=$(task_identity_escape_ere "t7.2") || return 1
	assert_equal 't7\.2' "$parsed" "escape ID for ERE" || return 1
	if task_identity_escape_ere "t7.*" >/dev/null; then
		fail "ERE helper accepted malformed ID"
		return 1
	fi
	pass "ERE helper validates input"

	if ! task_identity_has_malformed_candidate "Blocked by: t01"; then
		fail "malformed detector missed leading-zero ID"
		return 1
	fi
	pass "malformed detector finds invalid legacy ID"
	if ! task_identity_has_malformed_candidate "Blocked by: t${ORIGIN_ID}-01"; then
		fail "malformed detector missed invalid namespaced ID"
		return 1
	fi
	pass "malformed detector finds invalid namespaced ID"
	if ! task_identity_has_malformed_candidate "Blocked by: T7" ||
		! task_identity_has_malformed_candidate "Blocked by: tXYZ" ||
		! task_identity_has_malformed_candidate "Blocked by: to81j2abc3def4gh5jkm6npq7rst-1"; then
		fail "malformed detector missed alternate invalid marker"
		return 1
	fi
	pass "malformed detector finds uppercase, symbolic, and invalid-origin markers"
	if task_identity_has_malformed_candidate "ordinary text and t7"; then
		fail "malformed detector rejected valid ID"
		return 1
	fi
	pass "malformed detector accepts valid marker"

	parsed=$(task_identity_parse_list "t7, ${namespaced} t9.1") || return 1
	assert_equal $'t7\n'"${namespaced}"$'\nt9.1' "$parsed" "parse mixed structured list" || return 1
	if task_identity_parse_list "t7,t01" >/dev/null; then
		fail "list parser accepted malformed member"
		return 1
	fi
	pass "list parser fails closed"
	return 0
}

main() {
	test_valid_forms_and_fields || return 1
	test_boundary_forms || return 1
	test_invalid_forms || return 1
	test_formatter_round_trip || return 1
	test_failure_clears_fields || return 1
	test_validator_preserves_parsed_fields || return 1
	test_cwd_independence_and_regex_contract || return 1
	test_text_extraction || return 1
	test_structured_helpers || return 1
	if [[ "$FAIL_COUNT" -ne 0 ]]; then
		printf '%d test(s) failed\n' "$FAIL_COUNT" >&2
		return 1
	fi
	printf '%d assertions passed\n' "$PASS_COUNT"
	return 0
}

main "$@"
