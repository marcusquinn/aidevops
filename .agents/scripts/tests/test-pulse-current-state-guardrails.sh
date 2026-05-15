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

test_external_benign_block_ledger_is_preserved_and_refreshed() {
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
	if [[ "$ledger_path" == "$external_ledger" ]] && [[ -f "$external_ledger" ]] && ! grep -q $'^101\tmarcusquinn/aidevops\tcaller_managed$' "$external_ledger" && grep -q $'^23575\tmarcusquinn/aidevops\tdedup_active_claim$' "$external_ledger"; then
		print_result "guardrail: external benign block ledger is preserved and refreshed" 0
	else
		print_result "guardrail: external benign block ledger is preserved and refreshed" 1 "ledger=${ledger_path}"
	fi
	return 0
}

test_apply_dispatch_max_preserves_benign_ledger_across_refill() {
	reset_guardrail_env
	export AIDEVOPS_MIN_WORKER_CONCURRENCY=2
	local dispatch_calls_file="${TEST_ROOT}/dispatch-calls"
	local refill_reason_file="${TEST_ROOT}/refill-seen-reason"
	local child_env_file="${TEST_ROOT}/refill-child-env-sees-ledger"
	printf '0\n' >"$dispatch_calls_file"
	: >"$refill_reason_file"
	: >"$child_env_file"
	local dispatch_calls=""
	local refill_seen_reason=""
	local child_env_seen=""
	local ledger_after=""

	dispatch_max() {
		local current_calls=""
		current_calls=$(<"$dispatch_calls_file")
		[[ "$current_calls" =~ ^[0-9]+$ ]] || current_calls=0
		current_calls=$((current_calls + 1))
		printf '%s\n' "$current_calls" >"$dispatch_calls_file"
		if [[ "$current_calls" -eq 1 ]]; then
			_dispatch_mark_benign_blocked_candidate 23541 marcusquinn/aidevops dedup_active_claim
			printf '1\n'
		else
			if bash -c '[[ -n "${_DISPATCH_BENIGN_BLOCKS_FILE:-}" && -f "${_DISPATCH_BENIGN_BLOCKS_FILE}" ]]'; then
				printf 'yes\n' >"$child_env_file"
			fi
			_dispatch_benign_blocked_candidate_reason 23541 marcusquinn/aidevops >"$refill_reason_file" 2>/dev/null || true
			printf '0\n'
		fi
		return 0
	}

	count_active_workers() {
		printf '0\n'
		return 0
	}

	_adaptive_launch_settle_wait() {
		return 0
	}

	apply_dispatch_max
	dispatch_calls=$(<"$dispatch_calls_file")
	refill_seen_reason=$(<"$refill_reason_file")
	child_env_seen=$(<"$child_env_file")
	ledger_after="${_DISPATCH_BENIGN_BLOCKS_FILE:-}"
	unset AIDEVOPS_MIN_WORKER_CONCURRENCY
	if [[ "$dispatch_calls" -ge 2 && "$refill_seen_reason" == "dedup_active_claim" && "$child_env_seen" == "yes" && -z "$ledger_after" ]]; then
		print_result "guardrail: apply_dispatch_max preserves benign block ledger across refill" 0
	else
		print_result "guardrail: apply_dispatch_max preserves benign block ledger across refill" 1 "calls=${dispatch_calls} reason=${refill_seen_reason} child_env=${child_env_seen} ledger_after=${ledger_after}"
	fi
	return 0
}

test_ranked_candidates_prioritise_solvable_work() {
	reset_guardrail_env
	local repos_file="${TEST_ROOT}/repos.json"
	cat >"$repos_file" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/repo", "path": "/tmp/repo", "pulse": true, "priority": "tooling"}
  ]
}
JSON
	export REPOS_JSON="$repos_file"

	check_repo_pulse_schedule() {
		return 0
	}

	check_repo_pulse_interval() {
		return 0
	}

	update_repo_pulse_timestamp() {
		return 0
	}

	list_dispatchable_issue_candidates_json() {
		local repo_slug="$1"
		local limit="$2"
		printf '%s %s\n' "$repo_slug" "$limit" >/dev/null
		cat <<'JSON'
[
  {"number": 10, "title": "broad enhancement", "updatedAt": "2026-05-01T00:00:00Z", "labels": [{"name": "enhancement"}, {"name": "tier:thinking"}], "assignees": []},
  {"number": 11, "title": "small worker-ready fix", "updatedAt": "2026-05-02T00:00:00Z", "labels": [{"name": "enhancement"}, {"name": "tier:simple"}, {"name": "worker-ready"}, {"name": "auto-dispatch"}], "assignees": []},
  {"number": 12, "title": "plain bug", "updatedAt": "2026-05-03T00:00:00Z", "labels": [{"name": "bug"}], "assignees": []}
]
JSON
		return 0
	}

	local first_number=""
	first_number=$(build_ranked_dispatch_candidates_json 10 | jq -r '.[0].number' 2>/dev/null) || first_number=""
	if [[ "$first_number" == "11" ]]; then
		print_result "guardrail: ranked dispatch prefers solvable worker-ready issues over raw backlog" 0
	else
		print_result "guardrail: ranked dispatch prefers solvable worker-ready issues over raw backlog" 1 "first=${first_number}"
	fi
	return 0
}

test_ranked_candidates_prioritise_low_complexity_over_research() {
	reset_guardrail_env
	local repos_file="${TEST_ROOT}/repos-low-complexity.json"
	cat >"$repos_file" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/repo", "path": "/tmp/repo", "pulse": true, "priority": "tooling"}
  ]
}
JSON
	export REPOS_JSON="$repos_file"

	check_repo_pulse_schedule() {
		return 0
	}

	check_repo_pulse_interval() {
		return 0
	}

	update_repo_pulse_timestamp() {
		return 0
	}

	list_dispatchable_issue_candidates_json() {
		local repo_slug="$1"
		local limit="$2"
		printf '%s %s\n' "$repo_slug" "$limit" >/dev/null
		cat <<'JSON'
[
  {"number": 20, "title": "broad research priority", "updatedAt": "2026-05-01T00:00:00Z", "labels": [{"name": "priority:high"}, {"name": "research"}, {"name": "tier:thinking"}], "assignees": []},
  {"number": 21, "title": "low complexity actionable fix", "updatedAt": "2026-05-02T00:00:00Z", "labels": [{"name": "enhancement"}, {"name": "low-complexity"}, {"name": "status:available"}], "assignees": []}
]
JSON
		return 0
	}

	local first_number=""
	first_number=$(build_ranked_dispatch_candidates_json 10 | jq -r '.[0].number' 2>/dev/null) || first_number=""
	if [[ "$first_number" == "21" ]]; then
		print_result "guardrail: ranked dispatch prefers low-complexity actionable work over research backlog" 0
	else
		print_result "guardrail: ranked dispatch prefers low-complexity actionable work over research backlog" 1 "first=${first_number}"
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
test_external_benign_block_ledger_is_preserved_and_refreshed
test_apply_dispatch_max_preserves_benign_ledger_across_refill
test_ranked_candidates_prioritise_solvable_work
test_ranked_candidates_prioritise_low_complexity_over_research

printf '\n====================\n'
printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
printf '====================\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
