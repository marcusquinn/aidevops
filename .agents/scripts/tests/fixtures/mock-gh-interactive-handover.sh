#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Mock `gh` stub for test-pulse-merge-interactive-handover.sh (t2189).
#
# Reads canned responses from $TEST_ROOT state files, simulates side effects
# by mutating those files, and honours the --jq filter like server-side gh.
#
# No `local` declarations — this runs as a standalone script per invocation,
# so variables are naturally scoped to the process.

printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

_all_args=("$@")
_jq_filter=""
for _i in "${!_all_args[@]}"; do
	if [[ "${_all_args[$_i]}" == "--jq" ]]; then
		_jq_filter="${_all_args[$((_i + 1))]:-}"
		break
	fi
done

_subcmd="${1:-} ${2:-}"

# Render the labels state file as a JSON array of {name: ...} objects.
_labels_to_json_array() {
	_labels=$(cat "${TEST_ROOT}/labels.txt")
	_labels_json=""
	IFS=',' read -ra _arr <<<"$_labels"
	for _l in "${_arr[@]}"; do
		[[ -z "$_l" ]] && continue
		_labels_json+="{\"name\":\"$_l\"},"
	done
	printf '[%s]' "${_labels_json%,}"
}

_maybe_jq() {
	if [[ -n "$_jq_filter" ]]; then
		jq -r "$_jq_filter"
	else
		cat
	fi
}

case "$_subcmd" in
"pr view")
	if [[ "$*" == *"--json labels,updatedAt"* ]]; then
		_arr_json=$(_labels_to_json_array)
		_updated=$(cat "${TEST_ROOT}/updated.txt")
		printf '{"labels":%s,"updatedAt":"%s"}' "$_arr_json" "$_updated" | _maybe_jq
		exit 0
	fi
	if [[ "$*" == *"--json labels"* ]]; then
		_arr_json=$(_labels_to_json_array)
		printf '{"labels":%s}' "$_arr_json" | _maybe_jq
		exit 0
	fi
	if [[ "$*" == *"--json title"* ]]; then
		cat "${TEST_ROOT}/title.txt"
		exit 0
	fi
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/body.txt"
		exit 0
	fi
	exit 0
	;;
"issue edit")
	# Simulate label addition — append to labels.txt
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--add-label" ]]; then
			shift
			_cur=$(cat "${TEST_ROOT}/labels.txt")
			printf '%s,%s' "$_cur" "$1" >"${TEST_ROOT}/labels.txt"
			break
		fi
		shift
	done
	exit 0
	;;
"pr comment")
	exit 0
	;;
esac

# `gh api` paths
if [[ "${1:-}" == "api" ]]; then
	# repos/OWNER/REPO/issues/NNN — linked issue lookup
	if [[ "$*" == *"/issues/"* && "$*" != *"/comments"* ]]; then
		_state=$(cat "${TEST_ROOT}/issue-state.txt")
		_labels_json=$(cat "${TEST_ROOT}/issue-labels-json.txt")
		# Transform input (JSON array of label names) into {name: ...} array
		_name_array=$(printf '%s' "$_labels_json" | jq -c '[.[]] | map({name: .})' 2>/dev/null || echo '[]')
		jq -n --arg state "$_state" --argjson labels "$_name_array" \
			'{state: $state, labels: $labels}' | _maybe_jq
		exit 0
	fi
	# repos/OWNER/REPO/issues/NNN/comments — used by _gh_idempotent_comment
	if [[ "$*" == *"/comments"* ]]; then
		printf '[]\n'
		exit 0
	fi
fi

exit 0
