#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
export FAST_FAIL_STATE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
export FAST_FAIL_SKIP_THRESHOLD=5
export FAST_FAIL_EXPIRY_SECS=604800
export FAST_FAIL_INITIAL_BACKOFF_SECS=600
export FAST_FAIL_MAX_BACKOFF_SECS=604800
export AIDEVOPS_OBJECTIVE_EVIDENCE_FILE="${TEST_ROOT}/objective-evidence.jsonl"
export AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/ledger"
mkdir -p "${FAST_FAIL_STATE_FILE%/*}"
mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

log_msg() {
	local message="$1"
	printf '%s\n' "$message" >>"$LOGFILE"
	return 0
}

escalate_issue_tier() {
	return 0
}

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../worker-lifecycle-common.sh
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=../pulse-fast-fail.sh
source "${SCRIPTS_DIR}/pulse-fast-fail.sh"
# shellcheck source=../worker-watchdog-ff.sh
source "${SCRIPTS_DIR}/worker-watchdog-ff.sh"
# shellcheck source=../pulse-quality-debt.sh
source "${SCRIPTS_DIR}/pulse-quality-debt.sh"

OBJECTIVE_HELPER="${SCRIPTS_DIR}/objective-reconciliation-helper.sh"
"$OBJECTIVE_HELPER" record-outcome --repo owner/repo --issue 501 \
	--attempt-id attempt-success --run-id run-success --raw-result premature_exit \
	--outcome success --status recovered --classification worker_complete --next-action monitor_pr
"$OBJECTIVE_HELPER" record-outcome --repo owner/repo --issue 502 \
	--attempt-id attempt-failed --run-id run-failed --raw-result premature_exit \
	--outcome failed --status failed --classification worker_failed --next-action narrow_redispatch
"$OBJECTIVE_HELPER" record-outcome --repo owner/repo --issue 503 \
	--attempt-id attempt-old-success --run-id run-old --raw-result premature_exit \
	--outcome success --status recovered --classification worker_complete --next-action monitor_pr
"$OBJECTIVE_HELPER" record-outcome --repo owner/repo --issue 504 \
	--attempt-id attempt-ledger-success --run-id run-ledger --raw-result premature_exit \
	--outcome success --status recovered --classification worker_complete --next-action monitor_pr

cat >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" <<'JSONL'
{"session_key":"issue-503","attempt_id":"attempt-current-without-outcome","issue_number":"503","repo_slug":"owner/repo","status":"failed"}
{"session_key":"issue-504","attempt_id":"attempt-ledger-success","issue_number":"504","repo_slug":"owner/repo","status":"completed"}
JSONL

fast_fail_record 501 owner/repo premature_exit openai overwhelmed attempt-success
if [[ -s "$FAST_FAIL_STATE_FILE" ]] && jq -e '."owner/repo/501" != null' "$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	fail "pulse fast-fail recorded a reconciled success"
fi

fast_fail_record 502 owner/repo premature_exit openai overwhelmed attempt-failed
if ! jq -e '."owner/repo/502".count == 1' "$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	fail "pulse fast-fail suppressed a reconciled failure"
fi

fast_fail_record 503 owner/repo premature_exit openai overwhelmed
if ! jq -e '."owner/repo/503".count == 1' "$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	fail "pulse fast-fail let an older successful attempt suppress the current unresolved attempt"
fi

fast_fail_record 504 owner/repo premature_exit openai overwhelmed
if jq -e '."owner/repo/504" != null' "$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	fail "pulse fast-fail did not resolve the current successful attempt from the dispatch ledger"
fi

_watchdog_record_failure_and_escalate 501 owner/repo stall openai overwhelmed attempt-success
if jq -e '."owner/repo/501" != null' "$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	fail "watchdog fast-fail recorded a reconciled success"
fi

_watchdog_record_failure_and_escalate 504 owner/repo stall openai overwhelmed
if jq -e '."owner/repo/504" != null' "$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	fail "watchdog fast-fail did not correlate the current ledger attempt"
fi

if ! _enrichment_should_skip_for_objective 501 owner/repo; then
	fail "quality-debt enrichment did not suppress reconciled success"
fi
if _enrichment_should_skip_for_objective 502 owner/repo; then
	fail "quality-debt enrichment suppressed reconciled failure"
fi

if [[ "$(_enrichment_parse_fast_fail_key owner/repo/501)" != $'501\towner/repo' ]]; then
	fail "quality-debt enrichment could not parse the canonical fast-fail key"
fi
if [[ "$(_enrichment_parse_fast_fail_key 501:owner/repo)" != $'501\towner/repo' ]]; then
	fail "quality-debt enrichment lost legacy fast-fail key compatibility"
fi

ENRICHMENT_MAX_PER_CYCLE=5
STOP_FLAG="${TEST_ROOT}/stop"
ENRICHMENT_MODEL_CALLS="${TEST_ROOT}/enrichment-model-calls"
ENRICHMENT_RUN_CALLS="${TEST_ROOT}/enrichment-run-calls"
ENRICHMENT_MARK_CALLS="${TEST_ROOT}/enrichment-mark-calls"
_ff_load() {
	printf '%s\n' '{"owner/repo/501":{"enrichment_needed":true},"owner/repo/502":{"enrichment_needed":true}}'
	return 0
}
_ff_with_lock() {
	printf '%s\n' "$*" >>"$ENRICHMENT_MARK_CALLS"
	return 0
}
_enrichment_resolve_model() {
	printf 'resolve\n' >>"$ENRICHMENT_MODEL_CALLS"
	printf 'test/model\n'
	return 0
}
_enrichment_resolve_repo_path() {
	printf '%s\n' "$TEST_ROOT"
	return 0
}
_enrichment_fetch_issue_data() {
	printf '%s\n' '{"title":"test","body":"brief","prior_attempt":{"effective_outcome":"failed"}}'
	return 0
}
_enrichment_build_prompt() {
	printf '/dev/null\n'
	return 0
}
_enrichment_run_worker() {
	printf '%s\n' "$2" >>"$ENRICHMENT_RUN_CALLS"
	return 0
}
remaining_slots=$(dispatch_enrichment_workers 2)
if [[ "$remaining_slots" != "1" ]]; then
	fail "quality-debt enrichment consumed a slot for a reconciled success: ${remaining_slots}"
fi
if [[ "$(wc -l <"$ENRICHMENT_MODEL_CALLS" | tr -d ' ')" != "1" ]]; then
	fail "quality-debt enrichment did not resolve its model lazily after suppression"
fi
if [[ "$(<"$ENRICHMENT_RUN_CALLS")" != "502" ]]; then
	fail "quality-debt enrichment routed the wrong effective outcome"
fi
if [[ "$(wc -l <"$ENRICHMENT_MARK_CALLS" | tr -d ' ')" != "2" ]]; then
	fail "quality-debt enrichment did not finalize both suppressed and processed entries"
fi

printf 'PASS worker outcome routing consults reconciled dispositions\n'
