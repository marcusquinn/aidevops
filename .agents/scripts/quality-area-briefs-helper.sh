#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Service findings are data, never shell commands. Python owns the bounded plan.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

main() {
	local arg=""
	local offline=0
	for arg in "$@"; do
		case "$arg" in
		--help | -h)
			python3 "$SCRIPT_DIR/quality_area_briefs.py" --help
			return 0
			;;
		--offline) offline=1 ;;
		esac
	done
	if [[ "$offline" -eq 0 ]]; then
		if [[ -z "${CODACY_API_TOKEN:-}" ]]; then
			CODACY_API_TOKEN="$(aidevops secret get CODACY_API_TOKEN)" || return 1
			export CODACY_API_TOKEN
		fi
	fi
	python3 "$SCRIPT_DIR/quality_area_briefs.py" "$@" || return 1
	return 0
}

main "$@"
