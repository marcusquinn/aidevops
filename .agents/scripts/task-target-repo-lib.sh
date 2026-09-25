#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared, fail-closed target repository contract for task briefs.

# Print the declared owner/repo or nothing when the field is absent. Never
# infer a target from a parent reference, prose, file path, or URL.
task_brief_target_repo() {
	local brief_file="$1" line value found=""
	[[ -f "$brief_file" ]] || return 0
	[[ -r "$brief_file" ]] || { printf 'Unreadable task brief: %s\n' "$brief_file" >&2; return 1; }
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\*\*[Tt]arget[[:space:]]repository:\*\*[[:space:]]*(.*)$ ]]; then
			value="${BASH_REMATCH[1]}"
			value="${value#\`}"
			value="${value%\`}"
			if [[ ! "$value" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || -n "$found" ]]; then
				printf 'Invalid or duplicate Target repository in %s\n' "$brief_file" >&2
				return 1
			fi
			found="$value"
		fi
	done <"$brief_file"
	printf '%s\n' "$found"
}

task_require_target_repo() {
	local expected="$1" actual="$2" source="$3"
	[[ -z "$expected" ]] && return 0
	if [[ "$expected" != "$actual" ]]; then
		printf 'Target repository mismatch (%s): declared %s, selected %s\n' "$source" "$expected" "$actual" >&2
		return 1
	fi
	return 0
}
