#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for pulse cleanup permanent removal guards:
# - current-cwd worktrees are skipped before deletion
# - eligible orphan worktrees are removed permanently and unregistered

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/pulse.log"
export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup_worktrees.log"
UNREGISTER_LOG="${TEST_ROOT}/unregister.log"
LEASE_RELEASE_LOG="${TEST_ROOT}/lease-release.log"

# Production functions under test invoke `git` by name. Pin fixture operations
# to native Git so the canonical mutation guard for the real repository cannot
# misclassify isolated test repositories.
git() {
	"$GIT_BIN" "$@"
	return $?
}

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

test_locked_orphan_is_preserved() {
	local repo_path="${TEST_ROOT}/repo-locked"
	local wt_path="${TEST_ROOT}/wt-locked"
	local wt_root=""
	local metadata=""
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/locked"
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "observation-provenance" "$wt_path"

	if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/locked" "$(date +%s)" "" "main"; then
		fail "locked orphan was reported as removed"
	fi

	[[ -d "$wt_path" ]] || fail "locked orphan physical path was removed"
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel) || fail "locked orphan root became unreadable"
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || fail "locked orphan metadata became unreadable"
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || fail "locked orphan registration was removed"
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || fail "locked orphan lock marker was removed"
	if [[ -f "$UNREGISTER_LOG" ]] && grep -Fxq "$wt_path" "$UNREGISTER_LOG"; then
		fail "locked orphan was unregistered"
	fi
	grep -q 'git-worktree-locked.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" || fail "locked orphan skip was not audited"
	pass "pulse cleanup preserves Git-locked eligible orphan"
	return 0
}

test_late_write_before_permanent_remove_is_preserved() {
	local repo_path="${TEST_ROOT}/repo-late-write"
	local wt_path="${TEST_ROOT}/wt-late-write"
	local wrapper_path="${TEST_ROOT}/late-write-git"
	local marker_path="${TEST_ROOT}/late-write-injected"
	local metadata=""
	local wt_root=""
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/late-write"
	wt_root=$(/usr/bin/git -C "$wt_path" rev-parse --show-toplevel) || fail "late-write root became unreadable"
	cat >"$wrapper_path" <<'LATE_WRITE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${LATE_WRITE_MARKER:?}" ]]; then
	printf 'late state\n' >"${LATE_WRITE_WORKTREE:?}/late-write.txt" || exit 1
	: >"$LATE_WRITE_MARKER"
fi
exec "${REAL_GIT:?}" "$@"
LATE_WRITE_GIT
	chmod +x "$wrapper_path"

	if REAL_GIT="$GIT_BIN" LATE_WRITE_MARKER="$marker_path" \
		LATE_WRITE_WORKTREE="$wt_path" AIDEVOPS_REAL_GIT_BIN="$wrapper_path" \
		_cleanup_single_worktree "$repo_path" "$wt_path" "feature/late-write" \
		"$(date +%s)" "" "main"; then
		fail "late-write permanent cleanup was reported as complete"
	fi
	[[ -f "$wt_path/late-write.txt" && -e "$marker_path" ]] || fail "late write or source was removed"
	metadata=$(/usr/bin/git -C "$repo_path" worktree list --porcelain) || fail "late-write metadata became unreadable"
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || fail "late-write registration was removed"
	printf '%s\n' "$metadata" | grep -Fqx "branch refs/heads/feature/late-write" || fail "late-write branch identity was removed"
	if [[ -f "$UNREGISTER_LOG" ]] && grep -Fxq "$wt_path" "$UNREGISTER_LOG"; then
		fail "late-write worktree was unregistered"
	fi
	grep -q 'git-worktree-remove-failed.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" || fail "late-write refusal was not audited"
	pass "pulse permanent cleanup preserves a write acquired after clean classification"
	return 0
}

test_degraded_orphan_is_quarantined_with_bounded_retry() {
	local repo_path="${TEST_ROOT}/repo-degraded"
	local wt_path="${TEST_ROOT}/wt-degraded"
	local guard_log="${TEST_ROOT}/degraded-guard.log"
	local api_log="${TEST_ROOT}/degraded-api.log"
	local state_path=""
	local state_json=""
	local first_now=2000000000
	local retry_now=$((first_now + 61))
	local metadata=""
	local wt_root=""
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/degraded"
	wt_root=$(/usr/bin/git -C "$wt_path" rev-parse --show-toplevel) || fail "degraded root became unreadable"
	export PULSE_STATE_DIR="${TEST_ROOT}/pulse-state"
	export AIDEVOPS_DEGRADED_CWD_RETRY_INITIAL_SECONDS=60
	export AIDEVOPS_DEGRADED_CWD_RETRY_MAX_SECONDS=120
	export PROCESS_GUARD_LOG="$guard_log"
	export DEGRADED_API_LOG="$api_log"

	worktree_removal_guard() {
		local candidate_path="$1"
		local caller="$2"
		local reason="$3"
		: "$candidate_path" "$caller" "$reason"
		printf 'guard\n' >>"$PROCESS_GUARD_LOG"
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		return 2
	}
	gh_pr_list() {
		printf 'api\n' >>"$DEGRADED_API_LOG"
		return 0
	}

	if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/degraded" \
		"$first_now" "owner/repo" "main"; then
		fail "degraded orphan was reported as removed"
	fi
	state_path=$(_pcdo_quarantine_state_path "$wt_path") || fail "degraded state path was not created"
	[[ -f "$state_path" && -d "$wt_path" ]] || fail "degraded worktree was not quarantined in place"
	state_json=$(<"$state_path")
	jq -e --arg path "$wt_path" --arg branch "feature/degraded" --argjson retry "$((first_now + 60))" \
		'.path == $path and .branch == $branch and .attempt == 1 and .retry_after == $retry' \
		<<<"$state_json" >/dev/null || fail "initial degraded quarantine state is invalid"
	[[ "$(wc -l <"$guard_log" | tr -d ' ')" -eq 1 ]] || fail "initial process evidence was not collected once"
	[[ ! -e "$api_log" ]] || fail "degraded quarantine performed a GitHub API query"

	if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/degraded" \
		"$((first_now + 1))" "owner/repo" "main"; then
		fail "backoff-suppressed degraded orphan was reported as removed"
	fi
	[[ "$(wc -l <"$guard_log" | tr -d ' ')" -eq 1 ]] || fail "backoff recollected process evidence too early"
	[[ ! -e "$api_log" ]] || fail "backoff-suppressed quarantine performed a GitHub API query"

	if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/degraded" \
		"$retry_now" "owner/repo" "main"; then
		fail "retried degraded orphan was reported as removed"
	fi
	state_json=$(<"$state_path")
	jq -e --argjson observed "$retry_now" --argjson retry "$((retry_now + 120))" \
		'.attempt == 2 and .observed_at == $observed and .retry_after == $retry' \
		<<<"$state_json" >/dev/null || fail "degraded retry did not persist bounded backoff"
	[[ "$(wc -l <"$guard_log" | tr -d ' ')" -eq 2 ]] || fail "due retry did not collect fresh process evidence"
	[[ ! -e "$api_log" ]] || fail "due degraded retry performed a GitHub API query"
	metadata=$(/usr/bin/git -C "$repo_path" worktree list --porcelain) || fail "degraded metadata became unreadable"
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || fail "degraded worktree registration was removed"
	if [[ -f "$UNREGISTER_LOG" ]] && grep -Fxq "$wt_path" "$UNREGISTER_LOG"; then
		fail "degraded quarantine unregistered the worktree"
	fi
	grep -q 'degraded-cwd-in-place-quarantine.*mode=in-place-quarantine' "$AIDEVOPS_CLEANUP_LOG" ||
		fail "degraded in-place quarantine was not audited"
	pass "pulse cleanup quarantines degraded worktrees with bounded fresh-evidence retries"
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
	jq -cn --arg worktree "${LEDGER_WORKTREE:?}" --arg lease "${LEDGER_LEASE_TOKEN:?}" \
		'{session_key:"issue-3964",issue_number:"3964",repo_slug:"exampleorg/examplerepo",pid:123,status:"in-flight",lease_phase:"ready",worktree_path:$worktree,lease_token:$lease}'
	exit 0
fi
printf '%s\n' "$*" >>"${LEDGER_LOG:?}"
if [[ "$cmd" == "complete" && "${LEDGER_COMPLETE_FAIL:-0}" == "1" ]]; then
	exit 1
fi
exit 0
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

kill() {
	local pid="$1"
	printf '%s\n' "$pid" >>"${KILL_LOG:?}"
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
	if [[ "$subcommand" == "api" && "$action" == "graphql" ]]; then
		[[ "${GH_API_FAIL:-0}" == "0" ]] || return 1
		printf 'graphql-env response-cost=%s route=%s\n' \
			"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
			"${AIDEVOPS_GH_ROUTE_DECISION:-}" >>"${GH_LOG:?}"
		jq -cn --arg repo "${GH_GRAPHQL_REPO:-exampleorg/examplerepo}" \
			--argjson number "${GH_MERGED_PR:-3964}" --argjson issue "${GH_CLOSING_ISSUE:-3964}" \
			--arg branch "${GH_PR_BRANCH:?}" --arg head "${GH_PR_HEAD:?}" \
			--argjson pr_has_next "${GH_PR_PAGE_HAS_NEXT:-false}" \
			--argjson closing_has_next "${GH_CLOSING_PAGE_HAS_NEXT:-false}" \
			--argjson cost "${GH_GRAPHQL_COST:-1}" '
			{data:{repository:{nameWithOwner:$repo,pullRequests:{nodes:[{
				number:$number,state:"MERGED",mergedAt:"2026-07-15T12:00:00Z",
				headRefName:$branch,headRefOid:$head,
				closingIssuesReferences:{nodes:[{number:$issue,repository:{nameWithOwner:$repo}}],
					pageInfo:{hasNextPage:$closing_has_next}}
			}],pageInfo:{hasNextPage:$pr_has_next}}},rateLimit:{cost:$cost}}}'
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
	if grep -Eq 'gh_issue_comment|recover_failed_launch_state|issues/23379/comments' "$gh_log"; then
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
	local ledger_log="${TEST_ROOT}/ledger-with-ledger.log"
	local repo_path="${TEST_ROOT}/repo-with-ledger"
	local worker_worktree="${TEST_ROOT}/wt-with-ledger"
	local old_path="$PATH"

	: >"$kill_log"
	: >"$gh_log"
	: >"$ledger_log"
	LOGFILE="${TEST_ROOT}/pulse-with-ledger.log"
	make_repo_with_worktree "$repo_path" "$worker_worktree" "feature/worker-3964"
	write_ledger_stub "$scripts_dir" "present"
	write_kill_stub "$bin_dir"

	SCRIPT_DIR="$scripts_dir"
	PATH="${bin_dir}:${PATH}"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR="5000" GH_API_FAIL=0 GH_CLOSING_ISSUE=3964
	export GH_PR_BRANCH="feature/worker-3964" GH_PR_HEAD LEDGER_WORKTREE="$worker_worktree" LEDGER_LEASE_TOKEN="lease-3964" LEDGER_LOG="$ledger_log"
	GH_PR_HEAD=$(git -C "$worker_worktree" rev-parse HEAD)
	reap_zombie_workers
	PATH="$old_path"
	SCRIPT_DIR="$original_script_dir"

	grep -Fxq '123' "$kill_log" || fail "zombie reaper did not kill the ledger PID"
	grep -q -- '-F owner=exampleorg -F name=examplerepo' "$gh_log" || fail "zombie reaper did not query the ledger repo"
	grep -q -- '-F head=feature/worker-3964' "$gh_log" || fail "zombie reaper did not bind merged PR lookup to worker branch"
	grep -q 'closingIssuesReferences' "$gh_log" || fail "zombie reaper did not verify structured closing references"
	grep -q 'pageInfo { hasNextPage }' "$gh_log" || fail "zombie reaper did not request pagination proof"
	grep -q 'rateLimit { cost }' "$gh_log" || fail "zombie reaper did not request response-owned cost"
	grep -q 'graphql-env response-cost=1 route=pulse-zombie-merged-pr-exact-cost' "$gh_log" || fail "zombie reaper GraphQL route was not attributed exactly"
	if grep -q '^pr list ' "$gh_log"; then
		fail "zombie reaper used an opaque native PR list"
	fi
	grep -q 'record-outcome.*--reason merged_pr_reap' "$ledger_log" || fail "zombie reaper did not record typed terminal telemetry"
	grep -q 'complete.*--lease-token lease-3964.*--reason merged_pr_reap' "$ledger_log" || fail "zombie reaper did not complete the exact lease"
	grep -q 'PR #5000 already merged in exampleorg/examplerepo' "$LOGFILE" || fail "missing ledger-repo reap audit log"
	grep -q 'kill_reason=merged_pr_reap' "$LOGFILE" || fail "missing typed reap lifecycle log"
	pass "zombie reaper uses ledger repo and PID"
	return 0
}

test_zombie_reaper_rejects_unverified_completion() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-unverified"
	local repo_path="${TEST_ROOT}/repo-unverified"
	local worker_worktree="${TEST_ROOT}/wt-unverified"
	local kill_log="${TEST_ROOT}/kill-unverified.log"
	local gh_log="${TEST_ROOT}/gh-unverified.log"
	local ledger_log="${TEST_ROOT}/ledger-unverified.log"

	: >"$kill_log"
	: >"$gh_log"
	: >"$ledger_log"
	LOGFILE="${TEST_ROOT}/pulse-unverified.log"
	make_repo_with_worktree "$repo_path" "$worker_worktree" "feature/worker-3964-unverified"
	write_ledger_stub "$scripts_dir" "present"
	SCRIPT_DIR="$scripts_dir"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR=5001 GH_API_FAIL=0 GH_CLOSING_ISSUE=9999
	export GH_PR_BRANCH="feature/worker-3964-unverified" GH_PR_HEAD LEDGER_WORKTREE="$worker_worktree" LEDGER_LEASE_TOKEN="lease-3964-unverified" LEDGER_LOG="$ledger_log"
	GH_PR_HEAD=$(git -C "$worker_worktree" rev-parse HEAD)
	reap_zombie_workers
	SCRIPT_DIR="$original_script_dir"

	[[ ! -s "$kill_log" ]] || fail "planning PR without structured closure reaped the worker"
	[[ ! -s "$ledger_log" ]] || fail "unverified completion emitted terminal ledger state"
	pass "zombie reaper rejects planning PRs without structured closure"
	return 0
}

test_zombie_reaper_fails_closed_on_stale_or_indeterminate_evidence() {
	local original_script_dir="$SCRIPT_DIR"
	local scripts_dir="${TEST_ROOT}/scripts-indeterminate"
	local repo_path="${TEST_ROOT}/repo-indeterminate"
	local worker_worktree="${TEST_ROOT}/wt-indeterminate"
	local kill_log="${TEST_ROOT}/kill-indeterminate.log"
	local gh_log="${TEST_ROOT}/gh-indeterminate.log"
	local ledger_log="${TEST_ROOT}/ledger-indeterminate.log"

	: >"$kill_log"
	: >"$gh_log"
	: >"$ledger_log"
	LOGFILE="${TEST_ROOT}/pulse-indeterminate.log"
	make_repo_with_worktree "$repo_path" "$worker_worktree" "feature/worker-3964-indeterminate"
	write_ledger_stub "$scripts_dir" "present"
	SCRIPT_DIR="$scripts_dir"
	export GH_LOG="$gh_log" KILL_LOG="$kill_log" GH_MERGED_PR=5002 GH_API_FAIL=0 GH_CLOSING_ISSUE=3964
	export GH_PR_BRANCH="feature/worker-3964-indeterminate" GH_PR_HEAD="0000000000000000000000000000000000000000"
	export LEDGER_WORKTREE="$worker_worktree" LEDGER_LEASE_TOKEN="lease-3964-indeterminate" LEDGER_LOG="$ledger_log"
	reap_zombie_workers
	GH_API_FAIL=1
	GH_PR_HEAD=$(git -C "$worker_worktree" rev-parse HEAD)
	reap_zombie_workers
	GH_API_FAIL=0
	export LEDGER_COMPLETE_FAIL=1
	reap_zombie_workers
	unset LEDGER_COMPLETE_FAIL
	SCRIPT_DIR="$original_script_dir"

	[[ ! -s "$kill_log" ]] || fail "stale or API-indeterminate evidence reaped the worker"
	if grep -q 'record-outcome' "$ledger_log"; then
		fail "stale or API-indeterminate evidence emitted terminal telemetry"
	fi
	grep -q 'ambiguous or API-indeterminate' "$LOGFILE" || fail "API-indeterminate skip was not diagnosed"
	grep -q 'active dispatch generation changed' "$LOGFILE" || fail "stale lease transition was not diagnosed"
	pass "zombie reaper fails closed on stale dispatch and API-indeterminate evidence"
	return 0
}

test_worker_closing_pr_fails_closed_on_truncated_or_unmetered_graphql() {
	local gh_log="${TEST_ROOT}/gh-truncated-closing-pr.log"
	local head_oid="1111111111111111111111111111111111111111"
	local verification_rc=0
	: >"$gh_log"
	export GH_LOG="$gh_log" GH_API_FAIL=0 GH_MERGED_PR=5003 GH_CLOSING_ISSUE=3964
	export GH_PR_BRANCH="feature/worker-3964-truncated" GH_PR_HEAD="$head_oid"

	export GH_PR_PAGE_HAS_NEXT=true GH_CLOSING_PAGE_HAS_NEXT=false GH_GRAPHQL_COST=1
	_verified_worker_closing_pr "exampleorg/examplerepo" "3964" "$GH_PR_BRANCH" "$head_oid" \
		>/dev/null || verification_rc=$?
	[[ "$verification_rc" -eq 2 ]] || fail "truncated merged PR connection did not fail closed"

	verification_rc=0
	export GH_PR_PAGE_HAS_NEXT=false GH_CLOSING_PAGE_HAS_NEXT=true
	_verified_worker_closing_pr "exampleorg/examplerepo" "3964" "$GH_PR_BRANCH" "$head_oid" \
		>/dev/null || verification_rc=$?
	[[ "$verification_rc" -eq 2 ]] || fail "truncated closing-issue connection did not fail closed"

	verification_rc=0
	export GH_CLOSING_PAGE_HAS_NEXT=false GH_GRAPHQL_COST=0
	_verified_worker_closing_pr "exampleorg/examplerepo" "3964" "$GH_PR_BRANCH" "$head_oid" \
		>/dev/null || verification_rc=$?
	[[ "$verification_rc" -eq 2 ]] || fail "nonpositive GraphQL cost did not fail closed"

	unset GH_PR_PAGE_HAS_NEXT GH_CLOSING_PAGE_HAS_NEXT GH_GRAPHQL_COST
	pass "worker closing PR proof rejects truncated or unmetered GraphQL"
	return 0
}

test_permanent_removal_failure_has_no_git_fallback() {
	local repo_path="${TEST_ROOT}/repo-no-fallback"
	local wt_path="${TEST_ROOT}/wt-no-fallback"
	local fallback_log="${TEST_ROOT}/git-remove-fallback.log"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/no-fallback"

	if ! (
		remove_worktree_path_permanently() {
			return 1
		}
		git() {
			local all_args="$*"
			if [[ "$all_args" == *"worktree remove"* ]]; then
				printf '%s\n' "$all_args" >>"$fallback_log"
				return 0
			fi
			"$GIT_BIN" "$@"
			return $?
		}
		if _pc_permanently_remove_eligible_orphan "$repo_path" "$wt_path" \
			"feature/no-fallback" "verified stale orphan" 0 "" "repo-no-fallback" "test=context"; then
			exit 1
		fi
		exit 0
	); then
		fail "permanent helper refusal triggered a Git removal fallback"
	fi
	[[ -d "$wt_path" ]] || fail "failed permanent helper did not preserve the worktree"
	[[ ! -s "$fallback_log" ]] || fail "failed permanent helper invoked git worktree remove"
	pass "pulse cleanup never bypasses a failed permanent removal helper"
	return 0
}

test_current_cwd_skip
test_orphan_removal_unregisters
test_locked_orphan_is_preserved
test_late_write_before_permanent_remove_is_preserved
test_orphan_crash_skips_closed_issue_comment
test_orphan_crash_keeps_open_issue_recovery
test_zombie_reaper_requires_ledger_repo
test_zombie_reaper_uses_ledger_repo_and_pid
test_zombie_reaper_rejects_unverified_completion
test_zombie_reaper_fails_closed_on_stale_or_indeterminate_evidence
test_worker_closing_pr_fails_closed_on_truncated_or_unmetered_graphql
test_permanent_removal_failure_has_no_git_fallback
test_degraded_orphan_is_quarantined_with_bounded_retry

exit 0
