#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# draft-response-helper.sh — Notification-driven approval flow for contribution
# watch replies (t1555). Stores draft replies as markdown files locally;
# user approves or rejects via CLI before anything is posted to GitHub.
#
# Usage:
#   draft-response-helper.sh draft <item_key> [--body-file <file>]
#                                              Create a draft reply for a tracked item
#   draft-response-helper.sh list [--pending|--approved|--rejected]
#                                              List drafts (default: all)
#   draft-response-helper.sh show <draft_id>   Show draft content (prompt-injection-scanned)
#   draft-response-helper.sh approve <draft_id> Post draft to GitHub
#   draft-response-helper.sh reject <draft_id> [reason]
#                                              Discard draft without posting
#   draft-response-helper.sh check-approvals   Scan notification issues for user comments (t1556)
#   draft-response-helper.sh status            Summary of all drafts
#   draft-response-helper.sh help              Show usage
#
# Architecture:
#   1. contribution-watch-helper.sh detects "needs reply" items
#   2. 'draft <key>' creates local draft + notification issue in private repo
#   3. User gets GitHub notification, reviews draft, comments with instructions
#   4. Pulse/agent reads comment, interprets intent (intelligence-led, not keyword-matching)
#   5. 'approve' posts the draft body to GitHub; 'reject' discards it
#   6. Closing the notification issue without comment = no action (decline)
#   7. Any other comment = agent interprets and acts (re-draft, alternative, etc.)
#   8. Drafts are NEVER posted automatically — explicit approval always required
#
# Security:
#   - Draft bodies are scanned by prompt-guard-helper.sh before display
#   - Approved text is posted via --body-file (no secret-as-argument risk)
#   - Item keys are validated against contribution-watch state
#   - No credentials or secret values are written to draft files
#
# Draft storage: ~/.aidevops/.agent-workspace/draft-responses/
# Draft ID:      YYYYMMDD-HHMMSS-{item-key-slug}
#
# Sub-libraries:
#   - draft-response-notification.sh  notification repo, bot filtering, prerequisites
#   - draft-response-approvals.sh     approval flow, check-approvals command
#   - draft-response-storage.sh       draft CRUD, list/show/approve/reject/status
#
# Task: t1555 | Ref: GH#5475

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

DRAFT_DIR="${HOME}/.aidevops/.agent-workspace/draft-responses"
LOGFILE="${HOME}/.aidevops/logs/draft-response.log"
CW_STATE="${HOME}/.aidevops/cache/contribution-watch.json"
PROMPT_GUARD="${SCRIPT_DIR}/prompt-guard-helper.sh"
DRAFT_REPO_NAME="draft-responses"

# =============================================================================
# Logging
# =============================================================================

_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

_log_info() {
	_log "INFO" "$@"
	return 0
}

_log_warn() {
	_log "WARN" "$@"
	return 0
}

_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Sub-library loading
# =============================================================================

# shellcheck source=./draft-response-notification.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/draft-response-notification.sh"

# shellcheck source=./draft-response-storage.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/draft-response-storage.sh"

# shellcheck source=./draft-response-approvals.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/draft-response-approvals.sh"

# =============================================================================
# cmd_help
# =============================================================================

cmd_help() {
	echo "draft-response-helper.sh — Notification-driven approval flow for contribution watch replies"
	echo ""
	echo "Usage:"
	echo "  draft-response-helper.sh draft <item_key> [--body-file <file>]"
	echo "      Create a draft reply for a tracked GitHub issue/PR"
	echo "      item_key: owner/repo#123"
	echo "      --body-file: use existing markdown file as draft body (optional)"
	echo ""
	echo "  draft-response-helper.sh list [--pending|--approved|--rejected]"
	echo "      List drafts, optionally filtered by status"
	echo ""
	echo "  draft-response-helper.sh show <draft_id>"
	echo "      Display draft metadata and body (prompt-injection-scanned)"
	echo ""
	echo "  draft-response-helper.sh approve <draft_id>"
	echo "      Post the draft reply to GitHub and mark as approved"
	echo ""
	echo "  draft-response-helper.sh reject <draft_id> [reason]"
	echo "      Discard the draft (optionally with a reason)"
	echo ""
	echo "  draft-response-helper.sh check-approvals"
	echo "      Scan notification issues for user comments and act on them (t1556)"
	echo "      Deterministic gate: no LLM cost for issues without new user comments"
	echo "      Intelligence layer: interprets user intent (approve/decline/redraft/custom)"
	echo "      Bot comments are filtered out; role-based compose caps enforced"
	echo ""
	echo "  draft-response-helper.sh process-approved"
	echo "      Post all approved drafts and close their notification issues"
	echo "      Handles issues labeled 'approved' by the GitHub Actions workflow"
	echo ""
	echo "  draft-response-helper.sh status"
	echo "      Show summary of all drafts"
	echo ""
	echo "  draft-response-helper.sh help"
	echo "      Show this help"
	echo ""
	echo "Draft storage: ${DRAFT_DIR}"
	echo "Log file:      ${LOGFILE}"
	echo ""
	echo "Integration with contribution-watch-helper.sh:"
	echo "  contribution-watch-helper.sh scan --auto-draft"
	echo "  Automatically creates drafts when new activity is detected on tracked threads."
	echo "  Drafts are NEVER posted automatically — user approval is always required."
	echo ""
	echo "Approval scanning (t1556):"
	echo "  check-approvals scans open notification issues for user comments."
	echo "  When found, an LLM interprets the user's intent and acts accordingly."
	echo "  Runs as part of the hourly contribution-watch scan cycle."
	echo ""
	echo "Auto-decline safety net (t5520):"
	echo "  check-approvals also auto-declines drafts where:"
	echo "    1. The draft body contains no-reply indicators (e.g. 'no reply needed')"
	echo "    2. No user comment exists on the notification issue"
	echo "    3. The draft was created more than 24h ago (grace period)"
	echo "  This catches cases where the compose agent failed to call 'reject' directly."
	echo "  Primary path: agent calls 'reject <draft_id> \"No reply needed\"' immediately."
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true

	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

	case "$cmd" in
	init) _check_prerequisites && _ensure_draft_repo ;;
	draft) cmd_draft "$@" ;;
	list) cmd_list "$@" ;;
	show) cmd_show "$@" ;;
	approve) cmd_approve "$@" ;;
	reject) cmd_reject "$@" ;;
	status) cmd_status "$@" ;;
	check-approvals) cmd_check_approvals "$@" ;;
	process-approved) cmd_process_approved "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		echo "Run 'draft-response-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
