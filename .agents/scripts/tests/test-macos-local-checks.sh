#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bounded synthetic host/API tests; these do not claim native macOS execution.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../macos-local-checks.sh
source "$SCRIPT_DIR/macos-local-checks.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export AIDEVOPS_REPOS_CONFIG="$WORK/repos.json"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","maintainer":"default-user","macos_maintainer":"mac-user"}]}' >"$AIDEVOPS_REPOS_CONFIG"
changed='.agents/scripts/model-replay-process.mjs'
fake_host=Linux
diff_rc=0
review_rc=0

git() {
	local operation="$1"
	case "$operation" in
	diff) printf '%s\n' "$changed"; return "$diff_rc" ;;
	rev-parse) printf '%s\n' test-head ;;
	*) return 1 ;;
	esac
	return 0
}
uname() {
	printf '%s\n' "$fake_host"
	return 0
}
gh() {
	local args="$*"
	printf '%s\n' "$args" >>"$WORK/calls"
	if [[ "$args" == *--add-reviewer* ]]; then
		return "$review_rc"
	fi
	if [[ "$args" == *'--json reviewRequests'* && "$review_rc" -eq 0 ]]; then
		printf '%s\n' mac-user default-user
	fi
	return 0
}
macos_checks_run() {
	printf '%s\n' native-run >>"$WORK/native"
	return "${native_rc:-0}"
}

evidence=$(macos_checks_evidence base)
[[ "$evidence" == *'not run on this host'* ]]
macos_checks_route base 123 owner/repo
command grep -q -- '--add-label needs-macos-verification' "$WORK/calls"
command grep -q -- '--add-reviewer mac-user' "$WORK/calls"
review_rc=1
macos_checks_route base 123 owner/repo
command grep -q -- '--add-assignee mac-user' "$WORK/calls"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","maintainer":"default-user"}]}' >"$AIDEVOPS_REPOS_CONFIG"
macos_checks_route base 123 owner/repo
command grep -q -- '--add-reviewer default-user' "$WORK/calls"
changed=README.md
[[ -z "$(macos_checks_evidence base)" ]]
rm "$WORK/calls"
macos_checks_route base 123 owner/repo
[[ ! -e "$WORK/calls" ]]
changed='.agents/scripts/sandbox-exec-helper.sh'
fake_host=Darwin
[[ "$(macos_checks_evidence base)" == *'passed at test-head'* ]]
[[ -e "$WORK/native" ]]
native_rc=1
if macos_checks_evidence base; then exit 1; fi
native_rc=0
export AIDEVOPS_MACOS_CHECKS_HOST=Linux
[[ "$(macos_checks_evidence base)" == *'not run on this host'* ]]
fake_host=Linux
export AIDEVOPS_MACOS_CHECKS_HOST=Darwin
[[ "$(macos_checks_evidence base)" == *'not run on this host'* ]]
printf '%s\n' '{"initialized_repos":[]}' >"$AIDEVOPS_REPOS_CONFIG"
if macos_checks_route base 123 owner/repo; then exit 1; fi
diff_rc=1
if macos_checks_evidence bad-base; then exit 1; fi
if macos_checks_route bad-base 123 owner/repo; then exit 1; fi
printf '%s\n' 'PASS: sensitive/no-op detection, native failure, host override, maintainer override/fallback, review/assignment and fail-closed diff'
