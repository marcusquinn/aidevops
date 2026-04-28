#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Matrix Dispatch Auto-Setup Library — Automated Cloudron+Synapse Provisioning
# =============================================================================
# Full end-to-end automated setup: Cloudron Synapse install, bot user creation,
# access token retrieval, bot config, room creation, and runner mapping.
# Extracted from matrix-dispatch-helper.sh to keep the orchestrator under
# the 2000-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/matrix-dispatch-auto-setup.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_*, etc.)
#   - matrix-dispatch-api.sh (synapse_register_bot_user, matrix_login, etc.)
#   - matrix-dispatch-helper.sh globals: CONFIG_FILE, DATA_DIR, SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MATRIX_DISPATCH_AUTO_SETUP_LIB_LOADED:-}" ]] && return 0
_MATRIX_DISPATCH_AUTO_SETUP_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Non-interactive setup (writes config without prompts)
#######################################
cmd_setup_noninteractive() {
	local homeserver_url="$1"
	local access_token="$2"
	local allowed_users="${3:-}"
	local default_runner="${4:-}"
	local idle_timeout="${5:-300}"

	if [[ -z "$homeserver_url" || -z "$access_token" ]]; then
		log_error "Usage: cmd_setup_noninteractive <homeserver_url> <access_token> [allowed_users] [default_runner] [idle_timeout]"
		return 1
	fi

	check_deps || return 1
	ensure_dirs

	# Write config
	local temp_file
	temp_file=$(mktemp)
	trap 'rm -f "$temp_file"' RETURN

	local existing_mappings='{}'
	if [[ -f "$CONFIG_FILE" ]]; then
		existing_mappings=$(jq -r '.roomMappings // {}' "$CONFIG_FILE" 2>/dev/null || echo '{}')
	fi

	jq -n \
		--arg homeserverUrl "$homeserver_url" \
		--arg accessToken "$access_token" \
		--arg allowedUsers "$allowed_users" \
		--arg defaultRunner "$default_runner" \
		--argjson sessionIdleTimeout "$idle_timeout" \
		--argjson roomMappings "$existing_mappings" \
		'{
			homeserverUrl: $homeserverUrl,
			accessToken: $accessToken,
			allowedUsers: $allowedUsers,
			defaultRunner: $defaultRunner,
			roomMappings: $roomMappings,
			botPrefix: "!ai",
			ignoreOwnMessages: true,
			maxPromptLength: 3000,
			responseTimeout: 600,
			sessionIdleTimeout: $sessionIdleTimeout
		}' >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	# Install dependencies if needed
	local needs_install=false
	if [[ ! -d "$DATA_DIR/node_modules/matrix-bot-sdk" ]]; then
		needs_install=true
	fi
	if [[ ! -d "$DATA_DIR/node_modules/better-sqlite3" ]]; then
		needs_install=true
	fi

	if [[ "$needs_install" == "true" ]]; then
		log_info "Installing dependencies (matrix-bot-sdk, better-sqlite3)..."
		npm install --prefix "$DATA_DIR" matrix-bot-sdk better-sqlite3 2>/dev/null || {
			log_error "Failed to install dependencies"
			return 1
		}
		log_success "Dependencies installed"
	fi

	# Generate scripts
	generate_session_store_script
	generate_bot_script

	log_success "Non-interactive setup complete"
	return 0
}

#######################################
# Parse auto-setup arguments
# Outputs: cloudron_server subdomain bot_user bot_display runners allowed_users dry_run skip_install admin_token
# (one per line, in that order)
#######################################
_auto_setup_parse_args() {
	local cloudron_server="" subdomain="matrix" bot_user="aibot"
	local bot_display="AI DevOps Bot" runners="" allowed_users=""
	local dry_run=false skip_install=false admin_token=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--subdomain)
			subdomain="$2"
			shift 2
			;;
		--bot-user)
			bot_user="$2"
			shift 2
			;;
		--bot-display)
			bot_display="$2"
			shift 2
			;;
		--runners)
			runners="$2"
			shift 2
			;;
		--allowed-users)
			allowed_users="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--skip-install)
			skip_install=true
			shift
			;;
		--admin-token)
			admin_token="$2"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$cloudron_server" ]]; then
				cloudron_server="$1"
			else
				log_error "Unexpected argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
		"$cloudron_server" "$subdomain" "$bot_user" "$bot_display" \
		"$runners" "$allowed_users" "$dry_run" "$skip_install" "$admin_token"
	return 0
}

#######################################
# Resolve Cloudron server config
# Args: cloudron_server
# Outputs: server_domain (or exits with error)
#######################################
_auto_setup_resolve_cloudron() {
	local cloudron_server="$1"
	local cloudron_helper="${SCRIPT_DIR}/cloudron-helper.sh"

	if [[ ! -x "$cloudron_helper" ]]; then
		log_error "cloudron-helper.sh not found at $cloudron_helper"
		return 1
	fi

	local cloudron_config=""
	local config_paths=(
		"${SCRIPT_DIR}/../../configs/cloudron-config.json"
		"${SCRIPT_DIR}/../configs/cloudron-config.json"
		"configs/cloudron-config.json"
		"../configs/cloudron-config.json"
	)
	local candidate
	for candidate in "${config_paths[@]}"; do
		if [[ -f "$candidate" ]]; then
			cloudron_config="$candidate"
			break
		fi
	done

	if [[ -z "$cloudron_config" ]]; then
		log_error "Cloudron config not found"
		log_info "Copy and customize: cp configs/cloudron-config.json.txt configs/cloudron-config.json"
		return 1
	fi

	local server_domain server_token
	server_domain=$(jq -r ".servers.\"$cloudron_server\".domain" "$cloudron_config" 2>/dev/null)
	server_token=$(jq -r ".servers.\"$cloudron_server\".api_token" "$cloudron_config" 2>/dev/null)

	if [[ "$server_domain" == "null" || -z "$server_domain" ]]; then
		log_error "Server '$cloudron_server' not found in Cloudron config"
		log_info "Available servers:"
		jq -r '.servers | keys[]' "$cloudron_config" 2>/dev/null | while read -r s; do
			echo "  - $s"
		done
		return 1
	fi

	if [[ "$server_token" == "null" || -z "$server_token" || "$server_token" == *"YOUR_"* ]]; then
		log_error "API token not configured for server '$cloudron_server'"
		log_info "Set it in: configs/cloudron-config.json"
		return 1
	fi

	printf '%s\n' "$server_domain"
	return 0
}

#######################################
# Print dry-run plan for auto-setup
# Args: skip_install subdomain server_domain bot_user_id server_name runners
#######################################
_auto_setup_dry_run() {
	local skip_install="$1" subdomain="$2" server_domain="$3"
	local bot_user_id="$4" server_name="$5" runners="$6"

	echo -e "${YELLOW}[DRY RUN]${NC} The following steps would be executed:"
	echo ""
	if [[ "$skip_install" != "true" ]]; then
		echo "  1. Install Synapse on Cloudron at $subdomain.$server_domain"
		echo "  2. Wait for Synapse to be ready"
	else
		echo "  1-2. (skipped — Synapse already installed)"
	fi
	echo "  3. Register bot user: $bot_user_id"
	echo "  4. Login as bot to get access token"
	echo "  5. Store credentials via aidevops secret"
	echo "  6. Configure matrix-dispatch-helper.sh"
	if [[ -n "$runners" ]]; then
		echo "  7. Create rooms and map to runners:"
		local runner_list runner
		IFS=',' read -ra runner_list <<<"$runners"
		for runner in "${runner_list[@]}"; do
			runner=$(printf '%s' "$runner" | tr -d ' ')
			echo "     - Room: #${runner}:${server_name} -> runner: $runner"
		done
	else
		echo "  7. (no runners specified — skip room creation)"
	fi
	echo "  8. Install npm dependencies and generate bot scripts"
	echo ""
	echo "Run without --dry-run to execute."
	return 0
}

#######################################
# Install Synapse on Cloudron (steps 1-2)
# Args: cloudron_server subdomain server_domain homeserver_url
# Returns: 0 on success, 1 on failure
#######################################
_auto_setup_install_synapse() {
	local cloudron_server="$1" subdomain="$2" server_domain="$3" homeserver_url="$4"
	local cloudron_helper="${SCRIPT_DIR}/cloudron-helper.sh"
	local synapse_app_id="org.matrix.synapse.cloudronapp"

	log_info "Step 1/8: Installing Synapse on Cloudron..."

	local app_id
	app_id=$("$cloudron_helper" install-app "$cloudron_server" "$synapse_app_id" "$subdomain" 2>&1)
	local install_exit=$?

	if [[ $install_exit -ne 0 ]]; then
		local existing_app
		existing_app=$("$cloudron_helper" app-info "$cloudron_server" "$subdomain" 2>/dev/null)
		if [[ -n "$existing_app" ]]; then
			log_warn "Synapse appears to already be installed at $subdomain.$server_domain"
			app_id=$(printf '%s' "$existing_app" | jq -r '.id')
		else
			log_error "Failed to install Synapse: $app_id"
			return 1
		fi
	fi

	app_id=$(printf '%s' "$app_id" | tail -1 | tr -d '[:space:]')
	log_success "Synapse installation initiated (app ID: $app_id)"

	log_info "Step 2/8: Waiting for Synapse to be ready..."
	if ! "$cloudron_helper" wait-ready "$cloudron_server" "$app_id" 600; then
		log_error "Synapse failed to become ready within 10 minutes"
		return 1
	fi
	log_success "Synapse is ready"
	return 0
}

#######################################
# Register bot user and obtain access token (steps 3-4)
# Args: homeserver_url cloudron_server bot_user_id bot_password bot_display admin_token
# Outputs: bot_access_token on stdout
#######################################
_auto_setup_register_and_login() {
	local homeserver_url="$1" cloudron_server="$2" bot_user_id="$3"
	local bot_password="$4" bot_display="$5" admin_token="$6"

	log_info "Step 3/8: Registering bot user..."

	if [[ -z "$admin_token" ]]; then
		local secret_name="SYNAPSE_ADMIN_TOKEN_${cloudron_server}"
		admin_token=$(gopass show "aidevops/${secret_name}" 2>/dev/null || true)

		if [[ -z "$admin_token" ]]; then
			log_error "Synapse admin token not found"
			echo ""
			echo "To get the admin token:"
			echo "  1. Create an admin user on Synapse (via Cloudron dashboard or register_new_matrix_user)"
			echo "  2. Login via the Matrix API to get an access token"
			echo "  3. Store it: aidevops secret set ${secret_name}"
			echo ""
			echo "Or pass it directly: --admin-token <token>"
			return 1
		fi
	fi

	local register_result register_rc
	register_result=$(synapse_register_bot_user "$homeserver_url" "$admin_token" "$bot_user_id" "$bot_password" "$bot_display" 2>&1)
	register_rc=$?
	if [[ $register_rc -ne 0 ]]; then
		log_error "Failed to register bot user: $register_result"
		return 1
	fi
	log_success "Bot user registered: $bot_user_id"

	log_info "Step 4/8: Logging in as bot user..."
	local login_result login_rc
	login_result=$(matrix_login "$homeserver_url" "$bot_user_id" "$bot_password" 2>&1)
	login_rc=$?
	if [[ $login_rc -ne 0 ]]; then
		log_error "Failed to login as bot: $login_result"
		return 1
	fi

	local bot_access_token
	bot_access_token=$(printf '%s' "$login_result" | jq -r '.access_token // empty' 2>/dev/null)
	if [[ -z "$bot_access_token" ]]; then
		log_error "Failed to extract access token from login response"
		return 1
	fi
	log_success "Bot access token obtained"

	printf '%s\n' "$bot_access_token"
	return 0
}

#######################################
# Store bot credentials in gopass (step 5)
# Args: cloudron_server bot_password bot_access_token
#######################################
_auto_setup_store_credentials() {
	local cloudron_server="$1" bot_password="$2" bot_access_token="$3"
	local secret_prefix="MATRIX_BOT_${cloudron_server}"

	log_info "Step 5/8: Storing credentials..."

	if command -v gopass &>/dev/null; then
		printf '%s' "$bot_password" | gopass insert -f "aidevops/${secret_prefix}_PASSWORD" 2>/dev/null || {
			log_warn "Failed to store bot password in gopass"
		}
		printf '%s' "$bot_access_token" | gopass insert -f "aidevops/${secret_prefix}_TOKEN" 2>/dev/null || {
			log_warn "Failed to store bot token in gopass"
		}
		log_success "Credentials stored in gopass (aidevops/${secret_prefix}_*)"
	else
		log_warn "gopass not available — credentials stored only in config file"
		log_info "Install gopass for encrypted credential storage: aidevops secret set"
	fi
	return 0
}

#######################################
# Create rooms and map to runners (step 7)
# Args: homeserver_url bot_access_token runners allowed_users
#######################################
_auto_setup_create_rooms() {
	local homeserver_url="$1" bot_access_token="$2" runners="$3" allowed_users="$4"
	local runner_helper="$HOME/.aidevops/agents/scripts/runner-helper.sh"

	log_info "Step 7/8: Creating rooms, runners, and mapping..."

	local runner_list runner
	IFS=',' read -ra runner_list <<<"$runners"
	for runner in "${runner_list[@]}"; do
		runner=$(printf '%s' "$runner" | tr -d ' ')

		if [[ -x "$runner_helper" ]]; then
			if ! "$runner_helper" status "$runner" &>/dev/null; then
				log_info "Creating runner: $runner"
				"$runner_helper" create "$runner" --description "Matrix bot runner for $runner" 2>/dev/null || {
					log_warn "Failed to create runner: $runner"
				}
			else
				log_info "Runner already exists: $runner"
			fi
		else
			log_warn "runner-helper.sh not found — create runners manually: runner-helper.sh create $runner"
		fi

		local room_name="AI: ${runner}"
		local room_alias="${runner}"
		log_info "Creating room for runner: $runner"

		local room_result room_id room_rc
		room_result=$(matrix_create_room "$homeserver_url" "$bot_access_token" "$room_name" "$room_alias" "false" 2>&1)
		room_rc=$?
		if [[ $room_rc -ne 0 ]]; then
			log_warn "Failed to create room for $runner: $room_result"
			continue
		fi

		room_id=$(printf '%s' "$room_result" | jq -r '.room_id // empty' 2>/dev/null)
		if [[ -z "$room_id" ]]; then
			log_warn "Failed to extract room ID for $runner"
			continue
		fi
		log_success "Room created: $room_id ($room_name)"

		cmd_map "$room_id" "$runner"

		if [[ -n "$allowed_users" ]]; then
			local user_list user
			IFS=',' read -ra user_list <<<"$allowed_users"
			for user in "${user_list[@]}"; do
				user=$(printf '%s' "$user" | tr -d ' ')
				log_info "Inviting $user to room $room_id"
				matrix_invite_user "$homeserver_url" "$bot_access_token" "$room_id" "$user" 2>/dev/null || {
					log_warn "Failed to invite $user to $room_id"
				}
			done
		fi
	done

	log_success "Room creation and mapping complete"
	return 0
}

#######################################
# Print auto-setup completion summary (step 8)
# Args: homeserver_url bot_user_id runners cloudron_server
#######################################
_auto_setup_summary() {
	local homeserver_url="$1" bot_user_id="$2" runners="$3" cloudron_server="$4"
	local secret_prefix="MATRIX_BOT_${cloudron_server}"

	log_info "Step 8/8: Finalizing..."
	echo ""
	echo -e "${BOLD}Auto-Setup Complete!${NC}"
	echo "──────────────────────────────────"
	echo ""
	echo "Homeserver:    $homeserver_url"
	echo "Bot user:      $bot_user_id"
	echo "Config:        $CONFIG_FILE"
	echo ""

	if [[ -n "$runners" ]]; then
		echo "Room mappings:"
		jq -r '.roomMappings // {} | to_entries[] | "  \(.key) -> \(.value)"' "$CONFIG_FILE" 2>/dev/null
		echo ""
	fi

	echo "Next steps:"
	echo "  1. Start the bot:"
	echo "     matrix-dispatch-helper.sh start --daemon"
	echo ""
	if [[ -z "$runners" ]]; then
		echo "  2. Map rooms to runners:"
		echo "     matrix-dispatch-helper.sh map '!roomid:server' my-runner"
		echo ""
	fi
	echo "  3. In a mapped Matrix room, type:"
	echo "     !ai Review the auth module for security issues"
	echo ""

	if command -v gopass &>/dev/null; then
		echo "Credentials stored in gopass:"
		echo "  aidevops/${secret_prefix}_PASSWORD"
		echo "  aidevops/${secret_prefix}_TOKEN"
	fi
	return 0
}

#######################################
# Print auto-setup usage when no server is given
#######################################
_auto_setup_usage() {
	log_error "Cloudron server name is required"
	echo ""
	echo "Usage: matrix-dispatch-helper.sh auto-setup <cloudron-server> [options]"
	echo ""
	echo "Options:"
	echo "  --subdomain <name>     Synapse subdomain (default: matrix)"
	echo "  --bot-user <name>      Bot username (default: aibot)"
	echo "  --bot-display <name>   Bot display name (default: AI DevOps Bot)"
	echo "  --runners <list>       Comma-separated runner names for room creation"
	echo "  --allowed-users <list> Comma-separated allowed Matrix user IDs"
	echo "  --dry-run              Show plan without executing"
	echo "  --skip-install         Skip Synapse installation (already installed)"
	echo "  --admin-token <token>  Use existing Synapse admin token"
	echo ""
	echo "Example:"
	echo "  matrix-dispatch-helper.sh auto-setup cloudron01 --runners code-reviewer,seo-analyst,ops-monitor"
	return 1
}

#######################################
# Verify Synapse is accessible when skipping install (step 1-2 skip path)
# Args: homeserver_url
#######################################
_auto_setup_verify_synapse() {
	local homeserver_url="$1"
	log_info "Step 1-2/8: Skipping Synapse installation (--skip-install)"
	local health_check
	health_check=$(curl -sf "${homeserver_url}/_matrix/client/versions" 2>/dev/null)
	if [[ -z "$health_check" ]]; then
		log_error "Synapse not responding at $homeserver_url"
		log_info "Verify Synapse is installed and running on Cloudron"
		return 1
	fi
	log_success "Synapse is accessible at $homeserver_url"
	return 0
}

#######################################
# Auto-setup: Full end-to-end provisioning
#
# Orchestrates: Cloudron Synapse install -> bot user creation ->
# access token -> bot config -> room creation -> room mapping
#
# Usage:
#   matrix-dispatch-helper.sh auto-setup <cloudron-server> [options]
#
# Options:
#   --subdomain <name>     Synapse subdomain (default: matrix)
#   --bot-user <name>      Bot username (default: aibot)
#   --bot-display <name>   Bot display name (default: AI DevOps Bot)
#   --runners <list>       Comma-separated runner names for room creation
#   --allowed-users <list> Comma-separated Matrix user IDs to allow
#   --dry-run              Show what would be done without executing
#   --skip-install         Skip Synapse installation (already installed)
#   --admin-token <token>  Use existing Synapse admin token instead of auto-detecting
#######################################
cmd_auto_setup() {
	local parsed cloudron_server subdomain bot_user bot_display
	local runners allowed_users dry_run skip_install admin_token

	parsed=$(_auto_setup_parse_args "$@") || return 1
	cloudron_server=$(printf '%s' "$parsed" | sed -n '1p')
	subdomain=$(printf '%s' "$parsed" | sed -n '2p')
	bot_user=$(printf '%s' "$parsed" | sed -n '3p')
	bot_display=$(printf '%s' "$parsed" | sed -n '4p')
	runners=$(printf '%s' "$parsed" | sed -n '5p')
	allowed_users=$(printf '%s' "$parsed" | sed -n '6p')
	dry_run=$(printf '%s' "$parsed" | sed -n '7p')
	skip_install=$(printf '%s' "$parsed" | sed -n '8p')
	admin_token=$(printf '%s' "$parsed" | sed -n '9p')

	if [[ -z "$cloudron_server" ]]; then
		_auto_setup_usage
		return 1
	fi

	check_deps || return 1
	ensure_dirs

	local server_domain
	server_domain=$(_auto_setup_resolve_cloudron "$cloudron_server") || return 1

	local homeserver_url="https://${subdomain}.${server_domain}"
	local server_name
	server_name=$(extract_server_name "$homeserver_url")
	local bot_user_id="@${bot_user}:${server_name}"
	local bot_password
	bot_password=$(generate_password 32)

	echo -e "${BOLD}Matrix Bot Auto-Setup${NC}"
	echo "──────────────────────────────────"
	echo ""
	echo "Cloudron server:  $cloudron_server ($server_domain)"
	echo "Synapse URL:      $homeserver_url"
	echo "Bot user:         $bot_user_id"
	echo "Bot display name: $bot_display"
	echo "Runners:          ${runners:-none (add later with 'map' command)}"
	echo "Allowed users:    ${allowed_users:-all}"
	echo ""

	if [[ "$dry_run" == "true" ]]; then
		_auto_setup_dry_run "$skip_install" "$subdomain" "$server_domain" "$bot_user_id" "$server_name" "$runners"
		return 0
	fi

	# Steps 1-2: Install or verify Synapse
	if [[ "$skip_install" != "true" ]]; then
		_auto_setup_install_synapse "$cloudron_server" "$subdomain" "$server_domain" "$homeserver_url" || return 1
	else
		_auto_setup_verify_synapse "$homeserver_url" || return 1
	fi

	# Steps 3-4: Register bot and get access token
	local bot_access_token
	bot_access_token=$(_auto_setup_register_and_login \
		"$homeserver_url" "$cloudron_server" "$bot_user_id" \
		"$bot_password" "$bot_display" "$admin_token") || return 1

	# Step 5: Store credentials
	_auto_setup_store_credentials "$cloudron_server" "$bot_password" "$bot_access_token"

	# Step 6: Configure bot
	log_info "Step 6/8: Configuring bot..."
	cmd_setup_noninteractive "$homeserver_url" "$bot_access_token" "$allowed_users" "" "$DEFAULT_TIMEOUT"
	log_success "Bot configured"

	# Step 7: Create rooms
	if [[ -n "$runners" ]]; then
		_auto_setup_create_rooms "$homeserver_url" "$bot_access_token" "$runners" "$allowed_users" || return 1
	else
		log_info "Step 7/8: No runners specified — skipping room creation"
		log_info "Map rooms later with: matrix-dispatch-helper.sh map '<room_id>' <runner>"
	fi

	# Step 8: Summary
	_auto_setup_summary "$homeserver_url" "$bot_user_id" "$runners" "$cloudron_server"

	return 0
}
