#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# report-render-helper.sh — render report-ready Markdown/JSON to portable HTML.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
PY_HELPER="${SCRIPT_DIR}/report-render-helper.py"

[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

_die() {
	local _message="${1:-usage error}"
	printf '%b[%s] ERROR: %s%b\n' "$RED" "$SCRIPT_NAME" "$_message" "$NC" >&2
	exit 2
	# shellcheck disable=SC2317
	return 1
}

_run_python() {
	local _mode="${1:-render}"
	local _input="${2:-}"
	python3 "$PY_HELPER" "$_mode" "$_input"
	return 0
}

_print_usage() {
	cat <<'USAGE'
Usage:
  report-render-helper.sh render <input.md|input.json|-> [--output output.html]
  report-render-helper.sh validate <input.md|input.json|->
  report-render-helper.sh sample [markdown|json]
  report-render-helper.sh print-css

Evidence badges: {{evidence:verified}}, {{evidence:partial}}, {{evidence:inferred}}, {{evidence:missing}}
USAGE
	return 0
}

cmd_render() {
	local _input=""
	local _output=""
	while [[ $# -gt 0 ]]; do
		local _arg="${1:-}"
		shift
		case "$_arg" in
		--output)
			_output="${1:-}"
			[[ -z "$_output" ]] && _die "--output requires a path"
			shift
			;;
		-)
			[[ -n "$_input" ]] && _die "render accepts one input"
			_input="$_arg"
			;;
		-*)
			_die "unknown option: ${_arg}"
			;;
		*)
			[[ -n "$_input" ]] && _die "render accepts one input"
			_input="$_arg"
			;;
		esac
	done
	[[ -z "$_input" ]] && _die "render requires an input path"
	if [[ "$_input" != "-" && ! -f "$_input" ]]; then
		_die "input file not found: ${_input}"
	fi
	if [[ -n "$_output" ]]; then
		_run_python render "$_input" >"$_output"
	else
		_run_python render "$_input"
	fi
	return 0
}

cmd_validate() {
	local _input="${1:-}"
	[[ -z "$_input" ]] && _die "validate requires an input path"
	[[ "$_input" != "-" && ! -f "$_input" ]] && _die "input file not found: ${_input}"
	_run_python validate "$_input"
	return 0
}

cmd_sample() {
	local _format="${1:-markdown}"
	case "$_format" in
	markdown | md)
		cat <<'SAMPLE_MD'
# AI Visibility Report

## Executive summary

Visibility improved across answer engines. {{evidence:verified}}

## Scorecard

| Component | Score | Evidence |
|---|---:|---|
| AIO | 82 | {{evidence:verified}} |
| Gemini | 74 | {{evidence:partial}} |
| ChatGPT | 68 | {{evidence:inferred}} |
| Perplexity | 0 | {{evidence:missing}} |

## Sources

Source: SERP capture, crawl export, analytics comparison, and remediation notes.
SAMPLE_MD
		;;
	json)
		_run_python sample-json "-"
		;;
	*)
		_die "unknown sample format: ${_format}"
		;;
	esac
	return 0
}

cmd_print_css() {
	_run_python print-css "-"
	return 0
}

main() {
	local _command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$_command" in
	render)
		cmd_render "$@"
		;;
	validate)
		cmd_validate "$@"
		;;
	sample)
		cmd_sample "$@"
		;;
	print-css)
		cmd_print_css
		;;
	help | --help | -h)
		_print_usage
		;;
	*)
		_die "unknown command: ${_command}"
		;;
	esac
	return 0
}

main "$@"
