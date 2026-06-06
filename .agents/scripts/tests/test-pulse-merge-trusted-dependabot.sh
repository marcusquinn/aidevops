#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for trusted Dependabot dependency-update allowances.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
GATES_SCRIPT="${SCRIPT_DIR}/../pulse-merge-gates.sh"
AUTHOR_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-author-checks.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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

write_pr_fixture() {
	local author_login="$1"
	local commit_login="$2"
	local changed_path="$3"
	local security_conclusion="$4"
	local framework_conclusion="${5:-SUCCESS}"
	cat >"${TEST_ROOT}/pr.json" <<EOF
{
  "author": {"login": "${author_login}"},
  "headRepositoryOwner": {"login": "owner"},
  "headRepository": {"nameWithOwner": "owner/repo"},
  "body": "Bumps the pip group with 1 update in the / directory: [pyarrow](https://github.com/apache/arrow).\n\n---\nupdated-dependencies:\n- dependency-name: pyarrow\n  dependency-version: 23.0.1\n  dependency-type: direct:production\n  dependency-group: pip\n...",
  "commits": [
    {"authors": [{"login": "${commit_login}"}]}
  ],
  "files": [
    {"path": "${changed_path}"}
  ],
	"statusCheckRollup": [
		{"name": "Socket Security: Pull Request Alerts", "conclusion": "${security_conclusion}", "status": "COMPLETED"},
		{"name": "Framework Validation", "conclusion": "${framework_conclusion}", "status": "COMPLETED"},
		{"name": "gate / review-bot-gate", "workflowName": "Review Bot Gate", "conclusion": "FAILURE", "status": "COMPLETED"}
	]
}
EOF
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF="${TEST_ROOT}/trusted-dependabot-updates.conf"
	printf 'pip:pyarrow\n' >"$AIDEVOPS_TRUSTED_DEPENDABOT_UPDATES_CONF"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	printf 'pulse-runner\n' >"${TEST_ROOT}/collaborators.txt"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	cat "${TEST_ROOT}/pr.json"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	printf 'pulse-runner\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "-i" && "$*" == *"/collaborators/"*"/permission" ]]; then
	_user="${3#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'HTTP/2.0 200 OK\n'
	else
		printf 'HTTP/2.0 404 Not Found\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "$*" == *"/collaborators/"*"/permission"* && "$*" == *"--jq"* ]]; then
	_user="${2#*/collaborators/}"
	_user="${_user%/permission}"
	if grep -Fxq "$_user" "${TEST_ROOT}/collaborators.txt"; then
		printf 'admin\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "$*" == *"/pulls/"*"/reviews"* ]]; then
	printf '0\n'
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "review" ]]; then
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_helpers_under_test() {
	local dependabot_src=""
	local approve_src=""
	local collab_src=""
	dependabot_src=$(awk '
		/^_trusted_dependabot_updates_conf\(\) \{/,/^}$/ { print }
		/^_trusted_dependabot_dependency_allowed\(\) \{/,/^}$/ { print }
		/^_is_trusted_dependabot_update_pr\(\) \{/,/^}$/ { print }
		/^_trusted_dependabot_non_review_checks_green\(\) \{/,/^}$/ { print }
	' "$GATES_SCRIPT")
	approve_src=$(awk '/^approve_collaborator_pr\(\) \{/,/^}$/ { print }' "$GATES_SCRIPT")
	collab_src=$(awk '/^_is_collaborator_author\(\) \{/,/^}$/ { print }' "$AUTHOR_CHECKS_SCRIPT")
	[[ -n "$dependabot_src" && -n "$approve_src" && -n "$collab_src" ]] || return 1

	_has_maintainer_crypto_approval() { return 1; }
	# shellcheck disable=SC1090
	eval "$collab_src"
	# shellcheck disable=SC1090
	eval "$dependabot_src"
	# shellcheck disable=SC1090
	eval "$approve_src"
	return 0
}

test_trusted_dependabot_passes() {
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]"; then
		print_result "trusted Dependabot update passes narrow gate" 0
		return 0
	fi
	print_result "trusted Dependabot update passes narrow gate" 1 "Expected helper to trust fixture. Log: $(<"$LOGFILE")"
	return 0
}

test_spoofed_author_fails() {
	write_pr_fixture "attacker" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]"; then
		print_result "spoofed Dependabot author fails" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "spoofed Dependabot author fails" 0
	return 0
}

test_security_failure_fails() {
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" "requirements-lock.txt" "FAILURE"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]"; then
		print_result "security-scan failure blocks Dependabot trust" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "security-scan failure blocks Dependabot trust" 0
	return 0
}

test_non_dependency_file_fails() {
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" ".github/workflows/pwn.yml" "SUCCESS"
	if _is_trusted_dependabot_update_pr "24473" "owner/repo" "dependabot[bot]"; then
		print_result "non-dependency file blocks Dependabot trust" 1 "Unexpected trusted result"
		return 0
	fi
	print_result "non-dependency file blocks Dependabot trust" 0
	return 0
}

test_trusted_dependabot_can_be_approved() {
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" "requirements-lock.txt" "SUCCESS"
	approve_collaborator_pr "24473" "owner/repo" "dependabot[bot]" >/dev/null || true
	if grep -qF 'pr review 24473' "$GH_LOG" \
		&& grep -qF 'trusted Dependabot dependency update verified' "$GH_LOG"; then
		print_result "trusted Dependabot PR receives accurate auto-approval" 0
		return 0
	fi
	print_result "trusted Dependabot PR receives accurate auto-approval" 1 "Expected approval call. gh log: $(<"$GH_LOG")"
	return 0
}

test_review_bot_failure_is_ignored_when_other_checks_green() {
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" "requirements-lock.txt" "SUCCESS" "SUCCESS"
	if _trusted_dependabot_non_review_checks_green "24473" "owner/repo"; then
		print_result "review-bot failure ignored when non-review checks green" 0
		return 0
	fi
	print_result "review-bot failure ignored when non-review checks green" 1 "Expected non-review check helper to pass. Log: $(<"$LOGFILE")"
	return 0
}

test_non_review_failure_blocks_required_check_bypass() {
	write_pr_fixture "dependabot[bot]" "dependabot[bot]" "requirements-lock.txt" "SUCCESS" "FAILURE"
	if _trusted_dependabot_non_review_checks_green "24473" "owner/repo"; then
		print_result "non-review failure blocks Dependabot required-check bypass" 1 "Unexpected bypass"
		return 0
	fi
	print_result "non-review failure blocks Dependabot required-check bypass" 0
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	define_helpers_under_test
	test_trusted_dependabot_passes
	test_spoofed_author_fails
	test_security_failure_fails
	test_non_dependency_file_fails
	test_trusted_dependabot_can_be_approved
	test_review_bot_failure_is_ignored_when_other_checks_green
	test_non_review_failure_blocks_required_check_bypass

	printf '\nTests run: %s\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf 'Tests failed: %s\n' "$TESTS_FAILED"
		exit 1
	fi
	printf 'All tests passed.\n'
	return 0
}

main "$@"
