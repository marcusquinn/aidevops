#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Email Health Check Helper -- Orchestrator
# =============================================================================
# Validates email authentication and deliverability for domains.
# Checks: SPF, DKIM, DMARC, MX records, blacklist status,
#         BIMI, MTA-STS, TLS-RPT, DANE, and overall health score.
# Also validates HTML email content quality before sending.
#
# This is the thin orchestrator — sources sub-libraries for each domain:
#   - email-health-check-helper-infrastructure.sh (DNS/infra checks)
#   - email-health-check-helper-content.sh (HTML content analysis)
#   - email-health-check-helper-dispatch.sh (dispatch, scoring, UI)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# --- SCRIPT_DIR and shared constants ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

init_log_file

# --- Common message constants ---

readonly HELP_SHOW_MESSAGE="Show this help"
readonly USAGE_COMMAND_OPTIONS="Usage: $0 [command] [domain] [options]"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Common DKIM selectors by provider
readonly DKIM_SELECTORS="google google1 google2 selector1 selector2 k1 k2 s1 s2 pm smtp zoho default dkim"

# --- Health score tracking (global for accumulation across checks) ---

HEALTH_SCORE=0
HEALTH_MAX=0

# --- Shared utility functions ---

add_score() {
	local points="$1"
	local max_points="$2"
	HEALTH_SCORE=$((HEALTH_SCORE + points))
	HEALTH_MAX=$((HEALTH_MAX + max_points))
	return 0
}

print_header() {
	local msg="$1"
	echo ""
	echo -e "${BLUE}=== $msg ===${NC}"
	return 0
}

# Check if a command exists
command_exists() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1
	return $?
}

# --- Source sub-libraries ---

# shellcheck source=./email-health-check-helper-infrastructure.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-health-check-helper-infrastructure.sh"

# shellcheck source=./email-health-check-helper-content.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-health-check-helper-content.sh"

# shellcheck source=./email-health-check-helper-dispatch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-health-check-helper-dispatch.sh"

# --- Main function ---

# Main function — thin dispatcher delegating to sub-dispatchers by command group
main() {
	local command="${1:-help}"
	local arg2="${2:-}"
	local arg3="${3:-}"

	# Try infrastructure commands first
	if _dispatch_infrastructure_cmd "$command" "$arg2" "$arg3"; then
		return 0
	fi

	# Try content commands next
	if _dispatch_content_cmd "$command" "$arg2"; then
		return 0
	fi

	# Fall through to combined/utility commands
	_dispatch_combined_cmd "$command" "$arg2" "$arg3"

	return 0
}

main "$@"
