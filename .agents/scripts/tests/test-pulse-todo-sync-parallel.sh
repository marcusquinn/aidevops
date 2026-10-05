#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TEST_TMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TMP_PARENT"
TEST_ROOT="$(mktemp -d "${TEST_TMP_PARENT}/pulse-todo-sync-parallel-XXXXXX")"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export WRAPPER_LOGFILE="${TEST_ROOT}/pulse-wrapper.log"
export LOGFILE="$WRAPPER_LOGFILE"
export REPOS_JSON="${TEST_ROOT}/repos.json"
export SCRIPT_DIR="$SCRIPTS_DIR"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"
: >"$WRAPPER_LOGFILE"

# shellcheck source=../pulse-wrapper-cycle.sh
source "${SCRIPTS_DIR}/pulse-wrapper-cycle.sh"
real_sync_definition=$(declare -f sync_todo_refs_for_repo)

repo_json='[]'
for repo_number in 1 2 3 4 5 6; do
	repo_path="${TEST_ROOT}/repo-${repo_number}"
	mkdir -p "$repo_path"
	repo_json=$(jq -cn \
		--argjson repos "$repo_json" \
		--arg slug "owner/repo-${repo_number}" \
		--arg path "$repo_path" \
		'$repos + [{slug:$slug,path:$path,pulse:true,local_only:false}]')
done
jq -cn --argjson repos "$repo_json" '{initialized_repos:$repos}' >"$REPOS_JSON"

ACTIVE_DIR="${TEST_ROOT}/active"
COUNTER_LOCK="${TEST_ROOT}/counter.lock"
CALL_LOG="${TEST_ROOT}/calls.log"
TIMEOUT_LOG="${TEST_ROOT}/timeouts.log"
MAX_ACTIVE_FILE="${TEST_ROOT}/max-active"
mkdir -p "$ACTIVE_DIR"
printf '0\n' >"$MAX_ACTIVE_FILE"
: >"$CALL_LOG"
: >"$TIMEOUT_LOG"

_test_counter_lock_acquire() {
	while ! mkdir "$COUNTER_LOCK" 2>/dev/null; do
		sleep 0.01
	done
	return 0
}

_test_counter_lock_release() {
	rmdir "$COUNTER_LOCK" 2>/dev/null || true
	return 0
}

_test_active_count() {
	local active_file="" active_count=0
	for active_file in "$ACTIVE_DIR"/job.*; do
		[[ -f "$active_file" ]] || continue
		active_count=$((active_count + 1))
	done
	printf '%s\n' "$active_count"
	return 0
}

_pulse_refresh_repo() {
	local repo_path="$1"
	: "$repo_path"
	return 0
}

run_stage_with_timeout() {
	local stage_name="$1"
	local timeout_secs="$2"
	shift 2
	printf '%s|%s\n' "$stage_name" "$timeout_secs" >>"$TIMEOUT_LOG"
	"$@"
	return $?
}

sync_todo_refs_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local safe_slug="" active_file="" active_count=0 max_active=0
	: "$repo_path"
	safe_slug=$(printf '%s' "$repo_slug" | tr '/' '_')
	active_file="${ACTIVE_DIR}/job.${safe_slug}"
	_test_counter_lock_acquire
	: >"$active_file"
	printf '%s\n' "$repo_slug" >>"$CALL_LOG"
	active_count=$(_test_active_count)
	max_active=$(<"$MAX_ACTIVE_FILE")
	if [[ "$active_count" -gt "$max_active" ]]; then
		printf '%s\n' "$active_count" >"$MAX_ACTIVE_FILE"
	fi
	_test_counter_lock_release
	sleep 0.2
	_test_counter_lock_acquire
	rm -f "$active_file"
	_test_counter_lock_release
	[[ "$repo_slug" != "owner/repo-5" ]]
	return $?
}

export PULSE_TODO_SYNC_PARALLELISM=2
export PULSE_TODO_SYNC_REPO_TIMEOUT=7
export PRE_RUN_STAGE_TIMEOUT=30

unset PULSE_TODO_SYNC_REPO_TIMEOUT
[[ "$(_pulse_todo_sync_repo_timeout)" -eq 30 ]] || {
	printf 'FAIL default per-repo timeout did not inherit the enclosing stage ceiling\n' >&2
	exit 1
}
export PULSE_TODO_SYNC_REPO_TIMEOUT=7

sync_rc=0
sync_todo_refs_all_repos || sync_rc=$?
call_count=$(wc -l <"$CALL_LOG" | tr -d ' ')
timeout_count=$(wc -l <"$TIMEOUT_LOG" | tr -d ' ')
max_active=$(<"$MAX_ACTIVE_FILE")
remaining_active=$(_test_active_count)

[[ "$sync_rc" -eq 1 ]] || {
	printf 'FAIL aggregate sync did not preserve a child failure: rc=%s\n' "$sync_rc" >&2
	exit 1
}
[[ "$call_count" -eq 6 && "$timeout_count" -eq 6 ]] || {
	printf 'FAIL aggregate sync did not run all repositories: calls=%s timeouts=%s\n' \
		"$call_count" "$timeout_count" >&2
	exit 1
}
[[ "$max_active" -eq 2 && "$remaining_active" -eq 0 ]] || {
	printf 'FAIL aggregate sync violated its concurrency bound: max=%s remaining=%s\n' \
		"$max_active" "$remaining_active" >&2
	exit 1
}
if grep -Evq '\|7$' "$TIMEOUT_LOG"; then
	printf 'FAIL aggregate sync did not apply the configured per-repo timeout\n' >&2
	exit 1
fi
grep -q 'scheduled=6 failures=1 parallelism=2 per_repo_timeout=7s' "$WRAPPER_LOGFILE" || {
	printf 'FAIL aggregate sync omitted bounded batch telemetry\n' >&2
	exit 1
}

# A retry must consume only time remaining in the aggregate stage. Simulate a
# retryable first pass that leaves three seconds after the five-second guard;
# the old code would incorrectly grant a fresh ten-second per-repo timeout.
original_sync_definition=$(declare -f sync_todo_refs_for_repo)
retry_repos_json="${TEST_ROOT}/retry-repos.json"
jq -cn --arg slug owner/repo-retry --arg path "${TEST_ROOT}/repo-1" \
	'{initialized_repos:[{slug:$slug,path:$path,pulse:true,local_only:false}]}' >"$retry_repos_json"
export REPOS_JSON="$retry_repos_json"
export PRE_RUN_STAGE_TIMEOUT=15
export PULSE_TODO_SYNC_REPO_TIMEOUT=10
export PULSE_TODO_SYNC_RETRY_TIMEOUT=10
: >"$TIMEOUT_LOG"
TEST_NOW=100
date() {
	local format="${1:-}"
	if [[ "$format" == "+%s" ]]; then
		printf '%s\n' "$TEST_NOW"
		return 0
	fi
	command date "$@"
	return $?
}
sync_todo_refs_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	: "$repo_slug" "$repo_path"
	retry_attempt=$((retry_attempt + 1))
	if [[ "$retry_attempt" -eq 1 ]]; then
		TEST_NOW=107
		return 25
	fi
	return 0
}
retry_attempt=0
retry_rc=0
sync_todo_refs_all_repos || retry_rc=$?
eval "$original_sync_definition"
unset -f date
[[ "$retry_rc" -eq 0 ]] || {
	printf 'FAIL aggregate retry did not complete within its shared budget: rc=%s\n' "$retry_rc" >&2
	exit 1
}
if ! grep -qx 'sync_todo_refs_repo_1|5' "$TIMEOUT_LOG" || ! grep -qx 'sync_todo_refs_repo_1|3' "$TIMEOUT_LOG"; then
	printf 'FAIL aggregate retry received a fresh per-repo timeout\n' >&2
	exit 1
fi
grep -q 'status=retrying repo=owner/repo-retry attempt=2 reason=remote_advanced timeout=3s' "$WRAPPER_LOGFILE" || {
	printf 'FAIL aggregate retry omitted remaining-budget diagnostics\n' >&2
	exit 1
}

# An unchanged typed mismatch has no safe recreate action. It must remain a
# truthful child failure without consuming the bounded remote-advance retry.
: >"$CALL_LOG"
: >"$TIMEOUT_LOG"
sync_todo_refs_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	: "$repo_path"
	printf '%s\n' "$repo_slug" >>"$CALL_LOG"
	return 24
}
unchanged_rc=0
_pulse_sync_todo_repo_bounded owner/repo-unchanged "${TEST_ROOT}/repo-1" 10 1 || unchanged_rc=$?
eval "$original_sync_definition"
[[ "$unchanged_rc" -eq 24 ]] || {
	printf 'FAIL unchanged snapshot mismatch lost its typed result: rc=%s\n' "$unchanged_rc" >&2
	exit 1
}
[[ $(wc -l <"$CALL_LOG" | tr -d ' ') -eq 1 ]] || {
	printf 'FAIL unchanged snapshot mismatch consumed a useless recreation retry\n' >&2
	exit 1
}

# Absent root TODO.md: skip only when trusted registration metadata says
# planning is not enabled; every other case stays a visible failure, and a
# present legacy TODO keeps running all sync stages. Owned workspaces are
# always cleaned.
absent_remote="${TEST_ROOT}/absent-remote.git"
absent_clone="${TEST_ROOT}/absent-clone"
legacy_remote="${TEST_ROOT}/legacy-remote.git"
legacy_clone="${TEST_ROOT}/legacy-clone"
for fixture in "absent:$absent_remote:$absent_clone:README.md" "legacy:$legacy_remote:$legacy_clone:TODO.md"; do
	IFS=: read -r _fx_name fx_remote fx_clone fx_file <<<"$fixture"
	/usr/bin/git init --bare --quiet --initial-branch=main "$fx_remote"
	/usr/bin/git clone --quiet "$fx_remote" "$fx_clone" 2>/dev/null
	/usr/bin/git -C "$fx_clone" config user.email test@example.com
	/usr/bin/git -C "$fx_clone" config user.name Test
	/usr/bin/git -C "$fx_clone" config commit.gpgsign false
	printf '%s\n' '- [ ] t1 fixture' >"${fx_clone}/${fx_file}"
	/usr/bin/git -C "$fx_clone" add "$fx_file"
	/usr/bin/git -C "$fx_clone" commit --quiet -m seed
	/usr/bin/git -C "$fx_clone" push --quiet origin main
	/usr/bin/git --git-dir="$fx_remote" symbolic-ref HEAD refs/heads/main
done
STAGE_LOG="${TEST_ROOT}/stages.log"
export REPOS_JSON="${TEST_ROOT}/planning-repos.json"
eval "$real_sync_definition"
original_stage_definition=$(declare -f _pulse_run_issue_sync_stage)
_pulse_run_issue_sync_stage() {
	printf '%s\n' "$2" >>"$STAGE_LOG"
	return 1
}
write_planning_repos() {
	local features_json="$1"
	jq -cn --argjson features "$features_json" --arg path "$absent_clone" \
		'{initialized_repos:[{slug:"owner/absent",path:$path,pulse:true,features:$features}]}' >"$REPOS_JSON"
	return 0
}
run_absent_case() {
	local expected_rc="$1" expected_log="$2" case_rc=0
	: >"$STAGE_LOG"
	: >"$WRAPPER_LOGFILE"
	sync_todo_refs_for_repo owner/absent "$absent_clone" || case_rc=$?
	[[ "$case_rc" -eq "$expected_rc" ]] || {
		printf 'FAIL absent TODO case expected rc=%s got %s (%s)\n' "$expected_rc" "$case_rc" "$expected_log" >&2
		exit 1
	}
	grep -q "$expected_log" "$WRAPPER_LOGFILE" || {
		printf 'FAIL absent TODO case missing log %s\n' "$expected_log" >&2
		exit 1
	}
	[[ ! -s "$STAGE_LOG" ]] || {
		printf 'FAIL absent TODO case ran issue-sync stages\n' >&2
		exit 1
	}
	grep -q 'workspace cleanup outcome=removed' "$WRAPPER_LOGFILE" || {
		printf 'FAIL absent TODO case did not clean its workspace\n' >&2
		exit 1
	}
	return 0
}
write_planning_repos '["code-quality"]'
run_absent_case 0 'status=skipped reason=planning_not_enabled repo=owner/absent'
write_planning_repos '["code-quality","planning"]'
run_absent_case 1 'reason=missing_planning_file repo=owner/absent'
write_planning_repos '"planning"'
run_absent_case 1 'reason=planning_intent_unknown repo=owner/absent'
jq -cn --arg path "$absent_clone" \
	'{initialized_repos:[{slug:"owner/absent",path:$path,features:["planning"]},{slug:"owner/absent",path:$path,features:[]}]}' >"$REPOS_JSON"
run_absent_case 1 'reason=planning_intent_contradictory repo=owner/absent'
rm -f "$REPOS_JSON"
run_absent_case 1 'reason=planning_intent_unknown repo=owner/absent'

: >"$STAGE_LOG"
legacy_rc=0
sync_todo_refs_for_repo owner/legacy "$legacy_clone" || legacy_rc=$?
[[ "$legacy_rc" -eq 1 && $(wc -l <"$STAGE_LOG" | tr -d ' ') -eq 4 ]] || {
	printf 'FAIL present legacy TODO did not run all sync stages: rc=%s\n' "$legacy_rc" >&2
	exit 1
}
eval "$original_stage_definition"
unset -f write_planning_repos run_absent_case
eval "$original_sync_definition"
export REPOS_JSON="$retry_repos_json"

# The aggregate deadline is capped before spawning any repository job.
# shellcheck source=../pulse-watchdog.sh
source "${SCRIPTS_DIR}/pulse-watchdog.sh"
PULSE_START_EPOCH=0 PULSE_STALE_THRESHOLD=1800 PULSE_LOCK_MAX_AGE_S=1100
date() { [[ "${1:-}" == '+%s' ]] || return 1; printf '1000\n'; return 0; }
_pulse_sync_todo_repo_bounded() { printf '%s\n' "$5" >>"$CALL_LOG"; return 0; }
: >"$CALL_LOG"
sync_todo_refs_all_repos
unset -f date
[[ "$(<"$CALL_LOG")" == 1010 ]] || {
	printf 'FAIL TODO aggregate deadline exceeded cycle budget: %s\n' "$(<"$CALL_LOG")" >&2
	exit 1
}

printf 'PASS TODO reference sync uses bounded parallel jobs and preserves aggregate retry budgets\n'
