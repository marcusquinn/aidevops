#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#22399: external issue authors must not dispatch while
# the asynchronous issue-triage GitHub Actions workflow is queued.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
GH_CALLS_FILE=""
TEST_ROOT=""

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

define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_check_external_issue_author_gate\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _check_external_issue_author_gate from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

setup_case() {
	local association="$1"
	local author_type="${2:-User}"
	local approval_result="${3:-}"

	TEST_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-gh22399)
	GH_CALLS_FILE="${TEST_ROOT}/gh-calls.log"
	LOGFILE="${TEST_ROOT}/pulse.log"
	AGENTS_DIR="${TEST_ROOT}/agents"
	export TEST_ROOT GH_CALLS_FILE LOGFILE AGENTS_DIR
	mkdir -p "${AGENTS_DIR}/scripts" "${TEST_ROOT}/bin"
	: >"$GH_CALLS_FILE"
	: >"$LOGFILE"

	cat >"${TEST_ROOT}/issue-meta.tsv" <<EOF
${association}	${author_type}
EOF
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "gh $*" >>"$GH_CALLS_FILE"
if [[ "${1:-}" == "api" ]]; then
	cat "${TEST_ROOT}/issue-meta.tsv"
	exit 0
fi
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	PATH="${TEST_ROOT}/bin:$PATH"
	export PATH

	cat >"${AGENTS_DIR}/scripts/approval-helper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "verify" && "${approval_result}" == "VERIFIED" ]]; then
	printf 'VERIFIED\n'
	exit 0
fi
printf 'UNVERIFIED\n'
exit 1
EOF
	chmod +x "${AGENTS_DIR}/scripts/approval-helper.sh"
	return 0
}

cleanup_case() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh_issue_edit_safe() {
	printf 'gh_issue_edit_safe %s\n' "$*" >>"$GH_CALLS_FILE"
	return 0
}

test_external_author_without_approval_blocks_and_applies_nmr() {
	setup_case "CONTRIBUTOR" "User" ""
	if _check_external_issue_author_gate 22390 "owner/repo"; then
		if grep -q -- '--add-label needs-maintainer-review' "$GH_CALLS_FILE"; then
			print_result "external author without approval blocks and applies NMR" 0
			cleanup_case
			return 0
		fi
		print_result "external author without approval blocks and applies NMR" 1 "NMR label was not applied: $(<"$GH_CALLS_FILE")"
		cleanup_case
		return 0
	fi
	print_result "external author without approval blocks and applies NMR" 1 "Expected gate to block"
	cleanup_case
	return 0
}

test_owner_author_allows_dispatch() {
	setup_case "OWNER" "User" ""
	if _check_external_issue_author_gate 1 "owner/repo"; then
		print_result "OWNER author bypasses external gate" 1 "Expected gate to allow OWNER"
		cleanup_case
		return 0
	fi
	print_result "OWNER author bypasses external gate" 0
	cleanup_case
	return 0
}

test_collaborator_author_allows_dispatch() {
	setup_case "COLLABORATOR" "User" ""
	if _check_external_issue_author_gate 2 "owner/repo"; then
		print_result "COLLABORATOR author bypasses external gate" 1 "Expected gate to allow COLLABORATOR"
		cleanup_case
		return 0
	fi
	print_result "COLLABORATOR author bypasses external gate" 0
	cleanup_case
	return 0
}

test_external_author_with_crypto_approval_allows_dispatch() {
	setup_case "CONTRIBUTOR" "User" "VERIFIED"
	if _check_external_issue_author_gate 3 "owner/repo"; then
		print_result "external author with cryptographic approval dispatches" 1 "Expected verified approval to allow dispatch"
		cleanup_case
		return 0
	fi
	print_result "external author with cryptographic approval dispatches" 0
	cleanup_case
	return 0
}

test_author_lookup_failure_fails_closed() {
	setup_case "" "" ""
	rm -f "${TEST_ROOT}/issue-meta.tsv"
	if _check_external_issue_author_gate 4 "owner/repo"; then
		if grep -q -- '--add-label needs-maintainer-review' "$GH_CALLS_FILE"; then
			print_result "author lookup failure fails closed with NMR" 0
			cleanup_case
			return 0
		fi
		print_result "author lookup failure fails closed with NMR" 1 "NMR label was not applied"
		cleanup_case
		return 0
	fi
	print_result "author lookup failure fails closed with NMR" 1 "Expected gate to block on lookup failure"
	cleanup_case
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_external_author_without_approval_blocks_and_applies_nmr
	test_owner_author_allows_dispatch
	test_collaborator_author_allows_dispatch
	test_external_author_with_crypto_approval_allows_dispatch
	test_author_lookup_failure_fails_closed

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
