#!/usr/bin/env bash
# daytona-helper.sh — Daytona sandbox lifecycle management
# Usage: daytona-helper.sh <command> [args]
# Commands: create, start, stop, destroy, list, exec, snapshot, status
# Requires: DAYTONA_API_KEY env var or gopass secret
# Bash 3.2 compatible

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DAYTONA_API_BASE="${DAYTONA_API_BASE:-https://app.daytona.io/api}"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  create  [name] [--template T] [--cpus N] [--memory N] [--disk N] [--gpu G]
  start   <sandbox-id>
  stop    <sandbox-id>
  destroy <sandbox-id>
  list    [--json]
  exec    <sandbox-id> <command...>
  snapshot <sandbox-id> [snapshot-name]
  status  <sandbox-id>
  help

Environment:
  DAYTONA_API_KEY   API key (or set via: aidevops secret set DAYTONA_API_KEY)
  DAYTONA_API_BASE  API base URL (default: https://app.daytona.io/api)

Examples:
  $SCRIPT_NAME create my-sandbox --template python-3.11 --cpus 2 --memory 4
  $SCRIPT_NAME exec abc123 "python script.py"
  $SCRIPT_NAME snapshot abc123 "after-deps-installed"
  $SCRIPT_NAME list
  $SCRIPT_NAME destroy abc123
EOF
	return 0
}

log_info() {
	local msg="$1"
	printf '[daytona] %s\n' "$msg" >&2
	return 0
}

log_error() {
	local msg="$1"
	printf '[daytona] ERROR: %s\n' "$msg" >&2
	return 0
}

die() {
	local msg="$1"
	log_error "$msg"
	exit 1
}

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

get_api_key() {
	local key=""

	# 1. Environment variable
	if [ -n "${DAYTONA_API_KEY:-}" ]; then
		key="$DAYTONA_API_KEY"
	fi

	# 2. gopass
	if [ -z "$key" ] && command -v gopass >/dev/null 2>&1; then
		key="$(gopass show -o aidevops/daytona/api-key 2>/dev/null || true)"
	fi

	# 3. credentials.sh
	if [ -z "$key" ] && [ -f "$HOME/.config/aidevops/credentials.sh" ]; then
		# shellcheck source=/dev/null
		. "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true
		key="${DAYTONA_API_KEY:-}"
	fi

	if [ -z "$key" ]; then
		die "DAYTONA_API_KEY not set. Run: aidevops secret set DAYTONA_API_KEY"
	fi

	printf '%s' "$key"
	return 0
}

# ---------------------------------------------------------------------------
# API calls
# ---------------------------------------------------------------------------

api_get() {
	local path="$1"
	local api_key
	api_key="$(get_api_key)"

	curl -sf \
		-H "Authorization: Bearer $api_key" \
		-H "Content-Type: application/json" \
		"${DAYTONA_API_BASE}${path}"
	return 0
}

api_post() {
	local path="$1"
	local body="${2:-{}}"
	local api_key
	api_key="$(get_api_key)"

	curl -sf \
		-X POST \
		-H "Authorization: Bearer $api_key" \
		-H "Content-Type: application/json" \
		-d "$body" \
		"${DAYTONA_API_BASE}${path}"
	return 0
}

api_delete() {
	local path="$1"
	local api_key
	api_key="$(get_api_key)"

	curl -sf \
		-X DELETE \
		-H "Authorization: Bearer $api_key" \
		"${DAYTONA_API_BASE}${path}"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_create() {
	local name=""
	local template="ubuntu-22.04"
	local cpus="2"
	local memory="4"
	local disk="10"
	local gpu=""

	# Parse args
	while [ $# -gt 0 ]; do
		case "$1" in
		--template)
			template="$2"
			shift 2
			;;
		--cpus)
			cpus="$2"
			shift 2
			;;
		--memory)
			memory="$2"
			shift 2
			;;
		--disk)
			disk="$2"
			shift 2
			;;
		--gpu)
			gpu="$2"
			shift 2
			;;
		--*) die "Unknown option: $1" ;;
		*)
			name="$1"
			shift
			;;
		esac
	done

	# Build JSON body
	local resources
	resources="{\"cpus\":$cpus,\"memory\":$memory,\"disk\":$disk}"
	if [ -n "$gpu" ]; then
		resources="{\"cpus\":$cpus,\"memory\":$memory,\"disk\":$disk,\"gpu\":\"$gpu\"}"
	fi

	local body
	body="{\"template\":\"$template\",\"resources\":$resources}"
	if [ -n "$name" ]; then
		body="{\"name\":\"$name\",\"template\":\"$template\",\"resources\":$resources}"
	fi

	log_info "Creating sandbox (template=$template, cpus=$cpus, memory=${memory}GB, disk=${disk}GB)..."
	local result
	result="$(api_post "/sandboxes" "$body")"

	local sandbox_id
	sandbox_id="$(printf '%s' "$result" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')"

	if [ -z "$sandbox_id" ]; then
		log_error "Failed to create sandbox. Response: $result"
		return 1
	fi

	log_info "Created sandbox: $sandbox_id"
	printf '%s\n' "$sandbox_id"
	return 0
}

cmd_start() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		die "Usage: $SCRIPT_NAME start <sandbox-id>"
	fi

	log_info "Starting sandbox $sandbox_id..."
	api_post "/sandboxes/$sandbox_id/start" >/dev/null
	log_info "Sandbox $sandbox_id started"
	return 0
}

cmd_stop() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		die "Usage: $SCRIPT_NAME stop <sandbox-id>"
	fi

	log_info "Stopping sandbox $sandbox_id..."
	api_post "/sandboxes/$sandbox_id/stop" >/dev/null
	log_info "Sandbox $sandbox_id stopped (disk billing continues; destroy to stop all billing)"
	return 0
}

cmd_destroy() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		die "Usage: $SCRIPT_NAME destroy <sandbox-id>"
	fi

	log_info "Destroying sandbox $sandbox_id..."
	api_delete "/sandboxes/$sandbox_id" >/dev/null
	log_info "Sandbox $sandbox_id destroyed"
	return 0
}

cmd_list() {
	local json_output=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--json)
			json_output=1
			shift
			;;
		*) shift ;;
		esac
	done

	local result
	result="$(api_get "/sandboxes")"

	if [ "$json_output" -eq 1 ]; then
		printf '%s\n' "$result"
		return 0
	fi

	# Simple table output without jq dependency
	printf '%-36s  %-12s  %-20s\n' "ID" "STATE" "TEMPLATE"
	printf '%-36s  %-12s  %-20s\n' "------------------------------------" "------------" "--------------------"

	# Parse JSON manually (basic, no jq required)
	printf '%s\n' "$result" | grep -o '"id":"[^"]*"\|"state":"[^"]*"\|"template":"[^"]*"' |
		awk -F'"' '
        /^"id"/ { id=$4 }
        /^"state"/ { state=$4 }
        /^"template"/ { printf "%-36s  %-12s  %-20s\n", id, state, $4; id=""; state="" }
        '
	return 0
}

cmd_exec() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		die "Usage: $SCRIPT_NAME exec <sandbox-id> <command...>"
	fi
	shift

	if [ $# -eq 0 ]; then
		die "Usage: $SCRIPT_NAME exec <sandbox-id> <command...>"
	fi

	local command_str="$*"
	local body
	body="{\"command\":\"$command_str\",\"timeout\":300}"

	log_info "Executing in sandbox $sandbox_id: $command_str"
	local result
	result="$(api_post "/sandboxes/$sandbox_id/exec" "$body")"

	# Extract and print stdout
	local stdout
	stdout="$(printf '%s\n' "$result" | grep -o '"stdout":"[^"]*"' | sed 's/"stdout":"//;s/"$//' | sed 's/\\n/\n/g;s/\\t/\t/g')"

	local exit_code
	exit_code="$(printf '%s\n' "$result" | grep -o '"exit_code":[0-9]*' | sed 's/"exit_code"://')"

	if [ -n "$stdout" ]; then
		printf '%s\n' "$stdout"
	fi

	if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
		local stderr
		stderr="$(printf '%s\n' "$result" | grep -o '"stderr":"[^"]*"' | sed 's/"stderr":"//;s/"$//' | sed 's/\\n/\n/g')"
		if [ -n "$stderr" ]; then
			printf '%s\n' "$stderr" >&2
		fi
		return "$exit_code"
	fi

	return 0
}

cmd_snapshot() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		die "Usage: $SCRIPT_NAME snapshot <sandbox-id> [snapshot-name]"
	fi
	local snapshot_name="${2:-snapshot-$(date +%Y%m%d-%H%M%S)}"

	local body
	body="{\"name\":\"$snapshot_name\"}"

	log_info "Creating snapshot '$snapshot_name' for sandbox $sandbox_id..."
	local result
	result="$(api_post "/sandboxes/$sandbox_id/snapshots" "$body")"

	local snapshot_id
	snapshot_id="$(printf '%s\n' "$result" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')"

	if [ -z "$snapshot_id" ]; then
		log_error "Failed to create snapshot. Response: $result"
		return 1
	fi

	log_info "Snapshot created: $snapshot_id (name: $snapshot_name)"
	printf '%s\n' "$snapshot_id"
	return 0
}

cmd_status() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		die "Usage: $SCRIPT_NAME status <sandbox-id>"
	fi

	local result
	result="$(api_get "/sandboxes/$sandbox_id")"

	# Extract key fields
	local state
	state="$(printf '%s\n' "$result" | grep -o '"state":"[^"]*"' | head -1 | sed 's/"state":"//;s/"//')"
	local template
	template="$(printf '%s\n' "$result" | grep -o '"template":"[^"]*"' | head -1 | sed 's/"template":"//;s/"//')"

	printf 'Sandbox: %s\n' "$sandbox_id"
	printf 'State:   %s\n' "${state:-unknown}"
	printf 'Template: %s\n' "${template:-unknown}"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	create) cmd_create "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	destroy) cmd_destroy "$@" ;;
	list) cmd_list "$@" ;;
	exec) cmd_exec "$@" ;;
	snapshot) cmd_snapshot "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) usage ;;
	*)
		log_error "Unknown command: $command"
		usage
		exit 1
		;;
	esac
	return 0
}

main "$@"
