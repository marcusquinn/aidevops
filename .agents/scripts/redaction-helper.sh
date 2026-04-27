#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# redaction-helper.sh — PII/sensitive data redaction before cloud LLM calls
# =============================================================================
# MVP stub: copies input to output unchanged and marks the output with a
# TODO header. The hook point exists from day 1 so llm-routing-helper.sh
# can call it unconditionally for pii-tier cloud calls.
#
# Real redaction (entity recognition, pattern-based masking) is post-MVP.
# Track at: GH#20900 parent task (t2840 P0.5 phase).
#
# Usage:
#   redaction-helper.sh redact <input-file> <output-file>
#   redaction-helper.sh status
#   redaction-helper.sh help
#
# Exit codes:
#   0 — redaction applied (or stub pass-through succeeded)
#   1 — input file missing or output could not be written
#
# TODO(post-MVP): implement entity recognition (names, emails, IDs, keys)
# TODO(post-MVP): implement pattern-based masking (credit cards, phone numbers)
# TODO(post-MVP): implement configurable allow/deny lists per data category
# TODO(post-MVP): integrate with a local NER model via Ollama for PII detection
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Subcommands
# =============================================================================

cmd_redact() {
	local input_file="${1:-}"
	local output_file="${2:-}"

	if [[ -z "$input_file" || -z "$output_file" ]]; then
		print_error "Usage: redaction-helper.sh redact <input-file> <output-file>"
		return 1
	fi

	if [[ ! -f "$input_file" ]]; then
		print_error "Input file not found: ${input_file}"
		return 1
	fi

	# TODO(post-MVP): apply real PII/sensitive data redaction here.
	# For now, pass through unchanged. The routing layer records
	# redaction_applied=true when this returns exit 0.
	cp "$input_file" "$output_file" || {
		print_error "Failed to write output file: ${output_file}"
		return 1
	}

	print_warning "redaction-helper.sh stub: no redaction applied (post-MVP). Data passed through unchanged."
	return 0
}

cmd_status() {
	printf 'redaction-helper.sh status\n'
	printf '  Implementation: stub (pass-through)\n'
	printf '  Real redaction: TODO post-MVP\n'
	printf '  Planned: entity recognition, pattern masking, NER via Ollama\n'
	return 0
}

cmd_help() {
	cat <<'HELP'
redaction-helper.sh — PII/sensitive data redaction stub

Commands:
  redact <input> <output>   Copy input to output (stub; TODO: real redaction)
  status                    Show implementation status
  help                      Show this help

TODO(post-MVP):
  - Entity recognition (names, emails, IDs, API keys)
  - Pattern-based masking (credit cards, phone numbers, national IDs)
  - Configurable allow/deny lists per data category
  - Local NER model integration via Ollama for PII detection
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	redact) cmd_redact "$@" ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
