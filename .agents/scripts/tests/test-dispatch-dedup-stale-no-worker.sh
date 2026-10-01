#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#4011/GH#4012 and a private app meta issue's t2769
# no_work false trips.
#
# A stale active label + assignee with no dispatch claim comment can be cleaned
# up by stale recovery, but it is not evidence that a worker ever started. That
# recovery must not record stale_timeout/no_work fast-fails, or pre-launch
# canary failures can trip the t2769 no_work circuit breaker without worker
# evidence.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
REAL_HELPER="${SCRIPTS_DIR}/dispatch-dedup-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

TMP_DIR="$(mktemp -d -t stale-no-worker.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

export LOGFILE="${TMP_DIR}/pulse.log"
SCRIPT_DIR="$TMP_DIR"
HELPER_PATH="${TMP_DIR}/dispatch-dedup-helper.sh"

cat >"$HELPER_PATH" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

cmd="${1:-}"
shift || true

if [[ "$cmd" == "is-assigned" ]]; then
	case "${TEST_STALE_MODE:-no_worker}" in
	no_worker)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in exampleorg/examplerepo - unassigned runner (no dispatch claim comment found, no recent activity (threshold=600s, interactive=false))'
		exit 1
		;;
	prelaunch_canary)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in exampleorg/examplerepo - unassigned runner (no dispatch claim comment found, worker canary preflight failed before worktree pre-creation; will retry next cycle)'
		exit 1
		;;
	worker)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in exampleorg/examplerepo - unassigned runner (dispatch claim 900s old, last activity 900s old (threshold=600s, interactive=false))'
		exit 1
		;;
	live_owner)
		printf '%s\n' 'ASSIGNED: issue #2905 in exampleorg/examplerepo is assigned to runner live_worker=true durable_launch=true attempt_count=1'
		exit 0
		;;
	blocked_by)
		printf '%s\n' 'STALE_BLOCKED_BY_DEPENDENCY: issue #2905 in exampleorg/examplerepo - unassigned runner but kept status:blocked due to unresolved blocked-by (no_work)'
		exit 1
		;;
	terminal)
		printf '%s\n' 'STALE_ESCALATED: issue #2905 in exampleorg/examplerepo — unassigned runner, applied needs-maintainer-review'
		exit 1
		;;
	terminal_pr)
		printf '%s\n' 'STALE_PR_ESCALATED: issue #2905 in exampleorg/examplerepo — PR #456 preserved, applied needs-maintainer-review'
		exit 1
		;;
	*)
		printf '%s\n' 'ASSIGNED: issue #2905 in exampleorg/examplerepo is assigned to runner'
		exit 0
		;;
	esac
fi

if [[ "$cmd" == "classify-blocker" ]]; then
	signal="${1:-}"
	if [[ "$signal" == *"live_worker=true"* ]]; then
		printf 'dedup_active_claim_live_owner\n'
	else
		printf 'dedup_active_claim_unverified\n'
	fi
	exit 0
fi

exit 1
EOF
chmod +x "$HELPER_PATH"

# shellcheck source=../pulse-dispatch-dedup-layers.sh
source "${SCRIPTS_DIR}/pulse-dispatch-dedup-layers.sh"
# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"
# Sourced modules use SCRIPT_DIR for their own bootstrap; restore the fixture
# helper directory used by the Layer 6 tests below.
SCRIPT_DIR="$TMP_DIR"

FAST_FAIL_CALLS=0
LAST_FAST_FAIL=""
CLASSIFY_LOG="${TMP_DIR}/classify.log"
CONSOLIDATION_CALLS=0
LAST_CONSOLIDATION=""

reset_observations() {
	FAST_FAIL_CALLS=0
	LAST_FAST_FAIL=""
	CONSOLIDATION_CALLS=0
	LAST_CONSOLIDATION=""
	: >"$LOGFILE"
	: >"$CLASSIFY_LOG"
	return 0
}

test_active_claim_classifier_preserves_evidence() {
	local actual=""
	actual=$("$REAL_HELPER" classify-blocker 'ASSIGNED: live_worker=true durable_launch=true attempt_count=1')
	if [[ "$actual" != "dedup_active_claim_live_owner" ]]; then
		fail "active claim classifier identifies live owner" "actual=${actual}"
		return 0
	fi
	actual=$("$REAL_HELPER" classify-blocker 'STALE_RECOVERED stale_owner=true')
	if [[ "$actual" != "dedup_active_claim_stale_owner" ]]; then
		fail "active claim classifier identifies stale owner" "actual=${actual}"
		return 0
	fi
	actual=$("$REAL_HELPER" classify-blocker 'ASSIGNED: attempt_count=0 no dispatch claim comment found')
	if [[ "$actual" != "dedup_active_claim_zero_attempt" ]]; then
		fail "active claim classifier identifies zero-attempt claim" "actual=${actual}"
		return 0
	fi
	actual=$("$REAL_HELPER" classify-blocker 'skip from current pulse cycle current_cycle=true')
	if [[ "$actual" != "dedup_active_claim_current_cycle" ]]; then
		fail "active claim classifier identifies current-cycle suppression" "actual=${actual}"
		return 0
	fi
	pass "active claim classifier preserves live, stale, zero-attempt, and current-cycle evidence"
	return 0
}

test_live_owner_remains_blocked() {
	export TEST_STALE_MODE="live_owner"
	reset_observations
	local rc=0
	local output=""
	output=$(_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner") || rc=$?
	if [[ "$rc" -ne 0 || "$output" != *"live_worker=true"* ]]; then
		fail "live-owner active claim remains blocked" "rc=${rc} output=${output}"
		return 0
	fi
	if ! grep -q 'reason=dedup_active_claim_live_owner' "$LOGFILE" 2>/dev/null; then
		fail "live-owner active claim logs named evidence" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "live-owner active claim remains safely blocked"
	return 0
}

_route_terminal_breaker_to_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_source="$3"
	local breaker_detail="${4:-}"
	CONSOLIDATION_CALLS=$((CONSOLIDATION_CALLS + 1))
	LAST_CONSOLIDATION="${issue_number}|${repo_slug}|${breaker_source}|${breaker_detail}"
	return 0
}

fast_fail_record() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local provider="$4"
	local crash_type="$5"
	FAST_FAIL_CALLS=$((FAST_FAIL_CALLS + 1))
	LAST_FAST_FAIL="${issue_number}|${repo_slug}|${reason}|${provider}|${crash_type}"
	return 0
}

_classify_stale_recovery_crash_type() {
	local issue_number="$1"
	local repo_slug="$2"
	: "$issue_number" "$repo_slug"
	printf '%s|%s\n' "$issue_number" "$repo_slug" >>"$CLASSIFY_LOG"
	printf 'no_work'
	return 0
}

test_stale_recovery_without_claim_skips_fast_fail() {
	export TEST_STALE_MODE="no_worker"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "no-worker stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "no-worker stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if [[ -s "$CLASSIFY_LOG" ]]; then
		fail "no-worker stale recovery skips classifier" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if ! grep -q 'without worker evidence' "$LOGFILE" 2>/dev/null; then
		fail "no-worker stale recovery logs skip reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "no-worker stale recovery skips no_work fast-fail"
	return 0
}

test_prelaunch_canary_stale_recovery_skips_fast_fail() {
	export TEST_STALE_MODE="prelaunch_canary"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "prelaunch canary stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "prelaunch canary stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if [[ -s "$CLASSIFY_LOG" ]]; then
		fail "prelaunch canary stale recovery skips classifier" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if ! grep -q 'without worker evidence' "$LOGFILE" 2>/dev/null; then
		fail "prelaunch canary stale recovery logs skip reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "prelaunch canary stale recovery skips no_work fast-fail"
	return 0
}

test_stale_recovery_with_dispatch_claim_records_fast_fail() {
	export TEST_STALE_MODE="worker"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "worker stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$(tr '\n' ' ' <"$CLASSIFY_LOG")" != "2905|exampleorg/examplerepo " ]]; then
		fail "worker stale recovery classifies crash type" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 1 ]]; then
		fail "worker stale recovery records fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s)"
		return 0
	fi
	if [[ "$LAST_FAST_FAIL" != "2905|exampleorg/examplerepo|stale_timeout||no_work" ]]; then
		fail "worker stale recovery fast-fail payload" "payload: ${LAST_FAST_FAIL}"
		return 0
	fi
	pass "worker stale recovery still records no_work fast-fail"
	return 0
}

test_stale_recovery_blocked_by_dependency_blocks_redispatch() {
	export TEST_STALE_MODE="blocked_by"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "blocked-by stale recovery blocks redispatch" "expected rc=0, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "blocked-by stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if ! grep -q 'unresolved blocked-by dependency' "$LOGFILE" 2>/dev/null; then
		fail "blocked-by stale recovery logs redispatch block" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "blocked-by stale recovery blocks redispatch"
	return 0
}

test_terminal_stale_recovery_routes_consolidation_and_blocks() {
	export TEST_STALE_MODE="terminal"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "terminal stale recovery blocks redispatch" "expected rc=0, got rc=${rc}"
		return 0
	fi
	if [[ "$CONSOLIDATION_CALLS" -ne 1 || "$LAST_CONSOLIDATION" != 2905\|exampleorg/examplerepo\|stale-recovery-threshold\|STALE_ESCALATED:* ]]; then
		fail "terminal stale recovery routes consolidation once" \
			"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION}"
		return 0
	fi
	pass "terminal stale recovery routes consolidation once and blocks redispatch"
	return 0
}

test_terminal_pr_checkpoint_routes_existing_consolidation_guard() {
	export TEST_STALE_MODE="terminal_pr"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "terminal PR checkpoint blocks redispatch" "expected rc=0, got rc=${rc}"
		return 0
	fi
	if [[ "$CONSOLIDATION_CALLS" -ne 1 || "$LAST_CONSOLIDATION" != 2905\|exampleorg/examplerepo\|stale-pr-checkpoint\|STALE_PR_ESCALATED:* ]]; then
		fail "terminal PR checkpoint routes existing consolidation guard" \
			"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION}"
		return 0
	fi
	pass "terminal PR checkpoint routes consolidation guard and blocks redispatch"
	return 0
}

test_worker_draft_checkpoint_reaches_stale_guard_and_stays_blocked() {
	local result=""
	result=$(
		(
			local calls=""
			_dedup_layer1_ledger_check() { return 1; }
			_dedup_layer2_process_match() { return 1; }
			_dedup_layer3_title_match() { return 1; }
			_dedup_layer4_pr_evidence() { calls="${calls}4,"; return 2; }
			_dedup_layer5_dispatch_comment() { calls="${calls}5,"; return 1; }
			_dedup_layer6_assignee_and_stale() { calls="${calls}6,"; return 1; }

			local rc=0
			check_dispatch_dedup "2905" "exampleorg/examplerepo" "Issue #2905" "stale draft" "runner" || rc=$?
			printf '%s|%s' "$rc" "$calls"
		)
	)

	if [[ "$result" == "0|4,5,6," ]]; then
		pass "worker draft checkpoint reaches stale guard and cannot redispatch"
	else
		fail "worker draft checkpoint reaches stale guard and cannot redispatch" "result=${result}"
	fi
	return 0
}

test_protected_draft_remains_immediate_pr_block() {
	local result=""
	result=$(
		(
			local calls=""
			_dedup_layer1_ledger_check() { return 1; }
			_dedup_layer2_process_match() { return 1; }
			_dedup_layer3_title_match() { return 1; }
			_dedup_layer4_pr_evidence() { calls="${calls}4,"; return 0; }
			_dedup_layer5_dispatch_comment() { calls="${calls}5,"; return 1; }
			_dedup_layer6_assignee_and_stale() { calls="${calls}6,"; return 1; }

			local rc=0
			check_dispatch_dedup "2905" "exampleorg/examplerepo" "Issue #2905" "protected draft" "runner" || rc=$?
			printf '%s|%s' "$rc" "$calls"
		)
	)

	if [[ "$result" == "0|4," ]]; then
		pass "protected draft remains an immediate PR evidence block"
	else
		fail "protected draft remains an immediate PR evidence block" "result=${result}"
	fi
	return 0
}

test_remote_branch_liveness() {
	local result=""
	result=$(
		(
			# shellcheck source=../dispatch-dedup-stale.sh
			source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"
			SCRIPT_DIR="$SCRIPTS_DIR"
			STALE_ASSIGNMENT_THRESHOLD_SECONDS=600
			local tip_date=9880 branch_name="feature/auto-x-gh2905"
			local api_failed=false dispatch_ts=1000 activity_ts=1000
			local comments='[]' recovered=0 recovery_body=""
			local api_log="${TMP_DIR}/branch-api.log"
			date() { printf '10000\n'; return 0; }
			_ts_to_epoch() { local ts="$1"; printf '%s\n' "${ts:-0}"; return 0; }
			gh() {
				local args="$*"
				printf '%s\n' "$args" >>"$api_log"
				[[ "$api_failed" == true ]] && return 1
				# Pair case-pattern parentheses for Bash 3.2 inside nested $().
				case "$args" in
				(*git/matching-refs/heads/*)
					jq -nc --arg branch "$branch_name" '[[{ref:"refs/heads/main",object:{sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}],[{ref:("refs/heads/"+$branch),object:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]]'
					;;
				(*git/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa*) printf '%s\n' "$tip_date" ;;
				(*) return 1 ;;
				esac
				return 0
			}
			_interactive_claim_fence_blocks_dispatch() { return 1; }
			_stale_assignment_fetch_comments_json() { printf '%s' "$comments"; return 0; }
			_stale_assignment_load_threshold_context() {
				_STALE_CONTEXT_INTERACTIVE=false
				_STALE_CONTEXT_THRESHOLD=600
				_STALE_CONTEXT_CREATED_AT=1
				_STALE_CONTEXT_UPDATED_AT=1000
				return 0
			}
			_issue_too_young_for_staleness() { return 1; }
			_stale_assignment_latest_dispatch_ts() { printf '%s' "$dispatch_ts"; return 0; }
			_stale_assignment_latest_activity_ts() { printf '%s' "$activity_ts"; return 0; }
			_stale_assignment_has_recent_open_pr_activity() { return 1; }
			_stale_recovery_has_unresolved_blocked_by() { return 1; }
			_stale_recovery_fetch_comments_pages() { printf '[[]]'; return 0; }
			# The final takeover check independently protects a newly pushed tip.
			if _stale_recovery_final_evidence_recheck 2905 owner/repo "" true; then
				printf 'final recheck ignored recent push'; exit 1
			fi
			# Capture the real normal-recovery audit comment without external writes.
			_stale_recovery_final_evidence_recheck() { return 0; }
			set_issue_status() { return 0; }
			_stale_recovery_verify_transition() { return 0; }
			aidevops_ops_marker() { return 0; }
			gh_issue_comment() { recovery_body="$*"; return 0; }
			_recover_stale_assignment() {
				local issue="$1" repo="$2" assignees="$3" reason="$4"
				recovered=$((recovered + 1))
				_stale_recovery_apply "$issue" "$repo" "$assignees" "$reason" >/dev/null
				return 0
			}
			if _is_stale_assignment 2905 owner/repo runner; then
				printf '120s-old branch was recovered'; exit 1
			fi
			[[ "$recovered" -eq 0 ]] || exit 1
			tip_date=2800
			_is_stale_assignment 2905 owner/repo runner || exit 1
			[[ "$recovered" -eq 1 && "$recovery_body" == *"Last pushed issue branch: feature/auto-x-gh2905 (commit aaaa"* ]] || exit 1
			# Matching the numeric issue boundary excludes another issue's branch.
			branch_name="feature/auto-x-gh29050"
			tip_date=9880
			: >"$api_log"
			_is_stale_assignment 2905 owner/repo runner || exit 1
			if grep -q 'git/commits/' "$api_log"; then exit 1; fi
			[[ -z "$_STALE_BRANCH_CHECKPOINT" ]] || exit 1
			# A trusted dispatch can name a branch outside the automatic convention.
			branch_name="feature/custom"
			comments='[{"author_association":"COLLABORATOR","created_at":"1000","body":"DISPATCH_CLAIM branch=feature/custom"}]'
			if _is_stale_assignment 2905 owner/repo runner; then exit 1; fi
			comments='[{"author_association":"NONE","created_at":"1000","body":"DISPATCH_CLAIM branch=feature/custom"}]'
			_is_stale_assignment 2905 owner/repo runner || exit 1
			# No-claim assignments still honor pushed work, and API failure is not death.
			comments='[]'
			branch_name="feature/auto-x-gh2905"
			dispatch_ts=""
			if _is_stale_assignment 2905 owner/repo runner; then exit 1; fi
			api_failed=true
			if _is_stale_assignment 2905 owner/repo runner; then exit 1; fi
			# Ordinary recent issue activity must not spend branch lookup budget.
			: >"$api_log"
			activity_ts=9880
			if _is_stale_assignment 2905 owner/repo runner; then exit 1; fi
			[[ ! -s "$api_log" ]] || exit 1
			printf 'ok'
		)
	) || true
	if [[ "$result" == "ok" ]]; then
		pass "branch pushes protect ownership; old tips survive in recovery evidence"
	else
		fail "remote branch liveness and recovery evidence" "$result"
	fi
	return 0
}

test_remote_branch_liveness
test_active_claim_classifier_preserves_evidence
test_live_owner_remains_blocked
test_stale_recovery_without_claim_skips_fast_fail
test_prelaunch_canary_stale_recovery_skips_fast_fail
test_stale_recovery_with_dispatch_claim_records_fast_fail
test_stale_recovery_blocked_by_dependency_blocks_redispatch
test_terminal_stale_recovery_routes_consolidation_and_blocks
test_terminal_pr_checkpoint_routes_existing_consolidation_guard
test_worker_draft_checkpoint_reaches_stale_guard_and_stays_blocked
test_protected_draft_remains_immediate_pr_block

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
