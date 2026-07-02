#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# reach-routine.sh - Report-only periodic reach watch entry point.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REACH_HELPER="${SCRIPT_DIR}/reach-helper.sh"

usage() {
	cat <<'EOF'
Usage: reach-routine.sh [--format json]

Runs reach watch once in dry-run/report-only mode. It does not create issues,
write comments, mutate cookies/profiles, contact targets, or promote captures.
EOF
	return 0
}

main() {
	local format_value="json"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
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

	"$REACH_HELPER" watch --once --dry-run --format "$format_value"
	return $?
}

main "$@"
