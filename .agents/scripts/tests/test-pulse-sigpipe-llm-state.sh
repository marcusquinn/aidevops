#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME="${ROOT}/home"
PULSE_DIR="${HOME}/.aidevops/.agent-workspace/supervisor"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"
mkdir -p "$PULSE_DIR" "$(dirname "$LOGFILE")" "$(dirname "$REPOS_JSON")"
printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	return 1
}

safe_emit_output=$(
	set -euo pipefail
	for i in $(seq 1 20000); do
		_emit_stdout_line_safely "$i"
	done | sed -n '1p'
)
[[ "$safe_emit_output" == "1" ]] || fail "SIGPIPE-safe emit returned ${safe_emit_output}"

PULSE_LLM_DAILY_INTERVAL=100
PULSE_LLM_FAILURE_RETRY_INTERVAL=60
now_epoch=$(date +%s)
printf '%s\n' "$((now_epoch - 1000))" >"${PULSE_DIR}/last_llm_success_epoch"
printf '%s\n' "$((now_epoch - 10))" >"${PULSE_DIR}/last_llm_attempt_epoch"
if _should_run_llm_supervisor || [[ -f "${PULSE_DIR}/llm_trigger_mode" ]]; then
	fail "recent failed LLM attempt did not apply retry cooldown"
fi

printf '%s\n' "$((now_epoch - 120))" >"${PULSE_DIR}/last_llm_attempt_epoch"
_should_run_llm_supervisor || fail "old failed LLM attempt did not permit retry"
[[ "$(cat "${PULSE_DIR}/llm_trigger_mode")" == "daily_sweep" ]] || fail "retry trigger was not daily_sweep"

rm -f "${PULSE_DIR}/last_llm_attempt_epoch" "${PULSE_DIR}/last_llm_success_epoch" "${PULSE_DIR}/last_llm_run_epoch"
_pulse_record_llm_attempt "daily_sweep"
_pulse_record_llm_failure "daily_sweep" "7"
[[ -f "${PULSE_DIR}/last_llm_attempt_epoch" ]] || fail "attempt timestamp missing"
[[ ! -f "${PULSE_DIR}/last_llm_success_epoch" && ! -f "${PULSE_DIR}/last_llm_run_epoch" ]] || fail "failure wrote success timestamp"
_pulse_record_llm_success "daily_sweep"
[[ -f "${PULSE_DIR}/last_llm_success_epoch" && -f "${PULSE_DIR}/last_llm_run_epoch" ]] || fail "success timestamps missing"

printf 'PASS pulse SIGPIPE and LLM state regressions\n'
