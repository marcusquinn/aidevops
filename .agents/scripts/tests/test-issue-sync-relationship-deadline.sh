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

deadline_probe() {
	printf 'called\n' >>"${TMP_DIR}/deadline-probe.log"
	return 0
}

: >"${TMP_DIR}/deadline-probe.log"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) - 1 ))
deadline_rc=0
_gh_with_timeout read deadline_probe || deadline_rc=$?
[[ "$deadline_rc" -eq 124 ]] || fail "expired aggregate deadline did not return 124"
[[ ! -s "${TMP_DIR}/deadline-probe.log" ]] || fail "expired aggregate deadline invoked the child command"
pass "expired aggregate deadline stops before the next GitHub call"

cat >"${TMP_DIR}/slow-command" <<'SLOW_EOF'
#!/usr/bin/env bash
sleep 5
printf 'late\n'
SLOW_EOF
chmod +x "${TMP_DIR}/slow-command"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 1 ))
started_at=$(date +%s)
slow_rc=0
_gh_with_timeout write "${TMP_DIR}/slow-command" >/dev/null 2>&1 || slow_rc=$?
elapsed=$(( $(date +%s) - started_at ))
[[ "$slow_rc" -eq 124 ]] || fail "remaining aggregate budget did not cap a slow child"
[[ "$elapsed" -le 3 ]] || fail "slow child exceeded aggregate deadline allowance (${elapsed}s)"
pass "remaining aggregate budget caps an individual slow call"

unset AIDEVOPS_GH_DEADLINE_EPOCH
_init_relationship_sync_state || fail "relationship invocation state did not initialize"
AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) + 30 ))
DRY_RUN=true

resolve_task_gh_number() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$todo_file" "$repo"
	case "$task_id" in
	t1) printf '101\n' ;;
	t2) printf '102\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_cached_node_id() {
	local issue_num="$1"
	local repo="$2"
	: "$repo"
	printf 'NODE_%s\n' "$issue_num"
	return 0
}

_dependency_cycle_should_skip_edge() {
	local blocked_task="$1"
	local blocker_task="$2"
	local blocked_num="$3"
	local blocker_num="$4"
	local todo_file="$5"
	: "$blocked_task" "$blocker_task" "$blocked_num" "$blocker_num" "$todo_file"
	return 1
}

first_result=$(_sync_declared_blocked_by_edges t1 "${TMP_DIR}/TODO.md" example/repo 101 NODE_101 t2)
reciprocal_result=$(_sync_declared_blocks_edges t2 "${TMP_DIR}/TODO.md" example/repo 102 NODE_102 t1)
[[ "$first_result" == "1:0" ]] || fail "first normalized edge was not attempted once: $first_result"
[[ "$reciprocal_result" == "0:0" ]] || fail "reciprocal declaration replayed normalized edge: $reciprocal_result"
[[ "$(wc -l <"$_RELATIONSHIP_EDGE_SEEN_FILE" | tr -d '[:space:]')" -eq 1 ]] || fail "edge set did not retain exactly one normalized edge"
pass "reciprocal declarations attempt one normalized native edge"

AIDEVOPS_GH_DEADLINE_EPOCH=$(( $(date +%s) - 1 ))
expired_result=$(_sync_declared_blocked_by_edges t1 "${TMP_DIR}/TODO.md" example/repo 101 NODE_101 t2,t3,t4)
[[ "$expired_result" == "0:1" ]] || fail "expired edge loop did not stop with retryable state: $expired_result"
pass "edge loop stops with retryable state after aggregate exhaustion"

MAPPING_LOG="${TMP_DIR}/mapping.log"
: >"$MAPPING_LOG"
_PUSH_CREATED_NUM=123
add_gh_ref_to_todo() {
	local task_id="$1"
	local issue_num="$2"
	local todo_file="$3"
	printf 'mapped:%s:%s:%s\n' "$task_id" "$issue_num" "$todo_file" >>"$MAPPING_LOG"
	return 0
}
require_task_issue_mapping() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	local issue_num="$4"
	: "$task_id" "$todo_file" "$repo" "$issue_num"
	return 0
}
sync_relationships_for_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$task_id" "$todo_file" "$repo"
	return 1
}
finalize_output=$(_push_finalize_task_creation t1 example/repo "${TMP_DIR}/TODO.md" "title" "" "bug" "body" 2>"${TMP_DIR}/finalize.err")
[[ "$finalize_output" == *"CREATED RELATIONSHIPS_PENDING"* ]] || fail "post-create pending result was not actionable"
grep -q '^mapped:t1:123:' "$MAPPING_LOG" || fail "durable mapping was not preserved before pending relationship result"
grep -q 'durable mapping preserved' "${TMP_DIR}/finalize.err" || fail "pending result omitted durable-mapping diagnostic"
pass "post-create relationship timeout preserves mapping and reports pending recovery"

printf 'PASS: issue-sync relationship aggregate deadline regressions\n'
