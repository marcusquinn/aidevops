#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR}/.."
LOOP_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$LOOP_STATE_DIR"' EXIT

# shellcheck source=../loop-common.sh
source "${SCRIPTS_DIR}/loop-common.sh"

output=$(loop_emit_context_checkpoint_signal "explicit_context_signal" 2>/dev/null)

if [[ "$output" != *'<checkpoint>CONTEXT_CHECKPOINTED</checkpoint>'* ]]; then
	printf 'FAIL: context guard did not emit its non-terminal checkpoint signal\n' >&2
	exit 1
fi

if [[ "$output" == *'FULL_LOOP_COMPLETE'* ]]; then
	printf 'FAIL: context guard represented unfinished work as complete\n' >&2
	exit 1
fi

if rg -Fq -- '**CONTEXT GUARD:**' "${SCRIPTS_DIR}/loop-common.sh"; then
	printf 'FAIL: legacy low-context completion instruction remains in the re-anchor prompt\n' >&2
	exit 1
fi

if rg -Fq -- 'caller should exit' "${SCRIPTS_DIR}/loop-common.sh"; then
	printf 'FAIL: context guard still instructs callers to exit\n' >&2
	exit 1
fi

loop_create_state "full" "context continuation test" 3 "TASK_COMPLETE" "context-test" >/dev/null
calls=0
_loop_run_external_validate() { return 0; }
_loop_run_external_run_tool() {
	local output_file="$3"
	calls=$((calls + 1))
	if [[ "$calls" -eq 1 ]]; then
		printf 'maximum context length reached; preserve unfinished work\n' >"$output_file"
	else
		printf '<promise>TASK_COMPLETE</promise>\n' >"$output_file"
	fi
	return 0
}
loop_emergency_push() { return 0; }
loop_create_receipt() { return 0; }
loop_store_memory() { return 0; }
loop_store_success() { return 0; }
_loop_run_external_send_status() { return 0; }

if ! loop_run_external "stub" "context continuation test" 3 "TASK_COMPLETE" >/dev/null; then
	printf 'FAIL: external loop did not continue from context rollover to completion\n' >&2
	exit 1
fi

if [[ "$calls" -ne 2 ]]; then
	printf 'FAIL: expected a fresh iteration after context rollover, got %s calls\n' "$calls" >&2
	exit 1
fi

printf 'PASS: context exhaustion checkpoints and continues without a completion claim\n'
