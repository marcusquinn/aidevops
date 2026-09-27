#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pre-dispatch implementation brief scope validation
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PREDISPATCH_VALIDATOR_BRIEF_SCOPE_LIB_LOADED:-}" ]] && return 0
_PREDISPATCH_VALIDATOR_BRIEF_SCOPE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_brief_requires_files_scope() {
	local issue_body="$1"

	if printf '%s' "$issue_body" | grep -Eqi 'planning-only|pure planning|brief-only|no code changes'; then
		return 1
	fi

	printf '%s' "$issue_body" | grep -qE \
		'<!-- aidevops:generator=[a-z0-9_-]+[^>]* cited_file=[^ >]+|<!-- aidevops:dependabot-pr-intake[[:space:]]'
	return $?
}

_brief_files_scope_has_path() {
	local issue_body="$1"
	local scope_section=""

	scope_section=$(printf '%s' "$issue_body" |
		awk '
			/^## Files Scope[[:space:]]*$/ { found=1; level=2; next }
			/^### Files Scope[[:space:]]*$/ { found=1; level=3; next }
			found && level == 2 && /^## / { found=0 }
			found && level == 3 && (/^# / || /^## / || /^### /) { found=0 }
			found { print }
		')

	[[ -n "$scope_section" ]] || return 1
	# shellcheck disable=SC2016 # literal regular expression anchors
	printf '%s\n' "$scope_section" |
		grep -qE '^[[:space:]]*-[[:space:]]*(EDIT|NEW):[[:space:]]*`?[^`[:space:]][^`]*`?[[:space:]]*$'
}

_validate_implementation_brief_scope() {
	local issue_number="$1"
	local issue_body="$2"

	_brief_requires_files_scope "$issue_body" || return 0
	if _brief_files_scope_has_path "$issue_body"; then
		return 0
	fi

	_log "ERROR" "brief-defect: #${issue_number} generated implementation brief lacks a non-empty canonical Files Scope; add '### Files Scope' with '- EDIT: \`repo-relative/path\`' before dispatch"
	return 40
}
