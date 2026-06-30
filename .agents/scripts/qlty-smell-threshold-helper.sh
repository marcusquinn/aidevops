#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# qlty-smell-threshold-helper.sh — absolute qlty smell ratchet gate (GH#18775)

set -u

SCRIPT_NAME=$(basename "$0")

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

find_qlty() {
	if command -v qlty >/dev/null 2>&1; then
		command -v qlty
		return 0
	fi
	if [ -x "${HOME:-}/.qlty/bin/qlty" ]; then
		printf '%s/.qlty/bin/qlty\n' "$HOME"
		return 0
	fi
	return 1
}

read_threshold() {
	local _conf="$1"
	local _threshold="0"
	local _val=""
	if [ -f "$_conf" ]; then
		_val=$(grep '^QLTY_SMELL_THRESHOLD=' "$_conf" | cut -d= -f2 || true)
		if [ -n "$_val" ] && [ "$_val" -eq "$_val" ] 2>/dev/null; then
			_threshold="$_val"
		fi
	fi
	printf '%s\n' "$_threshold"
	return 0
}

emit_sarif_warning() {
	local _reason="$1"
	local _diag_file="$2"
	local _qlty_bin="$3"
	local _stdout_preview="${4:-}"
	local _qlty_rc="${5:-}"
	printf '::warning::qlty smells produced %s SARIF output — skipping absolute smell threshold check\n' "$_reason"
	if [ -n "$_qlty_rc" ]; then
		printf 'qlty smells exit code: %s\n' "$_qlty_rc"
	fi
	printf 'Qlty version: '
	"$_qlty_bin" --version 2>/dev/null || printf 'unknown\n'
	if [ -n "$_stdout_preview" ]; then
		printf '\nqlty stdout preview:\n'
		printf '%s\n' "${_stdout_preview:0:2000}"
	fi
	if [ -s "$_diag_file" ]; then
		printf '\nqlty stderr (first 40 lines):\n'
		sed -n '1,40p' "$_diag_file"
	fi
	return 0
}

is_blank_output() {
	local _value="$1"
	[[ -z "${_value//[[:space:]]/}" ]]
	return $?
}

is_valid_sarif_results() {
	local _value="$1"
	printf '%s\n' "$_value" | jq -e '.runs[0].results | type == "array"' >/dev/null 2>&1
	return $?
}

run_threshold_check() {
	local _conf="${1:-.agents/configs/complexity-thresholds.conf}"
	local _threshold=""
	local _qlty_bin=""
	local _diag_file=""
	local _sarif=""
	local _count=""
	local _headroom=""
	local _qlty_rc="0"

	_threshold=$(read_threshold "$_conf")
	if [ "$_threshold" -eq 0 ]; then
		printf '::warning::QLTY_SMELL_THRESHOLD not set in %s — skipping check\n' "$_conf"
		return 0
	fi

	_qlty_bin=$(find_qlty) || {
		printf '::error::qlty CLI not found\n'
		return 1
	}

	printf 'Counting total qlty smells across all files...\n'
	_diag_file=$(mktemp "${TMPDIR:-/tmp}/qlty-smell-threshold.XXXXXX") || return 1
	_sarif=$("$_qlty_bin" smells --all --sarif --no-snippets --quiet 2>"$_diag_file")
	_qlty_rc=$?
	if is_blank_output "$_sarif"; then
		emit_sarif_warning "empty" "$_diag_file" "$_qlty_bin" "" "$_qlty_rc"
		rm -f "$_diag_file"
		return 0
	fi
	if ! is_valid_sarif_results "$_sarif"; then
		emit_sarif_warning "invalid" "$_diag_file" "$_qlty_bin" "$_sarif" "$_qlty_rc"
		rm -f "$_diag_file"
		return 0
	fi
	rm -f "$_diag_file"

	_count=$(printf '%s\n' "$_sarif" | jq '.runs[0].results | length' 2>/dev/null || true)
	if ! [ "$_count" -eq "$_count" ] 2>/dev/null; then
		printf '::error::Failed to parse smell count from SARIF output\n'
		return 1
	fi

	printf '\n'
	printf 'Total qlty smells: %s\n' "$_count"
	printf 'Threshold:         %s\n' "$_threshold"
	printf '\n'

	if [ "$_count" -gt "$_threshold" ]; then
		printf '::error::Qlty smell regression: %s smells exceeds threshold %s\n' "$_count" "$_threshold"
		printf '\nPer-rule breakdown:\n'
		printf '%s\n' "$_sarif" | jq -r '.runs[0].results | group_by(.ruleId) | map({rule: .[0].ruleId, count: length}) | sort_by(-.count) | .[] | "  \(.count)\t\(.rule)"'
		printf '\nTop 20 files by smell count:\n'
		printf '%s\n' "$_sarif" | jq -r '.runs[0].results | group_by(.locations[0].physicalLocation.artifactLocation.uri) | map({file: .[0].locations[0].physicalLocation.artifactLocation.uri, count: length}) | sort_by(-.count) | .[0:20] | .[] | "  \(.count)\t\(.file)"'
		printf '\nFix options:\n'
		printf "  1. Reduce smells in your PR (preferred) — run 'qlty smells --all' locally\n"
		printf '  2. Justify a bump of QLTY_SMELL_THRESHOLD in complexity-thresholds.conf\n'
		printf '     with a history entry in complexity-thresholds-history.md\n'
		return 1
	fi

	_headroom=$((_threshold - _count))
	printf 'Within threshold (%s headroom)\n' "$_headroom"
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	run_threshold_check "${1:-.agents/configs/complexity-thresholds.conf}"
	exit $?
fi
