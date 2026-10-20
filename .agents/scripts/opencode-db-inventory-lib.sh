#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Fixed-depth inventory only: never walk arbitrary project trees or symlinks.

opencode_db_inventory() {
	local selected_db="$1"
	local root="${OPENCODE_INTERACTIVE_ROOT:-}"
	local db
	if [[ -z "$root" && -n "${HOME:-}" ]]; then
		root="${HOME}/.aidevops/.agent-workspace/work/opencode-interactive"
	fi
	[[ ! -f "$selected_db" ]] || printf '%s\0' "$selected_db"
	[[ -d "$root" && ! -L "$root" ]] || return 0
	for db in "$root"/*/opencode/opencode.db; do
		[[ -f "$db" && ! -L "$db" && ! -L "${db%/*}" && ! -L "${db%/opencode/opencode.db}" ]] || continue
		[[ "$db" -ef "$selected_db" ]] && continue
		printf '%s\0' "$db"
	done
	return 0
}
