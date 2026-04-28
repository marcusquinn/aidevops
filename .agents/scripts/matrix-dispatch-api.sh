#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Matrix Dispatch API Library — Matrix Client and Synapse Admin API Functions
# =============================================================================
# Low-level Matrix API functions for user registration, login, room creation,
# and user invitations. Extracted from matrix-dispatch-helper.sh to keep the
# orchestrator under the 2000-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/matrix-dispatch-api.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_*, etc.)
#   - curl, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MATRIX_DISPATCH_API_LIB_LOADED:-}" ]] && return 0
_MATRIX_DISPATCH_API_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Generate a random password (alphanumeric, 32 chars)
#######################################
generate_password() {
	local length="${1:-32}"
	LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
	return 0
}

#######################################
# Extract the Matrix server name from a homeserver URL
# e.g., https://matrix.example.com -> example.com
#######################################
extract_server_name() {
	local homeserver_url="$1"
	local domain
	domain=$(echo "$homeserver_url" | sed -E 's|https?://||' | sed 's|/.*||')

	# If domain starts with "matrix.", strip it for the server name
	if [[ "$domain" == matrix.* ]]; then
		echo "${domain#matrix.}"
	else
		echo "$domain"
	fi
	return 0
}

#######################################
# Synapse Admin API: Register bot user
#######################################
# Usage: synapse_register_bot_user <homeserver_url> <admin_token> <user_id> <password> [display_name]
# Example: synapse_register_bot_user "https://matrix.example.com" "syt_..." "@bot:example.com" "secret123" "My Bot"
synapse_register_bot_user() {
	local homeserver_url="$1"
	local admin_token="$2"
	local user_id="$3"
	local password="$4"
	local display_name="${5:-}"

	if [[ -z "$homeserver_url" || -z "$admin_token" || -z "$user_id" || -z "$password" ]]; then
		log_error "Usage: synapse_register_bot_user <homeserver_url> <admin_token> <user_id> <password> [display_name]"
		return 1
	fi

	# URL-encode the user ID for the path
	local encoded_user_id
	encoded_user_id=$(printf '%s' "$user_id" | jq -sRr @uri)

	local endpoint="${homeserver_url}/_synapse/admin/v2/users/${encoded_user_id}"

	local json_body
	json_body=$(jq -n \
		--arg password "$password" \
		--arg displayname "$display_name" \
		--argjson admin false \
		'{
			password: $password,
			admin: $admin,
			displayname: (if $displayname != "" then $displayname else null end)
		}')

	log_info "Registering bot user: $user_id"

	local response
	response=$(curl -sf -X PUT "$endpoint" \
		-H "Authorization: Bearer $admin_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "Bot user registered successfully"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Failed to register bot user"
		echo "$response"
		return 1
	fi
}

#######################################
# Matrix Client API: Login and get access token
#######################################
# Usage: matrix_login <homeserver_url> <user_id> <password>
# Example: matrix_login "https://matrix.example.com" "@bot:example.com" "secret123"
matrix_login() {
	local homeserver_url="$1"
	local user_id="$2"
	local password="$3"

	if [[ -z "$homeserver_url" || -z "$user_id" || -z "$password" ]]; then
		log_error "Usage: matrix_login <homeserver_url> <user_id> <password>"
		return 1
	fi

	local endpoint="${homeserver_url}/_matrix/client/v3/login"

	local json_body
	json_body=$(jq -n \
		--arg type "m.login.password" \
		--arg user "$user_id" \
		--arg password "$password" \
		'{
			type: $type,
			identifier: {
				type: "m.id.user",
				user: $user
			},
			password: $password
		}')

	log_info "Logging in as: $user_id"

	local response
	response=$(curl -sf -X POST "$endpoint" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "Login successful"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Login failed"
		echo "$response"
		return 1
	fi
}

#######################################
# Matrix Client API: Create room
#######################################
# Usage: matrix_create_room <homeserver_url> <access_token> <room_name> [room_alias] [is_public]
# Example: matrix_create_room "https://matrix.example.com" "syt_..." "My Room" "myroom" "false"
matrix_create_room() {
	local homeserver_url="$1"
	local access_token="$2"
	local room_name="$3"
	local room_alias="${4:-}"
	local is_public="${5:-false}"

	if [[ -z "$homeserver_url" || -z "$access_token" || -z "$room_name" ]]; then
		log_error "Usage: matrix_create_room <homeserver_url> <access_token> <room_name> [room_alias] [is_public]"
		return 1
	fi

	local endpoint="${homeserver_url}/_matrix/client/v3/createRoom"

	local preset
	if [[ "$is_public" == "true" ]]; then
		preset="public_chat"
	else
		preset="private_chat"
	fi

	local json_body
	json_body=$(jq -n \
		--arg name "$room_name" \
		--arg alias "$room_alias" \
		--arg preset "$preset" \
		'{
			name: $name,
			room_alias_name: (if $alias != "" then $alias else null end),
			preset: $preset,
			visibility: (if $preset == "public_chat" then "public" else "private" end)
		}')

	log_info "Creating room: $room_name"

	local response
	response=$(curl -sf -X POST "$endpoint" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "Room created successfully"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Failed to create room"
		echo "$response"
		return 1
	fi
}

#######################################
# Matrix Client API: Invite user to room
#######################################
# Usage: matrix_invite_user <homeserver_url> <access_token> <room_id> <user_id>
# Example: matrix_invite_user "https://matrix.example.com" "syt_..." "!abc:example.com" "@user:example.com"
matrix_invite_user() {
	local homeserver_url="$1"
	local access_token="$2"
	local room_id="$3"
	local user_id="$4"

	if [[ -z "$homeserver_url" || -z "$access_token" || -z "$room_id" || -z "$user_id" ]]; then
		log_error "Usage: matrix_invite_user <homeserver_url> <access_token> <room_id> <user_id>"
		return 1
	fi

	# URL-encode the room ID for the path
	local encoded_room_id
	encoded_room_id=$(printf '%s' "$room_id" | jq -sRr @uri)

	local endpoint="${homeserver_url}/_matrix/client/v3/rooms/${encoded_room_id}/invite"

	local json_body
	json_body=$(jq -n \
		--arg user_id "$user_id" \
		'{
			user_id: $user_id
		}')

	log_info "Inviting $user_id to room $room_id"

	local response
	response=$(curl -sf -X POST "$endpoint" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>&1)

	local exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		log_success "User invited successfully"
		echo "$response" | jq '.'
		return 0
	else
		log_error "Failed to invite user"
		echo "$response"
		return 1
	fi
}
