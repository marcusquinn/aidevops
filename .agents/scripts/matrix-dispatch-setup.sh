#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Matrix Dispatch Setup Library — Interactive and Non-Interactive Setup
# =============================================================================
# Interactive setup wizard helpers and non-interactive setup for the Matrix
# dispatch bot. Extracted from matrix-dispatch-helper.sh to keep the
# orchestrator under the 2000-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/matrix-dispatch-setup.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_*, etc.)
#   - matrix-dispatch-helper.sh globals: CONFIG_FILE, DATA_DIR, BOT_SCRIPT,
#     SESSION_STORE_SCRIPT, RUNNER_HELPER
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MATRIX_DISPATCH_SETUP_LIB_LOADED:-}" ]] && return 0
_MATRIX_DISPATCH_SETUP_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Read homeserver URL with optional existing-value prompt
# Sets $homeserver in caller scope via nameref-free pattern (bash 3.2 compat)
# Returns: prints the resolved homeserver URL
#######################################
_setup_read_homeserver() {
	local result=""
	if config_exists; then
		local existing_hs
		existing_hs=$(config_get "homeserverUrl")
		if [[ -n "$existing_hs" ]]; then
			echo -n "Matrix homeserver URL [$existing_hs]: " >/dev/tty
			read -r result </dev/tty
			result="${result:-$existing_hs}"
		else
			echo -n "Matrix homeserver URL (e.g., https://matrix.example.com): " >/dev/tty
			read -r result </dev/tty
		fi
	else
		echo -n "Matrix homeserver URL (e.g., https://matrix.example.com): " >/dev/tty
		read -r result </dev/tty
	fi
	printf '%s' "$result"
	return 0
}

#######################################
# Read access token with masked existing-value prompt
# Returns: prints the resolved access token
#######################################
_setup_read_access_token() {
	local result=""
	local existing_token
	existing_token=$(config_get "accessToken")
	if [[ -n "$existing_token" ]]; then
		echo -n "Bot access token [****${existing_token: -8}]: " >/dev/tty
		read -rs result </dev/tty
		echo "" >/dev/tty
		result="${result:-$existing_token}"
	else
		echo -n "Bot access token: " >/dev/tty
		read -rs result </dev/tty
		echo "" >/dev/tty
	fi
	printf '%s' "$result"
	return 0
}

#######################################
# Read optional setup fields: allowed_users, default_runner, idle_timeout
# Outputs three lines: allowed_users, default_runner, idle_timeout
#######################################
_setup_read_optional_fields() {
	local allowed_users="" default_runner="" idle_timeout=""

	# Allowed users
	echo "" >/dev/tty
	echo "Restrict which Matrix users can trigger the bot (comma-separated)." >/dev/tty
	echo "Leave empty to allow all users in mapped rooms." >/dev/tty
	echo "Example: @admin:example.com,@dev:example.com" >/dev/tty
	echo "" >/dev/tty
	local existing_users
	existing_users=$(config_get "allowedUsers")
	if [[ -n "$existing_users" ]]; then
		echo -n "Allowed users [$existing_users]: " >/dev/tty
		read -r allowed_users </dev/tty
		allowed_users="${allowed_users:-$existing_users}"
	else
		echo -n "Allowed users (empty = all): " >/dev/tty
		read -r allowed_users </dev/tty
	fi

	# Default runner
	echo "" >/dev/tty
	echo "Default runner for rooms without explicit mapping." >/dev/tty
	echo "Messages in unmapped rooms go to this runner (or are ignored if empty)." >/dev/tty
	echo "" >/dev/tty
	local existing_runner
	existing_runner=$(config_get "defaultRunner")
	if [[ -n "$existing_runner" ]]; then
		echo -n "Default runner [$existing_runner]: " >/dev/tty
		read -r default_runner </dev/tty
		default_runner="${default_runner:-$existing_runner}"
	else
		echo -n "Default runner (empty = ignore unmapped rooms): " >/dev/tty
		read -r default_runner </dev/tty
	fi

	# Session idle timeout
	echo "" >/dev/tty
	echo "Session idle timeout (seconds). After this period of inactivity," >/dev/tty
	echo "the bot compacts the conversation context and frees the session." >/dev/tty
	echo "The compacted summary is used to prime the next session." >/dev/tty
	echo "" >/dev/tty
	local existing_timeout
	existing_timeout=$(config_get "sessionIdleTimeout")
	if [[ -n "$existing_timeout" ]]; then
		echo -n "Session idle timeout [${existing_timeout}s]: " >/dev/tty
		read -r idle_timeout </dev/tty
		idle_timeout="${idle_timeout:-$existing_timeout}"
	else
		echo -n "Session idle timeout [300]: " >/dev/tty
		read -r idle_timeout </dev/tty
		idle_timeout="${idle_timeout:-300}"
	fi

	printf '%s\n%s\n%s\n' "$allowed_users" "$default_runner" "$idle_timeout"
	return 0
}

#######################################
# Save or preview setup config
# Args: dry_run homeserver access_token allowed_users default_runner idle_timeout
#######################################
_setup_save_config() {
	local dry_run="$1"
	local homeserver="$2"
	local access_token="$3"
	local allowed_users="$4"
	local default_runner="$5"
	local idle_timeout="$6"

	if [[ "$dry_run" == "true" ]]; then
		log_info "Dry-run: Would save configuration to $CONFIG_FILE"
		echo ""
		echo "Configuration preview:"
		jq -n \
			--arg homeserverUrl "$homeserver" \
			--arg accessToken "****${access_token: -8}" \
			--arg allowedUsers "$allowed_users" \
			--arg defaultRunner "$default_runner" \
			--argjson sessionIdleTimeout "$idle_timeout" \
			'{
				homeserverUrl: $homeserverUrl,
				accessToken: $accessToken,
				allowedUsers: $allowedUsers,
				defaultRunner: $defaultRunner,
				roomMappings: {},
				botPrefix: "!ai",
				ignoreOwnMessages: true,
				maxPromptLength: 3000,
				responseTimeout: 600,
				sessionIdleTimeout: $sessionIdleTimeout
			}'
		echo ""
	else
		local temp_file
		temp_file=$(mktemp)
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		push_cleanup "rm -f '${temp_file}'"
		jq -n \
			--arg homeserverUrl "$homeserver" \
			--arg accessToken "$access_token" \
			--arg allowedUsers "$allowed_users" \
			--arg defaultRunner "$default_runner" \
			--argjson sessionIdleTimeout "$idle_timeout" \
			'{
				homeserverUrl: $homeserverUrl,
				accessToken: $accessToken,
				allowedUsers: $allowedUsers,
				defaultRunner: $defaultRunner,
				roomMappings: (input.roomMappings // {}),
				botPrefix: "!ai",
				ignoreOwnMessages: true,
				maxPromptLength: 3000,
				responseTimeout: 600,
				sessionIdleTimeout: $sessionIdleTimeout
			}' --jsonargs < <(if [[ -f "$CONFIG_FILE" ]]; then cat "$CONFIG_FILE"; else echo '{}'; fi) >"$temp_file"
		mv "$temp_file" "$CONFIG_FILE"
		chmod 600 "$CONFIG_FILE"
	fi
	return 0
}

#######################################
# Install npm dependencies for the bot
# Args: dry_run
#######################################
_setup_install_deps() {
	local dry_run="$1"
	local needs_install=false

	if [[ ! -d "$DATA_DIR/node_modules/matrix-bot-sdk" ]]; then
		needs_install=true
	fi
	if [[ ! -d "$DATA_DIR/node_modules/better-sqlite3" ]]; then
		needs_install=true
	fi

	if [[ "$needs_install" == "true" ]]; then
		if [[ "$dry_run" == "true" ]]; then
			log_info "Dry-run: Would install dependencies (matrix-bot-sdk, better-sqlite3)"
		else
			log_info "Installing dependencies (matrix-bot-sdk, better-sqlite3)..."
			npm install --prefix "$DATA_DIR" matrix-bot-sdk better-sqlite3 2>/dev/null || {
				log_error "Failed to install dependencies"
				echo "Install manually: npm install --prefix $DATA_DIR matrix-bot-sdk better-sqlite3"
				return 1
			}
			log_success "Dependencies installed"
		fi
	fi
	return 0
}

#######################################
# Post-setup success messages and missing-runner check
#######################################
_setup_post_success() {
	log_success "Setup complete!"
	echo ""

	local runner_helper="$HOME/.aidevops/agents/scripts/runner-helper.sh"
	if config_exists && [[ -x "$runner_helper" ]]; then
		local mappings
		mappings=$(jq -r '.roomMappings // {} | values[]' "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$mappings" ]]; then
			local missing_runners=()
			while IFS= read -r runner_name; do
				if ! "$runner_helper" status "$runner_name" &>/dev/null; then
					missing_runners+=("$runner_name")
				fi
			done <<<"$mappings"

			if ((${#missing_runners[@]} > 0)); then
				log_info "Creating missing runners for mapped rooms..."
				for mr in "${missing_runners[@]}"; do
					if "$runner_helper" create "$mr" --description "Matrix bot runner for $mr" 2>/dev/null; then
						log_success "Created runner: $mr"
					else
						log_warn "Failed to create runner: $mr"
						echo "  Create manually: runner-helper.sh create $mr --description \"Description\" --workdir /path/to/project"
					fi
				done
				echo ""
			fi
		fi
	fi

	echo "Next steps:"
	echo "  1. Map rooms to runners:"
	echo "     matrix-dispatch-helper.sh map '!roomid:server' my-runner"
	echo ""
	echo "  2. Create runners for each mapped room:"
	echo "     runner-helper.sh create <name> --description \"desc\" --workdir /path/to/project"
	echo ""
	echo "  3. Start the bot:"
	echo "     matrix-dispatch-helper.sh start"
	echo ""
	echo "  4. In a mapped Matrix room, type:"
	echo "     !ai Review the auth module for security issues"
	return 0
}

#######################################
# Interactive setup wizard
#######################################
cmd_setup() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
		shift
	fi

	check_deps || return 1
	ensure_dirs

	echo -e "${BOLD}Matrix Bot Setup${NC}"
	if [[ "$dry_run" == "true" ]]; then
		echo -e "${YELLOW}[DRY RUN MODE - No changes will be saved]${NC}"
	fi
	echo "──────────────────────────────────"
	echo ""
	echo "This wizard configures a Matrix bot that dispatches messages to AI runners."
	echo ""

	local homeserver
	homeserver=$(_setup_read_homeserver)
	if [[ -z "$homeserver" ]]; then
		log_error "Homeserver URL is required"
		return 1
	fi

	echo ""
	echo "Create a bot account on your Matrix server, then get an access token."
	echo "For Synapse: use the admin API or register via Element and extract token."
	echo "For Cloudron Synapse: Admin Console > Users > Create user, then login via Element."
	echo ""

	local access_token
	access_token=$(_setup_read_access_token)
	if [[ -z "$access_token" ]]; then
		log_error "Access token is required"
		return 1
	fi

	local optional_fields allowed_users default_runner idle_timeout
	optional_fields=$(_setup_read_optional_fields)
	allowed_users=$(printf '%s' "$optional_fields" | sed -n '1p')
	default_runner=$(printf '%s' "$optional_fields" | sed -n '2p')
	idle_timeout=$(printf '%s' "$optional_fields" | sed -n '3p')

	_setup_save_config "$dry_run" "$homeserver" "$access_token" "$allowed_users" "$default_runner" "$idle_timeout" || return 1

	_setup_install_deps "$dry_run" || return 1

	if [[ "$dry_run" == "true" ]]; then
		log_info "Dry-run: Would generate session store and bot scripts"
	else
		generate_session_store_script
		generate_bot_script
	fi

	echo ""
	if [[ "$dry_run" == "true" ]]; then
		log_success "Dry-run complete! No changes were made."
		echo ""
		echo "To apply these settings, run:"
		echo "  matrix-dispatch-helper.sh setup"
	else
		_setup_post_success
	fi

	return 0
}
