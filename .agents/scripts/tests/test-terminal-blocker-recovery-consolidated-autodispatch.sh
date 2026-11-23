#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# A re-armed consolidated spec returns to status:available with auto-dispatch,
# unless a hold label or the canonical marker is missing (GH#39674).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
FAILED=0
SPEC='_Supersedes #99 — this issue is the consolidated spec._'

# shellcheck source=../terminal-blocker-recovery-helper.sh
source "${SCRIPT_DIR}/terminal-blocker-recovery-helper.sh"

CALL_ARGS=""
set_issue_status() {
	CALL_ARGS="$*"
	return 0
}
_tbr_post_rearm_receipt() { return 0; }

# Args: name, body, labels-json, expect-add (1|0)
run_case() {
	local name="$1" body="$2" labels="$3" expect="$4" json="" got=0
	json=$(jq -nc --arg body "$body" --argjson labels "$labels" '{body:$body,labels:($labels | map({name:.}))}')
	CALL_ARGS=""
	_tbr_project_rearm owner/repo 7 "$json" '[]' '<!-- r -->' a b >/dev/null 2>&1 || true
	[[ "$CALL_ARGS" == *"--add-label auto-dispatch"* ]] && got=1
	if [[ "$got" == "$expect" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s (args: %s)\n' "$name" "$CALL_ARGS"
		FAILED=$((FAILED + 1))
	fi
	return 0
}

run_case "canonical consolidated restores auto-dispatch" "$SPEC" '["status:blocked","consolidated"]' 1
run_case "parent-task stays off" "$SPEC" '["status:blocked","consolidated","parent-task"]' 0
run_case "no-auto-dispatch stays off" "$SPEC" '["status:blocked","consolidated","no-auto-dispatch"]' 0
run_case "hold-for-review stays off" "$SPEC" '["status:blocked","consolidated","hold-for-review"]' 0
run_case "missing marker stays off" "Hand-written" '["status:blocked","consolidated"]' 0
run_case "non-consolidated untouched" "$SPEC" '["status:blocked"]' 0

exit "$FAILED"
