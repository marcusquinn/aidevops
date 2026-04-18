#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# install-privacy-guard.sh — DEPRECATED thin shim (t2198).
#
# This script is superseded by install-pre-push-guards.sh which manages
# both the privacy guard and the complexity regression guard.
#
# For new installations, use:
#   install-pre-push-guards.sh install           (installs both guards)
#   install-pre-push-guards.sh install --guard privacy  (privacy only)
#
# Usage (back-compat, delegates to install-pre-push-guards.sh):
#   install-privacy-guard.sh install      Install privacy guard
#   install-privacy-guard.sh uninstall    Remove privacy guard
#   install-privacy-guard.sh status       Report current state
#   install-privacy-guard.sh test         Run the shared test harness
#
# The installer targets the git COMMON dir (`git rev-parse --git-common-dir`)
# so worktrees share the hook with the parent repo.

set -euo pipefail

[[ -z "${YELLOW+x}" ]] && YELLOW=$'\033[1;33m'
[[ -z "${NC+x}" ]]     && NC=$'\033[0m'

_warn() {
	local _m="$1"
	printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$_m" >&2
	return 0
}

# Locate install-pre-push-guards.sh relative to this script.
_self_dir() {
	local _src="${BASH_SOURCE[0]}"
	while [[ -L "$_src" ]]; do
		local _dir
		_dir=$(cd -P "$(dirname "$_src")" && pwd)
		_src=$(readlink "$_src")
		[[ "$_src" != /* ]] && _src="$_dir/$_src"
	done
	cd -P "$(dirname "$_src")" && pwd
	return 0
}

GUARDS_INSTALLER="$(_self_dir)/install-pre-push-guards.sh"

if [[ ! -f "$GUARDS_INSTALLER" ]]; then
	# Fall back to deployed copy
	GUARDS_INSTALLER="$HOME/.aidevops/agents/scripts/install-pre-push-guards.sh"
fi

if [[ ! -f "$GUARDS_INSTALLER" ]]; then
	printf '[ERROR] install-pre-push-guards.sh not found — cannot install\n' >&2
	exit 1
fi

cmd="${1:-install}"
shift || true

case "$cmd" in
install)
	_warn "install-privacy-guard.sh is deprecated — use install-pre-push-guards.sh instead"
	exec bash "$GUARDS_INSTALLER" install --guard privacy "$@"
	;;
uninstall)
	_warn "install-privacy-guard.sh is deprecated — use install-pre-push-guards.sh instead"
	exec bash "$GUARDS_INSTALLER" uninstall --guard privacy "$@"
	;;
status)
	exec bash "$GUARDS_INSTALLER" status "$@"
	;;
test)
	# test command is specific to the privacy guard — delegate to test-privacy-guard.sh
	_sd=$(_self_dir)
	test_script="${_sd}/test-privacy-guard.sh"
	if [[ ! -f "$test_script" ]]; then
		printf '[ERROR] test harness not found: %s\n' "$test_script" >&2
		exit 1
	fi
	exec bash "$test_script" "$@"
	;;
help | --help | -h)
	sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
	;;
*)
	printf '[ERROR] unknown command: %s\n' "$cmd" >&2
	exit 1
	;;
esac
