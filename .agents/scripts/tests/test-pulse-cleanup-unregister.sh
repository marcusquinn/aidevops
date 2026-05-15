#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for pulse cleanup permanent removal guards:
# - current-cwd worktrees are skipped before deletion
# - eligible orphan worktrees are removed permanently and unregistered

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/pulse.log"
export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup_worktrees.log"
UNREGISTER_LOG="${TEST_ROOT}/unregister.log"

# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

is_worktree_owned_by_others() { return 1; }
unregister_worktree() {
	local wt_path="$1"
	printf '%s\n' "$wt_path" >>"$UNREGISTER_LOG"
	return 0
}

# shellcheck source=../pulse-cleanup.sh
source "${SCRIPT_DIR}/pulse-cleanup.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

make_repo_with_worktree() {
	local repo_path="$1"
	local wt_path="$2"
	local branch="$3"

	mkdir -p "$repo_path"
	git -C "$repo_path" init -q -b main
	printf 'base\n' >"${repo_path}/README.md"
	git -C "$repo_path" add README.md
	git -C "$repo_path" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
	git -C "$repo_path" worktree add -q -b "$branch" "$wt_path" main
	touch -t 202001010000 "${wt_path}/.git"
	return 0
}

test_current_cwd_skip() {
	local repo_path="${TEST_ROOT}/repo-cwd"
	local wt_path="${TEST_ROOT}/wt-cwd"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/cwd"

	(
		cd "$wt_path"
		if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/cwd" "$(date +%s)" "" "main"; then
			exit 1
		fi
	)

	[[ -d "$wt_path" ]] || fail "current cwd worktree was removed"
	grep -q 'current-worktree.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" || fail "current-cwd skip was not audited"
	pass "pulse cleanup skips current cwd worktree"
	return 0
}

test_orphan_removal_unregisters() {
	local repo_path="${TEST_ROOT}/repo-remove"
	local wt_path="${TEST_ROOT}/wt-remove"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/remove"

	_cleanup_single_worktree "$repo_path" "$wt_path" "feature/remove" "$(date +%s)" "" "main" \
		|| fail "eligible orphan worktree was not removed"

	[[ ! -e "$wt_path" ]] || fail "eligible orphan worktree still exists"
	grep -Fxq "$wt_path" "$UNREGISTER_LOG" || fail "worktree unregister was not called"
	grep -q 'age-eligible.*mode=permanent' "$AIDEVOPS_CLEANUP_LOG" || fail "permanent removal was not audited"
	pass "pulse cleanup permanently removes and unregisters eligible orphan"
	return 0
}

write_kill_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/kill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${KILL_LOG:?}"
exit 0
STUB
	chmod +x "${bin_dir}/kill"
	return 0
}

write_ledger_stub() {
	local scripts_dir="$1"
	local mode="$2"
	mkdir -p "$scripts_dir"
	if [[ "$mode" == "missing" ]]; then
		cat >"${scripts_dir}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
	else
		cat >"${scripts_dir}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "check" ]]; then
	printf '%s\n' '{"session_key":"issue-3964","issue_number":"3964","repo_slug":"awardsapp/awardsapp","pid":123,"status":"in-flight"}'
	exit 0
fi
exit 1
STUB
	fi
	chmod +x "${scripts_dir}/dispatch-ledger-helper.sh"
	return 0
}

ps() {
	local subcommand="${1:-}"
	if [[ "$subcommand" == "aux" ]]; then
		printf '%s\n' 'runner 123 0.0 0.0 ?? ?? S 0:00 headless-runtime-helper.sh run --role worker --session-key issue-3964 --dir /tmp/wt'
	fi
	return 0
}

gh() {
	local subcommand="${1:-}"
	local action="${2:-}"
	printf '%s\n' "$*" >>"${GH_LOG:?}"
	if [[ "$subcommand" == "issue" && "$action" == "view" ]]; then
		printf '%s\n' "${GH_ISSUE_STATE:-OPEN}"
		return 0
	fi
	if [[ "$subcommand" == "pr" && "$action" == "list" ]]; then
		printf '%s\n' "${GH_MERGED_PR:-3964}"
		return 0
	fi
	return 1
}

gh_issue_comment() {
	printf 'gh_issue_comment %s\n' "$*" >>"${GH_LOG:?}"
	return 0
}

recover_failed_launch_state() {
	printf 'recover_failed_launch_state %s\n' "$*" >>"${GH_LOG:?}"
	return 0
}

test_orphan_crash_skips_closed_issue_comment() {
	local gh_log="${TEST_ROOT}/gh-closed-orphan.log"
	local old_state="${GH_ISSUE_STATE:-}"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-closed-orphan.log"
	GH_LOG="$gh_log"
	GH_ISSUE_STATE="CLOSED"
	export GH_LOG GH_ISSUE_STATE

	_record_orphan_crash_classification "feature/auto-20260515-123456-gh23379" 0 "owner/repo"

	grep -q 'issue view 23379 --repo owner/repo' "$gh_log" || fail "closed orphan did not check issue state"
	if grep -q 'gh_issue_comment\|recover_failed_launch_state\|issues/23379/comments' "$gh_log"; then
		fail "closed orphan posted or recovered issue state"
	fi
	grep -q 'Orphan cleanup skipped for #23379 (owner/repo): issue state=CLOSED' "$LOGFILE" || fail "closed orphan skip was not audited"
	if [[ -n "$old_state" ]]; then
		GH_ISSUE_STATE="$old_state"
	else
		unset GH_ISSUE_STATE
	fi
	pass "orphan cleanup skips recovery comments on closed issues"
	return 0
}

test_orphan_crash_keeps_open_issue_recovery() {
	local gh_log="${TEST_ROOT}/gh-open-orphan.log"
	local old_state="${GH_ISSUE_STATE:-}"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-open-orphan.log"
	GH_LOG="$gh_log"
	GH_ISSUE_STATE="OPEN"
	export GH_LOG GH_ISSUE_STATE

	_record_orphan_crash_classification "feature/auto-20260515-123456-gh23380" 0 "owner/repo"

	grep -q 'issue view 23380 --repo owner/repo' "$gh_log" || fail "open orphan did not check issue state"
	grep -q 'recover_failed_launch_state 23380 owner/repo premature_exit no_work' "$gh_log" || fail "open orphan did not recover launch state"
	grep -q 'gh_issue_comment 23380 --repo owner/repo --body' "$gh_log" || fail "open orphan did not post recovery comment"
	if [[ -n "$old_state" ]]; then
		GH_ISSUE_STATE="$old_state"
	else
		unset GH_ISSUE_STATE
	fi
	pass "orphan cleanup preserves recovery comments on open issues"
	return 0
}

test_zombie_reaper_requires_ledger_repo() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-no-ledger"
	local bin_dir="${TEST_ROOT}/bin-no-ledger"
	local kill_log="${TEST_ROOT}/kill-no-ledger.log"
	local gh_log="${TEST_ROOT}/gh-no-ledger.log"
	local old_path="$PATH"

	: >"$kill_log"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-no-ledger.log"
	printf '%s\n' '{"initialized_repos":[{"slug":"marcusquinn/aidevops","pulse":true}]}' >"${TEST_ROOT}/repos.json"
	REPOS_JSON="${TEST_ROOT}/repos.json"
	write_ledger_stub "$scripts_dir" "missing"
	write_kill_stub "$bin_dir"

	SCRIPT_DIR="$scripts_dir"
	PATH="${bin_dir}:${PATH}"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR="3964"
	reap_zombie_workers
	PATH="$old_path"
	SCRIPT_DIR="$original_script_dir"

	[[ ! -s "$kill_log" ]] || fail "zombie reaper killed a worker without a ledger repo"
	[[ ! -s "$gh_log" ]] || fail "zombie reaper queried merged PRs without a ledger repo"
	grep -q 'no live ledger repo' "$LOGFILE" || fail "missing no-ledger skip audit log"
	pass "zombie reaper refuses repo-less merged-PR lookup"
	return 0
}

test_zombie_reaper_uses_ledger_repo_and_pid() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-with-ledger"
	local bin_dir="${TEST_ROOT}/bin-with-ledger"
	local kill_log="${TEST_ROOT}/kill-with-ledger.log"
	local gh_log="${TEST_ROOT}/gh-with-ledger.log"
	local old_path="$PATH"

	: >"$kill_log"
	: >"$gh_log"
	LOGFILE="${TEST_ROOT}/pulse-with-ledger.log"
	write_ledger_stub "$scripts_dir" "present"
	write_kill_stub "$bin_dir"

	SCRIPT_DIR="$scripts_dir"
	PATH="${bin_dir}:${PATH}"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR="5000"
	reap_zombie_workers
	PATH="$old_path"
	SCRIPT_DIR="$original_script_dir"

	grep -Fxq '123' "$kill_log" || fail "zombie reaper did not kill the ledger PID"
	grep -q -- '--repo awardsapp/awardsapp' "$gh_log" || fail "zombie reaper did not query the ledger repo"
	grep -q 'PR #5000 already merged in awardsapp/awardsapp' "$LOGFILE" || fail "missing ledger-repo reap audit log"
	pass "zombie reaper uses ledger repo and PID"
	return 0
}

test_current_cwd_skip
test_orphan_removal_unregisters
test_orphan_crash_skips_closed_issue_comment
test_orphan_crash_keeps_open_issue_recovery
test_zombie_reaper_requires_ledger_repo
test_zombie_reaper_uses_ledger_repo_and_pid

exit 0
