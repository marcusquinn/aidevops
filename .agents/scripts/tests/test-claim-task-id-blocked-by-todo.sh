#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# GH#33159: TODO dependencies must remain strict task IDs, not GitHub refs.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../claim-task-id.sh
source "${TEST_DIR}/../claim-task-id.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
git -C "$TEST_TMP" init -q
git -C "$TEST_TMP" remote add origin https://github.com/example/project.git

# No network writes or real API calls. Verify the existing read-wrapper contract.
gh_issue_view() {
	local issue_num="$1"
	shift
	[[ "$*" == "--repo example/project --json title --jq .title" ]] || return 1
	printf '%s\n' "$issue_num" >>"${TEST_TMP}/api-calls"
	case "$issue_num" in
	202) printf 't72: remote predecessor\n' ;;
	203) printf 'Untracked issue without task prefix\n' ;;
	204) return 1 ;;
	205) printf 't0: invalid task prefix\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_repo_path_is_canonical_checkout() {
	[[ "${TEST_CANONICAL:-false}" == true ]] && return 0
	return 1
}

check_line() {
	local description="$1"
	local expected="$2"
	local labels="${3:-bug}"
	local line parsed
	printf '# TODO\n\n## Backlog\n- [ ] t71 local predecessor ref:GH#201\n- [ ] t99 prefix decoy ref:GH#2010\n' >"${TEST_TMP}/TODO.md"
	TASK_DESCRIPTION="$description"
	NO_BLOCKED_BY=false
	DRY_RUN=false
	_apply_blocked_by_detection
	local original_refs="$_CLAIM_BLOCKED_BY_REFS"
	_ensure_todo_entry_written t80 300 'follow-up work' "$labels" "$TEST_TMP" 2>"${TEST_TMP}/warnings"
	[[ "$_CLAIM_BLOCKED_BY_REFS" == "$original_refs" ]]
	if [[ "${TEST_CANONICAL:-false}" == true ]]; then
		line=$(grep '^- \[ \] t80 ' "${TEST_TMP}/warnings")
		if grep -q 't80' "${TEST_TMP}/TODO.md"; then
			printf 'FAIL: canonical TODO was modified\n' >&2
			exit 1
		fi
	else
		line=$(grep '^- \[ \] t80 ' "${TEST_TMP}/TODO.md")
	fi
	[[ "$line" != *'blocked-by:GH#'* ]]
	[[ "$line" != *'#blocked-by:'* ]]
	local dependency_fields=0 field
	for field in $line; do
		[[ "$field" != blocked-by:* ]] || dependency_fields=$((dependency_fields + 1))
	done
	if [[ -n "$expected" ]]; then
		[[ "$dependency_fields" -eq 1 ]]
	else
		[[ "$dependency_fields" -eq 0 ]]
	fi
	parsed=$(parse_task_line "$line")
	grep -qx "blocked_by=${expected}" <<<"$parsed"
	if [[ "$labels" == *enhancement* ]]; then
		[[ "$line" == *' #bug #feat #auto-dispatch #security '* ]]
		[[ "$line" != *'#status:'* && "$line" != *'#tier:'* && "$line" != *'#origin:'* ]]
		[[ "$line" != *'#dispatched:'* && "$line" != *'#implemented:'* && "$line" != *'#aidevops:'* ]]
	fi
	printf 'PASS: %s -> blocked_by=%s\n' "$description" "$expected"
	return 0
}

check_line 'Follow-up from GH#201' t71
[[ ! -f "${TEST_TMP}/api-calls" ]]
check_line 'Follow-up from GH#202' t72
check_line 'blocked-by:t71' t71
check_line 'Follow-up from GH#201; tracked in GH#202; blocked-by:t71' t71,t72
check_line 'Follow-up from GH#203' ''
grep -q 'Cannot resolve predecessor GH#203' "${TEST_TMP}/warnings"
check_line 'Follow-up from GH#204' ''
grep -q 'Cannot resolve predecessor GH#204' "${TEST_TMP}/warnings"
check_line 'Follow-up from GH#205' ''
grep -q 'Cannot resolve predecessor GH#205' "${TEST_TMP}/warnings"
check_line 'Follow-up from GH#201; tracked in GH#203' t71
grep -q 'Cannot resolve predecessor GH#203' "${TEST_TMP}/warnings"
check_line 'Independent description' t71 'bug,blocked-by:t71'
check_line 'Independent description' t71,t72 'blocked-by:t71,blocked-by:t72'
check_line 'Independent description' t71 'blocked-by:GH#201'
check_line 'blocked-by:t71' t71 'bug,blocked-by:t71,blocked-by:t71'
check_line 'Follow-up from GH#201' t71 'blocked-by:t71'
check_line 'blocked-by:t71' t71,t72 'blocked-by:GH#202'
check_line 'Independent description' t71 ' bug , enhancement , auto-dispatch , security , status:available,tier:standard,origin:worker,dispatched:standard,implemented:standard,aidevops:test, blocked-by:t71 '
TEST_CANONICAL=true
check_line 'Follow-up from GH#202' t72
check_line 'Independent description' t71 'bug,blocked-by:t71'
printf 'All blocked-by TODO checks passed\n'
