#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# dispatch-exclusion-age-helper.sh - runner-local ageing of deterministic
# dispatch-filter exclusions (t19178, GH#39332).
#
# A dispatch filter that skips an auto-dispatch issue on every pulse cycle
# leaves no owner. `note` records each skip in a per-issue stamp; once the same
# reason has persisted for AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS it
# queues the issue once into the terminal-blocker recovery intake as
# `persistent_exclusion`, where the pulse supervisor (AI brief owner) acts.
#
# Usage:
#   dispatch-exclusion-age-helper.sh note <owner/repo> <issue> <reason>
#   dispatch-exclusion-age-helper.sh active <owner/repo> <issue>
#
# `note` is best-effort and always exits 0. `active` exits 0 while the filter
# skipped the issue within AIDEVOPS_DISPATCH_EXCLUSION_GAP_SECONDS.
# No network calls and no GitHub writes. Maintainer-gate reasons never escalate.
#
# Env: AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS (default 86400; 0 disables)
#      AIDEVOPS_DISPATCH_EXCLUSION_GAP_SECONDS (default 21600)

set -uo pipefail

_DEA_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_DEA_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _DEA_SCRIPT_DIR="."

_dea_uint() {
	local value="$1" default="$2"
	[[ "$value" =~ ^[0-9]+$ ]] || value="$default"
	printf '%s\n' "$value"
	return 0
}

_dea_stamp_path() {
	local repo="$1" issue="$2"
	[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s/.aidevops/logs/dispatch-exclusion-age/%s--%s--%s\n' \
		"$HOME" "${repo%%/*}" "${repo##*/}" "$issue"
	return 0
}

# Maintainer gates already surface through /decisions; never escalate them.
_dea_reason_escalatable() {
	local reason="$1"
	[[ "$reason" =~ ^[a-z_]+$ ]] || return 1
	case "${reason#cross_cycle_}" in
	permission_grant_unverified | needs_maintainer_permissions | cost_budget_exceeded) return 1 ;;
	esac
	return 0
}

# Read "first last reason enqueued" from a stamp; unreadable stamps read empty.
_dea_read_stamp() {
	local stamp_file="$1"
	[[ -f "$stamp_file" && ! -L "$stamp_file" ]] || return 1
	IFS=' ' read -r _DEA_FIRST _DEA_LAST _DEA_REASON _DEA_ENQUEUED <"$stamp_file" || true
	[[ "${_DEA_FIRST:-}" =~ ^[0-9]+$ && "${_DEA_LAST:-}" =~ ^[0-9]+$ && "${_DEA_REASON:-}" =~ ^[a-z_]+$ ]] || return 1
	[[ "${_DEA_ENQUEUED:-}" =~ ^[a-z_]+$ ]] || _DEA_ENQUEUED="-"
	return 0
}

_dea_write_stamp() {
	local stamp_file="$1" content="$2"
	local tmp=""
	mkdir -p "${stamp_file%/*}" 2>/dev/null || return 1
	tmp=$(mktemp "${stamp_file}.XXXXXX" 2>/dev/null) || return 1
	if ! printf '%s\n' "$content" >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$stamp_file" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	return 0
}

dea_note() {
	local repo="${1:-}" issue="${2:-}" reason="${3:-}"
	local escalate="" gap="" stamp_file="" now="" first="" enqueued="-"
	escalate=$(_dea_uint "${AIDEVOPS_DISPATCH_EXCLUSION_ESCALATE_SECONDS:-86400}" 86400)
	gap=$(_dea_uint "${AIDEVOPS_DISPATCH_EXCLUSION_GAP_SECONDS:-21600}" 21600)
	[[ "$escalate" -gt 0 ]] || return 0
	_dea_reason_escalatable "$reason" || return 0
	stamp_file=$(_dea_stamp_path "$repo" "$issue") || return 0
	now=$(date +%s)
	first="$now"
	if _dea_read_stamp "$stamp_file" && [[ "$_DEA_REASON" == "$reason" ]] &&
		[[ "$now" -ge "$_DEA_LAST" && $((now - _DEA_LAST)) -le "$gap" ]]; then
		first="$_DEA_FIRST"
		enqueued="$_DEA_ENQUEUED"
	fi
	if [[ $((now - first)) -ge "$escalate" && "$enqueued" != "$reason" ]]; then
		if bash "${_DEA_SCRIPT_DIR}/terminal-blocker-recovery-helper.sh" enqueue "$repo" "$issue" "$reason" persistent_exclusion >/dev/null 2>&1; then
			enqueued="$reason"
		fi
	fi
	_dea_write_stamp "$stamp_file" "${first} ${now} ${reason} ${enqueued}" || true
	return 0
}

dea_active() {
	local repo="${1:-}" issue="${2:-}"
	local gap="" stamp_file="" now=""
	gap=$(_dea_uint "${AIDEVOPS_DISPATCH_EXCLUSION_GAP_SECONDS:-21600}" 21600)
	stamp_file=$(_dea_stamp_path "$repo" "$issue") || return 1
	_dea_read_stamp "$stamp_file" || return 1
	now=$(date +%s)
	[[ "$now" -ge "$_DEA_LAST" && $((now - _DEA_LAST)) -le "$gap" ]] || return 1
	return 0
}

main() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	note) dea_note "$@"; return 0 ;;
	active) dea_active "$@"; return $? ;;
	*)
		printf 'Usage: %s note <owner/repo> <issue> <reason> | active <owner/repo> <issue>\n' "${0##*/}" >&2
		return 2
		;;
	esac
}

main "$@"
