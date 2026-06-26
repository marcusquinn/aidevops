#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
MERGE_PROCESS="${SCRIPT_DIR}/../pulse-merge-process.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

file_contains() {
	local file_path="$1"
	local needle="$2"
	grep -Fq -- "$needle" "$file_path"
	return $?
}

test_ready_pr_fields_include_process_metadata() {
	local helper_src fields
	helper_src=$(awk '
		/^_pulse_merge_ready_pr_json_fields\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		print_result "ready PR field helper exists" 1 "missing _pulse_merge_ready_pr_json_fields"
		return 0
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	fields="$(_pulse_merge_ready_pr_json_fields)"

	local required missing=""
	for required in number mergeable reviewDecision author title isDraft labels updatedAt headRefOid headRefName baseRefName createdAt; do
		if [[ ",${fields}," != *",${required},"* ]]; then
			missing="${missing:+${missing},}${required}"
		fi
	done
	if [[ -n "$missing" ]]; then
		print_result "ready PR fields include process metadata" 1 "missing=${missing}; fields=${fields}"
		return 0
	fi
	print_result "ready PR fields include process metadata" 0
	return 0
}

test_callers_use_shared_field_helper() {
	local shared_field_arg="--json \"\$(_pulse_merge_ready_pr_json_fields)\""
	if ! file_contains "$MERGE_SCRIPT" "$shared_field_arg"; then
		print_result "process_pr uses shared PR field helper" 1 "process_pr still has an inline --json field list"
		return 0
	fi
	if ! file_contains "$MERGE_PROCESS" "$shared_field_arg"; then
		print_result "merge-ready list uses shared PR field helper" 1 "_merge_ready_prs_for_repo still has an inline --json field list"
		return 0
	fi
	print_result "PR JSON callers use shared field helper" 0
	return 0
}

test_merge_ready_list_failure_preserves_error_guard() {
	local failure_fallback='|| pr_json=""'
	if ! file_contains "$MERGE_PROCESS" "$failure_fallback"; then
		print_result "merge-ready list failure preserves error guard" 1 "gh_pr_list failure should leave pr_json empty so the -z guard logs the error"
		return 0
	fi
	print_result "merge-ready list failure preserves error guard" 0
	return 0
}

main() {
	test_ready_pr_fields_include_process_metadata
	test_callers_use_shared_field_helper
	test_merge_ready_list_failure_preserves_error_guard

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
