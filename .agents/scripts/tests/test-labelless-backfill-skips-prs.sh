#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: labelless backfill must not bless pull requests as
# origin:worker. PRs share the Issues API namespace, and mislabelling an
# interactive PR as worker-origin lets the merge/dispatch loop close it and
# open a replacement worker PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
RECONCILE_SCRIPT="${SCRIPT_DIR}/../pulse-issue-reconcile.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_ROOT=""
GH_LOG=""
LOGFILE=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	exit 1
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	GH_LOG="${TEST_ROOT}/gh.log"
	LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$GH_LOG"
	: >"$LOGFILE"
	export TEST_ROOT GH_LOG LOGFILE

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123" ]]; then
	printf '{"author_association":"OWNER","pull_request":{"url":"https://api.example.invalid/pulls/123"}}\n'
	exit 0
fi

if [[ "$1" == "issue" && "$2" == "view" ]]; then
	printf '\n'
	exit 0
fi

if [[ "$1" == "label" && "$2" == "create" ]]; then
	exit 0
fi

if [[ "$1" == "issue" && "$2" == "edit" ]]; then
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

main() {
	setup_test_env
	SCRIPT_DIR="$(cd "$(dirname "$RECONCILE_SCRIPT")" && pwd)" || exit
	# shellcheck source=/dev/null
	source "$RECONCILE_SCRIPT"

	_PIR_BOOL_TRUE=true
	_PIR_BOOL_FALSE=false
	_PIR_ADD_LABEL_FLAG=--add-label
	_PIR_REMOVE_LABEL_FLAG=--remove-label
	ensure_origin_labels_exist() { return 0; }
	gh_issue_comment() { return 0; }

	local result=0
	_action_lia_single "owner/repo" "123" "GH#123: interactive PR" "body" "" && result=0 || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "labelless backfill skips pull requests" 1 "expected non-zero return for PR target"
	fi
	if grep -q "gh issue edit" "$GH_LOG"; then
		print_result "labelless backfill skips pull requests" 1 "unexpected label mutation for PR target"
	fi
	if ! grep -q "skipped PR #123" "$LOGFILE"; then
		print_result "labelless backfill skips pull requests" 1 "expected skip log not found"
	fi

	print_result "labelless backfill skips pull requests" 0
	teardown_test_env
	return 0
}

main "$@"
