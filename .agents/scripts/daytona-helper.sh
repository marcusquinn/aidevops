#!/usr/bin/env bash
# daytona-helper.sh — Daytona sandbox lifecycle management
# Usage: daytona-helper.sh <command> [args]
# Commands: create, start, stop, destroy, list, exec, snapshot, status, archive
# Requires: DAYTONA_API_KEY env var or gopass secret
# API docs: https://www.daytona.io/docs/en/tools/api
# CLI docs: https://www.daytona.io/docs/en/tools/cli
# Bash 3.2 compatible

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# API base: https://app.daytona.io/api
# Sandbox endpoints use /sandbox (singular), not /sandboxes
DAYTONA_API_BASE="${DAYTONA_API_BASE:-https://app.daytona.io/api}"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  create   [name] [--snapshot S] [--cpu N] [--memory N] [--disk N] [--gpu G]
             [--auto-stop N] [--auto-archive N] [--auto-delete N] [--ephemeral]
  start    <sandbox-id-or-name>
  stop     <sandbox-id-or-name>
  destroy  <sandbox-id-or-name>
  archive  <sandbox-id-or-name>
  list     [--json]
  exec     <sandbox-id-or-name> <command...>
  snapshot <create|list|delete> [args]
  status   <sandbox-id-or-name>
  help

Environment:
  DAYTONA_API_KEY   API key (or set via: aidevops secret set DAYTONA_API_KEY)
  DAYTONA_API_BASE  API base URL (default: https://app.daytona.io/api)

Resource defaults: cpu=1 vCPU, memory=1 GiB, disk=3 GiB
Resource limits:   cpu=4 vCPU, memory=8 GiB, disk=10 GiB

Examples:
  $SCRIPT_NAME create my-sandbox --snapshot ubuntu-22.04 --cpu 2 --memory 4
  $SCRIPT_NAME create my-sandbox --ephemeral --auto-stop 30
  $SCRIPT_NAME exec abc123 python script.py
  $SCRIPT_NAME snapshot create --dockerfile ./Dockerfile --image my-image:latest
  $SCRIPT_NAME snapshot list
  $SCRIPT_NAME list
  $SCRIPT_NAME status abc123
  $SCRIPT_NAME stop abc123
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

# Print error and exit — use only from main dispatch, not from subcommand functions
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
		log_error "DAYTONA_API_KEY not set. Run: aidevops secret set DAYTONA_API_KEY"
		return 1
	fi

	printf '%s' "$key"
	return 0
}

# ---------------------------------------------------------------------------
# API calls
# Daytona REST API base: https://app.daytona.io/api
# Sandbox resource path: /sandbox (singular)
# ---------------------------------------------------------------------------

api_get() {
	local path="$1"
	local api_key
	api_key="$(get_api_key)" || return 1

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
	api_key="$(get_api_key)" || return 1

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
	api_key="$(get_api_key)" || return 1

	curl -sf \
		-X DELETE \
		-H "Authorization: Bearer $api_key" \
		"${DAYTONA_API_BASE}${path}"
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# create — POST /sandbox
# Resources: cpu (vCPU), memory (GiB), disk (GiB)
# Auto-lifecycle: auto_stop_interval, auto_archive_interval, auto_delete_interval (minutes)
# Ephemeral: auto_delete_interval=0 (deleted immediately on stop)
cmd_create() {
	local name=""
	local snapshot=""
	local cpu=""
	local memory=""
	local disk=""
	local gpu=""
	local auto_stop=""
	local auto_archive=""
	local auto_delete=""
	local ephemeral=0

	while [ $# -gt 0 ]; do
		case "$1" in
		--snapshot | --template)
			snapshot="$2"
			shift 2
			;;
		--cpu)
			cpu="$2"
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
		--auto-stop)
			auto_stop="$2"
			shift 2
			;;
		--auto-archive)
			auto_archive="$2"
			shift 2
			;;
		--auto-delete)
			auto_delete="$2"
			shift 2
			;;
		--ephemeral)
			ephemeral=1
			shift
			;;
		--*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			name="$1"
			shift
			;;
		esac
	done

	# Build JSON body incrementally using printf
	# Daytona API: POST /sandbox — all fields optional
	local fields=""
	[ -n "$name" ] && fields="${fields}\"name\":\"${name}\","
	[ -n "$snapshot" ] && fields="${fields}\"snapshot\":\"${snapshot}\","
	[ -n "$cpu" ] && fields="${fields}\"cpu\":${cpu},"
	[ -n "$memory" ] && fields="${fields}\"memory\":${memory},"
	[ -n "$disk" ] && fields="${fields}\"disk\":${disk},"
	[ -n "$gpu" ] && fields="${fields}\"gpu\":${gpu},"
	[ -n "$auto_stop" ] && fields="${fields}\"autoStopInterval\":${auto_stop},"
	[ -n "$auto_archive" ] && fields="${fields}\"autoArchiveInterval\":${auto_archive},"
	[ -n "$auto_delete" ] && fields="${fields}\"autoDeleteInterval\":${auto_delete},"
	[ "$ephemeral" -eq 1 ] && fields="${fields}\"autoDeleteInterval\":0,"

	# Strip trailing comma
	fields="${fields%,}"
	local body="{${fields}}"

	log_info "Creating sandbox${name:+ \"$name\"}..."
	local result
	result="$(api_post "/sandbox" "$body")" || return 1

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

# start — POST /sandbox/{sandboxIdOrName}/start
cmd_start() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		log_error "Usage: $SCRIPT_NAME start <sandbox-id-or-name>"
		return 1
	fi

	log_info "Starting sandbox $sandbox_id..."
	api_post "/sandbox/$sandbox_id/start" >/dev/null || return 1
	log_info "Sandbox $sandbox_id started"
	return 0
}

# stop — POST /sandbox/{sandboxIdOrName}/stop
# Note: stopped sandboxes still incur disk costs; use destroy to stop all billing
cmd_stop() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		log_error "Usage: $SCRIPT_NAME stop <sandbox-id-or-name>"
		return 1
	fi

	log_info "Stopping sandbox $sandbox_id..."
	api_post "/sandbox/$sandbox_id/stop" >/dev/null || return 1
	log_info "Sandbox $sandbox_id stopped (disk billing continues; use destroy to stop all billing)"
	return 0
}

# destroy — DELETE /sandbox/{sandboxIdOrName}
cmd_destroy() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		log_error "Usage: $SCRIPT_NAME destroy <sandbox-id-or-name>"
		return 1
	fi

	log_info "Destroying sandbox $sandbox_id..."
	api_delete "/sandbox/$sandbox_id" >/dev/null || return 1
	log_info "Sandbox $sandbox_id destroyed"
	return 0
}

# archive — POST /sandbox/{sandboxIdOrName}/archive
# Moves filesystem to object storage; sandbox must be stopped first
cmd_archive() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		log_error "Usage: $SCRIPT_NAME archive <sandbox-id-or-name>"
		return 1
	fi

	log_info "Archiving sandbox $sandbox_id (sandbox must be stopped first)..."
	api_post "/sandbox/$sandbox_id/archive" >/dev/null || return 1
	log_info "Sandbox $sandbox_id archived"
	return 0
}

# list — GET /sandbox
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
	result="$(api_get "/sandbox")" || return 1

	if [ "$json_output" -eq 1 ]; then
		printf '%s\n' "$result"
		return 0
	fi

	# Simple table output without jq dependency
	printf '%-36s  %-12s  %-20s\n' "ID" "STATE" "NAME"
	printf '%-36s  %-12s  %-20s\n' "------------------------------------" "------------" "--------------------"

	# Parse JSON manually (basic, no jq required)
	printf '%s\n' "$result" | grep -o '"id":"[^"]*"\|"state":"[^"]*"\|"name":"[^"]*"' |
		awk -F'"' '
		/^"id"/ { id=$4 }
		/^"state"/ { state=$4 }
		/^"name"/ { printf "%-36s  %-12s  %-20s\n", id, state, $4; id=""; state="" }
		'
	return 0
}

# exec — run a command inside a sandbox via the daytona CLI
# Falls back to the Toolbox API if CLI is unavailable
cmd_exec() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		log_error "Usage: $SCRIPT_NAME exec <sandbox-id-or-name> <command...>"
		return 1
	fi
	shift

	if [ $# -eq 0 ]; then
		log_error "Usage: $SCRIPT_NAME exec <sandbox-id-or-name> <command...>"
		return 1
	fi

	# Prefer daytona CLI (handles auth, streaming, TTY)
	if command -v daytona >/dev/null 2>&1; then
		log_info "Executing in sandbox $sandbox_id: $*"
		daytona exec "$sandbox_id" -- "$@"
		return $?
	fi

	# Fallback: Toolbox API — POST /sandbox/{id}/toolbox/process/execute
	local command_str="$*"
	local body
	body="{\"command\":\"$command_str\",\"timeout\":300}"

	log_info "Executing in sandbox $sandbox_id (via API): $command_str"
	local result
	result="$(api_post "/sandbox/$sandbox_id/toolbox/process/execute" "$body")" || return 1

	# Extract stdout
	local stdout
	stdout="$(printf '%s\n' "$result" | grep -o '"result":"[^"]*"' | sed 's/"result":"//;s/"$//' | sed 's/\\n/\n/g;s/\\t/\t/g')"

	local exit_code
	exit_code="$(printf '%s\n' "$result" | grep -o '"exitCode":[0-9]*' | sed 's/"exitCode"://')"

	if [ -n "$stdout" ]; then
		printf '%s\n' "$stdout"
	fi

	if [ -n "$exit_code" ] && [ "$exit_code" != "0" ]; then
		return "$exit_code"
	fi

	return 0
}

# snapshot — manage Daytona snapshots via CLI or API
# Subcommands: create, list, delete
cmd_snapshot() {
	local subcmd="${1:-}"
	if [ -z "$subcmd" ]; then
		log_error "Usage: $SCRIPT_NAME snapshot <create|list|delete> [args]"
		log_info "  create  [--dockerfile FILE] [--image NAME] [--cpu N] [--memory N] [--disk N]"
		log_info "  list    [--json]"
		log_info "  delete  <snapshot-id>"
		return 1
	fi
	shift

	# Prefer daytona CLI for snapshot management
	if command -v daytona >/dev/null 2>&1; then
		case "$subcmd" in
		create)
			log_info "Creating snapshot..."
			daytona snapshot create "$@"
			return $?
			;;
		list)
			daytona snapshot list "$@"
			return $?
			;;
		delete)
			local snapshot_id="${1:-}"
			if [ -z "$snapshot_id" ]; then
				log_error "Usage: $SCRIPT_NAME snapshot delete <snapshot-id>"
				return 1
			fi
			log_info "Deleting snapshot $snapshot_id..."
			daytona snapshot delete "$snapshot_id"
			return $?
			;;
		*)
			log_error "Unknown snapshot subcommand: $subcmd"
			return 1
			;;
		esac
	fi

	# Fallback: REST API for snapshot listing
	case "$subcmd" in
	list)
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
		result="$(api_get "/snapshot")" || return 1
		if [ "$json_output" -eq 1 ]; then
			printf '%s\n' "$result"
		else
			printf '%s\n' "$result"
		fi
		return 0
		;;
	*)
		log_error "daytona CLI required for snapshot $subcmd. Install: https://www.daytona.io/docs/en/getting-started#cli"
		return 1
		;;
	esac
}

# status — GET /sandbox/{sandboxIdOrName}
cmd_status() {
	local sandbox_id="${1:-}"
	if [ -z "$sandbox_id" ]; then
		log_error "Usage: $SCRIPT_NAME status <sandbox-id-or-name>"
		return 1
	fi

	local result
	result="$(api_get "/sandbox/$sandbox_id")" || return 1

	# Extract key fields without jq
	local state
	state="$(printf '%s\n' "$result" | grep -o '"state":"[^"]*"' | head -1 | sed 's/"state":"//;s/"//')"
	local name
	name="$(printf '%s\n' "$result" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//')"
	local snapshot
	snapshot="$(printf '%s\n' "$result" | grep -o '"snapshot":"[^"]*"' | head -1 | sed 's/"snapshot":"//;s/"//')"
	local cpu
	cpu="$(printf '%s\n' "$result" | grep -o '"cpu":[0-9]*' | head -1 | sed 's/"cpu"://')"
	local memory
	memory="$(printf '%s\n' "$result" | grep -o '"memory":[0-9]*' | head -1 | sed 's/"memory"://')"
	local disk
	disk="$(printf '%s\n' "$result" | grep -o '"disk":[0-9]*' | head -1 | sed 's/"disk"://')"

	printf 'Sandbox:  %s\n' "$sandbox_id"
	printf 'Name:     %s\n' "${name:-unknown}"
	printf 'State:    %s\n' "${state:-unknown}"
	printf 'Snapshot: %s\n' "${snapshot:-unknown}"
	printf 'CPU:      %s vCPU\n' "${cpu:-unknown}"
	printf 'Memory:   %s GiB\n' "${memory:-unknown}"
	printf 'Disk:     %s GiB\n' "${disk:-unknown}"
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
	destroy | delete) cmd_destroy "$@" ;;
	archive) cmd_archive "$@" ;;
	list) cmd_list "$@" ;;
	exec) cmd_exec "$@" ;;
	snapshot) cmd_snapshot "$@" ;;
	status | info) cmd_status "$@" ;;
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
