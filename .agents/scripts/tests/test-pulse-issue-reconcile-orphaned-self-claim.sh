#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#40204: a same-device worker that died without posting CLAIM_RELEASED
# leaves its issue status:in-progress and assigned to this runner. The stale
# sweep must hand such orphaned self-device claims to the guarded is-assigned
# recovery, and must leave live workers, other devices and live leases alone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_TMP="$(mktemp -d -t pulse-orphan-self-claim.XXXXXX)"
LOGFILE="${TEST_TMP}/pulse.log"
DEDUP_CALLS="${TEST_TMP}/dedup-calls"
DEDUP_HELPER="${TEST_TMP}/dispatch-dedup-helper.sh"
TESTS_RUN=0
TESTS_FAILED=0
NOW_EPOCH=100000
: >"$LOGFILE"

cleanup() {
	rm -rf "$TEST_TMP"
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local passed="$2"
	local details="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	[[ -z "$details" ]] || printf '     %s\n' "$details"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Stub is-assigned: records the call and reports the recovery the real
# guarded path prints (dispatch-dedup-stale.sh _stale_recovery_apply).
cat >"$DEDUP_HELPER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DEDUP_CALLS"
printf 'STALE_RECOVERED: issue #%s in %s — unassigned %s (stub)\n' "$2" "$3" "$4"
exit 1
STUB
chmod +x "$DEDUP_HELPER"
export DEDUP_CALLS

# shellcheck source=../pulse-issue-reconcile-stale.sh
source "${SCRIPT_DIR}/pulse-issue-reconcile-stale.sh"

export AIDEVOPS_DEVICE_ID=device-local

aidevops_pulse_worker_log_path() {
	printf '%s\n' "${TEST_TMP}/missing-worker.log"
	return 0
}

# Default world: a stray process still names "#N" (Check 1 skip), no live
# session leader, the recorded worker PID is gone.
pgrep() {
	[[ "$*" == *"session-key"* ]] && return 1
	[[ "$*" == *"#"* ]] && return 0
	return 1
}
ps() { return 1; }
_normalize_stale_find_open_pr() {
	printf '%s' ''
	return 0
}

comments_fixture() {
	local device="$1"
	local expires="$2"
	local runner="${3:-runner-bot}"
	printf '[[{"id":1,"author_association":"OWNER","user":{"login":"%s"},"created_at":"2026-11-24T12:00:00Z","body":"DISPATCH_CLAIM nonce=n runner=%s lease_token=t1 device=%s session=issue-7 phase=prelaunch expires_at=90000"},' "$runner" "$runner" "$device"
	printf '{"id":2,"author_association":"OWNER","user":{"login":"%s"},"created_at":"2026-11-24T12:01:00Z","body":"Dispatching worker (deterministic).\\n<!-- aidevops:dispatch lease_token=t1 device=%s session=issue-7 -->\\n- **Worker PID**: 4242\\n- **Runner**: %s"},' "$runner" "$device" "$runner"
	printf '{"id":3,"author_association":"OWNER","user":{"login":"%s"},"created_at":"2026-11-24T12:01:05Z","body":"DISPATCH_LEASE phase=ready lease_token=t1 device=%s session=issue-7 expires_at=%s"}]]' "$runner" "$device" "$expires"
	return 0
}

STUB_COMMENTS=""
_normalize_stale_issue_comments() {
	printf '%s' "$STUB_COMMENTS"
	return 0
}

reset_case() {
	: >"$LOGFILE"
	: >"$DEDUP_CALLS"
	return 0
}

test_orphaned_self_claim_is_recovered() {
	reset_case
	STUB_COMMENTS=$(comments_fixture device-local 99000)
	if _normalize_stale_should_skip_reset 7 owner/repo "$NOW_EPOCH" 10800 runner-bot &&
		[[ "$_NORMALIZE_STALE_SKIP_REASON" == "local_process" ]] &&
		_normalize_stale_orphan_local_prefilter 7 owner/repo "$NOW_EPOCH" &&
		_normalize_stale_recover_orphaned_self_claim 7 owner/repo "$NOW_EPOCH" runner-bot "$DEDUP_HELPER" &&
		grep -qx 'is-assigned 7 owner/repo runner-bot' "$DEDUP_CALLS" &&
		grep -q 'Orphaned self claim check: #7 in owner/repo .*STALE_RECOVERED' "$LOGFILE"; then
		print_result "expired self-device claim with a dead worker uses guarded is-assigned" 0
	else
		print_result "expired self-device claim with a dead worker uses guarded is-assigned" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_live_lease_is_untouched() {
	reset_case
	STUB_COMMENTS=$(comments_fixture device-local 100500)
	if ! _normalize_stale_recover_orphaned_self_claim 7 owner/repo "$NOW_EPOCH" runner-bot "$DEDUP_HELPER" &&
		[[ ! -s "$DEDUP_CALLS" ]]; then
		print_result "unexpired lease keeps the claim" 0
	else
		print_result "unexpired lease keeps the claim" 1 "$(<"$DEDUP_CALLS")"
	fi
	return 0
}

test_other_device_is_untouched() {
	reset_case
	STUB_COMMENTS=$(comments_fixture device-remote 99000)
	if ! _normalize_stale_recover_orphaned_self_claim 7 owner/repo "$NOW_EPOCH" runner-bot "$DEDUP_HELPER" &&
		[[ ! -s "$DEDUP_CALLS" ]]; then
		print_result "claim from another device sharing the login is untouched" 0
	else
		print_result "claim from another device sharing the login is untouched" 1 "$(<"$DEDUP_CALLS")"
	fi
	return 0
}

test_other_runner_is_untouched() {
	reset_case
	STUB_COMMENTS=$(comments_fixture device-local 99000 other-runner)
	if ! _normalize_stale_recover_orphaned_self_claim 7 owner/repo "$NOW_EPOCH" runner-bot "$DEDUP_HELPER" &&
		[[ ! -s "$DEDUP_CALLS" ]]; then
		print_result "claim by another runner login is untouched" 0
	else
		print_result "claim by another runner login is untouched" 1 "$(<"$DEDUP_CALLS")"
	fi
	return 0
}

test_live_registered_worker_is_untouched() {
	reset_case
	STUB_COMMENTS=$(comments_fixture device-local 99000)
	ps() {
		[[ "$*" == *"command="* ]] && printf '%s\n' "bash headless-runtime-helper.sh run --session-key issue-7 --title Issue #7: x"
		return 0
	}
	if ! _normalize_stale_recover_orphaned_self_claim 7 owner/repo "$NOW_EPOCH" runner-bot "$DEDUP_HELPER" &&
		[[ ! -s "$DEDUP_CALLS" ]]; then
		print_result "live registered worker PID keeps the claim" 0
	else
		print_result "live registered worker PID keeps the claim" 1 "$(<"$DEDUP_CALLS")"
	fi
	ps() { return 1; }
	return 0
}

test_reused_pid_does_not_protect_claim() {
	reset_case
	STUB_COMMENTS=$(comments_fixture device-local 99000)
	ps() {
		[[ "$*" == *"command="* ]] && printf '%s\n' "/usr/bin/some-unrelated-daemon"
		return 0
	}
	if _normalize_stale_recover_orphaned_self_claim 7 owner/repo "$NOW_EPOCH" runner-bot "$DEDUP_HELPER" &&
		grep -qx 'is-assigned 7 owner/repo runner-bot' "$DEDUP_CALLS"; then
		print_result "reused worker PID does not protect an orphaned claim" 0
	else
		print_result "reused worker PID does not protect an orphaned claim" 1 "$(<"$LOGFILE")"
	fi
	ps() { return 1; }
	return 0
}

test_live_session_leader_skips_without_api() {
	reset_case
	pgrep() {
		[[ "$*" == *"session-key"* ]] && printf '%s\n' 5151 && return 0
		[[ "$*" == *"#"* ]] && return 0
		return 1
	}
	ps() {
		[[ "$*" == *"pgid="* ]] && printf '%s\n' ' 5151'
		return 0
	}
	if ! _normalize_stale_orphan_local_prefilter 7 owner/repo "$NOW_EPOCH"; then
		print_result "live same-device session leader is filtered before any API read" 0
	else
		print_result "live same-device session leader is filtered before any API read" 1
	fi
	pgrep() {
		[[ "$*" == *"session-key"* ]] && return 1
		[[ "$*" == *"#"* ]] && return 0
		return 1
	}
	ps() { return 1; }
	return 0
}

test_surviving_subshell_is_not_a_leader() {
	reset_case
	pgrep() {
		[[ "$*" == *"session-key"* ]] && printf '%s\n' 6262 && return 0
		[[ "$*" == *"#"* ]] && return 0
		return 1
	}
	ps() {
		[[ "$*" == *"pgid="* ]] && printf '%s\n' ' 6200'
		return 0
	}
	if _normalize_stale_orphan_local_prefilter 7 owner/repo "$NOW_EPOCH"; then
		print_result "surviving subshell of a dead worker is not a live leader" 0
	else
		print_result "surviving subshell of a dead worker is not a live leader" 1
	fi
	pgrep() {
		[[ "$*" == *"session-key"* ]] && return 1
		[[ "$*" == *"#"* ]] && return 0
		return 1
	}
	ps() { return 1; }
	return 0
}

test_open_pr_skip_never_reaches_orphan_recovery() {
	reset_case
	_normalize_stale_find_open_pr() {
		printf '%s' '321|ready'
		return 0
	}
	if _normalize_stale_should_skip_reset 7 owner/repo "$NOW_EPOCH" 10800 runner-bot &&
		[[ "$_NORMALIZE_STALE_SKIP_REASON" == "open_pr" ]]; then
		print_result "open PR skip is not an orphan-recovery reason" 0
	else
		print_result "open PR skip is not an orphan-recovery reason" 1 "reason=${_NORMALIZE_STALE_SKIP_REASON}"
	fi
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	return 0
}

test_sweep_wires_orphan_recovery() {
	reset_case
	local repos_json="${TEST_TMP}/repos.json"
	printf '%s' '{"initialized_repos":[{"slug":"owner/repo"}]}' >"$repos_json"
	STUB_COMMENTS=$(comments_fixture device-local 99000)
	PULSE_QUEUED_SCAN_LIMIT=100
	repo_allows_pulse_write_actions() { return 0; }
	_normalize_repo_listing() {
		printf '%s' '[{"number":7,"assignees":[{"login":"runner-bot"}],"labels":[{"name":"status:in-progress"}],"updatedAt":"1970-01-01T00:00:00Z"}]'
		return 0
	}
	_normalize_unassign_stale runner-bot "$repos_json" "$NOW_EPOCH" 10800 "$DEDUP_HELPER"
	if grep -qx 'is-assigned 7 owner/repo runner-bot' "$DEDUP_CALLS" &&
		grep -q 'orphan_checked=1 orphan_recovered=1' "$LOGFILE"; then
		print_result "stale sweep routes orphaned self claims to is-assigned" 0
	else
		print_result "stale sweep routes orphaned self claims to is-assigned" 1 "$(<"$LOGFILE")"
	fi
	reset_case
	_normalize_unassign_stale runner-bot "$repos_json" "$NOW_EPOCH" 10800
	if [[ ! -s "$DEDUP_CALLS" ]] && grep -q 'orphan_checked=0' "$LOGFILE"; then
		print_result "sweep without a dedup helper keeps prior behaviour" 0
	else
		print_result "sweep without a dedup helper keeps prior behaviour" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_orphaned_self_claim_is_recovered
test_live_lease_is_untouched
test_other_device_is_untouched
test_other_runner_is_untouched
test_live_registered_worker_is_untouched
test_reused_pid_does_not_protect_claim
test_live_session_leader_skips_without_api
test_surviving_subshell_is_not_a_leader
test_open_pr_skip_never_reaches_orphan_recovery
test_sweep_wires_orphan_recovery

printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
