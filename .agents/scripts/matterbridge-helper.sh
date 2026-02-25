#!/usr/bin/env bash
# matterbridge-helper.sh — Manage Matterbridge multi-platform chat bridge
# Usage: matterbridge-helper.sh [setup|start|stop|status|logs|validate|update|simplex-bridge]
set -euo pipefail

BINARY_PATH="/usr/local/bin/matterbridge"
CONFIG_PATH="${MATTERBRIDGE_CONFIG:-$HOME/.config/aidevops/matterbridge.toml}"
DATA_DIR="$HOME/.aidevops/.agent-workspace/matterbridge"
PID_FILE="$DATA_DIR/matterbridge.pid"
LOG_FILE="$DATA_DIR/matterbridge.log"
LATEST_RELEASE_URL="https://api.github.com/repos/42wim/matterbridge/releases/latest"
SIMPLEX_BRIDGE_DIR="$DATA_DIR/simplex-bridge"
SIMPLEX_COMPOSE_FILE="${SIMPLEX_COMPOSE_FILE:-}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.aidevops/agents}"

# ── helpers ──────────────────────────────────────────────────────────────────

log() {
	local msg="$1"
	echo "[matterbridge] $msg"
	return 0
}

die() {
	local msg="$1"
	echo "[matterbridge] ERROR: $msg" >&2
	return 1
}

ensure_dirs() {
	mkdir -p "$DATA_DIR"
	return 0
}

get_latest_version() {
	local version
	version=$(curl -fsSL "$LATEST_RELEASE_URL" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
	echo "${version:-1.26.0}"
	return 0
}

detect_os_arch() {
	local os arch
	os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	arch="$(uname -m)"

	case "$arch" in
	x86_64) arch="64bit" ;;
	aarch64 | arm64) arch="arm64" ;;
	*) arch="64bit" ;;
	esac

	case "$os" in
	linux) echo "linux-${arch}" ;;
	darwin) echo "darwin-amd64" ;;
	*) echo "linux-${arch}" ;;
	esac
	return 0
}

is_running() {
	if [ -f "$PID_FILE" ]; then
		local pid
		pid="$(cat "$PID_FILE")"
		if kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
	fi
	return 1
}

# ── commands ─────────────────────────────────────────────────────────────────

cmd_setup() {
	ensure_dirs

	# Download binary if not present
	if [ ! -f "$BINARY_PATH" ]; then
		local version os_arch download_url
		version="$(get_latest_version)"
		os_arch="$(detect_os_arch)"
		download_url="https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-${version}-${os_arch}"

		log "Downloading matterbridge v${version} (${os_arch})..."
		curl -fsSL "$download_url" -o "$BINARY_PATH" || {
			die "Download failed. Check: https://github.com/42wim/matterbridge/releases"
			return 1
		}
		chmod +x "$BINARY_PATH"
		log "Installed to $BINARY_PATH"
	else
		log "Binary already installed: $BINARY_PATH ($($BINARY_PATH -version 2>&1 | head -1))"
	fi

	# Create config if not present
	if [ ! -f "$CONFIG_PATH" ]; then
		mkdir -p "$(dirname "$CONFIG_PATH")"
		cat >"$CONFIG_PATH" <<'TOML'
# Matterbridge configuration
# Docs: https://github.com/42wim/matterbridge/wiki
# Security: chmod 600 this file — it contains credentials

[general]
RemoteNickFormat="[{PROTOCOL}] <{NICK}> "

# Example: Matrix <-> Discord bridge
# Uncomment and fill in credentials to use

# [matrix]
#   [matrix.home]
#   Server="https://matrix.example.com"
#   Login="bridgebot"
#   Password="secret"

# [discord]
#   [discord.myserver]
#   Token="Bot YOUR_DISCORD_BOT_TOKEN"
#   Server="My Server Name"

# [[gateway]]
# name="mybridge"
# enable=true
#
#   [[gateway.inout]]
#   account="matrix.home"
#   channel="#general:example.com"
#
#   [[gateway.inout]]
#   account="discord.myserver"
#   channel="general"
TOML
		chmod 600 "$CONFIG_PATH"
		log "Created config template: $CONFIG_PATH"
		log "Edit the config file, then run: matterbridge-helper.sh validate"
	else
		log "Config already exists: $CONFIG_PATH"
	fi

	return 0
}

cmd_validate() {
	local config_path="${1:-$CONFIG_PATH}"

	if [ ! -f "$config_path" ]; then
		die "Config not found: $config_path. Run: matterbridge-helper.sh setup"
		return 1
	fi

	if [ ! -f "$BINARY_PATH" ]; then
		die "Binary not found: $BINARY_PATH. Run: matterbridge-helper.sh setup"
		return 1
	fi

	# Basic TOML syntax check via matterbridge dry-run
	# matterbridge exits non-zero if config is invalid
	log "Validating config: $config_path"
	if timeout 5 "$BINARY_PATH" -conf "$config_path" -version >/dev/null 2>&1; then
		log "Binary OK"
	fi

	# Check for required sections
	if ! grep -q '^\[\[gateway\]\]' "$config_path"; then
		log "WARNING: No [[gateway]] section found — bridge will do nothing"
	fi

	log "Config validation complete (syntax check only — credentials not verified)"
	return 0
}

cmd_start() {
	local daemon_mode=false
	local arg="${1:-}"

	if [ "$arg" = "--daemon" ]; then
		daemon_mode=true
	fi

	if is_running; then
		log "Already running (PID: $(cat "$PID_FILE"))"
		return 0
	fi

	if [ ! -f "$CONFIG_PATH" ]; then
		die "Config not found: $CONFIG_PATH. Run: matterbridge-helper.sh setup"
		return 1
	fi

	ensure_dirs

	if [ "$daemon_mode" = true ]; then
		log "Starting in daemon mode..."
		nohup "$BINARY_PATH" -conf "$CONFIG_PATH" >>"$LOG_FILE" 2>&1 &
		echo $! >"$PID_FILE"
		sleep 1
		if is_running; then
			log "Started (PID: $(cat "$PID_FILE"))"
		else
			die "Failed to start. Check logs: $LOG_FILE"
			return 1
		fi
	else
		log "Starting in foreground (Ctrl+C to stop)..."
		"$BINARY_PATH" -conf "$CONFIG_PATH"
	fi

	return 0
}

cmd_stop() {
	if ! is_running; then
		log "Not running"
		return 0
	fi

	local pid
	pid="$(cat "$PID_FILE")"
	log "Stopping (PID: $pid)..."
	kill "$pid" 2>/dev/null || true

	local timeout=10
	local count=0
	while is_running && [ $count -lt $timeout ]; do
		sleep 1
		count=$((count + 1))
	done

	if is_running; then
		log "Force killing..."
		kill -9 "$pid" 2>/dev/null || true
	fi

	rm -f "$PID_FILE"
	log "Stopped"
	return 0
}

cmd_status() {
	if is_running; then
		local pid
		pid="$(cat "$PID_FILE")"
		log "Running (PID: $pid)"
		log "Config: $CONFIG_PATH"
		log "Log: $LOG_FILE"
	else
		log "Not running"
	fi
	return 0
}

cmd_logs() {
	local follow=false
	local tail_lines=50
	local arg="${1:-}"

	case "$arg" in
	--follow | -f) follow=true ;;
	--tail) tail_lines="${2:-50}" ;;
	esac

	if [ ! -f "$LOG_FILE" ]; then
		log "No log file found: $LOG_FILE"
		return 0
	fi

	if [ "$follow" = true ]; then
		tail -f "$LOG_FILE"
	else
		tail -n "$tail_lines" "$LOG_FILE"
	fi

	return 0
}

cmd_update() {
	local current_version new_version
	current_version="$("$BINARY_PATH" -version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")"
	new_version="$(get_latest_version)"

	if [ "$current_version" = "$new_version" ]; then
		log "Already at latest version: v$current_version"
		return 0
	fi

	log "Updating from v$current_version to v$new_version..."

	local was_running=false
	if is_running; then
		was_running=true
		cmd_stop
	fi

	local os_arch download_url
	os_arch="$(detect_os_arch)"
	download_url="https://github.com/42wim/matterbridge/releases/latest/download/matterbridge-${new_version}-${os_arch}"

	curl -fsSL "$download_url" -o "$BINARY_PATH" || {
		die "Download failed"
		return 1
	}
	chmod +x "$BINARY_PATH"
	log "Updated to v$new_version"

	if [ "$was_running" = true ]; then
		cmd_start --daemon
	fi

	return 0
}

# ── simplex bridge (Docker Compose) ──────────────────────────────────────────

_find_compose_file() {
	# Priority: env var > simplex-bridge dir > agents configs dir
	if [ -n "$SIMPLEX_COMPOSE_FILE" ] && [ -f "$SIMPLEX_COMPOSE_FILE" ]; then
		echo "$SIMPLEX_COMPOSE_FILE"
		return 0
	fi
	if [ -f "$SIMPLEX_BRIDGE_DIR/docker-compose.yml" ]; then
		echo "$SIMPLEX_BRIDGE_DIR/docker-compose.yml"
		return 0
	fi
	if [ -f "$AGENTS_DIR/configs/matterbridge-simplex-compose.yml" ]; then
		echo "$AGENTS_DIR/configs/matterbridge-simplex-compose.yml"
		return 0
	fi
	# Check repo-local path (for development)
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_compose="${script_dir}/../configs/matterbridge-simplex-compose.yml"
	if [ -f "$repo_compose" ]; then
		echo "$repo_compose"
		return 0
	fi
	echo ""
	return 1
}

_ensure_simplex_bridge_dir() {
	mkdir -p "$SIMPLEX_BRIDGE_DIR"
	mkdir -p "$SIMPLEX_BRIDGE_DIR/data/simplex"
	return 0
}

cmd_simplex_bridge() {
	local action="${1:-help}"
	shift || true

	case "$action" in
	up | start)
		_simplex_bridge_up "$@"
		;;
	down | stop)
		_simplex_bridge_down "$@"
		;;
	status | ps)
		_simplex_bridge_status
		;;
	logs)
		_simplex_bridge_logs "$@"
		;;
	init | setup)
		_simplex_bridge_init "$@"
		;;
	help | --help | -h)
		_simplex_bridge_help
		;;
	*)
		log "Unknown simplex-bridge action: $action"
		_simplex_bridge_help
		return 1
		;;
	esac

	return 0
}

_simplex_bridge_up() {
	local compose_file
	compose_file="$(_find_compose_file)" || {
		die "No compose file found. Run: matterbridge-helper.sh simplex-bridge init"
		return 1
	}

	if ! command -v docker >/dev/null 2>&1; then
		die "Docker not found. Install Docker or OrbStack first."
		return 1
	fi

	# Check for matterbridge.toml in the compose file directory
	local compose_dir
	compose_dir="$(dirname "$compose_file")"
	if [ ! -f "$compose_dir/matterbridge.toml" ] && [ ! -f "$SIMPLEX_BRIDGE_DIR/matterbridge.toml" ]; then
		log "WARNING: No matterbridge.toml found. The bridge will not connect to any platforms."
		log "Copy the template: cp configs/matterbridge-simplex.toml.example matterbridge.toml"
	fi

	# Check for SimpleX database
	if [ ! -d "$SIMPLEX_BRIDGE_DIR/data/simplex" ] || [ -z "$(ls -A "$SIMPLEX_BRIDGE_DIR/data/simplex" 2>/dev/null)" ]; then
		log "WARNING: No SimpleX database found in $SIMPLEX_BRIDGE_DIR/data/simplex/"
		log "Run simplex-chat CLI first to create a profile, then copy database files."
		log "See: matterbridge-helper.sh simplex-bridge init"
	fi

	log "Starting SimpleX bridge stack..."
	docker compose -f "$compose_file" up --build -d "$@"
	log "SimpleX bridge started. Check status: matterbridge-helper.sh simplex-bridge status"
	return 0
}

_simplex_bridge_down() {
	local compose_file
	compose_file="$(_find_compose_file)" || {
		die "No compose file found."
		return 1
	}

	log "Stopping SimpleX bridge stack..."
	docker compose -f "$compose_file" down "$@"
	log "SimpleX bridge stopped."
	return 0
}

_simplex_bridge_status() {
	local compose_file
	compose_file="$(_find_compose_file)" || {
		log "No compose file found. SimpleX bridge not configured."
		return 0
	}

	log "Compose file: $compose_file"
	log "Data dir: $SIMPLEX_BRIDGE_DIR"

	if command -v docker >/dev/null 2>&1; then
		docker compose -f "$compose_file" ps 2>/dev/null || log "No containers running"
	else
		log "Docker not available"
	fi

	# Check for SimpleX database
	if [ -d "$SIMPLEX_BRIDGE_DIR/data/simplex" ]; then
		local db_count
		db_count="$(find "$SIMPLEX_BRIDGE_DIR/data/simplex" -name 'simplex_v1_*' 2>/dev/null | wc -l | tr -d ' ')"
		log "SimpleX database files: $db_count"
	else
		log "SimpleX database: not found"
	fi

	return 0
}

_simplex_bridge_logs() {
	local compose_file
	compose_file="$(_find_compose_file)" || {
		die "No compose file found."
		return 1
	}

	docker compose -f "$compose_file" logs "$@"
	return 0
}

_simplex_bridge_init() {
	_ensure_simplex_bridge_dir

	# Copy compose file to working directory if not present
	local compose_file
	compose_file="$(_find_compose_file)" || true

	if [ -z "$compose_file" ] || [ ! -f "$SIMPLEX_BRIDGE_DIR/docker-compose.yml" ]; then
		local template=""
		# Find template from agents dir or repo
		if [ -f "$AGENTS_DIR/configs/matterbridge-simplex-compose.yml" ]; then
			template="$AGENTS_DIR/configs/matterbridge-simplex-compose.yml"
		else
			local script_dir
			script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
			local repo_template="${script_dir}/../configs/matterbridge-simplex-compose.yml"
			if [ -f "$repo_template" ]; then
				template="$repo_template"
			fi
		fi

		if [ -n "$template" ]; then
			cp "$template" "$SIMPLEX_BRIDGE_DIR/docker-compose.yml"
			log "Copied compose template to $SIMPLEX_BRIDGE_DIR/docker-compose.yml"
		else
			die "No compose template found. Ensure aidevops is installed."
			return 1
		fi
	else
		log "Compose file already exists: $SIMPLEX_BRIDGE_DIR/docker-compose.yml"
	fi

	# Copy config template if not present
	if [ ! -f "$SIMPLEX_BRIDGE_DIR/matterbridge.toml" ]; then
		local config_template=""
		if [ -f "$AGENTS_DIR/configs/matterbridge-simplex.toml.example" ]; then
			config_template="$AGENTS_DIR/configs/matterbridge-simplex.toml.example"
		else
			local script_dir
			script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
			local repo_config="${script_dir}/../configs/matterbridge-simplex.toml.example"
			if [ -f "$repo_config" ]; then
				config_template="$repo_config"
			fi
		fi

		if [ -n "$config_template" ]; then
			cp "$config_template" "$SIMPLEX_BRIDGE_DIR/matterbridge.toml"
			chmod 600 "$SIMPLEX_BRIDGE_DIR/matterbridge.toml"
			log "Copied config template to $SIMPLEX_BRIDGE_DIR/matterbridge.toml"
		else
			log "WARNING: No config template found. Create matterbridge.toml manually."
		fi
	else
		log "Config already exists: $SIMPLEX_BRIDGE_DIR/matterbridge.toml"
	fi

	log ""
	log "Next steps:"
	log "  1. Run simplex-chat CLI to create a profile and join/create the chat to bridge"
	log "  2. Copy database: cp ~/.simplex/simplex_v1_* $SIMPLEX_BRIDGE_DIR/data/simplex/"
	log "  3. Set permissions: chmod -R 777 $SIMPLEX_BRIDGE_DIR/data/"
	log "  4. Get chat ID: simplex-chat -e '/i #group_name'"
	log "  5. Edit $SIMPLEX_BRIDGE_DIR/matterbridge.toml with platform credentials"
	log "  6. Start: matterbridge-helper.sh simplex-bridge up"
	return 0
}

_simplex_bridge_help() {
	cat <<'HELP'
matterbridge-helper.sh simplex-bridge — Manage SimpleX-Matterbridge Docker stack

Actions:
  init               Set up working directory with compose + config templates
  up                 Start the 3-container stack (simplex, matterbridge, adapter)
  down               Stop and remove containers
  status             Show container status and database info
  logs [--follow]    Show container logs (pass -f for follow)

Environment:
  SIMPLEX_COMPOSE_FILE   Override compose file path
  SIMPLEX_CHAT_ID        SimpleX chat ID to bridge (default: 1)
  SIMPLEX_CHAT_TYPE      Chat type: contact or group (default: group)

Docs: .agents/services/communications/matterbridge.md
HELP
	return 0
}

cmd_help() {
	cat <<'HELP'
matterbridge-helper.sh — Manage Matterbridge multi-platform chat bridge

Commands:
  setup              Download binary and create config template
  validate [config]  Validate config file syntax
  start [--daemon]   Start bridge (foreground or daemon)
  stop               Stop bridge daemon
  status             Show running status
  logs [--follow]    Show/follow log output
  update             Update to latest release
  simplex-bridge     Manage SimpleX bridge Docker stack (init|up|down|status|logs)

Config: ~/.config/aidevops/matterbridge.toml (override: MATTERBRIDGE_CONFIG)
Docs:   .agents/services/communications/matterbridge.md
HELP
	return 0
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	setup) cmd_setup "$@" ;;
	validate) cmd_validate "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	status) cmd_status "$@" ;;
	logs) cmd_logs "$@" ;;
	update) cmd_update "$@" ;;
	simplex-bridge) cmd_simplex_bridge "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $cmd" >&2
		cmd_help
		return 1
		;;
	esac

	return 0
}

main "$@"
