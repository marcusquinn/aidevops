#!/usr/bin/env bash
# simplex-helper.sh — SimpleX Chat CLI helper for aidevops
# Wraps common SimpleX CLI operations: install, init, bot management,
# message sending, connection management, group operations, and status.
#
# Usage:
#   simplex-helper.sh install [--verify]
#   simplex-helper.sh init [--name <bot-name>] [--port <port>] [--allow-files]
#   simplex-helper.sh bot-start [--port <port>] [--db <prefix>] [--background|--bg]
#   simplex-helper.sh bot-stop [--port <port>]
#   simplex-helper.sh send <contact> <message>
#   simplex-helper.sh send-group <group> <message>
#   simplex-helper.sh connect <link>
#   simplex-helper.sh address [--create|--show|--delete]
#   simplex-helper.sh group <name> [--create|--list|--add <contact>|--remove <contact>]
#   simplex-helper.sh status [--port <port>]
#   simplex-helper.sh server [--init|--start|--stop|--status] [--type <smp|xftp>] [--fqdn <domain>]
#   simplex-helper.sh help
#
# Options:
#   --port <port>       WebSocket port (default: 5225)
#   --db <prefix>       Database prefix (default: ~/.simplex/)
#   --name <name>       Bot display name
#   --allow-files       Allow file transfers for bot
#   --background, --bg  Run bot in background (detached)
#   --verify            Verify installation after install
#   --type <smp|xftp>   Server type for server subcommand
#   --fqdn <domain>     Fully qualified domain name for server init
#   --no-color          Disable color output
#
# Environment variables:
#   SIMPLEX_PORT          Default WebSocket port (default: 5225)
#   SIMPLEX_DB_PREFIX     Default database prefix
#   SIMPLEX_BOT_NAME      Default bot display name
#   SIMPLEX_PID_DIR       PID file directory (default: ~/.cache/simplex)
#
# Examples:
#   simplex-helper.sh install --verify
#   simplex-helper.sh init --name "AIBot" --port 5225 --allow-files
#   simplex-helper.sh bot-start --port 5225 --background
#   simplex-helper.sh bot-stop
#   simplex-helper.sh send "@alice" "Hello from aidevops"
#   simplex-helper.sh send-group "#devops" "Deploy complete"
#   simplex-helper.sh connect "simplex:/contact#..."
#   simplex-helper.sh address --create
#   simplex-helper.sh group mygroup --create
#   simplex-helper.sh group mygroup --add alice
#   simplex-helper.sh status
#   simplex-helper.sh server --init --type smp --fqdn smp.example.com

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

# shellcheck disable=SC2034
readonly VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" || {
	# shared-constants.sh is optional — defaults are defined below
	[[ "${SIMPLEX_DEBUG:-}" == "true" ]] && printf '[DEBUG] shared-constants.sh not found or failed to source\n' >&2
	true
}

readonly SIMPLEX_DEFAULT_PORT="${SIMPLEX_PORT:-5225}"
readonly SIMPLEX_DEFAULT_DB_PREFIX="${SIMPLEX_DB_PREFIX:-}"
readonly SIMPLEX_DEFAULT_BOT_NAME="${SIMPLEX_BOT_NAME:-AIBot}"
readonly PID_DIR="${SIMPLEX_PID_DIR:-${HOME}/.cache/simplex}"
readonly SIMPLEX_BIN="simplex-chat"
readonly INSTALL_URL="https://raw.githubusercontent.com/simplex-chat/simplex-chat/stable/install.sh"
readonly SERVER_INSTALL_URL="https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/install.sh"

# Color support
NO_COLOR="${NO_COLOR:-false}"

# =============================================================================
# Logging
# =============================================================================

log_info() {
	local msg="$1"
	if [[ "$NO_COLOR" == "false" ]]; then
		printf '\033[0;34m[INFO]\033[0m %s\n' "$msg" >&2
	else
		printf '[INFO] %s\n' "$msg" >&2
	fi
	return 0
}

log_success() {
	local msg="$1"
	if [[ "$NO_COLOR" == "false" ]]; then
		printf '\033[0;32m[OK]\033[0m %s\n' "$msg" >&2
	else
		printf '[OK] %s\n' "$msg" >&2
	fi
	return 0
}

log_warn() {
	local msg="$1"
	if [[ "$NO_COLOR" == "false" ]]; then
		printf '\033[1;33m[WARN]\033[0m %s\n' "$msg" >&2
	else
		printf '[WARN] %s\n' "$msg" >&2
	fi
	return 0
}

log_error() {
	local msg="$1"
	if [[ "$NO_COLOR" == "false" ]]; then
		printf '\033[0;31m[ERROR]\033[0m %s\n' "$msg" >&2
	else
		printf '[ERROR] %s\n' "$msg" >&2
	fi
	return 0
}

# =============================================================================
# Utility Functions
# =============================================================================

# Build a JSON command safely using jq (prevents JSON injection)
build_json_cmd() {
	local corr_id="$1"
	local cmd="$2"
	if command -v jq &>/dev/null; then
		jq -n --arg corrId "$corr_id" --arg cmd "$cmd" \
			'{"corrId": $corrId, "cmd": $cmd}'
	else
		# Fallback: escape backslashes first, then quotes, then control chars
		local safe_corr_id="${corr_id//\\/\\\\}"
		safe_corr_id="${safe_corr_id//\"/\\\"}"
		local safe_cmd="${cmd//\\/\\\\}"
		safe_cmd="${safe_cmd//\"/\\\"}"
		# Escape common control characters that break JSON
		safe_cmd="${safe_cmd//$'\n'/\\n}"
		safe_cmd="${safe_cmd//$'\t'/\\t}"
		safe_cmd="${safe_cmd//$'\r'/\\r}"
		printf '{"corrId":"%s","cmd":"%s"}' "$safe_corr_id" "$safe_cmd"
	fi
	return 0
}

# Require that a flag has a following argument
require_arg() {
	local flag="$1"
	local remaining="$2"
	if [[ "$remaining" -lt 2 ]]; then
		log_error "${flag} requires a value"
		return 1
	fi
	return 0
}

# Check if simplex-chat binary is available
check_simplex_installed() {
	if command -v "$SIMPLEX_BIN" &>/dev/null; then
		return 0
	fi
	log_error "simplex-chat not found. Run: simplex-helper.sh install"
	return 1
}

# Get PID file path for a given port
pid_file() {
	local port="$1"
	echo "${PID_DIR}/simplex-${port}.pid"
	return 0
}

# Check if a bot process is running on a given port
is_bot_running() {
	local port="$1"
	local pf
	pf="$(pid_file "$port")"
	if [[ -f "$pf" ]]; then
		local pid
		pid="$(cat "$pf")"
		if kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
		# Stale PID file
		rm -f "$pf"
	fi
	return 1
}

# Validate port number
validate_port() {
	local port="$1"
	if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
		return 0
	fi
	log_error "Invalid port: ${port}. Must be 1-65535."
	return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_install() {
	local verify="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--verify)
			verify="true"
			shift
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if command -v "$SIMPLEX_BIN" &>/dev/null; then
		local current_version
		current_version="$("$SIMPLEX_BIN" --version 2>/dev/null || echo "unknown")"
		log_info "simplex-chat already installed: ${current_version}"
		if [[ "$verify" == "true" ]]; then
			cmd_verify_install
			return $?
		fi
		return 0
	fi

	log_warn "This will download and execute an installer script from:"
	log_warn "  ${INSTALL_URL}"
	log_warn "Review the script at the URL above before proceeding."
	log_info "Downloading SimpleX Chat installer..."
	local installer
	installer="$(mktemp /tmp/simplex-install-XXXXXX.sh)"

	if ! curl -fsSLo "$installer" "$INSTALL_URL"; then
		log_error "Failed to download installer from ${INSTALL_URL}"
		rm -f "$installer"
		return 1
	fi

	log_info "Installing SimpleX Chat CLI..."
	if ! bash "$installer"; then
		log_error "Installation failed"
		rm -f "$installer"
		return 1
	fi
	rm -f "$installer"

	if [[ "$verify" == "true" ]]; then
		cmd_verify_install
		return $?
	fi

	log_success "SimpleX Chat CLI installed"
	return 0
}

cmd_verify_install() {
	if ! command -v "$SIMPLEX_BIN" &>/dev/null; then
		log_error "simplex-chat binary not found on PATH"
		return 1
	fi

	local version
	version="$("$SIMPLEX_BIN" --version 2>/dev/null || echo "unknown")"
	log_success "simplex-chat version: ${version}"

	# Check macOS Gatekeeper
	if [[ "$(uname -s)" == "Darwin" ]]; then
		log_info "macOS detected. If blocked by Gatekeeper: System Settings > Privacy & Security > Allow"
	fi

	return 0
}

cmd_init() {
	local name="$SIMPLEX_DEFAULT_BOT_NAME"
	local port="$SIMPLEX_DEFAULT_PORT"
	local allow_files="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			require_arg "--name" "$#" || return 1
			name="$2"
			shift 2
			;;
		--port)
			require_arg "--port" "$#" || return 1
			port="$2"
			shift 2
			;;
		--allow-files)
			allow_files="true"
			shift
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	validate_port "$port" || return 1
	check_simplex_installed || return 1

	log_info "Initializing SimpleX bot profile: ${name} on port ${port}"

	local cmd_args=("-p" "$port")
	cmd_args+=("--create-bot-display-name" "$name")

	if [[ "$allow_files" == "true" ]]; then
		cmd_args+=("--create-bot-allow-files")
	fi

	if [[ -n "$SIMPLEX_DEFAULT_DB_PREFIX" ]]; then
		cmd_args+=("-d" "$SIMPLEX_DEFAULT_DB_PREFIX")
	fi

	mkdir -p "$PID_DIR"

	log_info "Starting SimpleX CLI to create bot profile..."
	log_info "Command: ${SIMPLEX_BIN} ${cmd_args[*]}"
	log_info "The CLI will start interactively. Create your profile, then exit with /quit"

	"$SIMPLEX_BIN" "${cmd_args[@]}"

	log_success "Bot profile initialized: ${name}"
	return 0
}

cmd_bot_start() {
	local port="$SIMPLEX_DEFAULT_PORT"
	local db_prefix="$SIMPLEX_DEFAULT_DB_PREFIX"
	local background="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--port)
			require_arg "--port" "$#" || return 1
			port="$2"
			shift 2
			;;
		--db)
			require_arg "--db" "$#" || return 1
			db_prefix="$2"
			shift 2
			;;
		--background | --bg)
			background="true"
			shift
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	validate_port "$port" || return 1
	check_simplex_installed || return 1

	if is_bot_running "$port"; then
		local existing_pid
		existing_pid="$(cat "$(pid_file "$port")")"
		log_warn "Bot already running on port ${port} (PID: ${existing_pid})"
		return 0
	fi

	local cmd_args=("-p" "$port")
	if [[ -n "$db_prefix" ]]; then
		cmd_args+=("-d" "$db_prefix")
	fi

	mkdir -p "$PID_DIR"

	if [[ "$background" == "true" ]]; then
		local log_file="${PID_DIR}/simplex-${port}.log"
		log_info "Starting SimpleX CLI in background on port ${port}..."
		nohup "$SIMPLEX_BIN" "${cmd_args[@]}" >>"$log_file" 2>&1 &
		local pid=$!
		echo "$pid" >"$(pid_file "$port")"
		log_success "Bot started in background (PID: ${pid}, port: ${port}, log: ${log_file})"
	else
		log_info "Starting SimpleX CLI on port ${port} (foreground)..."
		"$SIMPLEX_BIN" "${cmd_args[@]}" &
		local pid=$!
		echo "$pid" >"$(pid_file "$port")"
		log_success "Bot started (PID: ${pid}, port: ${port})"
		wait "$pid" || true
		rm -f "$(pid_file "$port")"
	fi

	return 0
}

cmd_bot_stop() {
	local port="$SIMPLEX_DEFAULT_PORT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--port)
			require_arg "--port" "$#" || return 1
			port="$2"
			shift 2
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	validate_port "$port" || return 1

	local pf
	pf="$(pid_file "$port")"

	if [[ ! -f "$pf" ]]; then
		log_warn "No PID file found for port ${port}"
		return 0
	fi

	local pid
	pid="$(cat "$pf")"

	if kill -0 "$pid" 2>/dev/null; then
		log_info "Stopping bot on port ${port} (PID: ${pid})..."
		kill "$pid"
		# Wait up to 10 seconds for graceful shutdown
		local waited=0
		while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 10 ]]; do
			sleep 1
			waited=$((waited + 1))
		done
		if kill -0 "$pid" 2>/dev/null; then
			log_warn "Graceful shutdown timed out, sending SIGKILL..."
			kill -9 "$pid" 2>/dev/null || true
		fi
		log_success "Bot stopped (port: ${port})"
	else
		log_info "Bot not running (stale PID file)"
	fi

	rm -f "$pf"
	return 0
}

cmd_send() {
	local contact="${1:-}"
	local message="${2:-}"

	if [[ -z "$contact" ]] || [[ -z "$message" ]]; then
		log_error "Usage: simplex-helper.sh send <contact> <message>"
		log_error "  contact: @name for direct, #group for group"
		return 1
	fi

	check_simplex_installed || return 1

	# Determine if this is a contact or group message
	local prefix="${contact:0:1}"
	if [[ "$prefix" != "@" ]] && [[ "$prefix" != "#" ]]; then
		contact="@${contact}"
	fi

	log_info "Sending message to ${contact}..."

	# Use the WebSocket API if a bot is running, otherwise use CLI directly
	local port="$SIMPLEX_DEFAULT_PORT"
	if is_bot_running "$port"; then
		# Send via WebSocket JSON API
		local corr_id
		corr_id="$(date +%s)-${RANDOM}-${BASHPID}"
		local json_msg
		json_msg=$(build_json_cmd "$corr_id" "${contact} ${message}")

		if command -v websocat &>/dev/null; then
			echo "$json_msg" | websocat "ws://127.0.0.1:${port}" --one-message
			log_success "Message sent via WebSocket API"
		else
			log_warn "websocat not installed. Install with: brew install websocat (or cargo install websocat)"
			log_info "Falling back to CLI command..."
			echo "${contact} ${message}" | "$SIMPLEX_BIN" -p "$port" || true
		fi
	else
		log_warn "No bot running. Starting CLI to send message..."
		echo "${contact} ${message}" | "$SIMPLEX_BIN" || true
	fi

	return 0
}

cmd_send_group() {
	local group="${1:-}"
	local message="${2:-}"

	if [[ -z "$group" ]] || [[ -z "$message" ]]; then
		log_error "Usage: simplex-helper.sh send-group <group> <message>"
		return 1
	fi

	# Ensure group prefix
	if [[ "${group:0:1}" != "#" ]]; then
		group="#${group}"
	fi

	cmd_send "$group" "$message"
	return $?
}

cmd_connect() {
	local link="${1:-}"

	if [[ -z "$link" ]]; then
		log_error "Usage: simplex-helper.sh connect <link>"
		log_error "  link: SimpleX invitation or contact address link"
		return 1
	fi

	check_simplex_installed || return 1

	log_info "Connecting via link..."

	local port="$SIMPLEX_DEFAULT_PORT"
	if is_bot_running "$port"; then
		local corr_id
		corr_id="$(date +%s)-${RANDOM}-${BASHPID}"
		local json_cmd
		json_cmd=$(build_json_cmd "$corr_id" "/c ${link}")

		if command -v websocat &>/dev/null; then
			echo "$json_cmd" | websocat "ws://127.0.0.1:${port}" --one-message
			log_success "Connection request sent via WebSocket API"
		else
			log_warn "websocat not installed. Using CLI..."
			echo "/c ${link}" | "$SIMPLEX_BIN" || true
		fi
	else
		log_info "Starting CLI to connect..."
		echo "/c ${link}" | "$SIMPLEX_BIN" || true
	fi

	return 0
}

cmd_address() {
	local action="show"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--create)
			action="create"
			shift
			;;
		--show)
			action="show"
			shift
			;;
		--delete)
			action="delete"
			shift
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	check_simplex_installed || return 1

	local port="$SIMPLEX_DEFAULT_PORT"
	local cli_cmd=""

	case "$action" in
	create) cli_cmd="/ad" ;;
	show) cli_cmd="/sa" ;;
	delete) cli_cmd="/da" ;;
	esac

	log_info "Address operation: ${action}"

	if is_bot_running "$port"; then
		local corr_id
		corr_id="$(date +%s)-${RANDOM}-${BASHPID}"
		local json_cmd
		json_cmd=$(build_json_cmd "$corr_id" "$cli_cmd")

		if command -v websocat &>/dev/null; then
			echo "$json_cmd" | websocat "ws://127.0.0.1:${port}" --one-message
		else
			log_warn "websocat not installed"
			echo "$cli_cmd" | "$SIMPLEX_BIN" || true
		fi
	else
		echo "$cli_cmd" | "$SIMPLEX_BIN" || true
	fi

	return 0
}

cmd_group() {
	local group_name="${1:-}"
	shift || true

	if [[ -z "$group_name" ]]; then
		log_error "Usage: simplex-helper.sh group <name> [--create|--list|--add <contact>|--remove <contact>]"
		return 1
	fi

	local action="list"
	local contact=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--create)
			action="create"
			shift
			;;
		--list)
			action="list"
			shift
			;;
		--add)
			require_arg "--add" "$#" || return 1
			action="add"
			contact="$2"
			shift 2
			;;
		--remove)
			require_arg "--remove" "$#" || return 1
			action="remove"
			contact="$2"
			shift 2
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	check_simplex_installed || return 1

	local cli_cmd=""
	case "$action" in
	create) cli_cmd="/g ${group_name}" ;;
	list) cli_cmd="/ms ${group_name}" ;;
	add)
		if [[ -z "$contact" ]]; then
			log_error "Contact name required for --add"
			return 1
		fi
		cli_cmd="/a ${group_name} ${contact}"
		;;
	remove)
		if [[ -z "$contact" ]]; then
			log_error "Contact name required for --remove"
			return 1
		fi
		cli_cmd="/rm ${group_name} ${contact}"
		;;
	esac

	log_info "Group operation: ${action} on ${group_name}"

	local port="$SIMPLEX_DEFAULT_PORT"
	if is_bot_running "$port"; then
		local corr_id
		corr_id="$(date +%s)-${RANDOM}-${BASHPID}"
		local json_cmd
		json_cmd=$(build_json_cmd "$corr_id" "$cli_cmd")

		if command -v websocat &>/dev/null; then
			echo "$json_cmd" | websocat "ws://127.0.0.1:${port}" --one-message
		else
			echo "$cli_cmd" | "$SIMPLEX_BIN" || true
		fi
	else
		echo "$cli_cmd" | "$SIMPLEX_BIN" || true
	fi

	return 0
}

cmd_status() {
	local port="$SIMPLEX_DEFAULT_PORT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--port)
			require_arg "--port" "$#" || return 1
			port="$2"
			shift 2
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	echo "SimpleX Chat Status"
	echo "==================="
	echo ""

	# Check binary
	if command -v "$SIMPLEX_BIN" &>/dev/null; then
		local version
		version="$("$SIMPLEX_BIN" --version 2>/dev/null || echo "unknown")"
		echo "Binary:    installed (${version})"
	else
		echo "Binary:    NOT INSTALLED"
	fi

	# Check bot process
	if is_bot_running "$port"; then
		local pid
		pid="$(cat "$(pid_file "$port")")"
		echo "Bot:       running (PID: ${pid}, port: ${port})"
	else
		echo "Bot:       not running (port: ${port})"
	fi

	# Check database
	local db_dir="${HOME}/.simplex"
	if [[ -d "$db_dir" ]]; then
		local db_count
		db_count="$(find "$db_dir" -name "*.db" 2>/dev/null | wc -l | tr -d ' ')"
		echo "Database:  ${db_dir} (${db_count} files)"
	else
		echo "Database:  not initialized"
	fi

	# Check PID directory
	if [[ -d "$PID_DIR" ]]; then
		local pid_count
		pid_count="$(find "$PID_DIR" -name "*.pid" 2>/dev/null | wc -l | tr -d ' ')"
		echo "PID files: ${pid_count}"
	fi

	# Check websocat
	if command -v websocat &>/dev/null; then
		echo "websocat:  installed"
	else
		echo "websocat:  not installed (optional, for WebSocket API)"
	fi

	echo ""
	return 0
}

cmd_server() {
	local action=""
	local server_type="smp"
	local fqdn=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--init)
			action="init"
			shift
			;;
		--start)
			action="start"
			shift
			;;
		--stop)
			action="stop"
			shift
			;;
		--status)
			action="status"
			shift
			;;
		--type)
			require_arg "--type" "$#" || return 1
			server_type="$2"
			shift 2
			;;
		--fqdn)
			require_arg "--fqdn" "$#" || return 1
			fqdn="$2"
			shift 2
			;;
		--no-color)
			NO_COLOR="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$action" ]]; then
		log_error "Usage: simplex-helper.sh server [--init|--start|--stop|--status] [--type smp|xftp] [--fqdn domain]"
		return 1
	fi

	case "$server_type" in
	smp | xftp) ;;
	*)
		log_error "Invalid server type: ${server_type}. Must be 'smp' or 'xftp'."
		return 1
		;;
	esac

	local service_name="${server_type}-server"

	case "$action" in
	init)
		if [[ -z "$fqdn" ]]; then
			log_error "FQDN required for server init: --fqdn <domain>"
			return 1
		fi

		log_warn "This will download and execute a server installer script from:"
		log_warn "  ${SERVER_INSTALL_URL}"
		log_warn "Review the script at the URL above before proceeding."
		log_info "Downloading SimpleX server installer..."
		local installer
		installer="$(mktemp /tmp/simplex-server-install-XXXXXX.sh)"

		if ! curl -fsSLo "$installer" "$SERVER_INSTALL_URL"; then
			log_error "Failed to download server installer"
			rm -f "$installer"
			return 1
		fi

		log_info "Running server installer (choose option for ${server_type}-server)..."
		if ! bash "$installer"; then
			log_error "Server installation failed"
			rm -f "$installer"
			return 1
		fi
		rm -f "$installer"

		log_info "Initialize the server:"
		if [[ "$server_type" == "smp" ]]; then
			log_info "  su smp -c 'smp-server init --yes --store-log --control-port --fqdn=${fqdn}'"
		else
			log_info "  su xftp -c 'xftp-server init -l --fqdn=${fqdn} -q 100gb -p /srv/xftp/'"
		fi
		;;
	start)
		log_info "Starting ${service_name}..."
		if command -v systemctl &>/dev/null; then
			sudo systemctl enable --now "${service_name}.service"
			log_success "${service_name} started"
		else
			log_error "systemctl not available. Start the server manually."
			return 1
		fi
		;;
	stop)
		log_info "Stopping ${service_name}..."
		if command -v systemctl &>/dev/null; then
			sudo systemctl stop "${service_name}.service"
			log_success "${service_name} stopped"
		else
			log_error "systemctl not available. Stop the server manually."
			return 1
		fi
		;;
	status)
		if command -v systemctl &>/dev/null; then
			systemctl status "${service_name}.service" 2>/dev/null || log_info "${service_name} not found or not running"
		else
			log_info "systemctl not available"
		fi
		;;
	esac

	return 0
}

cmd_help() {
	cat <<'HELP'
simplex-helper.sh — SimpleX Chat CLI helper for aidevops

Usage:
  simplex-helper.sh <command> [options]

Commands:
  install [--verify]                Install SimpleX Chat CLI
  init [--name N] [--port P]        Initialize bot profile
  bot-start [--port P] [--bg]       Start SimpleX CLI as WebSocket server
  bot-stop [--port P]               Stop running bot process
  send <contact> <message>          Send message to contact (@name) or group (#name)
  send-group <group> <message>      Send message to group
  connect <link>                    Connect via invitation/address link
  address [--create|--show|--delete] Manage contact address
  group <name> [--create|--list|--add|--remove] Group operations
  status [--port P]                 Show SimpleX status
  server [--init|--start|--stop|--status] Self-hosted server management
  help                              Show this help

Options:
  --port <port>       WebSocket port (default: 5225)
  --db <prefix>       Database prefix
  --name <name>       Bot display name (default: AIBot)
  --allow-files       Allow file transfers for bot
  --background, --bg  Run bot in background
  --verify            Verify installation
  --type <smp|xftp>   Server type
  --fqdn <domain>     Domain for server init
  --no-color          Disable color output

Environment:
  SIMPLEX_PORT          Default WebSocket port (5225)
  SIMPLEX_DB_PREFIX     Default database prefix
  SIMPLEX_BOT_NAME      Default bot display name
  SIMPLEX_PID_DIR       PID file directory

Examples:
  simplex-helper.sh install --verify
  simplex-helper.sh init --name "MyBot" --allow-files
  simplex-helper.sh bot-start --background
  simplex-helper.sh send "@alice" "Hello!"
  simplex-helper.sh status

See also:
  .agents/services/communications/simplex.md
  https://simplex.chat/docs/
  https://github.com/simplex-chat/simplex-chat/tree/stable/bots
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Global flag processing
	local args=()
	for arg in "$@"; do
		case "$arg" in
		--no-color) NO_COLOR="true" ;;
		*) args+=("$arg") ;;
		esac
	done
	set -- "${args[@]+"${args[@]}"}"

	case "$command" in
	install) cmd_install "$@" ;;
	init) cmd_init "$@" ;;
	bot-start) cmd_bot_start "$@" ;;
	bot-stop) cmd_bot_stop "$@" ;;
	send) cmd_send "$@" ;;
	send-group) cmd_send_group "$@" ;;
	connect) cmd_connect "$@" ;;
	address) cmd_address "$@" ;;
	group) cmd_group "$@" ;;
	status) cmd_status "$@" ;;
	server) cmd_server "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: ${command}"
		log_error "Run 'simplex-helper.sh help' for usage"
		return 1
		;;
	esac
}

main "$@"
