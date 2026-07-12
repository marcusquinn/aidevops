#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared lexical codec for legacy and origin-namespaced task identifiers.

[[ -n "${_AIDEVOPS_TASK_IDENTITY_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_TASK_IDENTITY_LIB_LOADED=1

readonly TASK_IDENTITY_MAX_BYTES=199
readonly TASK_IDENTITY_MAX_DECIMAL_DIGITS=18
readonly TASK_IDENTITY_MAX_SUBTASK_DEPTH=8
readonly TASK_IDENTITY_LEGACY_ERE='^t[1-9][0-9]{0,17}(\.[1-9][0-9]{0,17}){0,8}$'
readonly TASK_IDENTITY_NAMESPACED_ERE='^to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17}(\.[1-9][0-9]{0,17}){0,8}$'
readonly TASK_IDENTITY_ANY_ERE='^(t[1-9][0-9]{0,17}(\.[1-9][0-9]{0,17}){0,8}|to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17}(\.[1-9][0-9]{0,17}){0,8})$'

TASK_IDENTITY_KIND=""
TASK_IDENTITY_CANONICAL_ID=""
TASK_IDENTITY_ORIGIN_ID=""
TASK_IDENTITY_SEQUENCE=""
TASK_IDENTITY_SUBTASK_PATH=""
TASK_IDENTITY_PARENT_ID=""

task_identity_reset() {
	TASK_IDENTITY_KIND=""
	TASK_IDENTITY_CANONICAL_ID=""
	TASK_IDENTITY_ORIGIN_ID=""
	TASK_IDENTITY_SEQUENCE=""
	TASK_IDENTITY_SUBTASK_PATH=""
	TASK_IDENTITY_PARENT_ID=""
	return 0
}

_task_identity_parent_for() {
	local base_id="$1"
	local subtask_path="$2"
	if [[ -z "$subtask_path" ]]; then
		printf '%s' ""
	elif [[ "$subtask_path" == *.* ]]; then
		printf '%s.%s' "$base_id" "${subtask_path%.*}"
	else
		printf '%s' "$base_id"
	fi
	return 0
}

_task_identity_set_fields() {
	local kind="$1"
	local canonical_id="$2"
	local origin_id="$3"
	local sequence="$4"
	local suffix="$5"
	local base_id=""

	TASK_IDENTITY_KIND="$kind"
	TASK_IDENTITY_CANONICAL_ID="$canonical_id"
	TASK_IDENTITY_ORIGIN_ID="$origin_id"
	TASK_IDENTITY_SEQUENCE="$sequence"
	TASK_IDENTITY_SUBTASK_PATH="${suffix#.}"
	if [[ "$kind" == "legacy" ]]; then
		base_id="t${sequence}"
	else
		base_id="t${origin_id}-${sequence}"
	fi
	TASK_IDENTITY_PARENT_ID=$(_task_identity_parent_for "$base_id" "$TASK_IDENTITY_SUBTASK_PATH")
	return 0
}

task_identity_parse() {
	local input="${1:-}"
	local legacy_capture_ere='^t([1-9][0-9]{0,17})((\.[1-9][0-9]{0,17}){0,8})$'
	local namespaced_capture_ere='^t(o[0-7][0-9a-hjkmnp-tv-z]{25})-([1-9][0-9]{0,17})((\.[1-9][0-9]{0,17}){0,8})$'

	task_identity_reset
	[[ -n "$input" && "${#input}" -le "$TASK_IDENTITY_MAX_BYTES" ]] || return 1
	if [[ "$input" =~ $legacy_capture_ere ]]; then
		_task_identity_set_fields "legacy" "$input" "" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi
	if [[ "$input" =~ $namespaced_capture_ere ]]; then
		_task_identity_set_fields "namespaced" "$input" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
		return 0
	fi
	return 1
}

task_identity_validate() {
	local input="${1:-}"
	# Validation runs in a subshell so it never changes or clears parsed fields.
	if (task_identity_parse "$input"); then
		return 0
	fi
	return 1
}

task_identity_format() {
	local kind="${1:-}"
	local origin_id="${2:-}"
	local sequence="${3:-}"
	local subtask_path="${4:-}"
	local candidate=""

	case "$kind" in
	legacy)
		[[ -z "$origin_id" ]] || return 1
		candidate="t${sequence}"
		;;
	namespaced)
		[[ -n "$origin_id" ]] || return 1
		candidate="t${origin_id}-${sequence}"
		;;
	*)
		return 1
		;;
	esac
	[[ -z "$subtask_path" ]] || candidate="${candidate}.${subtask_path}"
	task_identity_validate "$candidate" || return 1
	printf '%s\n' "$candidate"
	return 0
}

task_identity_ere() {
	local kind="${1:-any}"
	case "$kind" in
	legacy) printf '%s\n' "$TASK_IDENTITY_LEGACY_ERE" ;;
	namespaced) printf '%s\n' "$TASK_IDENTITY_NAMESPACED_ERE" ;;
	any) printf '%s\n' "$TASK_IDENTITY_ANY_ERE" ;;
	*) return 1 ;;
	esac
	return 0
}
