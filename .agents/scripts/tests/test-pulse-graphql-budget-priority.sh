#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="${TMP_DIR}/home"
export PULSE_JITTER_MAX=0
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export WRAPPER_LOGFILE="$LOGFILE"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache" "${HOME}/.aidevops/.agent-workspace/supervisor"

STUB_DIR="${TMP_DIR}/bin"
mkdir -p "$STUB_DIR"
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
	printf '{"login":"test-user"}\n'
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "rate_limit" ]]; then
	printf '{"resources":{"graphql":{"remaining":%s,"limit":5000}}}\n' "${GH_GRAPHQL_REMAINING:-5000}"
	exit 0
fi
printf '[]\n'
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
export PATH="${STUB_DIR}:${PATH}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../pulse-wrapper.sh" >/dev/null 2>&1

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"${TMP_DIR}/counters.log"
	return 0
}

_cb_rate_limit_json() {
	local mode="${1:-normal}"
	[[ -n "$mode" ]] || mode="normal"
	printf '{"resources":{"graphql":{"remaining":%s,"limit":5000}}}\n' "${GH_GRAPHQL_REMAINING:-5000}"
	return 0
}

export AIDEVOPS_PULSE_OPTIONAL_BUDGET_THRESHOLD=1250
export GH_GRAPHQL_REMAINING=100
_pulse_set_graphql_budget_priority
[[ "${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS}" == "reserve" ]]
_pulse_should_defer_budget_priority_stage "dashboard_freshness_check"
_pulse_should_defer_budget_priority_stage "evaluate_routines"
if _pulse_should_defer_budget_priority_stage "deterministic_merge_pass"; then
	printf 'FAIL: merge-critical stage was deferred\n' >&2
	exit 1
fi
if _pulse_should_defer_budget_priority_stage "dispatch_max"; then
	printf 'FAIL: dispatch-critical stage was deferred\n' >&2
	exit 1
fi

_pulse_defer_budget_priority_stage "dashboard_freshness_check"
grep -q 'pulse_graphql_budget_reserve_mode' "${TMP_DIR}/counters.log"
grep -q 'pulse_graphql_budget_stage_deferred_dashboard_freshness_check' "${TMP_DIR}/counters.log"
grep -q 'budget-priority: deferred optional stage' "$LOGFILE"

export GH_GRAPHQL_REMAINING=3000
_pulse_set_graphql_budget_priority
[[ "${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS}" == "normal" ]]
if _pulse_should_defer_budget_priority_stage "dashboard_freshness_check"; then
	printf 'FAIL: optional stage deferred with healthy budget\n' >&2
	exit 1
fi

printf 'PASS pulse-graphql-budget-priority\n'
