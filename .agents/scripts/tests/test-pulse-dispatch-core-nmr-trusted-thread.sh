#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for the ever-NMR trusted maintainer-only thread exemption.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ISSUE_ASSOC="OWNER"
COMMENTS_JSON="[]"
APPROVAL_KNOWN_STATUS=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

define_helpers_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_issue_thread_is_trusted_maintainer_only\(\) \{/,/^}$/ { print }
		/^_check_nmr_approval_gate\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

setup_case() {
	local issue_association="$1"
	local comments_json="$2"

	TEST_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-nmr-trusted-thread)
	LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	ISSUE_ASSOC="$issue_association"
	COMMENTS_JSON="$comments_json"
	APPROVAL_KNOWN_STATUS=""
	export LOGFILE ISSUE_ASSOC COMMENTS_JSON APPROVAL_KNOWN_STATUS
	return 0
}

cleanup_case() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh() {
	local command="$1"
	local endpoint="$2"
	shift 2

	if [[ "$command" != "api" ]]; then
		return 1
	fi

	case "$endpoint" in
		*/comments)
			printf '%s\n' "$COMMENTS_JSON"
			return 0
			;;
		*)
			printf '%s\n' "$ISSUE_ASSOC"
			return 0
			;;
	esac
}

_is_bot_generated_cleanup_issue() {
	return 1
}

issue_has_required_approval() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"
	APPROVAL_KNOWN_STATUS="$known_status"
	export APPROVAL_KNOWN_STATUS

	[[ -n "$issue_num" && -n "$slug" ]] || return 1
	if [[ "$known_status" == "false" ]]; then
		return 0
	fi
	return 1
}

notify_ever_nmr_without_approval() {
	return 0
}

test_owner_author_owner_member_comments_bypasses_historical_nmr() {
	setup_case "OWNER" '[{"author_association":"OWNER"},{"author_association":"MEMBER"}]'
	if _check_nmr_approval_gate 101 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		print_result "OWNER/MEMBER-only thread bypasses historical NMR" 1 "gate blocked; known_status=${APPROVAL_KNOWN_STATUS}"
		cleanup_case
		return 0
	fi
	if [[ "$APPROVAL_KNOWN_STATUS" == "false" ]]; then
		print_result "OWNER/MEMBER-only thread bypasses historical NMR" 0
	else
		print_result "OWNER/MEMBER-only thread bypasses historical NMR" 1 "expected known_status=false, got ${APPROVAL_KNOWN_STATUS}"
	fi
	cleanup_case
	return 0
}

test_member_author_no_comments_bypasses_historical_nmr() {
	setup_case "MEMBER" '[]'
	if _check_nmr_approval_gate 102 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		print_result "MEMBER-authored empty thread bypasses historical NMR" 1 "gate blocked; known_status=${APPROVAL_KNOWN_STATUS}"
		cleanup_case
		return 0
	fi
	if [[ "$APPROVAL_KNOWN_STATUS" == "false" ]]; then
		print_result "MEMBER-authored empty thread bypasses historical NMR" 0
	else
		print_result "MEMBER-authored empty thread bypasses historical NMR" 1 "expected known_status=false, got ${APPROVAL_KNOWN_STATUS}"
	fi
	cleanup_case
	return 0
}

test_external_comment_preserves_ever_nmr_gate() {
	setup_case "OWNER" '[{"author_association":"OWNER"},{"author_association":"CONTRIBUTOR"}]'
	if _check_nmr_approval_gate 103 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "external comment preserves ever-NMR gate" 0
		else
			print_result "external comment preserves ever-NMR gate" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "external comment preserves ever-NMR gate" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_active_nmr_label_preserves_gate() {
	setup_case "OWNER" '[{"author_association":"OWNER"}]'
	if _check_nmr_approval_gate 104 "owner/repo" '{"labels":[{"name":"needs-maintainer-review"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "true" ]]; then
			print_result "active NMR label preserves gate" 0
		else
			print_result "active NMR label preserves gate" 1 "expected known_status=true, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "active NMR label preserves gate" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_collaborator_author_does_not_bypass_historical_nmr() {
	setup_case "COLLABORATOR" '[{"author_association":"OWNER"}]'
	if _check_nmr_approval_gate 105 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "COLLABORATOR author does not bypass historical NMR" 0
		else
			print_result "COLLABORATOR author does not bypass historical NMR" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "COLLABORATOR author does not bypass historical NMR" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

main() {
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_owner_author_owner_member_comments_bypasses_historical_nmr
	test_member_author_no_comments_bypasses_historical_nmr
	test_external_comment_preserves_ever_nmr_gate
	test_active_nmr_label_preserves_gate
	test_collaborator_author_does_not_bypass_historical_nmr

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
