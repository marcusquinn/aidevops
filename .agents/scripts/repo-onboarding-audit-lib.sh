#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Read-only repository inspection; only disposable advisory files are changed.

_onboarding_label() {
	local slug="$1" result
	if result=$(gh api "repos/$slug/labels/auto-dispatch" 2>&1); then
		printf '%s' present
	elif [[ "$result" == *'HTTP 404'* ]]; then
		printf '%s' missing
	else
		log_warn "onboarding: $slug — label status unknown: $result"
		printf '%s' unknown
	fi
	return 0
}

_onboarding_write() {
	local slug="$1" gaps="$2" dry="$3" file tmp
	file="$HOME/.aidevops/advisories/repo-onboarding-${slug//\//-}.advisory"
	if [[ "$dry" == 1 ]]; then
		log_info "onboarding: $slug — ${gaps:-clean or out of scope}"
	elif [[ -z "$gaps" ]]; then
		rm -f "$file"
	else
		mkdir -p "${file%/*}"
		tmp=$(mktemp "${file}.XXXXXX") || return 1
		printf 'Repository: %s\n%bSee reference/repo-onboarding.md\n' "$slug" "$gaps" >"$tmp"
		mv "$tmp" "$file"
	fi
	return 0
}

_onboarding_one() {
	local entry="$1" mode="$2" dry="$3" now="$4" days="$5"
	local slug path pulse initialized epoch recent=0 blocked=0 issues label gaps=""
	slug=$(jq -r '.slug // empty' <<<"$entry")
	path=$(jq -r '.path // empty' <<<"$entry")
	pulse=$(jq -r '.pulse == true' <<<"$entry")
	initialized=$(jq -r '.initialized // empty' <<<"$entry")
	[[ -n "$slug" && -d "$path" ]] || return 0
	epoch=$(jq -nr --arg d "$initialized" 'try ($d | fromdateiso8601) catch 0')
	if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 && epoch <= now && now - epoch <= days * 86400 )); then recent=1; fi
	if [[ "$pulse" != true && "$recent" == 0 ]]; then
		if ! issues=$(gh issue list --repo "$slug" --label auto-dispatch --state open --limit 1 --json number 2>&1); then
			log_warn "onboarding: $slug — dispatch status unknown: $issues"
			_ONBOARD_UNKNOWN=$((_ONBOARD_UNKNOWN + 1)); return 0
		fi
		if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$issues"; then
			log_warn "onboarding: $slug — invalid dispatch response"
			_ONBOARD_UNKNOWN=$((_ONBOARD_UNKNOWN + 1)); return 0
		fi
		[[ $(jq 'length' <<<"$issues") -gt 0 ]] && blocked=1
	fi
	if [[ "$mode" != all && "$recent" == 0 && "$blocked" == 0 ]]; then
		_onboarding_write "$slug" "" "$dry"; return 0
	fi
	label=$(_onboarding_label "$slug")
	if [[ "$label" == unknown ]]; then _ONBOARD_UNKNOWN=$((_ONBOARD_UNKNOWN + 1)); return 0; fi
	if [[ "$pulse" != true && ( "$recent" == 1 || "$blocked" == 1 ) ]]; then gaps+="Pulse off: aidevops repos pulse on $slug\n"; fi
	if [[ ! -f "$path/.aidevops.json" ]]; then gaps+="Missing config: run aidevops init in $path\n"; fi
	if [[ "$label" == missing ]]; then gaps+="Missing label: label-sync-helper.sh sync --repo $slug\n"; fi
	if [[ -n "$gaps" ]]; then _ONBOARD_ADVISORIES=$((_ONBOARD_ADVISORIES + 1)); else _ONBOARD_CLEAN=$((_ONBOARD_CLEAN + 1)); fi
	if [[ "$mode" == report || "$mode" == all ]]; then
		printf '%s: ' "$slug"
		if [[ -n "$gaps" ]]; then printf '\n%b' "$gaps"; else printf 'clean\n'; fi
	else
		_onboarding_write "$slug" "$gaps" "$dry"
	fi
	return 0
}

_onboarding_audit() {
	local mode="$1" dry="$2" entry now days
	_ONBOARD_ADVISORIES=0; _ONBOARD_CLEAN=0; _ONBOARD_UNKNOWN=0
	days="${AIDEVOPS_ONBOARDING_RECENT_DAYS:-30}"
	[[ "$days" =~ ^[0-9]+$ ]] || days=30
	now=$(date -u +%s)
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		_onboarding_one "$entry" "$mode" "$dry" "$now" "$days"
	done < <(jq -c '.initialized_repos[]? | select(.maintenance != false and .local_only != true and (.role // "maintainer") == "maintainer")' "$CONFIG_FILE")
	log_info "onboarding: $_ONBOARD_ADVISORIES advisories, $_ONBOARD_CLEAN clean, $_ONBOARD_UNKNOWN unknown"
	return 0
}

_check_onboarding_gaps() {
	local dry="$1"
	_onboarding_audit audit "$dry"
	return 0
}

cmd_onboarding() {
	local arg="${1:-}" mode=report
	if [[ "$arg" == --all && $# == 1 ]]; then mode=all
	elif [[ $# != 0 ]]; then printf 'Usage: onboarding [--all]\n' >&2; return 1
	fi
	ensure_dirs
	[[ -f "$CONFIG_FILE" ]] || { printf 'No repos.json found\n' >&2; return 1; }
	_onboarding_audit "$mode" 1
	return 0
}
