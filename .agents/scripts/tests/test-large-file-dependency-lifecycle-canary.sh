#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/large-file-lifecycle-XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
export REPOS_JSON="${TEST_ROOT}/repos.json"
export LARGE_FILE_LINE_THRESHOLD=2000
mkdir -p "$HOME"
: >"$LOGFILE"

STATE_FILE="${TEST_ROOT}/state.json"
COMMENT_FILE="${TEST_ROOT}/gate-comment.txt"
TARGET_FILE="large-target.sh"
jq -cn '{parent:{number:100,title:"Implement parent",labels:["auto-dispatch","status:available"]},child:{number:42,state:"missing"}}' >"$STATE_FILE"

write_fixture_lines() {
	local target="$1" count="$2" line=0
	: >"$target"
	for ((line = 0; line < count; line++)); do
		printf ':\n' >>"$target"
	done
	return 0
}

write_fixture_lines "${TEST_ROOT}/${TARGET_FILE}" 2050

# shellcheck source=../pulse-dispatch-large-file-gate.sh
source "${SCRIPT_DIR}/pulse-dispatch-large-file-gate.sh"
# shellcheck source=../pulse-triage.sh
source "${SCRIPT_DIR}/pulse-triage.sh"
# shellcheck source=../pulse-repo-meta.sh
source "${SCRIPT_DIR}/pulse-repo-meta.sh"

fail() {
	printf 'FAIL %s\n' "$1" >&2
	exit 1
}

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	[[ "$actual" == "$expected" ]] || fail "${name}: expected=${expected} actual=${actual}"
	printf 'PASS %s\n' "$name"
}

_large_file_gate_create_debt_issue() {
	jq '.child.state = "open"' "$STATE_FILE" >"${STATE_FILE}.next"
	mv "${STATE_FILE}.next" "$STATE_FILE"
	printf '#42 (new)'
	return 0
}

_gh_idempotent_comment() {
	printf '%s\n' "$4" >"$COMMENT_FILE"
	return 0
}

_post_simplification_gate_cleared_comment() { return 0; }

gh() {
	if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
		return 0
	fi
	if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
		local action="" value="" previous=""
		shift 3
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--add-label | --remove-label)
				action="$1"
				value="${2:-}"
				shift 2
				;;
			*) shift ;;
			esac
		done
		if [[ "$value" == "needs-simplification" ]]; then
			if [[ "$action" == "--add-label" ]]; then
				jq '.parent.labels |= (. + ["needs-simplification"] | unique)' "$STATE_FILE" >"${STATE_FILE}.next"
			else
				jq '.parent.labels |= map(select(. != "needs-simplification"))' "$STATE_FILE" >"${STATE_FILE}.next"
			fi
			previous="$STATE_FILE"
			mv "${STATE_FILE}.next" "$previous"
		fi
		return 0
	fi
	return 1
}

gh_issue_view() {
	local jq_filter="" arg="" next_is_jq=0
	for arg in "$@"; do
		if [[ "$next_is_jq" -eq 1 ]]; then
			jq_filter="$arg"
			next_is_jq=0
		elif [[ "$arg" == "--jq" ]]; then
			next_is_jq=1
		fi
	done
	local response=""
	response=$(jq -c '{title:.parent.title,labels:[.parent.labels[] | {name:.}]}' "$STATE_FILE")
	if [[ -n "$jq_filter" ]]; then
		printf '%s' "$response" | jq -r "$jq_filter"
	else
		printf '%s\n' "$response"
	fi
	return 0
}

gh_issue_list() {
	jq -c '[{number:.parent.number,title:.parent.title,url:"https://github.com/owner/repo/issues/100",assignees:[],labels:[.parent.labels[] | {name:.}],createdAt:"2026-05-01T00:00:00Z",updatedAt:"2026-05-01T00:00:00Z"}]' "$STATE_FILE"
	return 0
}

# First unattended cycle: the gate labels the parent, creates the simplification
# dependency, and records the durable relationship in its comment.
_large_file_gate_apply "100" "owner/repo" "${TARGET_FILE} (2050 lines), " "${TARGET_FILE}\\n" "$TEST_ROOT"
assert_eq "large-file gate holds the parent" "true" \
	"$(jq -r '.parent.labels | index("needs-simplification") != null' "$STATE_FILE")"
assert_eq "large-file gate creates the dependency" "open" "$(jq -r '.child.state' "$STATE_FILE")"
grep -q '#42 (new)' "$COMMENT_FILE" || fail "gate comment did not cite the dependency"
printf 'PASS gate comment preserves the parent-dependency link\n'

# The dependency merge lands and closes its issue after shrinking the target.
jq '.child.state = "closed"' "$STATE_FILE" >"${STATE_FILE}.next"
mv "${STATE_FILE}.next" "$STATE_FILE"
write_fixture_lines "${TEST_ROOT}/${TARGET_FILE}" 100

prefetched=$(jq -c '{title:.parent.title,labels:[.parent.labels[] | {name:.}]}' "$STATE_FILE")
gate_rc=0
_issue_targets_large_files "100" "owner/repo" "EDIT: \`${TARGET_FILE}\`" \
	"$TEST_ROOT" true "$prefetched" || gate_rc=$?
assert_eq "dependency completion clears the obsolete gate" "1:false" \
	"${gate_rc}:$(jq -r '.parent.labels | index("needs-simplification") != null' "$STATE_FILE")"

# The next candidate scan sees the same parent as dispatchable without manual
# label repair or direct dispatch intervention.
candidate_json=$(list_dispatchable_issue_candidates_json "owner/repo" 100 "" "" skip)
assert_eq "parent returns to autonomous dispatch enumeration" "100" \
	"$(printf '%s' "$candidate_json" | jq -r '.[0].number')"

printf 'PASS unattended large-file dependency lifecycle returns the parent to dispatchable state\n'
