#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# background-keychain-helper.sh — non-interactive keychain readiness guard (GH#37232)
#
# Background (launchd/cron) routines must never trigger a macOS SecurityAgent
# dialog. `gh auth token` runs /usr/bin/security, which prompts when the login
# keychain is locked or the item is missing. Call before such reads:
#
#   source background-keychain-helper.sh
#   background_keychain_gh_ready "label" || return 1
#
# Non-macOS hosts and token-via-env setups always pass. On failure one WARN line
# is written to stderr, then a marker suppresses re-checks for 10 minutes.
#
# Env: AIDEVOPS_KEYCHAIN_BACKOFF_SECS (default 600), AIDEVOPS_KEYCHAIN_MARKER_FILE,
#      AIDEVOPS_KEYCHAIN_FORCE_STATE=locked|unlocked (test override)

_BKC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_bkc_uname() {
	uname -s 2>/dev/null || printf 'unknown'
	return 0
}

_bkc_marker() {
	printf '%s' "${AIDEVOPS_KEYCHAIN_MARKER_FILE:-${HOME}/.aidevops/.agent-workspace/tmp/keychain-locked.marker}"
	return 0
}

# Returns 0 if the default keychain is usable without interaction.
_bkc_probe() {
	local forced="${AIDEVOPS_KEYCHAIN_FORCE_STATE:-}"
	[[ "$forced" == "locked" ]] && return 1
	[[ "$forced" == "unlocked" ]] && return 0
	local rc=0
	python3 "${_BKC_DIR}/background-keychain.py" >/dev/null 2>&1 || rc=$?
	# An unavailable or failed probe cannot establish that access is safe.
	[[ "$rc" -ne 0 ]] && return 1
	return 0
}

# Returns 0 if the gh credential item exists (attributes only: no -w/-g, so no prompt).
_bkc_gh_item_present() {
	[[ -n "${AIDEVOPS_KEYCHAIN_FORCE_STATE:-}" ]] && return 0
	[[ -x /usr/bin/security ]] || return 0
	/usr/bin/security find-generic-password -s "gh:github.com" >/dev/null 2>&1
	return $?
}

_bkc_set_marker() {
	local marker="$1"
	mkdir -p "$(dirname "$marker")" 2>/dev/null || true
	: >"$marker" 2>/dev/null || true
	return 0
}

# background_keychain_ready [label] — 0 ready, 1 skip this cycle.
background_keychain_ready() {
	local label="${1:-background}"
	local uname_s
	uname_s="$(_bkc_uname)"
	[[ "$uname_s" == "Darwin" || -n "${AIDEVOPS_KEYCHAIN_FORCE_STATE:-}" ]] || return 0
	local marker backoff now mtime
	marker="$(_bkc_marker)"
	backoff="${AIDEVOPS_KEYCHAIN_BACKOFF_SECS:-600}"
	[[ "$backoff" =~ ^[0-9]+$ ]] || backoff=600
	if [[ -f "$marker" ]]; then
		now=$(date +%s)
		# shellcheck source=./portable-stat.sh
		source "${_BKC_DIR}/portable-stat.sh" 2>/dev/null || true
		mtime=$(_file_mtime_epoch "$marker" 2>/dev/null || printf '0')
		[[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
		if [[ $((now - mtime)) -lt "$backoff" ]]; then
			return 1
		fi
	fi
	if _bkc_probe; then
		rm -f "$marker" 2>/dev/null || true
		return 0
	fi
	_bkc_set_marker "$marker"
	printf '[WARN] %s: macOS login keychain is locked or unavailable; skipping cycle without prompting (re-check in %ss)\n' "$label" "$backoff" >&2
	return 1
}

# background_keychain_gh_ready [label] — keychain guard for `gh auth token`.
background_keychain_gh_ready() {
	local label="${1:-background}"
	# Token supplied by env: gh does not touch the keychain.
	[[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] || return 0
	background_keychain_ready "$label" || return 1
	if [[ "$(_bkc_uname)" == "Darwin" ]] && ! _bkc_gh_item_present; then
		_bkc_set_marker "$(_bkc_marker)"
		printf '[WARN] %s: gh credential item missing from keychain; skipping cycle without prompting\n' "$label" >&2
		return 1
	fi
	return 0
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
	case "${1:-}" in
	check)
		background_keychain_gh_ready "${2:-cli}"
		exit $?
		;;
	*)
		printf 'Usage: %s check [label]\n' "$0" >&2
		exit 2
		;;
	esac
fi
