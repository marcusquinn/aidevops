#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
set -euo pipefail

# Email Agent Helper Script — Orchestrator
# Autonomous 3rd-party email communication for missions.
# Thin orchestrator that sources sub-libraries and dispatches commands.
#
# Sub-libraries:
#   email-agent-helper-core.sh      — Config, database, templates
#   email-agent-helper-send.sh      — Email sending via AWS SES
#   email-agent-helper-poll.sh      — Email retrieval from S3
#   email-agent-helper-commands.sh  — Code extraction, threads, conversations, status
#
# Usage:
#   email-agent-helper.sh send --mission <id> --to <email> --template <file> [--vars 'key=val,...']
#   email-agent-helper.sh poll --mission <id> [--since <ISO-date>]
#   email-agent-helper.sh extract-codes --message <msg-id> [--mission <id>]
#   email-agent-helper.sh thread --mission <id> [--conversation <conv-id>]
#   email-agent-helper.sh conversations --mission <id>
#   email-agent-helper.sh status [--mission <id>]
#   email-agent-helper.sh help
#
# Requires: aws CLI (SES + S3), jq, python3 (for email parsing)
# Config: configs/email-agent-config.json (from .json.txt template)
# Credentials: aidevops secret set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#
# Part of aidevops mission system (t1360)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================================
# Constants (shared across sub-libraries)
# ============================================================================

readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly CONFIG_FILE="${CONFIG_DIR}/email-agent-config.json"
readonly EMAIL_TO_MD_SCRIPT="${SCRIPT_DIR}/email-to-markdown.py"
readonly THREAD_RECON_SCRIPT="${SCRIPT_DIR}/email-thread-reconstruction.py"
# WORKSPACE_DIR and DB_FILE are overridable via env vars for testing
readonly WORKSPACE_DIR="${EMAIL_AGENT_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/email-agent}"
readonly DB_FILE="${EMAIL_AGENT_DB:-${WORKSPACE_DIR}/conversations.db}"

# Verification code patterns (extended regex, most specific first)
readonly -a CODE_PATTERNS=(
	'[Cc]ode[: ]+[0-9]{6}'
	'[Cc]ode[: ]+is[: ]+[0-9]{6}'
	'[Vv]erification[: ]+[0-9]{4,8}'
	'[Oo][Tt][Pp][: ]+[0-9]{4,8}'
	'[Pp][Ii][Nn][: ]+[0-9]{4,6}'
	'[Cc]onfirmation[: ]+[A-Z0-9]{6,12}'
	'[Tt]oken[: ]+[A-Za-z0-9_-]{20,}'
	'[Tt]oken[: ]+is[: ]+[A-Za-z0-9_-]{20,}'
)

# URL patterns for confirmation/activation links (extended regex)
readonly -a LINK_PATTERNS=(
	'https?://[^ <>"]+[?&](token|code|confirm|activate|verify|key)=[^ <>"&]+'
	'https?://[^ <>"]+/(confirm|activate|verify|validate|approve)/[^ <>"]+'
	'https?://[^ <>"]+/(signup|register|onboard)/[^ <>"]*[?&][^ <>"]+'
)

# ============================================================================
# Source sub-libraries
# ============================================================================

# shellcheck source=./email-agent-helper-core.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-agent-helper-core.sh"

# shellcheck source=./email-agent-helper-send.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-agent-helper-send.sh"

# shellcheck source=./email-agent-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-agent-helper-commands.sh"

# shellcheck source=./email-agent-helper-poll.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/email-agent-helper-poll.sh"

# ============================================================================
# Help
# ============================================================================

show_help() {
	cat <<'EOF'
email-agent-helper.sh - Autonomous 3rd-party email communication for missions

Usage:
  email-agent-helper.sh send --mission <id> --to <email> [options]
  email-agent-helper.sh poll --mission <id> [--since <ISO-date>]
  email-agent-helper.sh extract-codes --message <msg-id> | --mission <id>
  email-agent-helper.sh thread --mission <id> [--conversation <conv-id>]
  email-agent-helper.sh conversations --mission <id>
  email-agent-helper.sh status [--mission <id>]
  email-agent-helper.sh help

Send Options:
  --mission <id>       Mission ID (required)
  --to <email>         Recipient email (required)
  --template <file>    Template file with {{variable}} placeholders
  --vars 'k=v,k=v'    Template variable substitutions
  --subject <text>     Email subject (or from template Subject: header)
  --body <text>        Email body (or from template)
  --from <email>       Sender email (or from config default_from_email)
  --reply-to <msg-id>  Reply to a previous message (adds In-Reply-To header)

Poll Options:
  --mission <id>       Mission ID (required)
  --since <ISO-date>   Only poll emails after this date (ISO 8601 format,
                       e.g. 2026-01-15T00:00:00Z or 2026-01-15)

Extract Options:
  --message <msg-id>   Extract codes from specific message
  --mission <id>       Extract codes from all unprocessed mission messages

Thread Options:
  --mission <id>       Show all conversations for mission
  --conversation <id>  Show specific conversation thread

Verification Code Types:
  otp        Numeric codes (4-8 digits)
  token      Alphanumeric tokens (20+ chars)
  link       Confirmation/activation URLs
  api_key    API keys
  password   Temporary passwords

Template Format:
  Subject: Your API Access Request for {{service_name}}

  Dear {{contact_name}},

  I am writing to request API access for {{project_name}}.
  {{custom_message}}

  Best regards,
  {{sender_name}}

Configuration:
  Config file: configs/email-agent-config.json
  Template:    configs/email-agent-config.json.txt

  Required config fields:
    default_from_email   Verified SES sender address
    aws_region           AWS region for SES
    s3_receive_bucket    S3 bucket for SES Receipt Rules
    s3_receive_prefix    S3 prefix for incoming emails

Environment:
  AWS_ACCESS_KEY_ID        AWS credentials (or via gopass/credentials.sh)
  AWS_SECRET_ACCESS_KEY    AWS credentials
  AWS_DEFAULT_REGION       AWS region (overridden by config)

Integration with Missions:
  The email agent integrates with the mission orchestrator:
  1. Mission identifies need for 3rd-party communication
  2. Orchestrator invokes: email-agent-helper.sh send --mission M001 ...
  3. Agent polls for responses: email-agent-helper.sh poll --mission M001
  4. Codes extracted automatically on poll
  5. Mission reads codes: email-agent-helper.sh extract-codes --mission M001
  6. Conversation history: email-agent-helper.sh thread --mission M001

Examples:
  # Send a templated email
  email-agent-helper.sh send --mission M001 --to api@vendor.com \
    --template templates/api-request.md --vars 'service_name=Acme API,project_name=MyProject'

  # Poll for responses
  email-agent-helper.sh poll --mission M001

  # Check for verification codes
  email-agent-helper.sh extract-codes --mission M001

  # View conversation thread
  email-agent-helper.sh thread --mission M001 --conversation conv-20260301-120000-abcd

  # Check status
  email-agent-helper.sh status --mission M001
EOF
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	send) cmd_send "$@" ;;
	poll) cmd_poll "$@" ;;
	extract-codes) cmd_extract_codes "$@" ;;
	thread) cmd_thread "$@" ;;
	conversations) cmd_conversations "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

# Allow sourcing for tests: only run main when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
