#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../issue-sync-helper.sh
source "${SCRIPTS_DIR}/issue-sync-helper.sh"

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

LINK_LOG="${TMP_DIR}/links.log"
: >"$LINK_LOG"

_link_sub_issue_pair() {
	local child_id="$1"
	local parent_id="$2"
	local todo_file="$3"
	local repo="$4"
	: "$todo_file" "$repo"
	[[ "$parent_id" != "t999" ]] || return 1
	printf '%s:%s\n' "$child_id" "$parent_id" >>"$LINK_LOG"
	return 0
}

cat >"${TMP_DIR}/TODO.md" <<'EOF'
- [ ] t100 Parent #parent ref:GH#100
- [ ] t200 Explicit child parent:t100 ref:GH#200
- [ ] t100.1 Dotted child ref:GH#201
- [ ] t100.2 Matching sources parent:t100 ref:GH#202
- [ ] t300 Other parent #parent ref:GH#300
- [ ] t100.3 Conflicting sources parent:t300 ref:GH#203
- [ ] t400 Legacy child blocked-by:t100 ref:GH#400
- [ ] t500 Self child parent:t500 ref:GH#500
- [ ] t600 Unresolved child parent:t999 ref:GH#600
EOF

_init_relationship_sync_state || fail "relationship state initialization failed"
AIDEVOPS_GH_DEADLINE_EPOCH=$(($(date +%s) + 30))

explicit_result=$(_sync_subtask_hierarchy_for_task t200 "${TMP_DIR}/TODO.md" example/repo)
[[ "$explicit_result" == "RELS:1 RETRYABLE:0" ]] || fail "explicit parent was not linked: $explicit_result"
grep -qx 't200:t100' "$LINK_LOG" || fail "explicit parent link was not recorded"
pass "explicit parent metadata creates one hierarchy link"

dotted_result=$(_sync_subtask_hierarchy_for_task t100.1 "${TMP_DIR}/TODO.md" example/repo)
[[ "$dotted_result" == "RELS:1 RETRYABLE:0" ]] || fail "dotted parent regressed: $dotted_result"
pass "dotted hierarchy remains supported"

matching_result=$(_sync_subtask_hierarchy_for_task t100.2 "${TMP_DIR}/TODO.md" example/repo)
[[ "$matching_result" == "RELS:1 RETRYABLE:0" ]] || fail "matching parent sources were not deduplicated: $matching_result"
[[ "$(grep -c '^t100.2:t100$' "$LINK_LOG")" -eq 1 ]] || fail "matching sources attempted duplicate links"
pass "matching explicit and dotted parents deduplicate"

legacy_result=$(_sync_subtask_hierarchy_for_task t400 "${TMP_DIR}/TODO.md" example/repo)
[[ "$legacy_result" == "RELS:1 RETRYABLE:0" ]] || fail "legacy parent-tagged blocker regressed: $legacy_result"
pass "parent-tagged blockers remain supported"

conflict_result=$(_sync_subtask_hierarchy_for_task t100.3 "${TMP_DIR}/TODO.md" example/repo)
[[ "$conflict_result" == "RELS:0 RETRYABLE:1" ]] || fail "conflicting parents did not fail closed: $conflict_result"
! grep -q '^t100.3:' "$LINK_LOG" || fail "conflicting parents mutated a relationship"
pass "conflicting parent sources fail before mutation"

self_result=$(_sync_subtask_hierarchy_for_task t500 "${TMP_DIR}/TODO.md" example/repo)
[[ "$self_result" == "RELS:0 RETRYABLE:1" ]] || fail "self parent did not fail closed: $self_result"
! grep -q '^t500:' "$LINK_LOG" || fail "self parent mutated a relationship"
pass "self-referential parent fails before mutation"

# The sourced production function is intentionally replaced below for the
# independent bulk-selection probe.
# shellcheck disable=SC2218
unresolved_result=$(_sync_subtask_hierarchy_for_task t600 "${TMP_DIR}/TODO.md" example/repo)
[[ "$unresolved_result" == "RELS:0 RETRYABLE:1" ]] || fail "unresolved parent did not remain retryable: $unresolved_result"
pass "unresolved explicit parent reports retryable failure"

_cleanup_relationship_sync_state

BULK_LOG="${TMP_DIR}/bulk.log"
: >"$BULK_LOG"
_init_cmd() {
	_CMD_REPO="example/repo"
	_CMD_TODO="${TMP_DIR}/TODO.md"
	return 0
}
_sync_blocked_by_for_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$todo_file" "$repo"
	printf 'blocked:%s\n' "$task_id" >>"$BULK_LOG"
	printf 'RELS:0 RETRYABLE:0\n'
	return 0
}
_sync_subtask_hierarchy_for_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$todo_file" "$repo"
	printf 'hierarchy:%s\n' "$task_id" >>"$BULK_LOG"
	printf 'RELS:0 RETRYABLE:0\n'
	return 0
}

cmd_relationships >/dev/null
grep -qx 'hierarchy:t200' "$BULK_LOG" || fail "bulk sync omitted parent-only task"
pass "bulk relationship sync includes parent-only tasks"
