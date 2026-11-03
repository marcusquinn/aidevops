#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Shared exit-path retry. Local evidence is checkpoint-only and never holds tokens.
_terminal_lease_emit_or_record() {
	local issue="$1" repo="$2" session="$3" helper="$4"
	local module="${BASH_SOURCE[0]%/*}/terminal_lease_recovery.py"
	local try=0
	for try in 1 2; do
		if "$helper" transition terminal "$issue" "$repo" \
			"$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$session" 0 >/dev/null 2>&1; then
			python3 "$module" resolved "$repo" "$issue" "$session" "$$" >/dev/null 2>&1 || true
			return 0
		fi
		[[ "$try" -eq 2 ]] || sleep 1
	done
	if ! python3 "$module" pending "$repo" "$issue" "$session" "$$"; then
		printf 'Terminal lease local evidence unavailable for #%s\n' "$issue" >&2
	fi
	return 1
}
