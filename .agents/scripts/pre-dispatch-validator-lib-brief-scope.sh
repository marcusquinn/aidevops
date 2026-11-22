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

# Print the body of the canonical `### Files Scope` (or legacy `## Files Scope`)
# section; prints nothing when the section is absent.
_brief_files_scope_section() {
	local issue_body="$1"
	printf '%s' "$issue_body" |
		awk '
			/^## Files Scope[[:space:]]*$/ { found=1; level=2; next }
			/^### Files Scope[[:space:]]*$/ { found=1; level=3; next }
			found && level == 2 && /^## / { found=0 }
			found && level == 3 && (/^# / || /^## / || /^### /) { found=0 }
			found { print }
		'
	return 0
}

_brief_files_scope_has_path() {
	local issue_body="$1"
	local scope_section=""

	scope_section=$(_brief_files_scope_section "$issue_body")

	[[ -n "$scope_section" ]] || return 1
	# Preserve the existing literal-path contract before considering glob entries.
	# shellcheck disable=SC2016 # literal regular expression anchors
	if printf '%s\n' "$scope_section" |
		grep -qE '^[[:space:]]*-[[:space:]]*((EDIT|NEW):[[:space:]]*)?`?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*`?[[:space:]]*$'; then
		return 0
	fi

	local entry="" path=""
	# A glob must be anchored beneath a literal repository-relative directory.
	# shellcheck disable=SC2016 # literal Markdown backticks and regex anchors
	local glob_entry='^[[:space:]]*-[[:space:]]*((EDIT|NEW):[[:space:]]*)?`?([A-Za-z0-9_.-]+(/[A-Za-z0-9_.*-]+)+)`?[[:space:]]*$'
	while IFS= read -r entry; do
		[[ "$entry" =~ $glob_entry ]] || continue
		path="${BASH_REMATCH[3]}"
		[[ "$path" == *'*'* && "$path" != *'**'* ]] || continue
		[[ "/${path}/" != *'/../'* ]] || continue
		return 0
	done <<<"$scope_section"
	return 1
}

# GH#38978: print each literal Files Scope path that is absent from the default
# branch and not declared new (a `NEW: path` bullet anywhere in the body, or a
# `NEW:` prefix on the scope line itself). A wrong path reads to a worker as an
# instruction to create it (GH#38966). Globs are skipped; a repo_path that is
# not a git checkout prints nothing. Authoring-time feedback only: returns 0.
_brief_files_scope_missing_paths() {
	local issue_body="$1"
	local repo_path="$2"
	local default_ref="" scope_section="" line="" path=""
	local declared_new=$'\n' reported=$'\n'

	git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || return 0
	default_ref=$(git -C "$repo_path" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || default_ref=""
	if [[ -z "$default_ref" ]]; then
		default_ref="HEAD"
		if git -C "$repo_path" rev-parse -q --verify 'origin/main^{commit}' >/dev/null 2>&1; then
			default_ref="origin/main"
		fi
	fi
	scope_section=$(_brief_files_scope_section "$issue_body")
	[[ -n "$scope_section" ]] || return 0

	# shellcheck disable=SC2016 # literal Markdown backticks and regex anchors
	local new_decl='^[[:space:]]*[-*][[:space:]]*NEW:[[:space:]]*`?([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*)`?'
	while IFS= read -r line; do
		[[ "$line" =~ $new_decl ]] && declared_new+="${BASH_REMATCH[1]}"$'\n'
	done <<<"$issue_body"

	# shellcheck disable=SC2016 # literal Markdown backticks and regex anchors
	local literal_entry='^[[:space:]]*-[[:space:]]*((EDIT|NEW):[[:space:]]*)?`?([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*)`?[[:space:]]*$'
	while IFS= read -r line; do
		[[ "$line" =~ $literal_entry ]] || continue
		[[ "${BASH_REMATCH[2]}" != "NEW" ]] || continue
		path="${BASH_REMATCH[3]}"
		[[ "$declared_new" != *$'\n'"${path}"$'\n'* ]] || continue
		[[ "$reported" != *$'\n'"${path}"$'\n'* ]] || continue
		git -C "$repo_path" cat-file -e "${default_ref}:${path}" 2>/dev/null && continue
		reported+="${path}"$'\n'
		printf '%s\n' "$path"
	done <<<"$scope_section"
	return 0
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
