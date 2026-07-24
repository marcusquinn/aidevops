#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Thin, dependency-free entrypoint for the GitHub API efficiency sidecar producer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
readonly EVIDENCE_ENGINE="${SCRIPT_DIR}/github-api-efficiency-evidence.py"

main() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'github-api-efficiency-evidence: python3 is required\n' >&2
		return 2
	fi
	if [[ ! -r "$EVIDENCE_ENGINE" ]]; then
		printf 'github-api-efficiency-evidence: evidence engine is unavailable\n' >&2
		return 2
	fi
	python3 "$EVIDENCE_ENGINE" "$@"
	return $?
}

main "$@"
