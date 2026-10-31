#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27853: merge-first must start before dispatch
# without making pulse preflight wait for the merge routine.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_LIB="${TEST_SCRIPT_DIR}/../pulse-dispatch-preflight-lib.sh"
DISPATCH_ENGINE="${TEST_SCRIPT_DIR}/../pulse-dispatch-engine.sh"
TEST_DIR=""

cleanup() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message"
	exit 1
}

main() {
	TEST_DIR=$(mktemp -d)
	trap cleanup EXIT
	local stub_dir="${TEST_DIR}/scripts"
	local marker="${TEST_DIR}/merge-first.marker"
	local merge_first_line early_dispatch_line
	mkdir -p "$stub_dir" "${TEST_DIR}/home/.aidevops/logs"

	merge_first_line=$(grep -n '^[[:space:]]*_preflight_start_merge_first' "$DISPATCH_ENGINE" | cut -d: -f1 || printf '')
	# Early dispatch may run directly or through a budget stage wrapper
	# (`_pulse_run_budget_priority_stage "..." _preflight_early_dispatch`).
	# Match the first non-comment call either way, never a definition.
	early_dispatch_line=$(grep -m 1 -nE \
		'^[[:space:]]*(_preflight_early_dispatch|[^#[:space:]].*[[:space:]]_preflight_early_dispatch)([[:space:]]|$)' \
		"$DISPATCH_ENGINE" | cut -d: -f1 || printf '')
	[[ -n "$merge_first_line" ]] || fail "dispatch engine does not call merge-first"
	[[ -n "$early_dispatch_line" ]] || fail "dispatch engine does not call early dispatch"
	if [[ "$merge_first_line" -ge "$early_dispatch_line" ]]; then
		fail "dispatch engine starts merge-first after early dispatch"
	fi

	cat >"${stub_dir}/pulse-merge-routine.sh" <<'STUB'
#!/usr/bin/env bash
printf 'started:%s\n' "$*" >"${PULSE_MERGE_FIRST_TEST_MARKER}"
sleep 5
printf 'finished:%s\n' "$*" >>"${PULSE_MERGE_FIRST_TEST_MARKER}"
exit 0
STUB
	chmod +x "${stub_dir}/pulse-merge-routine.sh"

	local start elapsed
	start=$(date +%s)
	(
		export HOME="${TEST_DIR}/home"
		export PULSE_MERGE_FIRST_TEST_MARKER="$marker"
		SCRIPT_DIR="$stub_dir"
		LOGFILE="${TEST_DIR}/pulse.log"
		# shellcheck source=../pulse-dispatch-preflight-lib.sh
		source "$PREFLIGHT_LIB"
		_preflight_start_merge_first
	)
	elapsed=$(($(date +%s) - start))

	if [[ "$elapsed" -ge 3 ]]; then
		fail "merge-first kick blocked preflight for ${elapsed}s"
	fi

	local attempt
	for ((attempt = 0; attempt < 25; attempt++)); do
		# Redirection creates the marker before printf writes its launch record.
		[[ -s "$marker" && "$(<"$marker")" == started:* ]] && break
		sleep 0.2
	done
	[[ -f "$marker" ]] || fail "standalone merge routine was not launched"
	if [[ "$(<"$marker")" != started:run* ]]; then
		fail "merge routine did not receive the run subcommand"
	fi

	rm -f "$marker"
	(
		export HOME="${TEST_DIR}/home"
		export PULSE_MERGE_FIRST_TEST_MARKER="$marker"
		SCRIPT_DIR="$stub_dir"
		LOGFILE="${TEST_DIR}/pulse-disabled.log"
		AIDEVOPS_PULSE_ASYNC_MERGE_FIRST=0
		# shellcheck source=../pulse-dispatch-preflight-lib.sh
		source "$PREFLIGHT_LIB"
		_preflight_start_merge_first
	)
	sleep 0.2
	[[ ! -f "$marker" ]] || fail "disabled merge-first kick still launched the routine"

	printf 'PASS: merge-first starts asynchronously before dispatch and honours rollback flag\n'
	return 0
}

main "$@"
