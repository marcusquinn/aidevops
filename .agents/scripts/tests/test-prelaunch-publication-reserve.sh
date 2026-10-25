#!/usr/bin/env bash
# shellcheck disable=SC2218  # Functions defined via dynamic source
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-prelaunch-publication-reserve.sh — GH#35602 regression guard.
#
# Queued ownership must never be published when the remaining prelaunch
# budget cannot reach spawn. The real _dispatch_launch_worker orchestrator,
# _dlw_lock_prelaunch_issue, _dlw_publish_queued_ownership and
# _dlw_prelaunch_budget_available run; GitHub, worktree and runtime I/O are
# stubbed, and elapsed time is advanced through Bash SECONDS (no sleeps).
#
# Asserts:
#   1. reserve short before the issue lock: no lock, assignment or spawn
#   2. reserve consumed by a slow ownership fence (worked example from the
#      issue): abort after the fence and before _dlw_assign_and_label
#   3. sufficient reserve: assignment and spawn still happen
#   4. an exhausted budget keeps the prelaunch_budget_exhausted reason
#   5. AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS=0 restores the old
#      remaining>0 boundary; an invalid value falls back to the default

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  FAIL %s\n' "$1"
	[[ -z "${2:-}" ]] || printf '       %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t gh35602.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export AIDEVOPS_TEMP_DIR="${TMP}/agent-tmp"
mkdir -p "$AIDEVOPS_TEMP_DIR"
export LOGFILE="${TMP}/pulse.log"
export SCRIPT_DIR="$TMP"
export AIDEVOPS_DISPATCH_STAGES_LOG="${TMP}/dispatch-stages.tsv"
export AIDEVOPS_WORKER_BACKEND=detached
unset AIDEVOPS_DISPATCH_PRELAUNCH_BUDGET_SECONDS AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS
FAKE_REPO="${TMP}/fake-repo"
WORKTREE="${TMP}/worktree"
mkdir -p "$FAKE_REPO" "$WORKTREE"
CALLS_FILE="${TMP}/calls.txt"
STAGES_FILE="${TMP}/stages.txt"

set +e
unset _PULSE_DISPATCH_WORKER_LAUNCH_LOADED
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"
SCRIPT_DIR="$TMP"

# --- Stubs (defined after sourcing so they replace the real I/O) ---------
_ds_now_ns() { printf '0'; return 0; }
_ds_stage_start() { return 0; }
_ds_record() {
	local stage_name="$3"
	printf '%s\n' "$stage_name" >>"$STAGES_FILE"
	return 0
}
aidevops_generate_execution_id() { printf 'attempt-test'; return 0; }
_worker_attempt_start_marker() { printf '123'; return 0; }
_dlw_setup_worker_log() { printf '%s' "${TMP}/worker.log"; return 0; }
_dlw_prebootstrap_gates() { return 0; }
_dlw_resolve_tier_and_model() {
	_DLW_DISPATCH_TIER="standard" _DLW_DISPATCH_MODEL_TIER="standard" _DLW_SELECTED_MODEL=""
	return 0
}
_dlw_assign_model_ab() { return 0; }
_dlw_canary_preflight() { return 0; }
_dlw_claim_lock_after_canary() { return 0; }
_dlw_comment_bloat_metrics() { printf '0\t0\t0\t0\n'; return 0; }
_dlw_hold_repeated_zero_output() { return 1; }
_dlw_resolve_seed_base() { return 0; }
_dlw_seed_prompt_note() { return 0; }
_dlw_precreate_worktree() {
	printf 'precreate\n' >>"$CALLS_FILE"
	SECONDS=$((SECONDS + STUB_PRECREATE_DELAY))
	_DLW_WORKTREE_PATH="$WORKTREE" _DLW_WORKTREE_BRANCH="feature/auto-test" _DLW_WORKTREE_REUSED=0
	return 0
}
_dlw_final_worker_spawn_gates() { return 0; }
_dlw_prepare_prompt_for_launch() { printf 'prompt'; return 0; }
lock_issue_for_worker() { printf 'lock\n' >>"$CALLS_FILE"; return 0; }
_dlw_final_assignment_guard() {
	printf 'ownership-guard\n' >>"$CALLS_FILE"
	SECONDS=$((SECONDS + STUB_FENCE_DELAY))
	return 0
}
_dlw_assign_and_label() { printf 'assign\n' >>"$CALLS_FILE"; return 0; }
_dlw_start_codegraph_init() { return 0; }
_dlw_live_issue_open_guard() { printf 'live-guard\n' >>"$CALLS_FILE"; return 0; }
_dlw_nohup_launch() { printf 'spawn\n' >>"$CALLS_FILE"; printf '12345'; return 0; }
_dlw_post_launch_hooks() { return 0; }

# Args: precreate delay, fence delay. Sets RUN_RC, RUN_CALLS, RUN_REASON.
run_launch() {
	local precreate_delay="$1" fence_delay="$2"
	STUB_PRECREATE_DELAY="$precreate_delay" STUB_FENCE_DELAY="$fence_delay"
	: >"$CALLS_FILE"
	: >"$STAGES_FILE"
	RUN_RC=0
	SECONDS=0
	_dispatch_launch_worker 35602 owner/repo dispatch issue testuser "$FAKE_REPO" prompt \
		issue-35602 "" '{}' || RUN_RC=$?
	RUN_CALLS=$(tr '\n' ' ' <"$CALLS_FILE")
	RUN_REASON="${_DLW_LAST_PRE_RUNTIME_FAILURE:-}"
	return 0
}

printf '\n%s\n' "=== GH#35602: prelaunch publication reserve ==="

# 1. 60 s remain after precreation (< 75 s default): stop before the lock.
run_launch 240 0
if [[ "$RUN_RC" -eq 2 && "$RUN_CALLS" == "precreate " && "$RUN_REASON" == "prelaunch_reserve_insufficient" ]] &&
	grep -qx 'pre_runtime_failure:prelaunch_reserve_insufficient' "$STAGES_FILE"; then
	pass "short reserve aborts before lock, assignment and spawn with a distinct reason"
else
	fail "short reserve aborts before lock, assignment and spawn with a distinct reason" \
		"rc=$RUN_RC calls='$RUN_CALLS' reason='$RUN_REASON'"
fi

# 2. Worked example: 100 s remain at the fence, the fence takes 41 s, 59 s
# remain. The old remaining>0 check published here and the worker never ran.
run_launch 200 41
if [[ "$RUN_RC" -eq 2 && "$RUN_CALLS" == "precreate lock ownership-guard " && "$RUN_REASON" == "prelaunch_reserve_insufficient" ]]; then
	pass "slow ownership fence aborts before _dlw_assign_and_label"
else
	fail "slow ownership fence aborts before _dlw_assign_and_label" \
		"rc=$RUN_RC calls='$RUN_CALLS' reason='$RUN_REASON'"
fi

# 3. Sufficient reserve still publishes and spawns.
run_launch 100 10
if [[ "$RUN_RC" -eq 0 && "$RUN_CALLS" == "precreate lock ownership-guard assign live-guard spawn " ]]; then
	pass "sufficient reserve publishes ownership and spawns"
else
	fail "sufficient reserve publishes ownership and spawns" "rc=$RUN_RC calls='$RUN_CALLS' reason='$RUN_REASON'"
fi

# 4. An expired budget keeps its existing reason.
run_launch 301 0
if [[ "$RUN_RC" -eq 2 && "$RUN_CALLS" == "precreate " && "$RUN_REASON" == "prelaunch_budget_exhausted" ]]; then
	pass "exhausted budget keeps prelaunch_budget_exhausted"
else
	fail "exhausted budget keeps prelaunch_budget_exhausted" "rc=$RUN_RC calls='$RUN_CALLS' reason='$RUN_REASON'"
fi

# 5. Operator override: 0 disables the reserve; invalid values use the default.
export AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS=0
run_launch 290 0
if [[ "$RUN_RC" -eq 0 && "$RUN_CALLS" == "precreate lock ownership-guard assign live-guard spawn " ]]; then
	pass "reserve 0 restores the remaining>0 publication boundary"
else
	fail "reserve 0 restores the remaining>0 publication boundary" "rc=$RUN_RC calls='$RUN_CALLS' reason='$RUN_REASON'"
fi
export AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS=not-a-number
run_launch 240 0
if [[ "$RUN_RC" -eq 2 && "$RUN_CALLS" == "precreate " && "$RUN_REASON" == "prelaunch_reserve_insufficient" ]]; then
	pass "invalid reserve value falls back to the default"
else
	fail "invalid reserve value falls back to the default" "rc=$RUN_RC calls='$RUN_CALLS' reason='$RUN_REASON'"
fi
unset AIDEVOPS_DISPATCH_PUBLICATION_RESERVE_SECONDS

printf '\n%s\n' "--- Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ---"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
