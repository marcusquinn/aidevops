#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Read-only GitHub autonomy outcome report.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

main() {
	local command="${1:-report}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$command" in
	report) python3 -B "${SCRIPT_DIR}/autonomy_report.py" "$@" || return 1 ;;
	help | -h | --help) python3 -B "${SCRIPT_DIR}/autonomy_report.py" --help || return 1 ;;
	*)
		printf 'Unknown command: %s (expected report or help)\n' "$command" >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
