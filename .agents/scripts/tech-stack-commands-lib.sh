#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tech Stack Commands Library -- BigQuery analytics commands
# =============================================================================
# Implements the categories, trending, and info commands that rely on BigQuery
# for technology metadata and adoption analytics.
#
# Usage: source "${SCRIPT_DIR}/tech-stack-commands-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, CYAN, NC)
#   - tech-stack-bq-lib.sh (check_bq_available, check_gcloud_auth,
#                            bq_list_categories, bq_trending, bq_tech_info,
#                            bq_tech_detections)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TECH_STACK_COMMANDS_LIB_LOADED:-}" ]] && return 0
_TECH_STACK_COMMANDS_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Command: categories
# =============================================================================

cmd_categories() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format | -f)
			format="$2"
			shift 2
			;;
		--help | -h)
			usage_categories
			return 0
			;;
		*) shift ;;
		esac
	done

	if ! check_bq_available || ! check_gcloud_auth; then
		print_error "BigQuery required for categories listing"
		return 1
	fi

	bq_list_categories "$format"
	return $?
}

# =============================================================================
# Command: trending
# =============================================================================

cmd_trending() {
	local direction="adopted"
	local limit=20
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--direction | -d)
			direction="$2"
			shift 2
			;;
		--limit | -n)
			limit="$2"
			shift 2
			;;
		--format | -f)
			format="$2"
			shift 2
			;;
		--help | -h)
			usage_trending
			return 0
			;;
		*) shift ;;
		esac
	done

	if ! check_bq_available || ! check_gcloud_auth; then
		print_error "BigQuery required for trending data"
		return 1
	fi

	bq_trending "$direction" "$limit" "$format"
	return $?
}

# =============================================================================
# Command: info
# =============================================================================

cmd_info() {
	local technology=""
	local format="json"
	local show_detections=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format | -f)
			format="$2"
			shift 2
			;;
		--detections)
			show_detections=true
			shift
			;;
		--help | -h)
			usage_info
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$technology" ]]; then
				technology="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$technology" ]]; then
		print_error "Technology name is required"
		usage_info
		return 1
	fi

	if ! check_bq_available || ! check_gcloud_auth; then
		print_error "BigQuery required for technology info"
		return 1
	fi

	bq_tech_info "$technology" "$format"

	if [[ "$show_detections" == true ]]; then
		echo ""
		print_info "Adoption/deprecation history:"
		bq_tech_detections "$technology" 6 "$format"
	fi

	return 0
}

# =============================================================================
# Help: BigQuery commands
# =============================================================================

usage_categories() {
	cat <<EOF
${CYAN}categories${NC} — List available technology categories

${HELP_LABEL_USAGE}
  $0 categories [options]

${HELP_LABEL_OPTIONS}
  --format, -f <fmt>   Output format: json (default), table
  --help, -h           ${HELP_SHOW_MESSAGE}
EOF
	return 0
}

usage_trending() {
	cat <<EOF
${CYAN}trending${NC} — Show trending technology adoptions/deprecations

${HELP_LABEL_USAGE}
  $0 trending [options]

${HELP_LABEL_OPTIONS}
  --direction, -d <dir>  Direction: adopted (default), deprecated
  --limit, -n <num>      Max results (default: 20)
  --format, -f <fmt>     Output format: json (default), table
  --help, -h             ${HELP_SHOW_MESSAGE}
EOF
	return 0
}

usage_info() {
	cat <<EOF
${CYAN}info${NC} — Get technology metadata and adoption trends

${HELP_LABEL_USAGE}
  $0 info <technology> [options]

${HELP_LABEL_OPTIONS}
  --detections         Include adoption/deprecation history
  --format, -f <fmt>   Output format: json (default), table
  --help, -h           ${HELP_SHOW_MESSAGE}
EOF
	return 0
}
