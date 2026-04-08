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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

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

readonly BOLD='\033[1m'

# Logging: uses shared log_* from shared-constants.sh with MATRIX prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="MATRIX"

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

#######################################
# Generate the session store module
#######################################
generate_session_store_script() {
	cat "$SCRIPT_DIR/matrix-session-store.mjs.template" >"$SESSION_STORE_SCRIPT"
	log_info "Generated session store script: $SESSION_STORE_SCRIPT"
}
generate_bot_script() {
	cat "$SCRIPT_DIR/matrix-bot.mjs.template" >"$BOT_SCRIPT"
	log_info "Generated bot script: $BOT_SCRIPT"
}
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
# Resolve session DB path and table name
# Outputs two lines: db_path, table_name
# Args: subcmd (used for empty-DB messaging)
#######################################
_sessions_resolve_db() {
	local subcmd="$1"
	local db_path="$MEMORY_DB"
	local table_name="matrix_room_sessions"

	if [[ ! -f "$db_path" ]] || ! sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT 1 FROM $table_name LIMIT 1;" &>/dev/null; then
		if [[ -f "$SESSION_DB" ]]; then
			db_path="$SESSION_DB"
			table_name="sessions"
			log_info "Using legacy session store: $SESSION_DB"
		else
			if [[ "$subcmd" == "list" ]]; then
				echo -e "${BOLD}Conversation Sessions${NC}"
				echo "──────────────────────────────────"
				echo "(no sessions — database not yet created)"
				echo "Sessions are created automatically when the bot processes messages."
			else
				log_info "No session database"
			fi
			printf 'NONE\nNONE\n'
			return 0
		fi
	fi

	printf '%s\n%s\n' "$db_path" "$table_name"
	return 0
}

#######################################
# List sessions from entity-aware store
# Args: db_path
#######################################
_sessions_list_entity_aware() {
	local db_path="$1"
	local sessions
	sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$db_path" \
		"SELECT s.room_id, s.runner_name, s.message_count, COALESCE(e.name, ''), s.entity_id, s.last_active
		 FROM matrix_room_sessions s
		 LEFT JOIN entities e ON s.entity_id = e.id
		 ORDER BY s.last_active DESC;" 2>/dev/null)

	if [[ -z "$sessions" ]]; then
		echo "(no sessions)"
		return 0
	fi

	printf "%-35s %-15s %5s %-20s %s\n" "Room ID" "Runner" "Msgs" "Entity" "Last Active"
	printf "%-35s %-15s %5s %-20s %s\n" "───────────────────────────────────" "───────────────" "─────" "────────────────────" "───────────────────"

	while IFS='|' read -r room runner msgs entity_name entity_id active; do
		local entity_display="${entity_name:-${entity_id:-(none)}}"
		printf "%-35s %-15s %5s %-20s %s\n" "$room" "$runner" "$msgs" "$entity_display" "$active"
	done <<<"$sessions"
	return 0
}

#######################################
# List sessions from legacy store
# Args: db_path
#######################################
_sessions_list_legacy() {
	local db_path="$1"
	local sessions
	sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$db_path" \
		"SELECT room_id, runner_name, message_count, length(compacted_context), last_active FROM sessions ORDER BY last_active DESC;" 2>/dev/null)

	if [[ -z "$sessions" ]]; then
		echo "(no sessions)"
		return 0
	fi

	printf "%-40s %-18s %6s %8s %s\n" "Room ID" "Runner" "Msgs" "Context" "Last Active"
	printf "%-40s %-18s %6s %8s %s\n" "────────────────────────────────────────" "──────────────────" "──────" "────────" "───────────────────"

	while IFS='|' read -r room runner msgs ctx_bytes active; do
		local ctx_display
		if [[ "$ctx_bytes" -gt 1024 ]]; then
			ctx_display="$((ctx_bytes / 1024))KB"
		else
			ctx_display="${ctx_bytes}B"
		fi
		printf "%-40s %-18s %6s %8s %s\n" "$room" "$runner" "$msgs" "$ctx_display" "$active"
	done <<<"$sessions"
	return 0
}

#######################################
# Show stats from entity-aware store
# Args: db_path
#######################################
_sessions_stats_entity_aware() {
	local db_path="$1"
	local total_sessions active_sessions matrix_interactions entity_count db_size
	total_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM matrix_room_sessions;" 2>/dev/null || echo "0")
	active_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM matrix_room_sessions WHERE session_id != '';" 2>/dev/null || echo "0")
	matrix_interactions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM interactions WHERE channel = 'matrix';" 2>/dev/null || echo "0")
	entity_count=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM entity_channels WHERE channel = 'matrix';" 2>/dev/null || echo "0")
	# Linux stat -c first (stat -f%z on Linux outputs filesystem info to stdout)
	db_size=$(stat -c%s "$db_path" 2>/dev/null || stat -f%z "$db_path" 2>/dev/null || echo "0")

	echo "Total sessions:       ${total_sessions:-0}"
	echo "Active sessions:      ${active_sessions:-0}"
	echo "Matrix interactions:  ${matrix_interactions:-0} (Layer 0, immutable)"
	echo "Matrix entities:      ${entity_count:-0}"
	echo "Database:             $db_path ($((${db_size:-0} / 1024))KB)"
	return 0
}

#######################################
# Show stats from legacy store
# Args: db_path
#######################################
_sessions_stats_legacy() {
	local db_path="$1"
	local total_sessions active_sessions total_messages context_bytes db_size
	total_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
	active_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null || echo "0")
	total_messages=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM message_log;" 2>/dev/null || echo "0")
	context_bytes=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COALESCE(SUM(length(compacted_context)), 0) FROM sessions;" 2>/dev/null || echo "0")
	# Linux stat -c first (stat -f%z on Linux outputs filesystem info to stdout)
	db_size=$(stat -c%s "$db_path" 2>/dev/null || stat -f%z "$db_path" 2>/dev/null || echo "0")

	echo "Total sessions:    ${total_sessions:-0} (legacy store)"
	echo "Active sessions:   ${active_sessions:-0}"
	echo "Messages in log:   ${total_messages:-0}"
	echo "Compacted context: $((${context_bytes:-0} / 1024))KB"
	echo "Database size:     $((${db_size:-0} / 1024))KB"
	return 0
}

#######################################
# Manage conversation sessions
#######################################
cmd_sessions() {
	local subcmd="${1:-list}"
	shift || true

	if ! command -v sqlite3 &>/dev/null; then
		log_error "sqlite3 required for session management"
		return 1
	fi

	ensure_dirs

	local db_info db_path table_name
	db_info=$(_sessions_resolve_db "$subcmd")
	db_path=$(printf '%s' "$db_info" | sed -n '1p')
	table_name=$(printf '%s' "$db_info" | sed -n '2p')

	if [[ "$db_path" == "NONE" ]]; then
		return 0
	fi

	case "$subcmd" in
	list)
		echo -e "${BOLD}Conversation Sessions${NC}"
		echo "──────────────────────────────────"
		if [[ "$table_name" == "matrix_room_sessions" ]]; then
			_sessions_list_entity_aware "$db_path"
		else
			_sessions_list_legacy "$db_path"
		fi
		;;

	clear)
		local room_id="${1:-}"
		if [[ -z "$room_id" ]]; then
			log_error "Room ID required"
			echo "Usage: matrix-dispatch-helper.sh sessions clear '<room_id>'"
			return 1
		fi
		# Clear from entity-aware table (Layer 0 interactions are preserved — immutable)
		sqlite3 -cmd ".timeout 5000" "$db_path" \
			"DELETE FROM $table_name WHERE room_id = '$(printf '%s' "$room_id" | sed "s/'/''/g")';" 2>/dev/null
		log_success "Cleared session for room $room_id"
		log_info "Note: Layer 0 interactions are preserved (immutable). Only session state was cleared."
		;;

	clear-all)
		sqlite3 -cmd ".timeout 5000" "$db_path" \
			"DELETE FROM $table_name;" 2>/dev/null
		log_success "Cleared all sessions"
		log_info "Note: Layer 0 interactions are preserved (immutable). Only session state was cleared."
		;;

	stats)
		echo -e "${BOLD}Session Statistics${NC}"
		echo "──────────────────────────────────"
		if [[ "$table_name" == "matrix_room_sessions" ]]; then
			_sessions_stats_entity_aware "$db_path"
		else
			_sessions_stats_legacy "$db_path"
		fi
		;;

	*)
		log_error "Unknown sessions subcommand: $subcmd"
		echo "Usage: matrix-dispatch-helper.sh sessions [list|clear <room>|clear-all|stats]"
		return 1
		;;
	esac

	return 0
}

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
