#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2155
set -euo pipefail

# Email Mailbox Helper Script
# IMAP/JMAP adapter and mailbox operations for AI assistants.
# Connects to any email provider via IMAP (JMAP planned for Phase 4).
#
# Usage:
#   email-mailbox-helper.sh accounts [--test]
#   email-mailbox-helper.sh inbox [account] [--limit N] [--offset N] [--folder FOLDER]
#   email-mailbox-helper.sh read [account] --uid UID [--folder FOLDER]
#   email-mailbox-helper.sh folders [account]
#   email-mailbox-helper.sh create-folder [account] --folder PATH
#   email-mailbox-helper.sh send [account] --to ADDR --subject SUBJ --body TEXT
#   email-mailbox-helper.sh move [account] --uid UID --dest FOLDER [--folder FOLDER]
#   email-mailbox-helper.sh flag [account] --uid UID --flag NAME [--clear] [--folder FOLDER]
#   email-mailbox-helper.sh search [account] --query "IMAP SEARCH" [--folder FOLDER] [--limit N]
#   email-mailbox-helper.sh smart-mailbox [account] --name NAME --criteria "SEARCH"
#   email-mailbox-helper.sh sync [account] [--folder FOLDER] [--full]
#   email-mailbox-helper.sh help
#
# Requires: python3 (for IMAP operations), jq
# Config: configs/email-providers.json (from .json.txt template)
# Credentials: gopass show -o email-imap-{account} (via IMAP_PASSWORD env var)
#
# Part of aidevops email system (t1493)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================================
# Constants
# ============================================================================

readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly PROVIDERS_TEMPLATE="${CONFIG_DIR}/email-providers.json.txt"
readonly PROVIDERS_CONFIG="${CONFIG_DIR}/email-providers.json"
readonly IMAP_ADAPTER="${SCRIPT_DIR}/email_imap_adapter.py"
readonly MAILBOX_WORKSPACE="${HOME}/.aidevops/.agent-workspace/email-mailbox"

# ============================================================================
# Dependency checks
# ============================================================================

check_dependencies() {
	local missing=0

	if ! command -v python3 &>/dev/null; then
		print_error "python3 is required for IMAP operations"
		missing=1
	fi

	if ! command -v jq &>/dev/null; then
		print_error "jq is required. Install: brew install jq (macOS) or apt install jq (Linux)"
		missing=1
	fi

	if [[ ! -f "$IMAP_ADAPTER" ]]; then
		print_error "IMAP adapter not found: $IMAP_ADAPTER"
		missing=1
	fi

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi
	return 0
}

# ============================================================================
# Configuration
# ============================================================================

load_providers_config() {
	# Try working config first, fall back to template
	local config_file="$PROVIDERS_CONFIG"
	if [[ ! -f "$config_file" ]]; then
		config_file="$PROVIDERS_TEMPLATE"
	fi

	if [[ ! -f "$config_file" ]]; then
		print_error "Provider config not found"
		print_info "Expected: $PROVIDERS_CONFIG or $PROVIDERS_TEMPLATE"
		return 1
	fi

	echo "$config_file"
	return 0
}

# Get provider config for an account slug
get_provider_config() {
	local account="$1"
	local config_file
	config_file=$(load_providers_config) || return 1

	local provider_json
	provider_json=$(jq -r ".providers.\"$account\" // empty" "$config_file" 2>/dev/null)

	if [[ -z "$provider_json" ]]; then
		print_error "Account '$account' not found in provider config"
		print_info "Available providers:"
		jq -r '.providers | keys[]' "$config_file" 2>/dev/null | while IFS= read -r key; do
			local name
			name=$(jq -r ".providers.\"$key\".name" "$config_file" 2>/dev/null)
			echo "  - $key ($name)" >&2
		done
		return 1
	fi

	echo "$provider_json"
	return 0
}

# Get IMAP connection details from provider config
get_imap_details() {
	local provider_json="$1"

	local host port security
	host=$(echo "$provider_json" | jq -r '.imap.host // empty')
	port=$(echo "$provider_json" | jq -r '.imap.port // 993')
	security=$(echo "$provider_json" | jq -r '.imap.security // "TLS"')

	if [[ -z "$host" ]]; then
		print_error "No IMAP host configured for this provider"
		return 1
	fi

	echo "${host}|${port}|${security}"
	return 0
}

# Get SMTP connection details from provider config
get_smtp_details() {
	local provider_json="$1"

	local host port security
	host=$(echo "$provider_json" | jq -r '.smtp.host // empty')
	port=$(echo "$provider_json" | jq -r '.smtp.port // 587')
	security=$(echo "$provider_json" | jq -r '.smtp.security // "STARTTLS"')

	if [[ -z "$host" ]]; then
		print_error "No SMTP host configured for this provider"
		return 1
	fi

	echo "${host}|${port}|${security}"
	return 0
}

# Get IMAP password from gopass (never printed, passed as env var)
get_imap_password() {
	local account="$1"
	local secret_name="email-imap-${account}"

	if command -v gopass &>/dev/null; then
		local password
		password=$(gopass show -o "aidevops/${secret_name}" 2>/dev/null) || password=""
		if [[ -n "$password" ]]; then
			echo "$password"
			return 0
		fi
	fi

	# Try credentials.sh fallback
	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$cred_file" ]]; then
		local var_name
		var_name="IMAP_PASSWORD_$(echo "$account" | tr '[:lower:]-' '[:upper:]_')"
		local password
		# Source in subshell to avoid polluting environment
		password=$(
			# shellcheck source=/dev/null
			source "$cred_file" 2>/dev/null
			eval "echo \"\${${var_name}:-}\""
		)
		if [[ -n "$password" ]]; then
			echo "$password"
			return 0
		fi
	fi

	print_error "No IMAP password found for account '$account'"
	print_info "Store via: aidevops secret set ${secret_name}"
	print_info "Or set IMAP_PASSWORD_$(echo "$account" | tr '[:lower:]-' '[:upper:]_') in credentials.sh"
	return 1
}

# Get IMAP username (email address) for an account
get_imap_user() {
	local account="$1"

	# Try gopass for the username
	if command -v gopass &>/dev/null; then
		local user
		user=$(gopass show "aidevops/email-imap-${account}" user 2>/dev/null) || user=""
		if [[ -n "$user" ]]; then
			echo "$user"
			return 0
		fi
	fi

	# Try credentials.sh
	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$cred_file" ]]; then
		local var_name
		var_name="IMAP_USER_$(echo "$account" | tr '[:lower:]-' '[:upper:]_')"
		local user
		user=$(
			# shellcheck source=/dev/null
			source "$cred_file" 2>/dev/null
			eval "echo \"\${${var_name}:-}\""
		)
		if [[ -n "$user" ]]; then
			echo "$user"
			return 0
		fi
	fi

	# Try IMAP_USER env var
	local env_var="IMAP_USER_$(echo "$account" | tr '[:lower:]-' '[:upper:]_')"
	local user="${!env_var:-}"
	if [[ -n "$user" ]]; then
		echo "$user"
		return 0
	fi

	print_error "No IMAP username found for account '$account'"
	print_info "Store via: gopass edit aidevops/email-imap-${account} (add 'user: you@example.com')"
	return 1
}

# Run the IMAP adapter with connection details
run_imap_adapter() {
	local account="$1"
	local command="$2"
	shift 2
	local extra_args=("$@")

	local provider_json
	provider_json=$(get_provider_config "$account") || return 1

	local imap_details
	imap_details=$(get_imap_details "$provider_json") || return 1

	local host port security
	IFS='|' read -r host port security <<<"$imap_details"

	local user
	user=$(get_imap_user "$account") || return 1

	local password
	password=$(get_imap_password "$account") || return 1

	# Pass password via environment variable (never as argv)
	IMAP_PASSWORD="$password" python3 "$IMAP_ADAPTER" \
		--host "$host" \
		--port "$port" \
		--user "$user" \
		--security "$security" \
		"$command" \
		"${extra_args[@]}"

	return $?
}

# ============================================================================
# Commands
# ============================================================================

cmd_accounts() {
	local test_connectivity=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--test)
			test_connectivity=true
			shift
			;;
		*) shift ;;
		esac
	done

	local config_file
	config_file=$(load_providers_config) || return 1

	print_info "Configured email providers:"
	echo ""

	local providers
	providers=$(jq -r '.providers | keys[]' "$config_file" 2>/dev/null)

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		local name type imap_host
		name=$(jq -r ".providers.\"$slug\".name" "$config_file")
		type=$(jq -r ".providers.\"$slug\".type" "$config_file")
		imap_host=$(jq -r ".providers.\"$slug\".imap.host // \"none\"" "$config_file")

		local status_icon="  "
		if [[ "$test_connectivity" == "true" ]]; then
			# Check if credentials exist (without printing them)
			local has_creds="no"
			if get_imap_user "$slug" >/dev/null 2>&1 && get_imap_password "$slug" >/dev/null 2>&1; then
				has_creds="yes"
				# Test actual connectivity
				if run_imap_adapter "$slug" "connect" >/dev/null 2>&1; then
					status_icon="OK"
				else
					status_icon="FAIL"
				fi
			else
				status_icon="NO_CREDS"
			fi
		fi

		printf "  %-20s %-30s %-12s %-25s %s\n" "$slug" "$name" "$type" "$imap_host" "$status_icon"
	done <<<"$providers"

	return 0
}

cmd_inbox() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		print_info "Usage: $0 inbox <account> [--limit N] [--offset N] [--folder FOLDER]"
		return 1
	fi

	local limit=50 offset=0 folder="INBOX"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit)
			limit="$2"
			shift 2
			;;
		--offset)
			offset="$2"
			shift 2
			;;
		--folder)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	run_imap_adapter "$account" "fetch_headers" \
		--folder "$folder" --limit "$limit" --offset "$offset"

	return $?
}

cmd_read() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local uid="" folder="INBOX"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--uid)
			uid="$2"
			shift 2
			;;
		--folder)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$uid" ]]; then
		print_error "--uid is required"
		return 1
	fi

	run_imap_adapter "$account" "fetch_body" --uid "$uid" --folder "$folder"
	return $?
}

cmd_folders() {
	local account="${1:-}"

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local config_file
	config_file=$(load_providers_config) || return 1

	run_imap_adapter "$account" "list_folders" --provider-config "$config_file"
	return $?
}

cmd_create_folder() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local folder=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--folder)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$folder" ]]; then
		print_error "--folder is required"
		return 1
	fi

	run_imap_adapter "$account" "create_folder" --folder "$folder"
	return $?
}

cmd_send() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local to="" subject="" body_text="" body_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			to="$2"
			shift 2
			;;
		--subject)
			subject="$2"
			shift 2
			;;
		--body)
			body_text="$2"
			shift 2
			;;
		--body-file)
			body_file="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$to" || -z "$subject" ]]; then
		print_error "--to and --subject are required"
		return 1
	fi

	if [[ -n "$body_file" && -f "$body_file" ]]; then
		body_text=$(cat "$body_file")
	fi

	if [[ -z "$body_text" ]]; then
		print_error "Message body is required (--body or --body-file)"
		return 1
	fi

	local provider_json
	provider_json=$(get_provider_config "$account") || return 1

	local smtp_details
	smtp_details=$(get_smtp_details "$provider_json") || return 1

	local smtp_host smtp_port smtp_security
	IFS='|' read -r smtp_host smtp_port smtp_security <<<"$smtp_details"

	local user
	user=$(get_imap_user "$account") || return 1

	local password
	password=$(get_imap_password "$account") || return 1

	# Use Python for SMTP sending (pass password via env var)
	SMTP_PASSWORD="$password" python3 -c "
import os, sys, smtplib
from email.mime.text import MIMEText

msg = MIMEText('''${body_text//\'/\\\'}''')
msg['Subject'] = '''${subject//\'/\\\'}'''
msg['From'] = '$user'
msg['To'] = '$to'

password = os.environ['SMTP_PASSWORD']
try:
    if '$smtp_security' == 'TLS':
        server = smtplib.SMTP_SSL('$smtp_host', $smtp_port)
    else:
        server = smtplib.SMTP('$smtp_host', $smtp_port)
        server.starttls()
    server.login('$user', password)
    server.send_message(msg)
    server.quit()
    import json
    print(json.dumps({'status': 'sent', 'to': '$to', 'subject': '''${subject//\'/\\\'}'''}))
except Exception as e:
    print(f'ERROR: Send failed: {e}', file=sys.stderr)
    sys.exit(1)
"
	return $?
}

cmd_move() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local uid="" dest="" folder="INBOX"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--uid)
			uid="$2"
			shift 2
			;;
		--dest)
			dest="$2"
			shift 2
			;;
		--folder)
			folder="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$uid" || -z "$dest" ]]; then
		print_error "--uid and --dest are required"
		return 1
	fi

	run_imap_adapter "$account" "move_message" --uid "$uid" --dest "$dest" --folder "$folder"
	return $?
}

cmd_flag() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local uid="" flag="" folder="INBOX" clear=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--uid)
			uid="$2"
			shift 2
			;;
		--flag)
			flag="$2"
			shift 2
			;;
		--folder)
			folder="$2"
			shift 2
			;;
		--clear)
			clear=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$uid" || -z "$flag" ]]; then
		print_error "--uid and --flag are required"
		print_info "Available flags: Reminders, Tasks, Review, Filing, Ideas, Add-to-Contacts"
		return 1
	fi

	local command="set_flag"
	if [[ "$clear" == "true" ]]; then
		command="clear_flag"
	fi

	run_imap_adapter "$account" "$command" --uid "$uid" --flag "$flag" --folder "$folder"
	return $?
}

cmd_search() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local query="" folder="INBOX" limit=50
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--query)
			query="$2"
			shift 2
			;;
		--folder)
			folder="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$query" ]]; then
		print_error "--query is required"
		print_info "Examples:"
		print_info "  --query 'FROM sender@example.com'"
		print_info "  --query 'SUBJECT \"meeting notes\"'"
		print_info "  --query 'UNSEEN SINCE 01-Mar-2026'"
		print_info "  --query 'KEYWORD \$Task'"
		return 1
	fi

	run_imap_adapter "$account" "search" --query "$query" --folder "$folder" --limit "$limit"
	return $?
}

cmd_smart_mailbox() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local name="" criteria=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			name="$2"
			shift 2
			;;
		--criteria)
			criteria="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$name" || -z "$criteria" ]]; then
		print_error "--name and --criteria are required"
		print_info "Examples:"
		print_info "  --name 'Action Required' --criteria 'KEYWORD \$Task OR KEYWORD \$Reminder'"
		print_info "  --name 'VIP Inbox' --criteria 'FROM ceo@company.com'"
		return 1
	fi

	# Smart mailboxes are saved searches stored locally
	mkdir -p "$MAILBOX_WORKSPACE" 2>/dev/null || true
	chmod 700 "$MAILBOX_WORKSPACE" 2>/dev/null || true

	local smart_file="${MAILBOX_WORKSPACE}/smart-mailboxes.json"
	local existing="[]"
	if [[ -f "$smart_file" ]]; then
		existing=$(cat "$smart_file")
	fi

	# Add or update the smart mailbox definition
	local updated
	updated=$(echo "$existing" | jq --arg name "$name" --arg criteria "$criteria" --arg account "$account" '
		[.[] | select(.name != $name)] + [{
			"name": $name,
			"account": $account,
			"criteria": $criteria,
			"created": (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
		}]
	')

	echo "$updated" >"$smart_file"
	chmod 600 "$smart_file" 2>/dev/null || true

	# Execute the search to show current results
	print_info "Smart mailbox '$name' saved. Running search..."
	run_imap_adapter "$account" "search" --query "$criteria" --folder "INBOX" --limit 50
	return $?
}

cmd_sync() {
	local account="${1:-}"
	shift || true

	if [[ -z "$account" ]]; then
		print_error "Account name is required"
		return 1
	fi

	local folder="INBOX" full_sync=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--folder)
			folder="$2"
			shift 2
			;;
		--full)
			full_sync=true
			shift
			;;
		*) shift ;;
		esac
	done

	local extra_args=(--folder "$folder")
	if [[ "$full_sync" == "true" ]]; then
		extra_args+=(--full)
	fi

	run_imap_adapter "$account" "index_sync" "${extra_args[@]}"
	return $?
}

cmd_help() {
	cat <<'HELP'
Email Mailbox Helper - IMAP/JMAP adapter and mailbox operations

Usage: email-mailbox-helper.sh <command> [account] [options]

Commands:
  accounts [--test]              List configured accounts (--test checks connectivity)
  inbox <account> [opts]         Fetch message headers from inbox
  read <account> --uid UID       Read a specific message body
  folders <account>              List IMAP folders with provider mapping
  create-folder <account> --folder PATH  Create a new IMAP folder
  send <account> --to --subject --body   Send an email via SMTP
  move <account> --uid --dest    Move a message to another folder
  flag <account> --uid --flag    Set/clear a flag on a message
  search <account> --query       Search messages using IMAP SEARCH
  smart-mailbox <account> --name --criteria  Create a saved search
  sync <account> [--folder] [--full]  Sync folder headers to local index
  help                           Show this help

Options:
  --limit N       Max messages to return (default: 50)
  --offset N      Skip N most recent messages (default: 0)
  --folder NAME   IMAP folder name (default: INBOX)
  --uid UID       Message UID for read/move/flag operations
  --dest FOLDER   Destination folder for move
  --flag NAME     Flag name: Reminders, Tasks, Review, Filing, Ideas, Add-to-Contacts
  --clear         Clear a flag instead of setting it
  --query SEARCH  IMAP SEARCH criteria string
  --full          Full sync (not incremental)
  --test          Test connectivity when listing accounts

Flag Taxonomy:
  Reminders       Time-sensitive, needs attention by a date
  Tasks           Requires a concrete action (reply, approve, create)
  Review          Read carefully (contract, proposal, technical doc)
  Filing          Archive to a specific project/reference folder
  Ideas           Inspiration, interesting link, future reference
  Add-to-Contacts New contact, save their details

Credentials:
  Store IMAP password: aidevops secret set email-imap-<account>
  Store IMAP username: gopass edit aidevops/email-imap-<account> (add 'user: you@example.com')

Provider Config:
  Template: .agents/configs/email-providers.json.txt
  Working:  .agents/configs/email-providers.json (copy and customise)

Examples:
  email-mailbox-helper.sh accounts --test
  email-mailbox-helper.sh inbox cloudron --limit 20
  email-mailbox-helper.sh read cloudron --uid 12345
  email-mailbox-helper.sh search cloudron --query 'FROM client@example.com UNSEEN'
  email-mailbox-helper.sh flag cloudron --uid 12345 --flag Tasks
  email-mailbox-helper.sh move cloudron --uid 12345 --dest Archive
  email-mailbox-helper.sh sync cloudron --full
HELP
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local command="${1:-help}"
	shift || true

	check_dependencies || exit 1

	case "$command" in
	accounts)
		cmd_accounts "$@"
		;;
	inbox)
		cmd_inbox "$@"
		;;
	read)
		cmd_read "$@"
		;;
	folders)
		cmd_folders "$@"
		;;
	create-folder)
		cmd_create_folder "$@"
		;;
	send)
		cmd_send "$@"
		;;
	move)
		cmd_move "$@"
		;;
	flag)
		cmd_flag "$@"
		;;
	search)
		cmd_search "$@"
		;;
	smart-mailbox)
		cmd_smart_mailbox "$@"
		;;
	sync)
		cmd_sync "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
