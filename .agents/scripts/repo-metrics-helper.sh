#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# repo-metrics-helper.sh — local repo LOC/language/dependency metrics.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_HELPER="$SCRIPT_DIR/repo_metrics.py"

usage() {
	printf '%s\n' "repo-metrics-helper.sh — generate local README/app repository metrics"
	printf '\n'
	printf '%s\n' "Usage:"
	printf '%s\n' "  repo-metrics-helper.sh generate [options] [path...]"
	printf '%s\n' "  repo-metrics-helper.sh json [options] [path...]"
	printf '%s\n' "  repo-metrics-helper.sh loc-summary [options] [path...]"
	printf '%s\n' "  repo-metrics-helper.sh help"
	printf '\n'
	printf '%s\n' "Options:"
	printf '%s\n' "  --output-dir DIR              Metrics JSON/Markdown dir (default: docs/metrics)"
	printf '%s\n' "  --badge-dir DIR               Badge SVG dir (default: OUTPUT_DIR/badges)"
	printf '%s\n' "  --legacy-badge-dir DIR        Also write legacy loc-total/loc-languages SVGs"
	printf '%s\n' "  --top N                       Top-N languages in SVG (default: 6)"
	printf '%s\n' "  --exclude PATTERN             Extra path/glob exclusion (repeatable)"
	printf '%s\n' "  --skip-if-fresh-hours HOURS   Skip writes when generated outputs are fresh"
	printf '\n'
	printf '%s\n' "Outputs: docs/metrics/repo-metrics.json, repo-metrics.md, badges/*.svg"
	return 0
}

die() {
	local _message="$1"
	local _code="${2:-1}"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_message" >&2
	exit "$_code"
}

require_runtime() {
	command -v python3 >/dev/null 2>&1 || die "python3 is required"
	[[ -f "$PY_HELPER" ]] || die "repo_metrics.py not found at $PY_HELPER"
	return 0
}

main() {
	local _cmd="${1:-generate}"
	case "$_cmd" in
	generate | json | loc-summary | help | --help | -h)
		shift || true
		;;
	*)
		if [[ "$_cmd" == -* ]]; then
			_cmd="generate"
		else
			die "unknown subcommand: $_cmd (try generate|json|loc-summary)" 2
		fi
		;;
	esac

	case "$_cmd" in
	help | --help | -h)
		usage
		return 0
		;;
	esac

	require_runtime
	local _args=("$@")
	case "$_cmd" in
	generate)
		python3 "$PY_HELPER" "${_args[@]}"
		;;
	json)
		python3 "$PY_HELPER" --json-only "${_args[@]}"
		;;
	loc-summary)
		python3 "$PY_HELPER" --loc-summary-json "${_args[@]}"
		;;
	esac
	return 0
}

main "$@"
