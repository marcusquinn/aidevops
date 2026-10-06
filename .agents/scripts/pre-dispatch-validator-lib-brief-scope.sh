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

# Operational consolidation packets (pulse-generated, label-authenticated) merge
# issue threads into a successor; they never edit source. Inlined parent bodies
# may carry generator markers, which are evidence, not execution authority.
# Both the consolidation-task label and the generated packet shape are required.
_brief_is_operational_consolidation() {
	local issue_body="$1"
	local labels_csv="${2:-}"

	[[ ",${labels_csv}," == *",consolidation-task,"* ]] || return 1
	printf '%s\n' "$issue_body" | grep -Eq '^## Consolidation target: #[0-9]+[[:space:]]*$' || return 1
	printf '%s\n' "$issue_body" | grep -Fq '**No PR is required.** This is an operational task.' || return 1
	return 0
}

_brief_requires_files_scope() {
	local issue_body="$1"
	local auto_dispatch="${2:-0}"

	if [[ "$auto_dispatch" == "1" ]]; then
		# Only an explicit planning declaration exempts an interactive brief;
		# incidental prose mentioning planning-only behavior is not an exemption.
		printf '%s\n' "$issue_body" | grep -Eqi '^[[:space:]]*(#{1,3}[[:space:]]*)?(planning-only|pure planning|brief-only|no code changes)(:|[[:space:]]*$)' && return 1
		return 0
	fi
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
		grep -qE '^[[:space:]]*-[[:space:]]*((EDIT|NEW):[[:space:]]*)?`?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*`?[[:space:]]*$'
}

_validate_implementation_brief_scope() {
	local issue_number="$1"
	local issue_body="$2"
	local auto_dispatch="${3:-0}"
	local issue_labels="${4:-}"

	if _brief_is_operational_consolidation "$issue_body" "$issue_labels"; then
		return 0
	fi
	_brief_requires_files_scope "$issue_body" "$auto_dispatch" || return 0
	if _brief_files_scope_has_path "$issue_body"; then
		return 0
	fi

	_log "ERROR" "brief-defect: #${issue_number} implementation brief lacks a non-empty canonical Files Scope; add '### Files Scope' with '- EDIT: \`repo-relative/path\`' before dispatch"
	return 40
}
