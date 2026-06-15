#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stats-quality-sweep-simplification-nmr.sh — regression guard for the
# quality-sweep simplification NMR trust boundary.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
TMP=$(mktemp -d -t t-sweep-nmr.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

CREATE_CALLS="${TMP}/create-calls.log"
LOGFILE="${TMP}/pulse.log"
export LOGFILE

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local message="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$name"
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	return 0
}

print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

gh_create_issue() {
	printf '%s\n' "$*" >>"$CREATE_CALLS"
	printf 'https://github.com/test/repo/issues/123\n'
	return 0
}
export -f gh_create_issue

gh() {
	case "$*" in
	*"label create"*)
		return 0
		;;
	*"api graphql"*)
		printf '0\n'
		return 0
		;;
	*"issue list"*)
		printf '0\n'
		return 0
		;;
	esac
	return 0
}
export -f gh

mkdir -p "${TMP}/.config/aidevops"
cat >"${TMP}/.config/aidevops/repos.json" <<'JSON'
{"initialized_repos":[{"slug":"test/repo","maintainer":"maintainer"}]}
JSON
ORIGINAL_HOME="$HOME"
export HOME="$TMP"

# shellcheck source=../stats-quality-sweep.sh
SCRIPT_DIR="$SCRIPTS_DIR" source "${SCRIPTS_DIR}/stats-quality-sweep.sh" 2>/dev/null || {
	printf 'FATAL could not source stats-quality-sweep.sh\n'
	export HOME="$ORIGINAL_HOME"
	exit 1
}

make_sarif() {
	cat <<'JSON'
{"runs":[{"results":[
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]},
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]},
{"ruleId":"complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"src/foo.py"}}}]}
]}]}
JSON
	return 0
}

printf '\n[a] trusted repo writer skips NMR\n'
true >"$CREATE_CALLS"
qlty_section=""
_gh_current_user_allows_repo_write() {
	AIDEVOPS_GH_WRITE_PERMISSION_USER="maintainer"
	AIDEVOPS_GH_WRITE_PERMISSION_LEVEL="admin"
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="allowed"
	export AIDEVOPS_GH_WRITE_PERMISSION_USER AIDEVOPS_GH_WRITE_PERMISSION_LEVEL AIDEVOPS_GH_WRITE_PERMISSION_REASON
	return 0
}
_create_simplification_issues "test/repo" "$(make_sarif)"
if grep -q -- '--label needs-maintainer-review' "$CREATE_CALLS" 2>/dev/null; then
	fail "trusted-writer-no-nmr-label" "unexpected NMR label: $(cat "$CREATE_CALLS")"
else
	pass "trusted-writer-no-nmr-label"
fi

printf '\n[b] unverified identity keeps NMR\n'
true >"$CREATE_CALLS"
qlty_section=""
_gh_current_user_allows_repo_write() {
	AIDEVOPS_GH_WRITE_PERMISSION_REASON="permission-lookup-failed:api-failure"
	export AIDEVOPS_GH_WRITE_PERMISSION_REASON
	return 1
}
_create_simplification_issues "test/repo" "$(make_sarif)"
if grep -q -- '--label needs-maintainer-review' "$CREATE_CALLS" 2>/dev/null; then
	pass "unverified-keeps-nmr-label"
else
	fail "unverified-keeps-nmr-label" "missing NMR label: $(cat "$CREATE_CALLS")"
fi

export HOME="$ORIGINAL_HOME"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed.\n' "$TESTS_RUN"
	exit 0
fi
printf '%d of %d tests FAILED.\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
