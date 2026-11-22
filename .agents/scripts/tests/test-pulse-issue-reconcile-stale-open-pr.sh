#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
LOGFILE="$(mktemp -t pulse-stale-open-pr.XXXXXX)"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -f "$LOGFILE"
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

# shellcheck source=../pulse-issue-reconcile-stale.sh
source "${SCRIPT_DIR}/pulse-issue-reconcile-stale.sh"

pgrep() {
	return 1
}

aidevops_pulse_worker_log_path() {
	printf '%s\n' "/nonexistent/worker.log"
	return 0
}

test_open_pr_skips_stale_reset() {
	_normalize_stale_find_open_pr() {
		printf '%s\n' '321|ready'
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf 'unexpected-dispatch-read\n' >>"$LOGFILE"
		return 1
	}
	if _normalize_stale_should_skip_reset 42 owner/repo 2000 600 runner-bot &&
		grep -q 'open PR #321' "$LOGFILE" &&
		! grep -q 'unexpected-dispatch-read' "$LOGFILE"; then
		print_result "authoritative open PR blocks stale reset before dispatch inspection" 0
	else
		print_result "authoritative open PR blocks stale reset before dispatch inspection" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_open_pr_lookup_failure_is_fail_closed() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		return 1
	}
	_normalize_stale_get_dispatch_info() {
		printf 'unexpected-dispatch-read\n' >>"$LOGFILE"
		return 1
	}
	if _normalize_stale_should_skip_reset 43 owner/repo 2000 600 runner-bot &&
		grep -q 'open-PR lookup fail-closed' "$LOGFILE" &&
		! grep -q 'unexpected-dispatch-read' "$LOGFILE"; then
		print_result "indeterminate open PR evidence fails closed" 0
	else
		print_result "indeterminate open PR evidence fails closed" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_confirmed_absence_allows_stale_evaluation() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '\n\n\n'
		return 0
	}
	if _normalize_stale_should_skip_reset 44 owner/repo 2000 600 runner-bot; then
		print_result "confirmed open PR absence continues stale evaluation" 1 "unexpected skip"
	else
		print_result "confirmed open PR absence continues stale evaluation" 0
	fi
	return 0
}

# GH#35218: one runner login on several devices. A recent dispatch from
# another device must not be judged by this device's PID table or logs.
test_same_login_other_device_is_cross_runner() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '%s\n%s\n%s\n%s\n' 4242 1970-01-01T00:16:40Z runner-bot device-remote
		return 0
	}
	ps() { return 1; }
	if AIDEVOPS_DEVICE_ID=device-local _normalize_stale_should_skip_reset 45 owner/repo 2000 10800 runner-bot &&
		grep -q 'cross-runner guard' "$LOGFILE"; then
		print_result "same-login dispatch on another device keeps its claim" 0
	else
		print_result "same-login dispatch on another device keeps its claim" 1 "$(<"$LOGFILE")"
	fi
	unset -f ps
	return 0
}

test_same_login_same_device_dead_pid_resets() {
	: >"$LOGFILE"
	_normalize_stale_find_open_pr() {
		printf '%s' ''
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '%s\n%s\n%s\n%s\n' 4242 1970-01-01T00:16:40Z runner-bot device-local
		return 0
	}
	ps() { return 1; }
	if AIDEVOPS_DEVICE_ID=device-local _normalize_stale_should_skip_reset 46 owner/repo 2000 10800 runner-bot; then
		print_result "same-device dispatch with a dead PID still resets" 1 "$(<"$LOGFILE")"
	else
		print_result "same-device dispatch with a dead PID still resets" 0
	fi
	unset -f ps
	return 0
}

# GH#36186: abandoned unprotected worker drafts. now=100000, max_runtime=10800.
NOW_EPOCH=100000
MAX_RUNTIME=10800

stub_abandoned_draft_evidence() {
	_normalize_stale_find_open_pr() {
		printf '%s' '777|draft_checkpoint'
		return 0
	}
	_normalize_stale_get_dispatch_info() {
		printf '\n\n\n\n'
		return 0
	}
	_normalize_stale_issue_comments() {
		printf '%s' "${STUB_COMMENTS:-[]}"
		return 0
	}
	_normalize_stale_pr_activity_epoch() {
		printf '%s' "${STUB_PR_ACTIVITY:-1000}"
		return 0
	}
	return 0
}

test_abandoned_draft_resets() {
	: >"$LOGFILE"
	stub_abandoned_draft_evidence
	STUB_COMMENTS='[[{"id":1,"author_association":"COLLABORATOR","user":{"login":"runner-bot"},"created_at":"2026-10-30T16:29:00Z","body":"DISPATCH_LEASE phase=ready lease_token=t1 session=issue-47 expires_at=99000"}]]'
	STUB_PR_ACTIVITY=1000
	_NORMALIZE_STALE_RELEASE_DETAIL=""
	if ! _normalize_stale_should_skip_reset 47 owner/repo "$NOW_EPOCH" "$MAX_RUNTIME" runner-bot &&
		[[ "$_NORMALIZE_STALE_RELEASE_DETAIL" == "abandoned_draft_pr=777" ]] &&
		grep -q 'abandoned worker draft PR #777' "$LOGFILE"; then
		print_result "abandoned worker draft no longer blocks stale reset" 0
	else
		print_result "abandoned worker draft no longer blocks stale reset" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_live_lease_keeps_draft_claim() {
	: >"$LOGFILE"
	stub_abandoned_draft_evidence
	STUB_COMMENTS='[[{"id":1,"author_association":"COLLABORATOR","user":{"login":"other-runner"},"created_at":"2026-10-30T22:44:00Z","body":"DISPATCH_LEASE phase=ready lease_token=t2 session=pr-checkpoint-continuation-owner-repo-777 expires_at=100500"}]]'
	STUB_PR_ACTIVITY=1000
	if _normalize_stale_should_skip_reset 48 owner/repo "$NOW_EPOCH" "$MAX_RUNTIME" runner-bot &&
		grep -q 'lease live' "$LOGFILE"; then
		print_result "unexpired continuation lease keeps the draft claim" 0
	else
		print_result "unexpired continuation lease keeps the draft claim" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_terminal_or_untrusted_lease_is_not_live() {
	local comments='[[{"id":1,"author_association":"COLLABORATOR","user":{"login":"r"},"created_at":"2026-10-30T22:44:00Z","body":"DISPATCH_LEASE phase=ready lease_token=t3 expires_at=100500"},{"id":2,"author_association":"COLLABORATOR","user":{"login":"r"},"created_at":"2026-10-30T22:45:00Z","body":"DISPATCH_LEASE phase=terminal lease_token=t3 expires_at=100500"},{"id":3,"author_association":"NONE","user":{"login":"stranger"},"created_at":"2026-10-30T22:46:00Z","body":"DISPATCH_LEASE phase=ready lease_token=t4 expires_at=999999"}]]'
	local rc=0
	_normalize_stale_has_live_lease "$comments" "$NOW_EPOCH" runner-bot || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "terminal or untrusted leases do not keep a claim alive" 0
	else
		print_result "terminal or untrusted leases do not keep a claim alive" 1 "rc=${rc}"
	fi
	return 0
}

test_local_continuation_process_keeps_draft_claim() {
	: >"$LOGFILE"
	stub_abandoned_draft_evidence
	STUB_COMMENTS='[]'
	STUB_PR_ACTIVITY=1000
	pgrep() {
		[[ "$*" == *"pr-checkpoint-continuation-owner-repo-777"* ]] && return 0
		return 1
	}
	if _normalize_stale_should_skip_reset 49 owner/repo "$NOW_EPOCH" "$MAX_RUNTIME" runner-bot &&
		grep -q 'continuation running' "$LOGFILE"; then
		print_result "local continuation process keeps the draft claim" 0
	else
		print_result "local continuation process keeps the draft claim" 1 "$(<"$LOGFILE")"
	fi
	pgrep() {
		return 1
	}
	return 0
}

test_recent_pr_activity_keeps_draft_claim() {
	: >"$LOGFILE"
	stub_abandoned_draft_evidence
	STUB_COMMENTS='[]'
	STUB_PR_ACTIVITY=95000
	if _normalize_stale_should_skip_reset 50 owner/repo "$NOW_EPOCH" "$MAX_RUNTIME" runner-bot &&
		grep -q 'active 5000s ago' "$LOGFILE"; then
		print_result "recent draft PR activity keeps the draft claim" 0
	else
		print_result "recent draft PR activity keeps the draft claim" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_unreadable_draft_evidence_fails_closed() {
	: >"$LOGFILE"
	stub_abandoned_draft_evidence
	_normalize_stale_issue_comments() {
		return 1
	}
	if _normalize_stale_should_skip_reset 51 owner/repo "$NOW_EPOCH" "$MAX_RUNTIME" runner-bot &&
		grep -q 'lease lookup fail-closed' "$LOGFILE"; then
		print_result "unreadable draft lease evidence fails closed" 0
	else
		print_result "unreadable draft lease evidence fails closed" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_protected_draft_still_blocks() {
	: >"$LOGFILE"
	stub_abandoned_draft_evidence
	_normalize_stale_find_open_pr() {
		printf '%s' '778|protected_draft'
		return 0
	}
	_normalize_stale_issue_comments() {
		printf 'unexpected-evidence-read\n' >>"$LOGFILE"
		return 1
	}
	if _normalize_stale_should_skip_reset 52 owner/repo "$NOW_EPOCH" "$MAX_RUNTIME" runner-bot &&
		grep -q 'open PR #778' "$LOGFILE" &&
		! grep -q 'unexpected-evidence-read' "$LOGFILE"; then
		print_result "protected draft still blocks stale reset" 0
	else
		print_result "protected draft still blocks stale reset" 1 "$(<"$LOGFILE")"
	fi
	return 0
}

test_open_pr_skips_stale_reset
test_open_pr_lookup_failure_is_fail_closed
test_confirmed_absence_allows_stale_evaluation
test_same_login_other_device_is_cross_runner
test_same_login_same_device_dead_pid_resets
test_abandoned_draft_resets
test_live_lease_keeps_draft_claim
test_terminal_or_untrusted_lease_is_not_live
test_local_continuation_process_keeps_draft_claim
test_recent_pr_activity_keeps_draft_claim
test_unreadable_draft_evidence_fails_closed
test_protected_draft_still_blocks

printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
