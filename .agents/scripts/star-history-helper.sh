#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# star-history-helper.sh — fetch authorised GitHub star history and render a static SVG.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PYTHON_HELPER="${SCRIPT_DIR}/star_history.py"

usage() {
	printf '%s\n' 'Usage:'
	printf '%s\n' '  star-history-helper.sh fetch --repo OWNER/REPO --output FILE'
	printf '%s\n' '  star-history-helper.sh render --repo OWNER/REPO --input FILE --output FILE'
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	fetch | render)
		shift
		;;
	help | --help | -h)
		usage
		return 0
		;;
	*)
		usage >&2
		return 2
		;;
	esac
	command -v python3 >/dev/null 2>&1 || {
		printf 'star-history: python3 is required\n' >&2
		return 1
	}
	[[ -f "$PYTHON_HELPER" ]] || {
		printf 'star-history: missing generator: %s\n' "$PYTHON_HELPER" >&2
		return 1
	}
	python3 "$PYTHON_HELPER" "$command" "$@"
	return $?
}

main "$@"
