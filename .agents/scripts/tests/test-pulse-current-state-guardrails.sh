#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-current-state-guardrails.sh — mission m-20260504-1e325d task 3.4.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
export AIDEVOPS_HEADLESS_METRICS_FILE="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
: >"$LOGFILE"
: >"$AIDEVOPS_HEADLESS_METRICS_FILE"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

STATS_COUNTER_FILE="${TEST_ROOT}/stats-counter.log"
STATS_GAUGE_FILE="${TEST_ROOT}/stats-gauge.log"
: >"$STATS_COUNTER_FILE"
: >"$STATS_GAUGE_FILE"

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}

pulse_stats_set_gauge() {
	local gauge_name="$1"
	local gauge_value="$2"
	printf '%s=%s\n' "$gauge_name" "$gauge_value" >>"$STATS_GAUGE_FILE"
	return 0
}

reset_guardrail_env() {
	: >"$LOGFILE"
	: >"$AIDEVOPS_HEADLESS_METRICS_FILE"
	: >"$STATS_COUNTER_FILE"
	: >"$STATS_GAUGE_FILE"
	unset PULSE_DISPATCH_CURRENT_STATE_COUNTS 2>/dev/null || true
	unset AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS 2>/dev/null || true
	export PULSE_DISPATCH_GUARDRAIL_RATE_LIMIT_THRESHOLD=4
	export PULSE_DISPATCH_GUARDRAIL_FAILURE_THRESHOLD=6
	export PULSE_DISPATCH_GUARDRAIL_HEALTHY_PR_THRESHOLD=3
	export PULSE_DISPATCH_GUARDRAIL_NO_DISPATCHABLE_THRESHOLD=2
	return 0
}

guardrail_slots() {
	local counts="$1"
	local available_slots="$2"
	export PULSE_DISPATCH_CURRENT_STATE_COUNTS="$counts"
	_dispatch_apply_current_state_guardrails 24 4 "$available_slots" | awk '{print $3}'
	return 0
}

test_provider_rate_limits_pause_without_success() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 4 4 0 0" 8)
	if [[ "$slots" == "0" ]] && grep -q 'provider_rate_limit_pressure' "$LOGFILE"; then
		print_result "guardrail: provider-wide rate limits pause launches when no success evidence exists" 0
	else
		print_result "guardrail: provider-wide rate limits pause launches when no success evidence exists" 1 "slots=${slots}"
	fi
	return 0
}

test_provider_rate_limits_keep_probe_slot_with_success() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "2 6 5 0 0" 8)
	if [[ "$slots" == "1" ]]; then
		print_result "guardrail: provider pressure keeps one safe probe slot when successes exist" 0
	else
		print_result "guardrail: provider pressure keeps one safe probe slot when successes exist" 1 "slots=${slots}"
	fi
	return 0
}

test_repeated_failures_pause_without_success() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 6 0 0 0" 8)
	if [[ "$slots" == "0" ]] && grep -q 'repeated_failure_pressure' "$LOGFILE"; then
		print_result "guardrail: repeated failures pause raw concurrency without success evidence" 0
	else
		print_result "guardrail: repeated failures pause raw concurrency without success evidence" 1 "slots=${slots}"
	fi
	return 0
}

test_healthy_pr_backlog_rations_new_launches() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "1 3 0 3 0" 8)
	if [[ "$slots" == "1" ]] && grep -q 'healthy_pr_backlog' "$LOGFILE"; then
		print_result "guardrail: active healthy PR evidence rations new issue launches" 0
	else
		print_result "guardrail: active healthy PR evidence rations new issue launches" 1 "slots=${slots}"
	fi
	return 0
}

test_no_dispatchable_evidence_keeps_probe_slot() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "0 0 0 0 2" 8)
	if [[ "$slots" == "1" ]] && grep -q 'no_dispatchable_evidence' "$LOGFILE"; then
		print_result "guardrail: no-dispatchable evidence keeps one probe slot" 0
	else
		print_result "guardrail: no-dispatchable evidence keeps one probe slot" 1 "slots=${slots}"
	fi
	return 0
}

test_clean_state_preserves_available_slots() {
	reset_guardrail_env
	local slots
	slots=$(guardrail_slots "3 1 0 0 0" 8)
	if [[ "$slots" == "8" ]] && grep -q '^pulse_dispatch_guardrail_available_slots=8$' "$STATS_GAUGE_FILE" && grep -q '^pulse_dispatch_guardrail_successes=3$' "$STATS_GAUGE_FILE"; then
		print_result "guardrail: clean current state preserves safe slots" 0
	else
		print_result "guardrail: clean current state preserves safe slots" 1 "slots=${slots}"
	fi
	return 0
}

test_disabled_guardrail_still_updates_available_slots_gauge() {
	reset_guardrail_env
	export AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
	local slots
	slots=$(guardrail_slots "0 0 0 0 0" 5)
	if [[ "$slots" == "5" ]] && grep -q '^pulse_dispatch_guardrail_available_slots=5$' "$STATS_GAUGE_FILE"; then
		print_result "guardrail: disabled current-state path still refreshes slot gauge" 0
	else
		print_result "guardrail: disabled current-state path still refreshes slot gauge" 1 "slots=${slots}"
	fi
	return 0
}

test_interactive_hold_reason_is_classified() {
	reset_guardrail_env
	printf '%s\n' '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=interactive_review_hold signal=interactive_review_hold issue=#4772 repo=awardsapp/awardsapp' >>"$LOGFILE"
	local reason
	reason=$(_dispatch_candidate_failure_reason 4772 awardsapp/awardsapp 3)
	if [[ "$reason" == "interactive_review_hold" ]]; then
		print_result "guardrail: interactive review hold classifies as benign block" 0
	else
		print_result "guardrail: interactive review hold classifies as benign block" 1 "reason=${reason}"
	fi
	return 0
}

test_pr_target_reason_is_classified_as_benign_block() {
	reset_guardrail_env
	printf '%s\n' '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=pr_target_not_dispatchable signal=pr_target_not_dispatchable issue=#4849 repo=awardsapp/awardsapp' >>"$LOGFILE"
	local reason
	reason=$(_dispatch_candidate_failure_reason 4849 awardsapp/awardsapp 3)
	if [[ "$reason" == "pr_target_not_dispatchable" ]] && _dispatch_candidate_benign_block_reason "$reason"; then
		print_result "guardrail: PR target classifies as benign block" 0
	else
		print_result "guardrail: PR target classifies as benign block" 1 "reason=${reason}"
	fi
	return 0
}

test_benign_block_ledger_is_cycle_local_and_cleaned() {
	reset_guardrail_env
	local first_ledger second_ledger lingering_reason=""
	_dispatch_begin_benign_blocks_cycle >/dev/null
	first_ledger="$_DISPATCH_BENIGN_BLOCKS_FILE"
	_dispatch_mark_benign_blocked_candidate 23541 marcusquinn/aidevops dedup_active_claim
	_dispatch_cleanup_benign_blocks_cycle
	_dispatch_begin_benign_blocks_cycle >/dev/null
	second_ledger="$_DISPATCH_BENIGN_BLOCKS_FILE"
	lingering_reason=$(_dispatch_benign_blocked_candidate_reason 23541 marcusquinn/aidevops 2>/dev/null || true)
	_dispatch_cleanup_benign_blocks_cycle
	if [[ "$first_ledger" != "$second_ledger" && ! -e "$first_ledger" && ! -e "$second_ledger" && -z "$lingering_reason" ]]; then
		print_result "guardrail: benign block ledger is cycle-local and cleaned" 0
	else
		print_result "guardrail: benign block ledger is cycle-local and cleaned" 1 "first=${first_ledger} second=${second_ledger} lingering=${lingering_reason}"
	fi
	return 0
}

test_external_benign_block_ledger_is_preserved() {
	reset_guardrail_env
	local external_ledger="${TEST_ROOT}/external-benign-blocks.tsv"
	local ledger_path=""
	printf '%s\t%s\t%s\n' 101 marcusquinn/aidevops caller_managed >"$external_ledger"
	export AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE="$external_ledger"
	_dispatch_begin_benign_blocks_cycle >/dev/null
	ledger_path="$_DISPATCH_BENIGN_BLOCKS_FILE"
	_dispatch_mark_benign_blocked_candidate 23575 marcusquinn/aidevops dedup_active_claim
	_dispatch_cleanup_benign_blocks_cycle
	unset AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE
	if [[ "$ledger_path" == "$external_ledger" ]] && [[ -f "$external_ledger" ]] && grep -q $'^101\tmarcusquinn/aidevops\tcaller_managed$' "$external_ledger" && grep -q $'^23575\tmarcusquinn/aidevops\tdedup_active_claim$' "$external_ledger"; then
		print_result "guardrail: external benign block ledger is preserved" 0
	else
		print_result "guardrail: external benign block ledger is preserved" 1 "ledger=${ledger_path}"
	fi
	return 0
}

test_provider_rate_limits_pause_without_success
test_provider_rate_limits_keep_probe_slot_with_success
test_repeated_failures_pause_without_success
test_healthy_pr_backlog_rations_new_launches
test_no_dispatchable_evidence_keeps_probe_slot
test_clean_state_preserves_available_slots
test_disabled_guardrail_still_updates_available_slots_gauge
test_interactive_hold_reason_is_classified
test_pr_target_reason_is_classified_as_benign_block
test_benign_block_ledger_is_cycle_local_and_cleaned
test_external_benign_block_ledger_is_preserved

printf '\n====================\n'
printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
printf '====================\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
