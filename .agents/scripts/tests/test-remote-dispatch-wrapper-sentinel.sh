#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for wrapper sentinel diagnostics in remote-dispatch-helper.sh.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/remote-dispatch-helper.sh"

pass() {
	printf '  PASS %s\n' "$1"
	return 0
}

fail() {
	printf '  FAIL %s\n' "$1" >&2
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
	exit 1
	return 1
}

if [[ ! -f "$HELPER" ]]; then
	fail "helper file exists" "$HELPER"
fi

helper_content=$(<"$HELPER")
wrapper_started_line=""
while IFS= read -r line; do
	if [[ "$line" == *"WRAPPER_STARTED"* ]]; then
		wrapper_started_line="$line"
		break
	fi
done <"$HELPER"

# shellcheck disable=SC2016 # literal generated wrapper line; variables expand in the generated wrapper, not in this test.
sentinel_line='echo "WRAPPER_STARTED task_id=${task_id} wrapper_pid=\$\$ host=${host} timestamp=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${remote_log_file}" || true'

if [[ "$helper_content" == *"$sentinel_line"* ]]; then
	pass "wrapper sentinel preserves runtime PID expansion and avoids blanket stderr suppression"
else
	fail "wrapper sentinel line should not use 2>/dev/null" "expected: $sentinel_line"
fi

if [[ "$wrapper_started_line" != *"2>/dev/null"* ]]; then
	pass "WRAPPER_STARTED writes do not suppress diagnostic errors"
else
	fail "WRAPPER_STARTED write still suppresses errors with 2>/dev/null" "$wrapper_started_line"
fi

exit 0
