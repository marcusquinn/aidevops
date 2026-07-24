#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Thin, dependency-free entrypoint for the GitHub API efficiency comparator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
readonly BENCHMARK_ENGINE="${SCRIPT_DIR}/github-api-efficiency-benchmark.py"

main() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'github-api-efficiency-benchmark: python3 is required\n' >&2
		return 2
	fi
	if [[ ! -r "$BENCHMARK_ENGINE" ]]; then
		printf 'github-api-efficiency-benchmark: comparison engine is unavailable\n' >&2
		return 2
	fi
	python3 "$BENCHMARK_ENGINE" "$@"
	return $?
}

main "$@"
