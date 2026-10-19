#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# dependency-supersession-repoint-helper.sh — CLI for GH#35130.
# Usage: dependency-supersession-repoint-helper.sh repoint <owner/repo> <original> <successor>
# Run after "Superseded by #S" is posted and the original is closed.

set -uo pipefail
_dir="${BASH_SOURCE[0]%/*}"
[[ "$_dir" == "${BASH_SOURCE[0]}" ]] && _dir="."
# shellcheck source=./dependency-supersession-lib.sh
source "${_dir}/dependency-supersession-lib.sh"
# shellcheck source=./dependency-supersession-repoint-lib.sh
source "${_dir}/dependency-supersession-repoint-lib.sh"

_usage() {
	printf 'Usage: dependency-supersession-repoint-helper.sh repoint <owner/repo> <original> <successor>\n' >&2
	return 1
}

main() {
	local command="${1:-}"
	local repo="${2:-}"
	local original="${3:-}"
	local successor="${4:-}"
	if [[ "$command" != "repoint" || $# -ne 4 ]]; then
		_usage
		return $?
	fi
	dsr_repoint_dependants_of "$repo" "$original" "$successor" || return 1
	return 0
}

main "$@"
exit $?
