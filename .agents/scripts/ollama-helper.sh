#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# ollama-helper.sh — Thin wrapper for Ollama local LLM management
# =============================================================================
# Provides status/serve/stop/models/pull/recommend/validate subcommands.
# ShellCheck clean, bash 3.2 compatible.
#
# Usage:
#   ollama-helper.sh <command> [options]
#
# Commands:
#   status              Show Ollama server status and loaded models
#   serve               Start the Ollama server (background)
#   stop                Stop the Ollama server
#   models              List locally available models
#   pull <model>        Pull a model; validates num_ctx if --num-ctx provided
#   recommend           Suggest models based on available VRAM/RAM
#   validate <model>    Validate a model is present and functional
#   help                Show this help message
#
# Options:
#   --num-ctx <n>       Context window size (used with pull/validate)
#   --host <host>       Ollama host (default: localhost)
#   --port <port>       Ollama port (default: 11434)
#   --json              Output in JSON format where supported
#
# Examples:
#   ollama-helper.sh status
#   ollama-helper.sh serve
#   ollama-helper.sh pull llama3.2 --num-ctx 8192
#   ollama-helper.sh validate llama3.2 --num-ctx 4096
#   ollama-helper.sh recommend
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Configuration
# =============================================================================

OLLAMA_HOST="${OLLAMA_HOST:-localhost}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
OLLAMA_PID_FILE="${TMPDIR:-/tmp}/ollama-helper.pid"

# num_ctx limits: warn if requested value exceeds model's trained context
# These are conservative defaults; actual limits vary by model
OLLAMA_MAX_NUM_CTX_DEFAULT=131072

# =============================================================================
# Internal helpers
# =============================================================================

_ollama_binary() {
	if command -v ollama >/dev/null 2>&1; then
		echo "ollama"
		return 0
	fi
	# Common install locations
	local candidates="/usr/local/bin/ollama /usr/bin/ollama $HOME/.local/bin/ollama"
	local c
	for c in $candidates; do
		if [[ -x "$c" ]]; then
			echo "$c"
			return 0
		fi
	done
	return 1
}

_ollama_api() {
	local endpoint="$1"
	local method="${2:-GET}"
	local body="${3:-}"
	local url="${OLLAMA_BASE_URL}${endpoint}"

	if [[ -n "$body" ]]; then
		curl -sf -X "$method" -H "Content-Type: application/json" \
			-d "$body" "$url" 2>/dev/null
	else
		curl -sf -X "$method" "$url" 2>/dev/null
	fi
	return $?
}

_server_running() {
	_ollama_api "/api/tags" >/dev/null 2>&1
	return $?
}

_require_server() {
	if ! _server_running; then
		print_error "Ollama server is not running at ${OLLAMA_BASE_URL}"
		print_info "Run: ollama-helper.sh serve"
		return 1
	fi
	return 0
}

_require_binary() {
	if ! _ollama_binary >/dev/null 2>&1; then
		print_error "ollama binary not found. Install from https://ollama.com"
		return 1
	fi
	return 0
}

# Validate num_ctx: must be a positive integer and within model limits
_validate_num_ctx() {
	local num_ctx="$1"
	local model="${2:-}"

	# Must be a positive integer
	case "$num_ctx" in
	'' | *[!0-9]*)
		print_error "num_ctx must be a positive integer, got: ${num_ctx}"
		return 1
		;;
	esac

	if [[ "$num_ctx" -lt 1 ]]; then
		print_error "num_ctx must be >= 1, got: ${num_ctx}"
		return 1
	fi

	# Warn if exceeds known safe maximum
	if [[ "$num_ctx" -gt "$OLLAMA_MAX_NUM_CTX_DEFAULT" ]]; then
		print_warning "num_ctx=${num_ctx} exceeds typical maximum (${OLLAMA_MAX_NUM_CTX_DEFAULT}). This may cause OOM errors."
	fi

	# If model is provided and server is running, check model's actual context
	if [[ -n "$model" ]] && _server_running; then
		local model_info
		model_info=$(_ollama_api "/api/show" "POST" "{\"name\":\"${model}\"}" 2>/dev/null) || true
		if [[ -n "$model_info" ]]; then
			local model_ctx
			model_ctx=$(printf '%s' "$model_info" |
				grep -o '"num_ctx":[0-9]*' |
				grep -o '[0-9]*$' | head -1) || true
			if [[ -n "$model_ctx" ]] && [[ "$num_ctx" -gt "$model_ctx" ]]; then
				print_warning "num_ctx=${num_ctx} exceeds model's trained context (${model_ctx}). Performance may degrade."
			fi
		fi
	fi

	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_status() {
	local json_output=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=1
			shift
			;;
		*) shift ;;
		esac
	done

	local binary
	binary=$(_ollama_binary 2>/dev/null) || binary=""

	if [[ -z "$binary" ]]; then
		if [[ "$json_output" -eq 1 ]]; then
			printf '{"installed":false,"running":false}\n'
		else
			print_error "ollama binary not found"
		fi
		return 1
	fi

	local running=false
	local version=""
	local models_json=""

	version=$("$binary" --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1) || version="unknown"

	if _server_running; then
		running=true
		models_json=$(_ollama_api "/api/tags" 2>/dev/null) || models_json="{}"
	fi

	if [[ "$json_output" -eq 1 ]]; then
		printf '{"installed":true,"version":"%s","running":%s,"models":%s}\n' \
			"$version" "$running" "${models_json:-{}}"
		return 0
	fi

	print_info "Ollama Status"
	printf "  Binary:   %s\n" "$binary"
	printf "  Version:  %s\n" "$version"
	printf "  Server:   %s\n" "$running"
	printf "  Endpoint: %s\n" "$OLLAMA_BASE_URL"

	if [[ "$running" == "true" ]] && [[ -n "$models_json" ]]; then
		local model_names
		model_names=$(printf '%s' "$models_json" |
			grep -o '"name":"[^"]*"' |
			sed 's/"name":"//;s/"//' 2>/dev/null) || model_names=""
		if [[ -n "$model_names" ]]; then
			printf "\n  Loaded models:\n"
			printf '%s\n' "$model_names" | while IFS= read -r m; do
				printf "    - %s\n" "$m"
			done
		else
			printf "\n  No models loaded.\n"
		fi
	fi

	return 0
}

cmd_serve() {
	_require_binary || return 1

	if _server_running; then
		print_info "Ollama server already running at ${OLLAMA_BASE_URL}"
		return 0
	fi

	local binary
	binary=$(_ollama_binary)

	print_info "Starting Ollama server..."
	OLLAMA_HOST="${OLLAMA_HOST}" \
		OLLAMA_PORT="${OLLAMA_PORT}" \
		"$binary" serve >/dev/null 2>&1 &
	local pid=$!
	printf '%s\n' "$pid" >"$OLLAMA_PID_FILE"

	# Wait up to 10s for server to become ready
	local i=0
	while [[ $i -lt 10 ]]; do
		if _server_running; then
			print_success "Ollama server started (PID ${pid}) at ${OLLAMA_BASE_URL}"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done

	print_error "Ollama server did not become ready within 10 seconds"
	return 1
}

cmd_stop() {
	if ! _server_running; then
		print_info "Ollama server is not running"
		return 0
	fi

	# Try PID file first
	if [[ -f "$OLLAMA_PID_FILE" ]]; then
		local pid
		pid=$(cat "$OLLAMA_PID_FILE")
		if kill "$pid" 2>/dev/null; then
			rm -f "$OLLAMA_PID_FILE"
			print_success "Ollama server stopped (PID ${pid})"
			return 0
		fi
	fi

	# Fallback: find and kill by process name
	local pids
	pids=$(pgrep -x ollama 2>/dev/null) || pids=""
	if [[ -n "$pids" ]]; then
		printf '%s\n' "$pids" | while IFS= read -r p; do
			kill "$p" 2>/dev/null || true
		done
		print_success "Ollama server stopped"
		return 0
	fi

	print_warning "Could not find Ollama server process to stop"
	return 1
}

cmd_models() {
	local json_output=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=1
			shift
			;;
		*) shift ;;
		esac
	done

	_require_server || return 1

	local response
	response=$(_ollama_api "/api/tags") || {
		print_error "Failed to retrieve model list"
		return 1
	}

	if [[ "$json_output" -eq 1 ]]; then
		printf '%s\n' "$response"
		return 0
	fi

	local model_names
	model_names=$(printf '%s' "$response" |
		grep -o '"name":"[^"]*"' |
		sed 's/"name":"//;s/"//' 2>/dev/null) || model_names=""

	if [[ -z "$model_names" ]]; then
		print_info "No models available. Use: ollama-helper.sh pull <model>"
		return 0
	fi

	print_info "Available models:"
	printf '%s\n' "$model_names" | while IFS= read -r m; do
		printf "  %s\n" "$m"
	done

	return 0
}

cmd_pull() {
	local model="${1:-}"
	local num_ctx=""
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--num-ctx)
			num_ctx="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Model name required. Usage: ollama-helper.sh pull <model> [--num-ctx <n>]"
		return 1
	fi

	_require_binary || return 1

	# Validate num_ctx before pulling
	if [[ -n "$num_ctx" ]]; then
		_validate_num_ctx "$num_ctx" "$model" || return 1
	fi

	local binary
	binary=$(_ollama_binary)

	print_info "Pulling model: ${model}"
	if [[ -n "$num_ctx" ]]; then
		print_info "Requested num_ctx: ${num_ctx}"
	fi

	"$binary" pull "$model" || {
		print_error "Failed to pull model: ${model}"
		return 1
	}

	print_success "Model pulled: ${model}"

	# Post-pull validation of num_ctx against model metadata
	if [[ -n "$num_ctx" ]] && _server_running; then
		_validate_num_ctx "$num_ctx" "$model" || true
	fi

	return 0
}

cmd_recommend() {
	local json_output=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=1
			shift
			;;
		*) shift ;;
		esac
	done

	# Detect available memory (macOS and Linux)
	local total_ram_gb=0
	local vram_gb=0

	# RAM detection
	if command -v sysctl >/dev/null 2>&1; then
		# macOS
		local mem_bytes
		mem_bytes=$(sysctl -n hw.memsize 2>/dev/null) || mem_bytes=0
		total_ram_gb=$((mem_bytes / 1073741824))
	elif [[ -f /proc/meminfo ]]; then
		# Linux
		local mem_kb
		mem_kb=$(grep MemTotal /proc/meminfo | grep -o '[0-9]*') || mem_kb=0
		total_ram_gb=$((mem_kb / 1048576))
	fi

	# VRAM detection (nvidia-smi if available)
	if command -v nvidia-smi >/dev/null 2>&1; then
		local vram_mb
		vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1) || vram_mb=0
		vram_gb=$((vram_mb / 1024))
	fi

	# Recommendation logic based on available memory
	# Uses RAM as primary signal; VRAM as accelerator signal
	local effective_gb=$total_ram_gb
	if [[ "$vram_gb" -gt 0 ]]; then
		effective_gb=$vram_gb
	fi

	local recommendations=""
	local tier=""

	if [[ "$effective_gb" -ge 64 ]]; then
		tier="high"
		recommendations="llama3.3:70b mixtral:8x22b qwen2.5:72b"
	elif [[ "$effective_gb" -ge 32 ]]; then
		tier="medium-high"
		recommendations="llama3.1:70b qwen2.5:32b mixtral:8x7b"
	elif [[ "$effective_gb" -ge 16 ]]; then
		tier="medium"
		recommendations="llama3.2:latest qwen2.5:14b mistral:latest phi4:latest"
	elif [[ "$effective_gb" -ge 8 ]]; then
		tier="low-medium"
		recommendations="llama3.2:3b qwen2.5:7b phi3.5:latest gemma2:9b"
	else
		tier="low"
		recommendations="llama3.2:1b qwen2.5:0.5b phi3:mini gemma2:2b"
	fi

	if [[ "$json_output" -eq 1 ]]; then
		printf '{"ram_gb":%d,"vram_gb":%d,"tier":"%s","recommendations":[' \
			"$total_ram_gb" "$vram_gb" "$tier"
		local first=1
		for r in $recommendations; do
			if [[ "$first" -eq 1 ]]; then
				printf '"%s"' "$r"
				first=0
			else
				printf ',"%s"' "$r"
			fi
		done
		printf ']}\n'
		return 0
	fi

	print_info "System Memory"
	printf "  RAM:  %d GB\n" "$total_ram_gb"
	printf "  VRAM: %d GB\n" "$vram_gb"
	printf "  Tier: %s\n" "$tier"
	printf "\nRecommended models:\n"
	for r in $recommendations; do
		printf "  %s\n" "$r"
	done
	printf "\nPull a model: ollama-helper.sh pull <model>\n"

	return 0
}

cmd_validate() {
	local model="${1:-}"
	local num_ctx=""
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--num-ctx)
			num_ctx="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Model name required. Usage: ollama-helper.sh validate <model> [--num-ctx <n>]"
		return 1
	fi

	_require_server || return 1

	# Check model exists in local list
	local models_json
	models_json=$(_ollama_api "/api/tags") || {
		print_error "Failed to retrieve model list"
		return 1
	}

	local model_base
	model_base=$(printf '%s' "$model" | sed 's/:.*//') # strip tag for partial match

	if ! printf '%s' "$models_json" | grep -q "\"${model_base}"; then
		print_error "Model not found locally: ${model}"
		print_info "Pull it first: ollama-helper.sh pull ${model}"
		return 1
	fi

	print_success "Model present: ${model}"

	# Validate num_ctx if provided
	if [[ -n "$num_ctx" ]]; then
		_validate_num_ctx "$num_ctx" "$model" || return 1
		print_success "num_ctx=${num_ctx} is valid for model: ${model}"
	fi

	# Functional check: send a minimal generate request
	print_info "Running functional check..."
	local test_response
	test_response=$(_ollama_api "/api/generate" "POST" \
		"{\"model\":\"${model}\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}") || {
		print_error "Functional check failed for model: ${model}"
		return 1
	}

	if printf '%s' "$test_response" | grep -q '"response"'; then
		print_success "Functional check passed: ${model}"
	else
		print_error "Unexpected response from model: ${model}"
		return 1
	fi

	return 0
}

cmd_help() {
	cat <<'EOF'
ollama-helper.sh — Thin wrapper for Ollama local LLM management

Usage:
  ollama-helper.sh <command> [options]

Commands:
  status              Show Ollama server status and loaded models
  serve               Start the Ollama server (background)
  stop                Stop the Ollama server
  models              List locally available models
  pull <model>        Pull a model; validates num_ctx if --num-ctx provided
  recommend           Suggest models based on available VRAM/RAM
  validate <model>    Validate a model is present and functional
  help                Show this help message

Options:
  --num-ctx <n>       Context window size (used with pull/validate)
  --host <host>       Ollama host (default: localhost)
  --port <port>       Ollama port (default: 11434)
  --json              Output in JSON format where supported

Environment:
  OLLAMA_HOST         Override default host (default: localhost)
  OLLAMA_PORT         Override default port (default: 11434)

Examples:
  ollama-helper.sh status
  ollama-helper.sh serve
  ollama-helper.sh stop
  ollama-helper.sh models
  ollama-helper.sh pull llama3.2
  ollama-helper.sh pull llama3.2 --num-ctx 8192
  ollama-helper.sh recommend
  ollama-helper.sh validate llama3.2
  ollama-helper.sh validate llama3.2 --num-ctx 4096
  OLLAMA_HOST=192.168.1.10 ollama-helper.sh status
EOF
	return 0
}

# =============================================================================
# Argument parsing
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Parse global flags before command
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--host)
			OLLAMA_HOST="${2:-localhost}"
			OLLAMA_BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
			shift 2
			;;
		--port)
			OLLAMA_PORT="${2:-11434}"
			OLLAMA_BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
			shift 2
			;;
		*)
			break
			;;
		esac
	done

	case "$command" in
	status) cmd_status "$@" ;;
	serve) cmd_serve "$@" ;;
	stop) cmd_stop "$@" ;;
	models) cmd_models "$@" ;;
	pull) cmd_pull "$@" ;;
	recommend) cmd_recommend "$@" ;;
	validate) cmd_validate "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
