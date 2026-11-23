#!/usr/bin/env bash
# Paired base/head subprocess spawn profiler (argv signatures, parents, repeats).
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Usage:
#   spawn-profile-helper.sh run --base <ref> [--tool git,bash,...] [--top N] -- <suite command>
#   spawn-profile-helper.sh summary <log> [--top N]
#   spawn-profile-helper.sh compare <base-log> <head-log> [--top N]
#
# Logs go under ${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}. Wrappers are
# temporary, exec the next tool on PATH unchanged, and are removed after the run.

set -u

main() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
	local command="${1:-}"
	case "$command" in
	run | summary | compare)
		python3 "${script_dir}/spawn_profile.py" "$@"
		return $?
		;;
	*)
		sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		[[ "$command" == "-h" || "$command" == "--help" ]] && return 0
		return 1
		;;
	esac
}

main "$@"
