#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pre-dispatch validator core helpers
# =============================================================================
# Shared logging and GitHub command helpers for pre-dispatch validators.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PREDISPATCH_VALIDATOR_CORE_LIB_LOADED:-}" ]] && return 0
_PREDISPATCH_VALIDATOR_CORE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_pdv_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_log() {
	local level="$1"
	shift
	printf '[pre-dispatch-validator] %s: %s\n' "$level" "$*" >&2
	return 0
}

_log_error() {
	_log "ERROR" "$@"
	return 0
}

_github_clone_url() {
	local slug="$1"
	printf 'https://github.com/%s.git' "$slug"
	return 0
}
