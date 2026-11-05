#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared PR-description and explicit merge-message validation (GH#36797).

_gh_pr_body_negated_closing_ref() {
	local body_text="$1"
	local negation='(not|never|cannot|without|don[^[:space:]]{0,3}t|doesn[^[:space:]]{0,3}t|won[^[:space:]]{0,3}t|shouldn[^[:space:]]{0,3}t|can[^[:space:]]{0,3}t|mustn[^[:space:]]{0,3}t)'
	local keyword='(close[sd]?|fix(e[sd])?|resolve[sd]?)'
	local ref='(https?://[^[:space:]]+/(issues|pull)/[0-9]+|([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+)'
	# Bound the clause to 24 words; allow list commas, but not sentence or
	# semicolon boundaries. This is a wording guard, not an intent classifier.
	local gap='[[:space:]]+([[:alpha:]]+,?[[:space:]]+){0,24}'
	local pattern="(^|[^[:alnum:]_])${negation}${gap}${keyword}:?[[:space:]]+${ref}"
	local stripped="" match="" backtick=$'\x60'
	stripped=$(printf '%s\n' "$body_text" |
		awk '/^[[:space:]]*(```|~~~)/ { fenced = !fenced; next } !fenced' |
		sed -E "s/${backtick}[^${backtick}]*${backtick}//g" |
		tr '\n' ' ')
	match=$(printf '%s\n' "$stripped" | grep -oiE "$pattern" | sed -n '1p') || true
	[[ -n "$match" ]] || return 1
	match="${match#"${match%%[![:space:]]*}"}"
	printf '%s\n' "$match"
	return 0
}

_gh_validate_pr_closing_keywords() {
	local arg="" pending="" body_text="" has_body=0 body_file=""
	for arg in "$@"; do
		if [[ "$pending" == "body" ]]; then
			body_text="$arg"
			pending=""
			continue
		elif [[ "$pending" == "body-file" ]]; then
			body_file="$arg"
			pending=""
			continue
		fi
		case "$arg" in
		--body | -b) has_body=1; body_text=""; pending="body" ;;
		--body=*) has_body=1; body_text="${arg#--body=}" ;;
		-b?*) has_body=1; body_text="${arg#-b}" ;;
		--body-file | -F) pending="body-file" ;;
		--body-file=*) body_file="${arg#--body-file=}" ;;
		-F?*) body_file="${arg#-F}" ;;
		*) ;;
		esac
	done
	if [[ "$has_body" -eq 0 && -n "$body_file" && -f "$body_file" && -r "$body_file" ]]; then
		body_text=$(<"$body_file")
	fi
	[[ -n "$body_text" ]] || return 0
	_gh_pr_body_negated_closing_ref "$body_text" >/dev/null || return 0
	# Do not echo the author's body: it has not passed the privacy scan yet.
	_GH_EDIT_REJECTION_REASON="negated closing keyword — GitHub still treats it as a closing reference"
	printf '[SAFETY] gh pr body rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
	printf '[SAFETY] Use "Ref #N" or "For #N" and state "The referenced PR or issue remains open." Negation does not neutralize closing keywords.\n' >&2
	return 1
}
