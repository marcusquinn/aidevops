#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Synchronize managed Star History and aidevops attribution README sections.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

usage() {
	printf '%s\n' 'Usage: managed-readme-helper.sh sync|check --repo OWNER/REPO [--root PATH]'
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	sync | check)
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
		printf '%s\n' 'managed-readme: python3 is required' >&2
		return 1
	}
	python3 "$SCRIPT_DIR/managed_readme.py" "$command" "$@"
	return $?
}

main "$@"
