#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NMR_SCRIPT="${SCRIPT_DIR}/../pulse-nmr-approval.sh"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t nmr-authority.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	export POSTED_COMMENT="${TEST_ROOT}/posted-comment.txt"
	export ISSUE_ASSOC="OWNER"
	export ACTOR_PERMISSION="write"
	: >"$LOGFILE"
	: >"$POSTED_COMMENT"
	printf '{"initialized_repos":[{"slug":"owner/repo","maintainer":"maintainer","pulse":true}]}' >"$REPOS_JSON"
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	path="${2:-}"
	jq_filter=""
	shift 2 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--jq) jq_filter="$2"; shift 2 ;;
			--paginate|--slurp) shift ;;
			*) shift ;;
		esac
	done
	if [[ "$path" == "user" ]]; then
		printf '{"login":"runner"}\n' | jq -r "${jq_filter:-.}"
		exit 0
	fi
	if [[ "$path" == */collaborators/runner/permission ]]; then
		printf '{"permission":"%s"}\n' "${ACTOR_PERMISSION:-none}" | jq -r "${jq_filter:-.}"
		exit 0
	fi
	if [[ "$path" == */issues/24479 ]]; then
		printf '{"user":{"login":"maintainer"},"author_association":"%s","labels":[]}\n' "${ISSUE_ASSOC:-NONE}"
		exit 0
	fi
	if [[ "$path" == */timeline ]]; then
		printf '[]\n'
		exit 0
	fi
	if [[ "$path" == */comments ]]; then
		printf '[]\n'
		exit 0
	fi
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "lock" ]]; then
	exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
	exit 0
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh_issue_list() {
	printf '[{"number":24479,"author":{"login":"maintainer"}}]\n'
	return 0
}
export -f gh_issue_list

gh_issue_comment() {
	local body=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			body="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	printf '%s\n' "$body" >"$POSTED_COMMENT"
	return 0
}
export -f gh_issue_comment

run_auto_approve() {
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	auto_approve_maintainer_issues
	return 0
}

test_blocks_none_author_association() {
	setup_test_env
	export ISSUE_ASSOC="NONE"
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "auto-approval blocks maintainer-login issue with NONE association" 0
	else
		print_result "auto-approval blocks maintainer-login issue with NONE association" 1 "unexpected approval comment"
	fi
	teardown_test_env
	return 0
}

test_blocks_actor_without_write_permission() {
	setup_test_env
	export ISSUE_ASSOC="OWNER"
	export ACTOR_PERMISSION="read"
	run_auto_approve
	if [[ ! -s "$POSTED_COMMENT" ]]; then
		print_result "auto-approval blocks runner without upstream write authority" 0
	else
		print_result "auto-approval blocks runner without upstream write authority" 1 "unexpected approval comment"
	fi
	teardown_test_env
	return 0
}

test_allows_owner_author_with_write_permission() {
	setup_test_env
	export ISSUE_ASSOC="OWNER"
	export ACTOR_PERMISSION="write"
	run_auto_approve
	if grep -q 'aidevops-signed-approval' "$POSTED_COMMENT" 2>/dev/null; then
		print_result "auto-approval allows upstream OWNER author and write-capable runner" 0
	else
		print_result "auto-approval allows upstream OWNER author and write-capable runner" 1 "approval comment missing"
	fi
	teardown_test_env
	return 0
}

main() {
	test_blocks_none_author_association
	test_blocks_actor_without_write_permission
	test_allows_owner_author_with_write_permission
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
