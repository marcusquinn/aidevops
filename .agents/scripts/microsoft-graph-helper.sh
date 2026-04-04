#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# microsoft-graph-helper.sh - Microsoft Graph API adapter for Outlook/365 shared mailboxes
#
# Provides OAuth2 authentication and shared mailbox delegation for Microsoft 365.
# Supports delegated (user) and application (service account) permission flows.
#
# Usage:
#   microsoft-graph-helper.sh auth                                          # Interactive OAuth2 device flow
#   microsoft-graph-helper.sh auth --client-credentials                     # App-only (service account) flow
#   microsoft-graph-helper.sh token-status                                  # Show token expiry and scopes
#   microsoft-graph-helper.sh token-refresh                                 # Force token refresh
#   microsoft-graph-helper.sh list-mailboxes                                # List accessible shared mailboxes
#   microsoft-graph-helper.sh list-messages --mailbox <addr> [--folder <f>] [--limit N] [--since <ISO>]
#   microsoft-graph-helper.sh get-message --mailbox <addr> --id <msg-id>    # Fetch single message
#   microsoft-graph-helper.sh send --mailbox <addr> --to <addr> --subject <s> --body <text> [--html]
#   microsoft-graph-helper.sh reply --mailbox <addr> --id <msg-id> --body <text> [--html]
#   microsoft-graph-helper.sh move --mailbox <addr> --id <msg-id> --folder <dest>
#   microsoft-graph-helper.sh flag --mailbox <addr> --id <msg-id> --flag <read|unread|flagged|unflagged>
#   microsoft-graph-helper.sh delete --mailbox <addr> --id <msg-id>
#   microsoft-graph-helper.sh list-folders --mailbox <addr>                 # List mail folders
#   microsoft-graph-helper.sh create-folder --mailbox <addr> --name <n>    # Create mail folder
#   microsoft-graph-helper.sh permissions --mailbox <addr>                  # Show delegation permissions
#   microsoft-graph-helper.sh grant-access --mailbox <addr> --user <upn> --role <FullAccess|SendAs|SendOnBehalf>
#   microsoft-graph-helper.sh revoke-access --mailbox <addr> --user <upn>
#   microsoft-graph-helper.sh status                                        # Show adapter status
#   microsoft-graph-helper.sh help
#
# OAuth2 Flows:
#   Device flow (delegated)  - Interactive login, user context, requires user consent
#   Client credentials       - App-only, no user context, requires admin consent
#
# Requires: curl, jq
# Config: configs/microsoft-graph-config.json (from .json.txt template)
# Credentials: aidevops secret set MSGRAPH_CLIENT_ID / MSGRAPH_CLIENT_SECRET / MSGRAPH_TENANT_ID
#
# Part of aidevops email system (t1526)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================================
# Constants
# ============================================================================

readonly GRAPH_API_BASE="https://graph.microsoft.com/v1.0"
readonly GRAPH_AUTH_BASE="https://login.microsoftonline.com"
readonly GRAPH_SCOPE_MAIL="https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/MailboxSettings.ReadWrite"
readonly GRAPH_SCOPE_SHARED="https://graph.microsoft.com/Mail.ReadWrite.Shared https://graph.microsoft.com/Mail.Send.Shared"
readonly GRAPH_SCOPE_FULL_ACCESS="https://graph.microsoft.com/MailboxSettings.ReadWrite offline_access"

readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly CONFIG_FILE="${CONFIG_DIR}/microsoft-graph-config.json"
readonly TOKEN_CACHE_DIR="${HOME}/.aidevops/.agent-workspace/microsoft-graph"
readonly TOKEN_CACHE_FILE="${TOKEN_CACHE_DIR}/token-cache.json"
readonly TOKEN_CACHE_PERMS="600"

LOG_PREFIX="MSGRAPH"

# ============================================================================
# Dependency checks
# ============================================================================

check_dependencies() {
	local missing=0

	if ! command -v curl &>/dev/null; then
		print_error "curl is required. Install: brew install curl"
		missing=1
	fi

	if ! command -v jq &>/dev/null; then
		print_error "jq is required. Install: brew install jq"
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

load_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		print_error "${ERROR_CONFIG_NOT_FOUND}: $CONFIG_FILE"
		print_info "Copy template: cp ${CONFIG_DIR}/microsoft-graph-config.json.txt ${CONFIG_FILE}"
		return 1
	fi
	return 0
}

get_config_value() {
	local key="$1"
	local default="${2:-}"

	local value
	value=$(jq -r "$key // empty" "$CONFIG_FILE" 2>/dev/null)
	if [[ -z "$value" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

# ============================================================================
# Credential loading (never prints values)
# ============================================================================

load_credentials() {
	# Try gopass first
	if command -v gopass &>/dev/null; then
		local client_id tenant_id client_secret
		client_id=$(gopass show -o "aidevops/MSGRAPH_CLIENT_ID" 2>/dev/null || echo "")
		tenant_id=$(gopass show -o "aidevops/MSGRAPH_TENANT_ID" 2>/dev/null || echo "")
		client_secret=$(gopass show -o "aidevops/MSGRAPH_CLIENT_SECRET" 2>/dev/null || echo "")
		if [[ -n "$client_id" && -n "$tenant_id" ]]; then
			export MSGRAPH_CLIENT_ID="$client_id"
			export MSGRAPH_TENANT_ID="$tenant_id"
			[[ -n "$client_secret" ]] && export MSGRAPH_CLIENT_SECRET="$client_secret"
			return 0
		fi
	fi

	# Fall back to env vars or credentials.sh
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		# shellcheck disable=SC1090
		source "$creds_file"
	fi

	if [[ -z "${MSGRAPH_CLIENT_ID:-}" || -z "${MSGRAPH_TENANT_ID:-}" ]]; then
		print_error "Microsoft Graph credentials not found."
		print_info "Set via: aidevops secret set MSGRAPH_CLIENT_ID && aidevops secret set MSGRAPH_TENANT_ID"
		print_info "For app-only flow also set: aidevops secret set MSGRAPH_CLIENT_SECRET"
		return 1
	fi
	return 0
}

# ============================================================================
# Token cache (stored at 0600 — never printed)
# ============================================================================

ensure_token_cache_dir() {
	mkdir -p "$TOKEN_CACHE_DIR"
	chmod 700 "$TOKEN_CACHE_DIR"
	return 0
}

save_token() {
	local access_token="$1"
	local refresh_token="${2:-}"
	local expires_in="${3:-3600}"
	local token_type="${4:-Bearer}"
	local scope="${5:-}"

	ensure_token_cache_dir

	local expires_at
	expires_at=$(date -u -v+"${expires_in}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "+${expires_in} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		echo "")

	# Write token cache — never log the actual token values
	jq -n \
		--arg at "$access_token" \
		--arg rt "$refresh_token" \
		--arg ea "$expires_at" \
		--arg tt "$token_type" \
		--arg sc "$scope" \
		'{access_token: $at, refresh_token: $rt, expires_at: $ea, token_type: $tt, scope: $sc}' \
		>"$TOKEN_CACHE_FILE"
	chmod "$TOKEN_CACHE_PERMS" "$TOKEN_CACHE_FILE"

	log_info "Token cached (expires: $expires_at)"
	return 0
}

load_token() {
	if [[ ! -f "$TOKEN_CACHE_FILE" ]]; then
		return 1
	fi

	local expires_at
	expires_at=$(jq -r '.expires_at // empty' "$TOKEN_CACHE_FILE" 2>/dev/null)

	if [[ -z "$expires_at" ]]; then
		return 1
	fi

	# Check expiry with 5-minute buffer
	local now_epoch expires_epoch
	now_epoch=$(date -u +%s)
	expires_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null ||
		date -u -d "$expires_at" +%s 2>/dev/null ||
		echo "0")

	local buffer=300
	if [[ "$((expires_epoch - now_epoch))" -lt "$buffer" ]]; then
		log_info "Token expired or expiring soon — refresh required"
		return 1
	fi

	return 0
}

get_access_token() {
	if ! load_token; then
		# Try refresh first
		if ! refresh_token_silent; then
			print_error "No valid token. Run: microsoft-graph-helper.sh auth"
			return 1
		fi
	fi

	jq -r '.access_token' "$TOKEN_CACHE_FILE"
	return 0
}

refresh_token_silent() {
	if [[ ! -f "$TOKEN_CACHE_FILE" ]]; then
		return 1
	fi

	local refresh_tok
	refresh_tok=$(jq -r '.refresh_token // empty' "$TOKEN_CACHE_FILE" 2>/dev/null)

	if [[ -z "$refresh_tok" ]]; then
		return 1
	fi

	load_credentials || return 1

	local tenant_id="$MSGRAPH_TENANT_ID"
	local client_id="$MSGRAPH_CLIENT_ID"
	local token_url="${GRAPH_AUTH_BASE}/${tenant_id}/oauth2/v2.0/token"

	# Write POST body to a temp file to avoid refresh token appearing in process list (rule 8.2)
	local body_file
	body_file=$(mktemp)
	chmod 600 "$body_file"
	printf 'client_id=%s&grant_type=refresh_token&refresh_token=%s&scope=%s%%20%s%%20%s' \
		"$client_id" "$refresh_tok" \
		"$GRAPH_SCOPE_MAIL" "$GRAPH_SCOPE_SHARED" "$GRAPH_SCOPE_FULL_ACCESS" >"$body_file"

	local response
	response=$(curl -s -X POST "$token_url" \
		-H "$CONTENT_TYPE_FORM" \
		--data-binary "@${body_file}" \
		2>/dev/null)
	rm -f "$body_file"

	local new_access_token new_refresh_token expires_in scope
	new_access_token=$(echo "$response" | jq -r '.access_token // empty')
	new_refresh_token=$(echo "$response" | jq -r '.refresh_token // empty')
	expires_in=$(echo "$response" | jq -r '.expires_in // 3600')
	scope=$(echo "$response" | jq -r '.scope // empty')

	if [[ -z "$new_access_token" ]]; then
		local error_desc
		error_desc=$(echo "$response" | jq -r '.error_description // .error // "Unknown error"')
		log_error "Token refresh failed: $error_desc"
		return 1
	fi

	save_token "$new_access_token" "$new_refresh_token" "$expires_in" "Bearer" "$scope"
	log_info "Token refreshed successfully"
	return 0
}

# ============================================================================
# OAuth2 Device Flow (interactive delegated auth)
# ============================================================================

cmd_auth() {
	local client_credentials=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--client-credentials)
			client_credentials=1
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	load_credentials || return 1
	load_config || return 1

	if [[ "$client_credentials" -eq 1 ]]; then
		auth_client_credentials
	else
		auth_device_flow
	fi
	return 0
}

auth_device_flow() {
	local tenant_id="$MSGRAPH_TENANT_ID"
	local client_id="$MSGRAPH_CLIENT_ID"
	local device_auth_url="${GRAPH_AUTH_BASE}/${tenant_id}/oauth2/v2.0/devicecode"
	local token_url="${GRAPH_AUTH_BASE}/${tenant_id}/oauth2/v2.0/token"

	local scopes="${GRAPH_SCOPE_MAIL} ${GRAPH_SCOPE_SHARED} ${GRAPH_SCOPE_FULL_ACCESS}"

	print_info "Starting OAuth2 device flow for Microsoft Graph..."

	# Request device code
	local device_response
	device_response=$(curl -s -X POST "$device_auth_url" \
		-H "$CONTENT_TYPE_FORM" \
		-d "client_id=${client_id}&scope=${scopes// /%20}" \
		2>/dev/null)

	local device_code user_code verification_uri expires_in interval message
	device_code=$(echo "$device_response" | jq -r '.device_code // empty')
	user_code=$(echo "$device_response" | jq -r '.user_code // empty')
	verification_uri=$(echo "$device_response" | jq -r '.verification_uri // empty')
	expires_in=$(echo "$device_response" | jq -r '.expires_in // 900')
	interval=$(echo "$device_response" | jq -r '.interval // 5')
	message=$(echo "$device_response" | jq -r '.message // empty')

	if [[ -z "$device_code" || -z "$user_code" ]]; then
		local error_desc
		error_desc=$(echo "$device_response" | jq -r '.error_description // .error // "Unknown error"')
		print_error "Device code request failed: $error_desc"
		return 1
	fi

	# Display instructions to user (user_code is not a secret — it's meant to be shown)
	echo ""
	echo "=== Microsoft Graph Authentication ==="
	echo ""
	if [[ -n "$message" ]]; then
		echo "$message"
	else
		echo "1. Open: $verification_uri"
		echo "2. Enter code: $user_code"
		echo "3. Sign in with your Microsoft 365 account"
	fi
	echo ""
	echo "Waiting for authentication (expires in ${expires_in}s)..."
	echo ""

	# Poll for token
	local elapsed=0
	while [[ "$elapsed" -lt "$expires_in" ]]; do
		sleep "$interval"
		elapsed=$((elapsed + interval))

		local poll_response
		poll_response=$(curl -s -X POST "$token_url" \
			-H "$CONTENT_TYPE_FORM" \
			-d "client_id=${client_id}&grant_type=urn:ietf:params:oauth2:grant-type:device_code&device_code=${device_code}" \
			2>/dev/null)

		local error
		error=$(echo "$poll_response" | jq -r '.error // empty')

		case "$error" in
		"authorization_pending")
			# Still waiting — continue polling
			continue
			;;
		"slow_down")
			interval=$((interval + 5))
			continue
			;;
		"authorization_declined" | "expired_token" | "bad_verification_code")
			print_error "Authentication failed: $error"
			return 1
			;;
		"")
			# No error — check for access token
			local access_token refresh_token token_expires scope
			access_token=$(echo "$poll_response" | jq -r '.access_token // empty')
			refresh_token=$(echo "$poll_response" | jq -r '.refresh_token // empty')
			token_expires=$(echo "$poll_response" | jq -r '.expires_in // 3600')
			scope=$(echo "$poll_response" | jq -r '.scope // empty')

			if [[ -n "$access_token" ]]; then
				save_token "$access_token" "$refresh_token" "$token_expires" "Bearer" "$scope"
				print_success "Authentication successful. Token cached."
				return 0
			fi
			;;
		esac
	done

	print_error "Authentication timed out. Run auth again."
	return 1
}

auth_client_credentials() {
	local tenant_id="$MSGRAPH_TENANT_ID"
	local client_id="$MSGRAPH_CLIENT_ID"
	local token_url="${GRAPH_AUTH_BASE}/${tenant_id}/oauth2/v2.0/token"

	if [[ -z "${MSGRAPH_CLIENT_SECRET:-}" ]]; then
		print_error "MSGRAPH_CLIENT_SECRET required for client credentials flow."
		print_info "Set via: aidevops secret set MSGRAPH_CLIENT_SECRET"
		return 1
	fi

	print_info "Authenticating with client credentials (app-only)..."

	# Write POST body to a temp file to avoid secret appearing in process list (rule 8.2)
	local body_file
	body_file=$(mktemp)
	chmod 600 "$body_file"
	printf 'client_id=%s&client_secret=%s&grant_type=client_credentials&scope=https://graph.microsoft.com/.default' \
		"$client_id" "$MSGRAPH_CLIENT_SECRET" >"$body_file"

	local response
	response=$(curl -s -X POST "$token_url" \
		-H "$CONTENT_TYPE_FORM" \
		--data-binary "@${body_file}" \
		2>/dev/null)
	rm -f "$body_file"

	local access_token expires_in
	access_token=$(echo "$response" | jq -r '.access_token // empty')
	expires_in=$(echo "$response" | jq -r '.expires_in // 3600')

	if [[ -z "$access_token" ]]; then
		local error_desc
		error_desc=$(echo "$response" | jq -r '.error_description // .error // "Unknown error"')
		print_error "Client credentials auth failed: $error_desc"
		return 1
	fi

	# No refresh token in client credentials flow — app re-authenticates on expiry
	save_token "$access_token" "" "$expires_in" "Bearer" "https://graph.microsoft.com/.default"
	print_success "App-only authentication successful. Token cached."
	return 0
}

# ============================================================================
# Token status
# ============================================================================

cmd_token_status() {
	if [[ ! -f "$TOKEN_CACHE_FILE" ]]; then
		print_info "No token cached. Run: microsoft-graph-helper.sh auth"
		return 0
	fi

	local expires_at scope has_refresh
	expires_at=$(jq -r '.expires_at // "unknown"' "$TOKEN_CACHE_FILE")
	scope=$(jq -r '.scope // "unknown"' "$TOKEN_CACHE_FILE")
	has_refresh=$(jq -r 'if .refresh_token != "" then "yes" else "no" end' "$TOKEN_CACHE_FILE")

	echo "Token status:"
	echo "  Expires:       $expires_at"
	echo "  Has refresh:   $has_refresh"
	echo "  Scope:         $scope"

	if load_token; then
		echo "  Status:        valid"
	else
		echo "  Status:        expired (run token-refresh or auth)"
	fi
	return 0
}

cmd_token_refresh() {
	if refresh_token_silent; then
		print_success "Token refreshed."
	else
		print_error "Refresh failed. Run: microsoft-graph-helper.sh auth"
		return 1
	fi
	return 0
}

# ============================================================================
# Graph API request helper
# ============================================================================

graph_request() {
	local method="$1"
	local endpoint="$2"
	local body="${3:-}"

	local token
	token=$(get_access_token) || return 1

	local url="${GRAPH_API_BASE}${endpoint}"
	local curl_args=(-s -X "$method" "$url" -H "$AUTH_HEADER_PREFIX $token" -H "$CONTENT_TYPE_JSON")

	if [[ -n "$body" ]]; then
		curl_args+=(-d "$body")
	fi

	local response http_code
	response=$(curl "${curl_args[@]}" -w "\n%{http_code}" 2>/dev/null)
	http_code=$(echo "$response" | tail -1)
	response=$(echo "$response" | sed '$d')

	if [[ "$http_code" -ge 400 ]]; then
		local error_msg
		error_msg=$(echo "$response" | jq -r '.error.message // .error // "HTTP error"' 2>/dev/null || echo "HTTP $http_code")
		print_error "Graph API error ($http_code): $error_msg"
		return 1
	fi

	echo "$response"
	return 0
}

# ============================================================================
# Mailbox operations
# ============================================================================

# Resolve mailbox path: /me for current user, /users/{addr} for shared mailboxes
mailbox_path() {
	local mailbox="$1"
	if [[ "$mailbox" == "me" || -z "$mailbox" ]]; then
		echo "/me"
	else
		echo "/users/${mailbox}"
	fi
	return 0
}

cmd_list_mailboxes() {
	print_info "Listing accessible mailboxes..."

	# List shared mailboxes the authenticated user has access to
	local response
	response=$(graph_request GET "/users?\$select=displayName,mail,userPrincipalName,mailboxSettings&\$filter=assignedLicenses/any()&\$top=50") || return 1

	echo "$response" | jq -r '.value[] | "\(.displayName) <\(.mail // .userPrincipalName)>"' 2>/dev/null ||
		echo "$response" | jq '.'
	return 0
}

cmd_list_messages() {
	local mailbox=""
	local folder="Inbox"
	local limit=25
	local since=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
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
		--since)
			since="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" ]]; then
		print_error "--mailbox is required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local endpoint="${mb_path}/mailFolders/${folder}/messages?\$top=${limit}&\$select=id,subject,from,toRecipients,receivedDateTime,isRead,hasAttachments,bodyPreview&\$orderby=receivedDateTime%20desc"

	if [[ -n "$since" ]]; then
		endpoint="${endpoint}&\$filter=receivedDateTime%20ge%20${since}"
	fi

	local response
	response=$(graph_request GET "$endpoint") || return 1

	echo "$response" | jq -r '.value[] | "[\(.isRead | if . then "read" else "UNREAD" end)] \(.receivedDateTime[:19]) \(.from.emailAddress.address) -- \(.subject)"' 2>/dev/null ||
		echo "$response" | jq '.'
	return 0
}

cmd_get_message() {
	local mailbox=""
	local msg_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--id)
			msg_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$msg_id" ]]; then
		print_error "--mailbox and --id are required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local response
	response=$(graph_request GET "${mb_path}/messages/${msg_id}?\$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,hasAttachments,body,internetMessageId") || return 1

	echo "$response" | jq '{
		id: .id,
		subject: .subject,
		from: .from.emailAddress.address,
		to: [.toRecipients[].emailAddress.address],
		received: .receivedDateTime,
		isRead: .isRead,
		hasAttachments: .hasAttachments,
		body: .body.content
	}' 2>/dev/null || echo "$response"
	return 0
}

cmd_send() {
	local mailbox=""
	local to=""
	local subject=""
	local body=""
	local html=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--to)
			to="$2"
			shift 2
			;;
		--subject)
			subject="$2"
			shift 2
			;;
		--body)
			body="$2"
			shift 2
			;;
		--html)
			html=1
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$to" || -z "$subject" || -z "$body" ]]; then
		print_error "--mailbox, --to, --subject, and --body are required"
		return 1
	fi

	local content_type="text"
	[[ "$html" -eq 1 ]] && content_type="html"

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local payload
	payload=$(jq -n \
		--arg to "$to" \
		--arg subject "$subject" \
		--arg body "$body" \
		--arg ct "$content_type" \
		'{
			message: {
				subject: $subject,
				body: { contentType: $ct, content: $body },
				toRecipients: [{ emailAddress: { address: $to } }]
			},
			saveToSentItems: true
		}')

	graph_request POST "${mb_path}/sendMail" "$payload" >/dev/null || return 1
	print_success "Message sent from $mailbox to $to"
	return 0
}

cmd_reply() {
	local mailbox=""
	local msg_id=""
	local body=""
	local html=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--id)
			msg_id="$2"
			shift 2
			;;
		--body)
			body="$2"
			shift 2
			;;
		--html)
			html=1
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$msg_id" || -z "$body" ]]; then
		print_error "--mailbox, --id, and --body are required"
		return 1
	fi

	local content_type="text"
	[[ "$html" -eq 1 ]] && content_type="html"

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local payload
	payload=$(jq -n \
		--arg body "$body" \
		--arg ct "$content_type" \
		'{comment: $body}')

	graph_request POST "${mb_path}/messages/${msg_id}/reply" "$payload" >/dev/null || return 1
	print_success "Reply sent"
	return 0
}

cmd_move() {
	local mailbox=""
	local msg_id=""
	local dest_folder=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--id)
			msg_id="$2"
			shift 2
			;;
		--folder)
			dest_folder="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$msg_id" || -z "$dest_folder" ]]; then
		print_error "--mailbox, --id, and --folder are required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local payload
	payload=$(jq -n --arg dest "$dest_folder" '{destinationId: $dest}')

	local response
	response=$(graph_request POST "${mb_path}/messages/${msg_id}/move" "$payload") || return 1
	local new_id
	new_id=$(echo "$response" | jq -r '.id // "unknown"')
	print_success "Message moved to $dest_folder (new id: $new_id)"
	return 0
}

cmd_flag() {
	local mailbox=""
	local msg_id=""
	local flag=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--id)
			msg_id="$2"
			shift 2
			;;
		--flag)
			flag="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$msg_id" || -z "$flag" ]]; then
		print_error "--mailbox, --id, and --flag are required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local payload
	case "$flag" in
	read) payload='{"isRead": true}' ;;
	unread) payload='{"isRead": false}' ;;
	flagged) payload='{"flag": {"flagStatus": "flagged"}}' ;;
	unflagged) payload='{"flag": {"flagStatus": "notFlagged"}}' ;;
	*)
		print_error "Unknown flag: $flag. Use: read|unread|flagged|unflagged"
		return 1
		;;
	esac

	graph_request PATCH "${mb_path}/messages/${msg_id}" "$payload" >/dev/null || return 1
	print_success "Message flagged as: $flag"
	return 0
}

cmd_delete() {
	local mailbox=""
	local msg_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--id)
			msg_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$msg_id" ]]; then
		print_error "--mailbox and --id are required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	graph_request DELETE "${mb_path}/messages/${msg_id}" >/dev/null || return 1
	print_success "Message deleted"
	return 0
}

# ============================================================================
# Folder operations
# ============================================================================

cmd_list_folders() {
	local mailbox=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" ]]; then
		print_error "--mailbox is required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local response
	response=$(graph_request GET "${mb_path}/mailFolders?\$top=50&\$select=id,displayName,totalItemCount,unreadItemCount") || return 1

	echo "$response" | jq -r '.value[] | "\(.displayName) (total: \(.totalItemCount), unread: \(.unreadItemCount)) id=\(.id)"' 2>/dev/null ||
		echo "$response" | jq '.'
	return 0
}

cmd_create_folder() {
	local mailbox=""
	local folder_name=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--name)
			folder_name="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$folder_name" ]]; then
		print_error "--mailbox and --name are required"
		return 1
	fi

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local payload
	payload=$(jq -n --arg name "$folder_name" '{displayName: $name}')

	local response
	response=$(graph_request POST "${mb_path}/mailFolders" "$payload") || return 1
	local folder_id
	folder_id=$(echo "$response" | jq -r '.id // "unknown"')
	print_success "Folder '$folder_name' created (id: $folder_id)"
	return 0
}

# ============================================================================
# Delegation / permissions
# ============================================================================

cmd_permissions() {
	local mailbox=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" ]]; then
		print_error "--mailbox is required"
		return 1
	fi

	print_info "Fetching mailbox permissions for $mailbox..."
	print_info "Note: Full mailbox permission management requires Exchange Online PowerShell or EAC."
	print_info "Graph API provides read access to mailbox settings."

	local mb_path
	mb_path=$(mailbox_path "$mailbox")

	local response
	response=$(graph_request GET "${mb_path}/mailboxSettings") || return 1

	echo "$response" | jq '{
		automaticRepliesSetting: .automaticRepliesSetting.status,
		timeZone: .timeZone,
		language: .language.displayName,
		delegateMeetingMessageDeliveryOptions: .delegateMeetingMessageDeliveryOptions
	}' 2>/dev/null || echo "$response" | jq '.'
	return 0
}

cmd_grant_access() {
	local mailbox=""
	local user_upn=""
	local role=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--user)
			user_upn="$2"
			shift 2
			;;
		--role)
			role="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$user_upn" || -z "$role" ]]; then
		print_error "--mailbox, --user, and --role are required"
		return 1
	fi

	case "$role" in
	FullAccess | SendAs | SendOnBehalf) ;;
	*)
		print_error "Invalid role: $role. Use: FullAccess|SendAs|SendOnBehalf"
		return 1
		;;
	esac

	print_info "Granting $role access on $mailbox to $user_upn..."
	print_info "Note: Mailbox delegation requires Exchange Online admin permissions."
	print_info "Use Exchange Admin Center or PowerShell for full delegation management:"
	echo ""
	echo "  # PowerShell (Exchange Online):"
	echo "  Add-MailboxPermission -Identity '$mailbox' -User '$user_upn' -AccessRights $role"
	echo ""
	echo "  # Or via Microsoft 365 Admin Center:"
	echo "  https://admin.microsoft.com > Users > Active users > $mailbox > Mail > Manage mailbox delegation"
	return 0
}

cmd_revoke_access() {
	local mailbox=""
	local user_upn=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			mailbox="$2"
			shift 2
			;;
		--user)
			user_upn="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mailbox" || -z "$user_upn" ]]; then
		print_error "--mailbox and --user are required"
		return 1
	fi

	print_info "Revoking access on $mailbox from $user_upn..."
	print_info "Note: Mailbox delegation requires Exchange Online admin permissions."
	print_info "Use Exchange Admin Center or PowerShell:"
	echo ""
	echo "  # PowerShell (Exchange Online):"
	echo "  Remove-MailboxPermission -Identity '$mailbox' -User '$user_upn' -AccessRights FullAccess"
	echo ""
	echo "  # Or via Microsoft 365 Admin Center:"
	echo "  https://admin.microsoft.com > Users > Active users > $mailbox > Mail > Manage mailbox delegation"
	return 0
}

# ============================================================================
# Status
# ============================================================================

cmd_status() {
	echo "Microsoft Graph Adapter Status"
	echo "=============================="
	echo ""

	# Config
	if [[ -f "$CONFIG_FILE" ]]; then
		local tenant_id_cfg
		tenant_id_cfg=$(get_config_value '.tenant_id' 'not set')
		echo "Config:        $CONFIG_FILE"
		echo "Tenant ID:     $tenant_id_cfg"
	else
		echo "Config:        NOT FOUND ($CONFIG_FILE)"
	fi

	# Credentials (names only, never values)
	echo ""
	echo "Credentials (names only):"
	if command -v gopass &>/dev/null; then
		local client_id_set tenant_id_set client_secret_set
		client_id_set=$(gopass show -o "aidevops/MSGRAPH_CLIENT_ID" 2>/dev/null && echo "set" || echo "not set")
		tenant_id_set=$(gopass show -o "aidevops/MSGRAPH_TENANT_ID" 2>/dev/null && echo "set" || echo "not set")
		client_secret_set=$(gopass show -o "aidevops/MSGRAPH_CLIENT_SECRET" 2>/dev/null && echo "set" || echo "not set")
		echo "  MSGRAPH_CLIENT_ID:     $client_id_set (gopass)"
		echo "  MSGRAPH_TENANT_ID:     $tenant_id_set (gopass)"
		echo "  MSGRAPH_CLIENT_SECRET: $client_secret_set (gopass)"
	else
		echo "  MSGRAPH_CLIENT_ID:     ${MSGRAPH_CLIENT_ID:+set}${MSGRAPH_CLIENT_ID:-not set}"
		echo "  MSGRAPH_TENANT_ID:     ${MSGRAPH_TENANT_ID:+set}${MSGRAPH_TENANT_ID:-not set}"
		echo "  MSGRAPH_CLIENT_SECRET: ${MSGRAPH_CLIENT_SECRET:+set}${MSGRAPH_CLIENT_SECRET:-not set}"
	fi

	# Token
	echo ""
	cmd_token_status

	return 0
}

# ============================================================================
# Help
# ============================================================================

cmd_help() {
	cat <<'EOF'
microsoft-graph-helper.sh - Microsoft Graph API adapter for Outlook/365 shared mailboxes

USAGE:
  microsoft-graph-helper.sh <command> [options]

AUTHENTICATION:
  auth                                    Interactive OAuth2 device flow (delegated)
  auth --client-credentials               App-only OAuth2 (requires MSGRAPH_CLIENT_SECRET)
  token-status                            Show token expiry and scopes
  token-refresh                           Force token refresh

MAILBOX OPERATIONS:
  list-mailboxes                          List accessible mailboxes
  list-messages --mailbox <addr>          List messages in a mailbox
    [--folder <name>]                     Folder name (default: Inbox)
    [--limit N]                           Max messages (default: 25)
    [--since <ISO-date>]                  Filter by received date
  get-message --mailbox <addr> --id <id>  Fetch a single message
  send --mailbox <addr> --to <addr>       Send a message
    --subject <text> --body <text>
    [--html]                              Send as HTML
  reply --mailbox <addr> --id <id>        Reply to a message
    --body <text> [--html]
  move --mailbox <addr> --id <id>         Move message to folder
    --folder <dest>
  flag --mailbox <addr> --id <id>         Set message flag
    --flag <read|unread|flagged|unflagged>
  delete --mailbox <addr> --id <id>       Delete a message

FOLDER OPERATIONS:
  list-folders --mailbox <addr>           List mail folders
  create-folder --mailbox <addr>          Create a mail folder
    --name <name>

DELEGATION:
  permissions --mailbox <addr>            Show mailbox settings
  grant-access --mailbox <addr>           Show PowerShell commands to grant access
    --user <upn> --role <role>            Roles: FullAccess|SendAs|SendOnBehalf
  revoke-access --mailbox <addr>          Show PowerShell commands to revoke access
    --user <upn>

OTHER:
  status                                  Show adapter status
  help                                    Show this help

SETUP:
  1. Register an Azure AD app: https://portal.azure.com > App registrations
  2. Add API permissions: Mail.ReadWrite, Mail.Send, Mail.ReadWrite.Shared
  3. Copy config template: cp configs/microsoft-graph-config.json.txt configs/microsoft-graph-config.json
  4. Set credentials:
       aidevops secret set MSGRAPH_CLIENT_ID
       aidevops secret set MSGRAPH_TENANT_ID
       aidevops secret set MSGRAPH_CLIENT_SECRET  # app-only flow only
  5. Authenticate: microsoft-graph-helper.sh auth

EXAMPLES:
  # Authenticate interactively
  microsoft-graph-helper.sh auth

  # List messages in shared mailbox
  microsoft-graph-helper.sh list-messages --mailbox support@company.com --limit 10

  # Send from shared mailbox
  microsoft-graph-helper.sh send --mailbox support@company.com \
    --to customer@example.com --subject "Re: Your inquiry" --body "Hello..."

  # Move message to archive
  microsoft-graph-helper.sh move --mailbox support@company.com \
    --id <msg-id> --folder Archive

  # App-only authentication (no user interaction)
  microsoft-graph-helper.sh auth --client-credentials
EOF
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
	auth) cmd_auth "$@" ;;
	token-status) cmd_token_status ;;
	token-refresh) cmd_token_refresh ;;
	list-mailboxes) load_credentials && load_config && cmd_list_mailboxes ;;
	list-messages) load_credentials && load_config && cmd_list_messages "$@" ;;
	get-message) load_credentials && load_config && cmd_get_message "$@" ;;
	send) load_credentials && load_config && cmd_send "$@" ;;
	reply) load_credentials && load_config && cmd_reply "$@" ;;
	move) load_credentials && load_config && cmd_move "$@" ;;
	flag) load_credentials && load_config && cmd_flag "$@" ;;
	delete) load_credentials && load_config && cmd_delete "$@" ;;
	list-folders) load_credentials && load_config && cmd_list_folders "$@" ;;
	create-folder) load_credentials && load_config && cmd_create_folder "$@" ;;
	permissions) load_credentials && load_config && cmd_permissions "$@" ;;
	grant-access) cmd_grant_access "$@" ;;
	revoke-access) cmd_revoke_access "$@" ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: $command"
		cmd_help
		exit 1
		;;
	esac
}

# Only run main when executed directly, not when sourced (allows unit testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
