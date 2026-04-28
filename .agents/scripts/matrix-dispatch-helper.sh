#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# matrix-dispatch-helper.sh - Matrix bot for dispatching messages to AI runners
#
# Bridges Matrix chat rooms to aidevops runners via OpenCode server.
# Each Matrix room maps to a named runner. Messages in the room become
# prompts dispatched to the runner, with responses posted back.
#
# Usage:
#   matrix-dispatch-helper.sh setup [--dry-run]        # Interactive setup wizard
#   matrix-dispatch-helper.sh start [--daemon]         # Start the bot
#   matrix-dispatch-helper.sh stop                     # Stop the bot
#   matrix-dispatch-helper.sh status                   # Show bot status
#   matrix-dispatch-helper.sh map <room> <runner>      # Map room to runner
#   matrix-dispatch-helper.sh unmap <room>             # Remove room mapping
#   matrix-dispatch-helper.sh mappings                 # List room-to-runner mappings
#   matrix-dispatch-helper.sh test <room> "message"    # Test dispatch without Matrix
#   matrix-dispatch-helper.sh logs [--tail N] [--follow]
#   matrix-dispatch-helper.sh help
#
# Requirements:
#   - Node.js >= 18 (for matrix-bot-sdk)
#   - jq (brew install jq)
#   - OpenCode server running (opencode serve)
#   - Matrix homeserver with bot account
#
# Configuration:
#   ~/.config/aidevops/matrix-bot.json
#
# Security:
#   - Bot access token stored in matrix-bot.json (600 permissions)
#   - Uses HTTPS for remote Matrix homeservers
#   - Room-to-runner mapping prevents unauthorized dispatch
#   - Only responds to messages from allowed users (configurable)
#
# Sub-libraries (sourced below):
#   matrix-dispatch-setup.sh      — interactive and non-interactive setup
#   matrix-dispatch-sessions.sh   — conversation session management
#   matrix-dispatch-api.sh        — Matrix Client and Synapse Admin API
#   matrix-dispatch-auto-setup.sh — automated Cloudron+Synapse provisioning

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Include guard
[[ -n "${_MATRIX_DISPATCH_HELPER_LOADED:-}" ]] && return 0
_MATRIX_DISPATCH_HELPER_LOADED=1

# Configuration
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aidevops"
readonly CONFIG_FILE="$CONFIG_DIR/matrix-bot.json"
readonly DATA_DIR="$HOME/.aidevops/.agent-workspace/matrix-bot"
readonly LOG_DIR="$DATA_DIR/logs"
readonly PID_FILE="$DATA_DIR/bot.pid"
readonly BOT_SCRIPT="$DATA_DIR/bot.mjs"
readonly SESSION_STORE_SCRIPT="$DATA_DIR/session-store.mjs"
readonly SESSION_DB="$DATA_DIR/sessions.db"
readonly ENTITY_HELPER="$HOME/.aidevops/agents/scripts/entity-helper.sh"
readonly MEMORY_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"
readonly RUNNER_HELPER="$HOME/.aidevops/agents/scripts/runner-helper.sh"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Logging: uses shared log_* from shared-constants.sh with MATRIX prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="MATRIX"

# Source sub-libraries
# shellcheck source=matrix-dispatch-setup.sh
source "${SCRIPT_DIR}/matrix-dispatch-setup.sh"
# shellcheck source=matrix-dispatch-sessions.sh
source "${SCRIPT_DIR}/matrix-dispatch-sessions.sh"
# shellcheck source=matrix-dispatch-api.sh
source "${SCRIPT_DIR}/matrix-dispatch-api.sh"
# shellcheck source=matrix-dispatch-auto-setup.sh
source "${SCRIPT_DIR}/matrix-dispatch-auto-setup.sh"

#######################################
# Check dependencies
#######################################
check_deps() {
	local missing=()

	if ! command -v node &>/dev/null; then
		missing+=("node (Node.js >= 18)")
	fi

	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	if ((${#missing[@]} > 0)); then
		log_error "Missing dependencies:"
		for dep in "${missing[@]}"; do
			echo "  - $dep"
		done
		return 1
	fi

	return 0
}

#######################################
# Ensure config directory exists
#######################################
ensure_dirs() {
	mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
	chmod 700 "$CONFIG_DIR"
}

#######################################
# Check if config exists
#######################################
config_exists() {
	[[ -f "$CONFIG_FILE" ]]
}

#######################################
# Read config value
#######################################
config_get() {
	local key="$1"
	jq -r --arg key "$key" '.[$key] // empty' "$CONFIG_FILE" 2>/dev/null
}

#######################################
# Write config value
#######################################
config_set() {
	local key="$1"
	local value="$2"

	if [[ ! -f "$CONFIG_FILE" ]]; then
		echo '{}' >"$CONFIG_FILE"
		chmod 600 "$CONFIG_FILE"
	fi

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$CONFIG_FILE" >"$temp_file" && mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"
}

#######################################
# Determine protocol based on host
#######################################
get_protocol() {
	local host="$1"
	if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
		echo "http"
	else
		echo "https"
	fi
}

#######################################
# Check if OpenCode server is running
#######################################
check_opencode_server() {
	local protocol
	protocol=$(get_protocol "$OPENCODE_HOST")
	local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/global/health"

	if curl -sf "$url" &>/dev/null; then
		return 0
	else
		return 1
	fi
}

#######################################
# Generate the session store module
#######################################
generate_session_store_script() {
	cat "$SCRIPT_DIR/matrix-session-store.mjs.template" >"$SESSION_STORE_SCRIPT"
	log_info "Generated session store script: $SESSION_STORE_SCRIPT"
}

#######################################
# Generate the bot script
#######################################
generate_bot_script() {
	cat "$SCRIPT_DIR/matrix-bot.mjs.template" >"$BOT_SCRIPT"
	log_info "Generated bot script: $BOT_SCRIPT"
}

#######################################
# Start the bot
#######################################
cmd_start() {
	check_deps || return 1

	if ! config_exists; then
		log_error "Bot not configured. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	if [[ ! -f "$SESSION_STORE_SCRIPT" ]]; then
		log_info "Generating session store..."
		generate_session_store_script
	fi

	if [[ ! -f "$BOT_SCRIPT" ]]; then
		log_info "Generating bot script..."
		generate_bot_script
	fi

	if [[ ! -d "$DATA_DIR/node_modules/matrix-bot-sdk" ]] || [[ ! -d "$DATA_DIR/node_modules/better-sqlite3" ]]; then
		log_error "Dependencies not installed. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	# Check if already running
	if [[ -f "$PID_FILE" ]]; then
		local pid
		pid=$(cat "$PID_FILE")
		if kill -0 "$pid" 2>/dev/null; then
			log_warn "Bot already running (PID: $pid)"
			return 0
		else
			rm -f "$PID_FILE"
		fi
	fi

	# Check OpenCode server
	if ! check_opencode_server; then
		log_warn "OpenCode server not responding on ${OPENCODE_HOST}:${OPENCODE_PORT}"
		echo "Start it with: opencode serve"
		echo "The bot will still start but dispatches will fail until the server is running."
	fi

	local daemon=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--daemon | -d)
			daemon=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local log_file
	log_file="$LOG_DIR/bot-$(date +%Y%m%d-%H%M%S).log"

	if [[ "$daemon" == "true" ]]; then
		log_info "Starting bot in daemon mode..."
		nohup node "$BOT_SCRIPT" >>"$log_file" 2>&1 &
		local pid=$!
		echo "$pid" >"$PID_FILE"
		log_success "Bot started (PID: $pid)"
		echo "Log: $log_file"
		echo "Stop with: matrix-dispatch-helper.sh stop"
	else
		log_info "Starting bot in foreground..."
		echo "Press Ctrl+C to stop"
		echo ""
		node "$BOT_SCRIPT" 2>&1 | tee "$log_file"
	fi

	return 0
}

#######################################
# Stop the bot
#######################################
cmd_stop() {
	if [[ ! -f "$PID_FILE" ]]; then
		log_info "Bot is not running"
		return 0
	fi

	local pid
	pid=$(cat "$PID_FILE")

	if kill -0 "$pid" 2>/dev/null; then
		log_info "Stopping bot (PID: $pid)..."
		kill "$pid"

		# Wait for graceful shutdown
		local wait_count=0
		while kill -0 "$pid" 2>/dev/null && ((wait_count < 10)); do
			sleep 1
			((++wait_count))
		done

		if kill -0 "$pid" 2>/dev/null; then
			log_warn "Force killing bot..."
			kill -9 "$pid" 2>/dev/null || true
		fi

		log_success "Bot stopped"
	else
		log_info "Bot process not found (stale PID file)"
	fi

	rm -f "$PID_FILE"
	return 0
}

#######################################
# Show bot status
#######################################
cmd_status() {
	echo -e "${BOLD}Matrix Bot Status${NC}"
	echo "──────────────────────────────────"

	# Config
	if config_exists; then
		local homeserver
		homeserver=$(config_get "homeserverUrl")
		local default_runner
		default_runner=$(config_get "defaultRunner")
		local allowed_users
		allowed_users=$(config_get "allowedUsers")
		local prefix
		prefix=$(config_get "botPrefix")

		echo "Config: $CONFIG_FILE"
		echo "Homeserver: ${homeserver:-not set}"
		echo "Bot prefix: ${prefix:-!ai}"
		echo "Default runner: ${default_runner:-none}"
		echo "Allowed users: ${allowed_users:-all}"
	else
		echo "Config: not configured"
		echo "Run: matrix-dispatch-helper.sh setup"
		return 0
	fi

	echo ""

	# Process
	if [[ -f "$PID_FILE" ]]; then
		local pid
		pid=$(cat "$PID_FILE")
		if kill -0 "$pid" 2>/dev/null; then
			echo -e "Status: ${GREEN}running${NC} (PID: $pid)"
		else
			echo -e "Status: ${RED}stopped${NC} (stale PID)"
			rm -f "$PID_FILE"
		fi
	else
		echo -e "Status: ${YELLOW}stopped${NC}"
	fi

	echo ""

	# Room mappings
	echo "Room Mappings:"
	if config_exists; then
		local mappings
		mappings=$(jq -r '.roomMappings // {} | to_entries[] | "  \(.key) -> \(.value)"' "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$mappings" ]]; then
			echo "$mappings"
		else
			echo "  (none)"
		fi
	fi

	echo ""

	# OpenCode server
	if check_opencode_server; then
		echo -e "OpenCode server: ${GREEN}running${NC} (${OPENCODE_HOST}:${OPENCODE_PORT})"
	else
		echo -e "OpenCode server: ${RED}not responding${NC} (${OPENCODE_HOST}:${OPENCODE_PORT})"
	fi

	echo ""

	# Session store — check entity-aware store first, then legacy
	if [[ -f "$MEMORY_DB" ]] && command -v sqlite3 &>/dev/null &&
		sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT 1 FROM matrix_room_sessions LIMIT 1;" &>/dev/null; then
		local total_sessions active_sessions matrix_interactions entity_count
		total_sessions=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM matrix_room_sessions;" 2>/dev/null || echo "0")
		active_sessions=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM matrix_room_sessions WHERE session_id != '';" 2>/dev/null || echo "0")
		matrix_interactions=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM interactions WHERE channel = 'matrix';" 2>/dev/null || echo "0")
		entity_count=$(sqlite3 -cmd ".timeout 5000" "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE channel = 'matrix';" 2>/dev/null || echo "0")
		echo "Sessions: ${total_sessions} total, ${active_sessions} active"
		echo "Matrix interactions: ${matrix_interactions} (Layer 0, immutable)"
		echo "Matrix entities: ${entity_count}"
		echo -e "Entity integration: ${GREEN}enabled${NC}"
		echo "Session DB: $MEMORY_DB (shared memory.db)"
	elif [[ -f "$SESSION_DB" ]] && command -v sqlite3 &>/dev/null; then
		local total_sessions active_sessions
		total_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
		active_sessions=$(sqlite3 -cmd ".timeout 5000" "$SESSION_DB" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null || echo "0")
		echo "Sessions: ${total_sessions} total, ${active_sessions} active (legacy store)"
		echo -e "Entity integration: ${YELLOW}not yet active${NC} (run setup to enable)"
		echo "Session DB: $SESSION_DB"
	else
		echo "Sessions: (no database yet)"
		echo -e "Entity integration: ${YELLOW}not yet active${NC}"
	fi

	return 0
}

#######################################
# Map a room to a runner
#######################################
cmd_map() {
	local room_id="${1:-}"
	local runner_name="${2:-}"

	if [[ -z "$room_id" || -z "$runner_name" ]]; then
		log_error "Room ID and runner name required"
		echo "Usage: matrix-dispatch-helper.sh map '<room_id>' <runner-name>"
		echo ""
		echo "Get room IDs from Element: Room Settings > Advanced > Internal room ID"
		echo "Example: matrix-dispatch-helper.sh map '!abc123:matrix.example.com' code-reviewer"
		return 1
	fi

	if ! config_exists; then
		log_error "Bot not configured. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	# Check runner exists
	if [[ -x "$RUNNER_HELPER" ]] && ! "$RUNNER_HELPER" status "$runner_name" &>/dev/null 2>&1; then
		log_warn "Runner '$runner_name' not found. Create it with:"
		echo "  runner-helper.sh create $runner_name --description \"Description\""
	fi

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg room "$room_id" --arg runner "$runner_name" \
		'.roomMappings[$room] = $runner' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	log_success "Mapped room $room_id -> runner $runner_name"
	echo ""
	echo "Restart the bot to apply: matrix-dispatch-helper.sh stop && matrix-dispatch-helper.sh start --daemon"

	return 0
}

#######################################
# Remove a room mapping
#######################################
cmd_unmap() {
	local room_id="${1:-}"

	if [[ -z "$room_id" ]]; then
		log_error "Room ID required"
		echo "Usage: matrix-dispatch-helper.sh unmap '<room_id>'"
		return 1
	fi

	if ! config_exists; then
		log_error "Bot not configured"
		return 1
	fi

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg room "$room_id" 'del(.roomMappings[$room])' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE"

	log_success "Removed mapping for room $room_id"
	return 0
}

#######################################
# List room-to-runner mappings
#######################################
cmd_mappings() {
	if ! config_exists; then
		log_error "Bot not configured"
		return 1
	fi

	echo -e "${BOLD}Room-to-Runner Mappings${NC}"
	echo "──────────────────────────────────"

	local mappings
	mappings=$(jq -r '.roomMappings // {} | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG_FILE" 2>/dev/null)

	if [[ -z "$mappings" ]]; then
		echo "(no mappings)"
		echo ""
		echo "Add one with: matrix-dispatch-helper.sh map '<room_id>' <runner-name>"
		return 0
	fi

	printf "%-45s %s\n" "Room ID" "Runner"
	printf "%-45s %s\n" "─────────────────────────────────────────────" "──────────────────"

	while IFS=$'\t' read -r room runner; do
		printf "%-45s %s\n" "$room" "$runner"
	done <<<"$mappings"

	local default_runner
	default_runner=$(config_get "defaultRunner")
	if [[ -n "$default_runner" ]]; then
		echo ""
		echo "Default runner (unmapped rooms): $default_runner"
	fi

	return 0
}

#######################################
# Test dispatch without Matrix
#######################################
cmd_test() {
	local room_or_runner="${1:-}"
	local message="${2:-}"

	if [[ -z "$room_or_runner" || -z "$message" ]]; then
		log_error "Room/runner and message required"
		echo "Usage: matrix-dispatch-helper.sh test <room-id-or-runner> \"message\""
		return 1
	fi

	# Determine runner name
	local runner_name="$room_or_runner"
	if config_exists; then
		local mapped_runner
		mapped_runner=$(jq -r --arg room "$room_or_runner" '.roomMappings[$room] // empty' "$CONFIG_FILE" 2>/dev/null)
		if [[ -n "$mapped_runner" ]]; then
			runner_name="$mapped_runner"
			log_info "Room $room_or_runner maps to runner: $runner_name"
		fi
	fi

	log_info "Testing dispatch to runner: $runner_name"
	log_info "Message: $message"
	echo ""

	if [[ -x "$RUNNER_HELPER" ]]; then
		"$RUNNER_HELPER" run "$runner_name" "$message"
	else
		log_error "runner-helper.sh not found at $RUNNER_HELPER"
		return 1
	fi

	return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
	local tail_lines=50
	local follow=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tail)
			[[ $# -lt 2 ]] && {
				log_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
			;;
		--follow | -f)
			follow=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ ! -d "$LOG_DIR" ]]; then
		log_info "No logs found"
		return 0
	fi

	local latest
	latest=$(find "$LOG_DIR" -name "*.log" -type f 2>/dev/null | sort -r | head -1)

	if [[ -z "$latest" ]]; then
		log_info "No log files found"
		return 0
	fi

	if [[ "$follow" == "true" ]]; then
		log_info "Following: $(basename "$latest")"
		tail -f "$latest"
	else
		echo -e "${BOLD}Latest log: $(basename "$latest")${NC}"
		tail -n "$tail_lines" "$latest"
	fi

	return 0
}

#######################################
# Help: commands and usage overview
#######################################
_help_commands() {
	cat <<'EOF'
matrix-dispatch-helper.sh - Matrix bot for AI runner dispatch

USAGE:
    matrix-dispatch-helper.sh <command> [options]

COMMANDS:
    setup [--dry-run]           Interactive setup wizard (--dry-run to preview without saving)
    auto-setup <server> [opts]  Full automated provisioning (Cloudron + Synapse)
    start [--daemon]            Start the bot (foreground or daemon)
    stop                        Stop the bot (compacts all active sessions first)
    status                      Show bot status and configuration
    map <room> <runner>         Map a Matrix room to a runner
    unmap <room>                Remove a room mapping
    mappings                    List all room-to-runner mappings
    sessions [list|clear|stats] Manage per-channel conversation sessions
    test <room|runner> "msg"    Test dispatch without Matrix
    logs [--tail N] [--follow]  View bot logs
    help                        Show this help

SETUP:
    1. Create a Matrix bot account on your homeserver
    2. Run: matrix-dispatch-helper.sh setup
    3. Map rooms: matrix-dispatch-helper.sh map '!room:server' runner-name
    4. Start: matrix-dispatch-helper.sh start --daemon

MATRIX USAGE:
    In a mapped room, type:
        !ai Review the auth module for security issues
        !ai Generate unit tests for src/utils/

    The bot prefix (!ai) is configurable in setup.

ARCHITECTURE:
    Matrix Room → Bot receives message → Lookup room-to-runner mapping
    → Dispatch to runner via runner-helper.sh → Post response back to room

    ┌──────────────┐     ┌──────────────┐     ┌──────────────────┐
    │ Matrix Room   │────▶│ Matrix Bot   │────▶│ runner-helper.sh │
    │ !ai prompt    │     │ (Node.js)    │     │ → OpenCode       │
    │               │◀────│              │◀────│                  │
    │ AI response   │     │              │     │                  │
    └──────────────┘     └──────────────┘     └──────────────────┘
EOF
	return 0
}

#######################################
# Help: Synapse Admin API scripting functions
#######################################
_help_api_functions() {
	cat <<'EOF'
SYNAPSE ADMIN API FUNCTIONS (for scripting):
    Source this script to use these functions in your own scripts:
        source matrix-dispatch-helper.sh

    synapse_register_bot_user <homeserver_url> <admin_token> <user_id> <password> [display_name]
        Register a new bot user via Synapse Admin API
        Example: synapse_register_bot_user "https://matrix.example.com" "syt_..." "@bot:example.com" "secret123" "My Bot"

    matrix_login <homeserver_url> <user_id> <password>
        Login and get access token via Matrix Client API
        Example: matrix_login "https://matrix.example.com" "@bot:example.com" "secret123"

    matrix_create_room <homeserver_url> <access_token> <room_name> [room_alias] [is_public]
        Create a new Matrix room
        Example: matrix_create_room "https://matrix.example.com" "syt_..." "My Room" "myroom" "false"

    matrix_invite_user <homeserver_url> <access_token> <room_id> <user_id>
        Invite a user to a room
        Example: matrix_invite_user "https://matrix.example.com" "syt_..." "!abc:example.com" "@user:example.com"
EOF
	return 0
}

#######################################
# Help: auto-setup, requirements, configuration, and examples
#######################################
_help_setup_and_examples() {
	cat <<'EOF'
AUTO-SETUP (Cloudron + Synapse):
    Fully automated provisioning — installs Synapse, creates bot user,
    obtains access token, configures the bot, creates rooms, and maps runners.

    matrix-dispatch-helper.sh auto-setup <cloudron-server> [options]

    Options:
      --subdomain <name>     Synapse subdomain (default: matrix)
      --bot-user <name>      Bot username (default: aibot)
      --bot-display <name>   Bot display name (default: AI DevOps Bot)
      --runners <list>       Comma-separated runner names for room creation
      --allowed-users <list> Comma-separated allowed Matrix user IDs
      --dry-run              Show plan without executing
      --skip-install         Skip Synapse installation (already installed)
      --admin-token <token>  Use existing Synapse admin token

    Prerequisites:
      - Cloudron server configured in configs/cloudron-config.json
      - Cloudron API token set for the server
      - Synapse admin token stored via: aidevops secret set SYNAPSE_ADMIN_TOKEN_<server>

    Example:
      matrix-dispatch-helper.sh auto-setup cloudron01 \
        --runners code-reviewer,seo-analyst,ops-monitor \
        --allowed-users @admin:example.com

MANUAL CLOUDRON SETUP:
    1. Install Synapse on Cloudron (Matrix homeserver)
    2. Create bot user via Synapse Admin Console
    3. Login as bot via Element to get access token
    4. Run setup wizard with homeserver URL and token
    5. Invite bot to rooms, then map rooms to runners

REQUIREMENTS:
    - Node.js >= 18 (for matrix-bot-sdk)
    - jq (brew install jq)
    - OpenCode server running (opencode serve)
    - Matrix homeserver with bot account
    - runner-helper.sh (for runner dispatch)

CONFIGURATION:
    Config: ~/.config/aidevops/matrix-bot.json
    Data:   ~/.aidevops/.agent-workspace/matrix-bot/
    Logs:   ~/.aidevops/.agent-workspace/matrix-bot/logs/

EXAMPLES:
    # Automated setup (recommended)
    matrix-dispatch-helper.sh auto-setup cloudron01 \
      --runners code-reviewer,seo-analyst,ops-monitor \
      --allowed-users @admin:example.com

    # Dry run (preview without executing)
    matrix-dispatch-helper.sh auto-setup cloudron01 --dry-run

    # Manual setup flow
    matrix-dispatch-helper.sh setup
    runner-helper.sh create code-reviewer --description "Code review bot"
    matrix-dispatch-helper.sh map '!abc:matrix.example.com' code-reviewer
    matrix-dispatch-helper.sh start --daemon

    # Multiple rooms, different runners
    matrix-dispatch-helper.sh map '!dev:server' code-reviewer
    matrix-dispatch-helper.sh map '!seo:server' seo-analyst
    matrix-dispatch-helper.sh map '!ops:server' ops-monitor

    # Test without Matrix
    matrix-dispatch-helper.sh test code-reviewer "Review src/auth.ts"
EOF
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	_help_commands
	echo ""
	_help_api_functions
	echo ""
	_help_setup_and_examples
	return 0
}

#######################################
# Cleanup stale invites
# Rejects pending invites to rooms not in the room mappings
#######################################
cmd_cleanup_invites() {
	if ! config_exists; then
		log_error "Bot not configured. Run: matrix-dispatch-helper.sh setup"
		return 1
	fi

	local access_token
	access_token=$(config_get "accessToken")
	local homeserver
	homeserver=$(config_get "homeserverUrl")

	if [[ -z "$access_token" || -z "$homeserver" ]]; then
		log_error "Missing accessToken or homeserverUrl in config"
		return 1
	fi

	log_info "Fetching pending invites..."

	# Get sync data to find pending invites
	local sync_data
	sync_data=$(curl -sf "${homeserver}/_matrix/client/v3/sync?filter=%7B%22room%22%3A%7B%22timeline%22%3A%7B%22limit%22%3A0%7D%7D%7D" \
		-H "Authorization: Bearer $access_token" 2>/dev/null)

	if [[ -z "$sync_data" ]]; then
		log_error "Failed to fetch sync data from homeserver"
		return 1
	fi

	# Get invited room IDs
	local invited_rooms
	invited_rooms=$(echo "$sync_data" | jq -r '.rooms.invite // {} | keys[]' 2>/dev/null)

	if [[ -z "$invited_rooms" ]]; then
		log_info "No pending invites"
		return 0
	fi

	# Get mapped room IDs
	local mapped_rooms
	mapped_rooms=$(jq -r '.roomMappings // {} | keys[]' "$CONFIG_FILE" 2>/dev/null)

	local rejected=0
	while IFS= read -r room_id; do
		# Check if this room is in our mappings
		if echo "$mapped_rooms" | grep -qxF "$room_id"; then
			log_info "Keeping invite for mapped room: $room_id"
			continue
		fi

		# Get room name from invite state
		local room_name
		room_name=$(echo "$sync_data" | jq -r --arg rid "$room_id" \
			'.rooms.invite[$rid].invite_state.events[] | select(.type == "m.room.name") | .content.name // "unknown"' 2>/dev/null)

		log_info "Rejecting stale invite: $room_id ($room_name)"

		# URL-encode room_id safely — pass as argument, not interpolated into code
		local encoded_room
		encoded_room=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$room_id")

		# Leave (reject invite) — check exit code before counting
		local leave_ok=false
		if curl -sf -X POST "${homeserver}/_matrix/client/v3/rooms/${encoded_room}/leave" \
			-H "Authorization: Bearer $access_token" \
			-H "Content-Type: application/json" \
			-d '{}' >/dev/null 2>&1; then
			leave_ok=true
		fi

		# Forget the room
		if [[ "$leave_ok" == "true" ]]; then
			curl -sf -X POST "${homeserver}/_matrix/client/v3/rooms/${encoded_room}/forget" \
				-H "Authorization: Bearer $access_token" \
				-H "Content-Type: application/json" \
				-d '{}' >/dev/null 2>&1
			((++rejected))
		else
			log_error "Failed to leave room: $room_id"
		fi
	done <<<"$invited_rooms"

	if ((rejected > 0)); then
		log_success "Rejected $rejected stale invite(s)"
		echo "Restart the bot to apply: matrix-dispatch-helper.sh stop && matrix-dispatch-helper.sh start"
	else
		log_info "All pending invites are for mapped rooms"
	fi

	return 0
}

# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	setup) cmd_setup "$@" ;;
	auto-setup) cmd_auto_setup "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	status) cmd_status "$@" ;;
	map) cmd_map "$@" ;;
	unmap) cmd_unmap "$@" ;;
	mappings) cmd_mappings "$@" ;;
	sessions) cmd_sessions "$@" ;;
	test) cmd_test "$@" ;;
	logs) cmd_logs "$@" ;;
	cleanup-invites) cmd_cleanup_invites "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
