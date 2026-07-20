#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# qlty-smell-threshold-helper.sh — absolute qlty smell ratchet gate (GH#18775)

set -u

SCRIPT_NAME=$(basename "$0")
UNKNOWN_VALUE="unknown"

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

qlty_version() {
	local _qlty_bin="$1"
	local _version=""
	_version=$("$_qlty_bin" --version 2>/dev/null) || _version="$UNKNOWN_VALUE"
	printf '%s\n' "$_version"
	return 0
}

verify_qlty_version() {
	local _version="$1"
	local _expected="${QLTY_CLI_VERSION:-}"
	if [ -n "$_expected" ] && [[ "$_version" != *" $_expected"* ]]; then
		printf '::error::Qlty CLI version mismatch: expected %s, resolved %s\n' "$_expected" "$_version"
		return 1
	fi
	return 0
}

emit_valid_scan_metadata() {
	local _qlty_version="$1"
	local _sarif="$2"
	local _commit="$UNKNOWN_VALUE"
	local _tree="$UNKNOWN_VALUE"
	local _config="none"
	local _mode="${QLTY_SCAN_MODE:-direct-checkout}"
	local _count="0"
	_commit=$(git rev-parse HEAD 2>/dev/null) || _commit="$UNKNOWN_VALUE"
	_tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null) || _tree="$UNKNOWN_VALUE"
	if [ -f .qlty/qlty.toml ]; then
		_config=".qlty/qlty.toml"
	fi
	_count=$(printf '%s\n' "$_sarif" | jq '.runs[0].results | length')
	printf 'Qlty version: %s\n' "$_qlty_version"
	printf 'Scan commit: %s\n' "$_commit"
	printf 'Scan tree: %s\n' "$_tree"
	printf 'Scan mode: %s\n' "$_mode"
	printf 'Scan root: repository-root\n'
	printf 'Qlty config: %s\n' "$_config"
	printf 'Normalized result count: %s\n' "$_count"
	printf 'Normalized per-rule counts:\n'
	printf '%s\n' "$_sarif" | jq -r '[.runs[0].results[]?.ruleId? | select(. != null)] | group_by(.) | map({rule: .[0], count: length}) | sort_by(.rule) | .[] | "  \(.count)\t\(.rule)"'
	return 0
}

is_non_negative_integer() {
	local _value="$1"
	case "$_value" in
	'' | *[!0-9]*)
		return 1
		;;
	*)
		return 0
		;;
	esac
	return 1
}

read_threshold() {
	local _conf="$1"
	local _threshold="0"
	local _val=""
	if [ -f "$_conf" ]; then
		_val=$(grep '^QLTY_SMELL_THRESHOLD=' "$_conf" | cut -d= -f2 || true)
		if is_non_negative_integer "$_val"; then
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
	printf 'Absolute threshold status: diagnostic-only for this run; PR-specific qlty delta gate remains authoritative.\n'
	printf 'Command: %s smells --all --sarif --no-snippets --quiet\n' "$_qlty_bin"
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

emit_remediation_evidence() {
	local _count="$1"
	local _threshold="$2"
	local _sarif="$3"
	local _deficit=$((_count - _threshold))
	local _evidence=""

	_evidence=$(printf '%s\n' "$_sarif" | jq -c \
		--argjson actual "$_count" --argjson threshold "$_threshold" --argjson deficit "$_deficit" '
		{
			schema: "aidevops.qlty-remediation.v1",
			actual: $actual,
			threshold: $threshold,
			deficit: $deficit,
			scope: "repository",
			files: ([.runs[0].results[]? |
				.locations[0]?.physicalLocation?.artifactLocation?.uri? |
				select(. != null)] |
				group_by(.) | map({file: .[0], count: length}) | sort_by([-.count, .file])),
			rules: ([.runs[0].results[]?.ruleId? | select(. != null)] |
				group_by(.) | map({rule: .[0], count: length}) | sort_by([-.count, .rule]))
		}' 2>/dev/null) || _evidence=""
	if [ -n "$_evidence" ]; then
		printf 'QLTY_REMEDIATION_EVIDENCE=%s\n' "$_evidence"
	fi
	return 0
}

run_threshold_check() {
	local _conf="${1:-.agents/configs/complexity-thresholds.conf}"
	local _threshold=""
	local _qlty_bin=""
	local _cache_dir=""
	local _diag_file=""
	local _warmup_file=""
	local _sarif=""
	local _count=""
	local _headroom=""
	local _qlty_rc="0"
	local _qlty_version=""

	_threshold=$(read_threshold "$_conf")
	if [ "$_threshold" -eq 0 ]; then
		printf '::warning::QLTY_SMELL_THRESHOLD not set in %s — skipping check\n' "$_conf"
		return 0
	fi

	_qlty_bin=$(find_qlty) || {
		printf '::error::qlty CLI not found\n'
		return 1
	}
	_qlty_version=$(qlty_version "$_qlty_bin")
	verify_qlty_version "$_qlty_version" || return 1

	printf 'Warming isolated qlty cache before authoritative scan...\n'
	_diag_file=$(mktemp "${TMPDIR:-/tmp}/qlty-smell-threshold.XXXXXX") || return 1
	_warmup_file=$(mktemp "${TMPDIR:-/tmp}/qlty-smell-warmup.XXXXXX") || {
		rm -f "$_diag_file"
		return 1
	}
	_cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/qlty-smell-cache.XXXXXX") || {
		rm -f "$_diag_file" "$_warmup_file"
		return 1
	}
	XDG_CACHE_HOME="$_cache_dir" "$_qlty_bin" smells --all --sarif --no-snippets --quiet \
		>"$_warmup_file" 2>/dev/null || true
	printf 'Counting total qlty smells across all files...\n'
	_sarif=$(XDG_CACHE_HOME="$_cache_dir" "$_qlty_bin" smells --all --sarif --no-snippets --quiet 2>"$_diag_file")
	_qlty_rc=$?
	rm -f "$_warmup_file"
	rm -rf "$_cache_dir"
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
	if ! is_non_negative_integer "$_count"; then
		printf '::error::Failed to parse smell count from SARIF output\n'
		return 1
	fi
	emit_valid_scan_metadata "$_qlty_version" "$_sarif"

	printf '\n'
	printf 'Total qlty smells: %s\n' "$_count"
	printf 'Threshold:         %s\n' "$_threshold"
	printf '\n'

	if [ "$_count" -gt "$_threshold" ]; then
		printf '::error::Qlty smell regression: %s smells exceeds threshold %s\n' "$_count" "$_threshold"
		emit_remediation_evidence "$_count" "$_threshold" "$_sarif"
		printf '\nPer-rule breakdown:\n'
		printf '%s\n' "$_sarif" | jq -r '[.runs[0].results[]?.ruleId? | select(. != null)] | group_by(.) | map({rule: .[0], count: length}) | sort_by(-.count) | .[] | "  \(.count)\t\(.rule)"'
		printf '\nTop 20 files by smell count:\n'
		printf '%s\n' "$_sarif" | jq -r '[.runs[0].results[]? | .locations[0]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | group_by(.) | map({file: .[0], count: length}) | sort_by(-.count) | .[0:20] | .[] | "  \(.count)\t\(.file)"'
		printf '\nFix options:\n'
		printf "  1. New PR smells remain blocking — run 'qlty smells --all' locally\n"
		printf '  2. Pre-existing default-branch debt must enter the autonomous quality-sweep remediation loop\n'
		printf '  3. Do not raise QLTY_SMELL_THRESHOLD to absorb recurring debt\n'
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
