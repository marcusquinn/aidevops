#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# reach-feedback-routine.sh - Report-only reach feedback mining routine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REACH_HELPER="${SCRIPT_DIR}/reach-helper.sh"

usage() {
	cat <<'EOF'
Usage: reach-feedback-routine.sh [--window 7d] [--format json|markdown]

Runs the reach feedback miner in report-only mode. It does not create issues,
write comments, or promote themes; promotion stays behind review gates.
EOF
	return 0
}

main() {
	local window_value="7d"
	local format_value="json"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--window)
				shift
				window_value="${1:-7d}"
				;;
			--format)
				shift
				format_value="${1:-json}"
				;;
			-h | --help | help)
				usage
				return 0
				;;
			*)
				printf '[ERROR] Unknown option: %s\n' "$arg" >&2
				usage >&2
				return 1
				;;
		esac
		shift || true
	done

	"$REACH_HELPER" feedback mine --window "$window_value" --format "$format_value"
	return $?
}

main "$@"
