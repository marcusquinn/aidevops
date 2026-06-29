#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# loc-badge-helper.sh — compatibility wrapper for repo-metrics-helper.sh.
#
# Historical aidevops callers used this helper to generate only two SVG files:
# .github/badges/loc-total.svg and .github/badges/loc-languages.svg. The
# implementation now delegates to the dependency-light repository metrics
# generator so README badge generation no longer depends on tokei/cargo.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_HELPER="$SCRIPT_DIR/repo-metrics-helper.sh"

OUTPUT_DIR=".github/badges"
TOP_N="6"
JSON_ONLY=0
EXTRA_ARGS=()
SCAN_PATHS=()

usage() {
	printf '%s\n' "Usage: loc-badge-helper.sh [options] [path...]"
	printf '\n'
	printf '%s\n' "Options:"
	printf '%s\n' "  --output-dir DIR   Where to write legacy SVGs (default: .github/badges)"
	printf '%s\n' "  --top N            Top-N languages in the language badge (default: 6)"
	printf '%s\n' "  --exclude PATTERN  Additional path/glob exclusion (repeatable)"
	printf '%s\n' "  --json-only        Print legacy LOC summary JSON; do not write SVGs"
	printf '%s\n' "  --no-color-deps    Accepted for compatibility; ignored"
	printf '%s\n' "  -h, --help         Show usage"
	return 0
}

die() {
	local _message="$1"
	local _code="${2:-1}"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_message" >&2
	exit "$_code"
}

parse_args() {
	while (($# > 0)); do
		local _arg="$1"
		case "$_arg" in
		--output-dir)
			[[ $# -ge 2 ]] || die "--output-dir requires an argument" 2
			local _output_dir="$2"
			OUTPUT_DIR="$_output_dir"
			shift 2
			;;
		--top)
			[[ $# -ge 2 ]] || die "--top requires an argument" 2
			local _top="$2"
			[[ "$_top" =~ ^[0-9]+$ ]] || die "--top must be a positive integer" 2
			TOP_N="$_top"
			shift 2
			;;
		--exclude)
			[[ $# -ge 2 ]] || die "--exclude requires an argument" 2
			local _exclude="$2"
			EXTRA_ARGS+=(--exclude "$_exclude")
			shift 2
			;;
		--json-only)
			JSON_ONLY=1
			shift
			;;
		--no-color-deps)
			shift
			;;
		--version)
			printf '2.0.0\n'
			exit 0
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			while (($# > 0)); do
				local _path_after_dash="$1"
				SCAN_PATHS+=("$_path_after_dash")
				shift
			done
			;;
		-*)
			die "unknown option: $_arg" 2
			;;
		*)
			SCAN_PATHS+=("$_arg")
			shift
			;;
		esac
	done
	return 0
}

main() {
	parse_args "$@"
	[[ -f "$METRICS_HELPER" ]] || die "repo-metrics-helper.sh not found at $METRICS_HELPER"

	local _scan=("${SCAN_PATHS[@]}")
	if [[ ${#_scan[@]} -eq 0 ]]; then
		_scan=(".")
	fi

	if [[ "$JSON_ONLY" -eq 1 ]]; then
		bash "$METRICS_HELPER" loc-summary --top "$TOP_N" "${EXTRA_ARGS[@]}" "${_scan[@]}"
		return 0
	fi

	local _tmp_dir
	_tmp_dir=$(mktemp -d)
	trap 'rm -rf "$TMPDIR_TO_REMOVE"' EXIT
	TMPDIR_TO_REMOVE="$_tmp_dir"
	bash "$METRICS_HELPER" generate \
		--output-dir "$_tmp_dir" \
		--badge-dir "$OUTPUT_DIR" \
		--legacy-badge-dir "$OUTPUT_DIR" \
		--top "$TOP_N" \
		"${EXTRA_ARGS[@]}" \
		"${_scan[@]}"
	return 0
}

main "$@"
