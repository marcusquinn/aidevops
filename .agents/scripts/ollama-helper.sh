#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# ollama-helper.sh — Thin wrapper for Ollama local LLM management
# =============================================================================
# Provides status/serve/stop/models/pull/recommend/validate subcommands.
# Also provides chat/embed/health/privacy-check for LLM routing integration.
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
#   health              Check daemon running + at least one model (exit 0/1)
#   chat                Run inference: --model <m> --prompt-file <f>
#   embed               Get embeddings: --model <m> --text-file <f>
#   privacy-check       Verify no external connections during inference (best-effort)
#   help                Show this help message
#
# Options:
#   --num-ctx <n>       Context window size (used with pull/validate)
#   --host <host>       Ollama host (default: localhost)
#   --port <port>       Ollama port (default: 11434)
#   --json              Output in JSON format where supported
#   --model <name>      Model name (chat/embed/validate)
#   --prompt-file <f>   Prompt input file (chat)
#   --text-file <f>     Text input file (embed)
#   --max-tokens <n>    Max tokens in response (chat; maps to num_predict)
#   --temperature <f>   Sampling temperature 0.0-2.0 (chat)
#
# Environment:
#   OLLAMA_HOST                  Override Ollama host (default: localhost)
#   OLLAMA_PORT                  Override Ollama port (default: 11434)
#   OLLAMA_CHAT_TIMEOUT          Seconds before chat/embed timeout (default: 120)
#   AIDEVOPS_OLLAMA_BUNDLE       Path to bundle config (default: ~/.aidevops/configs/ollama-bundle.json)
#
# Examples:
#   ollama-helper.sh status
#   ollama-helper.sh serve
#   ollama-helper.sh pull llama3.2 --num-ctx 8192
#   ollama-helper.sh validate llama3.2 --num-ctx 4096
#   ollama-helper.sh recommend
#   ollama-helper.sh health
#   ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/prompt.txt
#   ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/p.txt --max-tokens 512
#   ollama-helper.sh embed --model nomic-embed-text --text-file /tmp/doc.txt
#   ollama-helper.sh privacy-check
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

# API endpoint paths — defined once to avoid repeated string literals
OLLAMA_ENDPOINT_GENERATE="/api/generate"

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

# POST JSON from a file body to the Ollama REST API.
# Centralises Content-Type header and curl flags for chat/embed callers.
# Usage: _ollama_api_file <endpoint> <body_file> [timeout_secs]
_ollama_api_file() {
	local endpoint="$1"
	local body_file="$2"
	local timeout_secs="${3:-${OLLAMA_CHAT_TIMEOUT:-120}}"
	local url="${OLLAMA_BASE_URL}${endpoint}"
	curl -sf -X POST -H "Content-Type: application/json" \
		--max-time "${timeout_secs}" \
		--data "@${body_file}" \
		"$url" 2>/dev/null
	return $?
}

# Extract model names from Ollama /api/tags JSON on stdin.
# Used in cmd_status, cmd_models, cmd_privacy_check to avoid repeating
# the same grep+sed pipeline.
_extract_model_names() {
	grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//'
	return 0
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

# Ensure the Ollama server is running; attempt to start it if not.
# Returns 0 if server is ready, 2 if start timed out.
_ensure_running() {
	if _server_running; then
		return 0
	fi
	_require_binary || return 1
	print_info "Ollama server not running — attempting to start..."
	cmd_serve >/dev/null 2>&1 || true
	local i=0
	while [[ $i -lt 30 ]]; do
		if _server_running; then
			print_success "Ollama server is ready"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	print_error "Ollama server did not start within 30 seconds"
	print_info "Run manually: ollama serve"
	return 2
}

# Check if a model is installed locally. Returns 0 if found, 1 if not.
_model_installed() {
	local model="$1"
	local models_json
	models_json=$(_ollama_api "/api/tags") || return 1
	# Match exact name or base name (strip tag for partial match)
	local model_base
	model_base=$(printf '%s' "$model" | sed 's/:.*//')
	if printf '%s' "$models_json" | grep -q "\"${model}\""; then
		return 0
	fi
	if printf '%s' "$models_json" | grep -q "\"${model_base}:"; then
		return 0
	fi
	return 1
}

# Build options JSON fragment for /api/generate from optional flags.
# Usage: _build_options_json <max_tokens> <temperature>
# Both arguments may be empty strings for no override.
_build_options_json() {
	local max_tokens="${1:-}" temperature="${2:-}"
	local parts=""
	if [[ -n "$max_tokens" ]]; then
		parts="\"num_predict\":${max_tokens}"
	fi
	if [[ -n "$temperature" ]]; then
		if [[ -n "$parts" ]]; then
			parts="${parts},"
		fi
		parts="${parts}\"temperature\":${temperature}"
	fi
	printf '{%s}\n' "${parts:-}"
	return 0
}

# Warn about disk space requirements if model appears in the bundle config.
_warn_bundle_disk_estimate() {
	local model="$1"
	local bundle_path="${AIDEVOPS_OLLAMA_BUNDLE:-$HOME/.aidevops/configs/ollama-bundle.json}"
	[[ ! -f "$bundle_path" ]] && return 0
	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi
	local size
	size=$(jq -r --arg m "$model" \
		'to_entries[] | select(.value.model == $m) | .value.size_estimate // empty' \
		"$bundle_path" 2>/dev/null | head -1) || size=""
	if [[ -n "$size" ]]; then
		print_warning "Pulling ${model} requires approximately ${size} of disk space."
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
		model_names=$(printf '%s' "$models_json" | _extract_model_names 2>/dev/null) || model_names=""
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
	model_names=$(printf '%s' "$response" | _extract_model_names 2>/dev/null) || model_names=""

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
	local test_response val_tmp
	val_tmp=$(mktemp 2>/dev/null) || val_tmp=""
	if [[ -z "$val_tmp" ]]; then
		print_warning "Cannot create temp file for functional check — skipping"
		return 0
	fi
	# Build JSON body with printf (model names/prompts are ASCII-safe here)
	printf '{"model":"%s","prompt":"hi","stream":false}\n' "$model" >"$val_tmp"
	test_response=$(_ollama_api_file "${OLLAMA_ENDPOINT_GENERATE}" "$val_tmp") || {
		rm -f "$val_tmp"
		print_error "Functional check failed for model: ${model}"
		return 1
	}
	rm -f "$val_tmp"

	if printf '%s' "$test_response" | grep -q '"response"'; then
		print_success "Functional check passed: ${model}"
	else
		print_error "Unexpected response from model: ${model}"
		return 1
	fi

	return 0
}

cmd_health() {
	# health only needs the HTTP API — no binary required
	if ! _server_running; then
		print_error "Ollama server not running at ${OLLAMA_BASE_URL}"
		return 1
	fi
	local models_json
	models_json=$(_ollama_api "/api/tags") || {
		print_error "Ollama server unreachable at ${OLLAMA_BASE_URL}"
		return 1
	}
	# Count models using safe pattern (avoid grep -c exit-1 on zero matches)
	local model_count=0
	local model_lines
	model_lines=$(printf '%s' "$models_json" | grep -o '"name"' 2>/dev/null) || model_lines=""
	if [[ -n "$model_lines" ]]; then
		model_count=$(printf '%s\n' "$model_lines" | wc -l | tr -d ' \t')
	fi
	if [[ "${model_count:-0}" -lt 1 ]]; then
		print_error "Ollama running but no models installed"
		print_info "Pull a model: ollama-helper.sh pull llama3.1:8b"
		return 1
	fi
	print_success "Ollama healthy: server up, ${model_count} model(s) installed"
	return 0
}

cmd_chat() {
	local model="" prompt_file="" max_tokens="" temperature=""
	while [[ $# -gt 0 ]]; do
		local _opt="${1:-}"
		case "$_opt" in
		--model)       model="${2:-}";       shift 2 ;;
		--prompt-file) prompt_file="${2:-}"; shift 2 ;;
		--max-tokens)  max_tokens="${2:-}";  shift 2 ;;
		--temperature) temperature="${2:-}"; shift 2 ;;
		*)             shift ;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Model name required. Usage: ollama-helper.sh chat --model <name> --prompt-file <path>"
		return 1
	fi
	if [[ -z "$prompt_file" ]]; then
		print_error "Prompt file required. Usage: ollama-helper.sh chat --model <name> --prompt-file <path>"
		return 1
	fi
	if [[ ! -f "$prompt_file" ]]; then
		print_error "Prompt file not found: ${prompt_file}"
		return 1
	fi

	# _ensure_running handles binary requirement for the auto-start path
	_ensure_running || return $?

	# Auto-pull model if not installed locally
	if ! _model_installed "$model"; then
		print_info "Model '${model}' not found locally — pulling..."
		_warn_bundle_disk_estimate "$model"
		cmd_pull "$model" || {
			print_error "Auto-pull failed for model: ${model}"
			return 1
		}
	fi

	local options
	options=$(_build_options_json "${max_tokens:-}" "${temperature:-}")

	local timeout_secs="${OLLAMA_CHAT_TIMEOUT:-120}"

	# Use REST API via a temp body file (handles prompt encoding correctly).
	local tmp_body
	tmp_body=$(mktemp) || { print_error "Cannot create temp file"; return 1; }

	local response exit_code=0
	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg model "$model" \
			--rawfile prompt "$prompt_file" \
			--argjson options "$options" \
			'{model: $model, prompt: $prompt, stream: false, options: $options}' \
			>"$tmp_body" 2>/dev/null || {
			# jq --rawfile may not be available in older jq; fall back to run
			rm -f "$tmp_body"
			_cmd_chat_cli_fallback "$model" "$prompt_file" "$timeout_secs"
			return $?
		}
		response=$(_ollama_api_file "${OLLAMA_ENDPOINT_GENERATE}" "$tmp_body" "$timeout_secs") || exit_code=$?
		rm -f "$tmp_body"
		if [[ $exit_code -ne 0 ]]; then
			print_error "Chat request failed for model: ${model}"
			return 1
		fi
		local completion
		completion=$(printf '%s' "$response" | jq -r '.response // empty' 2>/dev/null) || completion=""
		if [[ -z "$completion" ]]; then
			print_error "Empty or unexpected response from model: ${model}"
			return 1
		fi
		printf '%s\n' "$completion"
	else
		rm -f "$tmp_body"
		_cmd_chat_cli_fallback "$model" "$prompt_file" "$timeout_secs"
		exit_code=$?
	fi

	return $exit_code
}

# Fallback chat via 'ollama run' CLI (no options support; used when jq absent).
_cmd_chat_cli_fallback() {
	local model="$1" prompt_file="$2" timeout_secs="${3:-120}"
	local binary
	binary=$(_ollama_binary) || return 1
	local completion
	completion=$(timeout "${timeout_secs}" "$binary" run "$model" <"$prompt_file" 2>/dev/null)
	local ec=$?
	if [[ $ec -eq 124 ]]; then
		print_error "Chat timed out after ${timeout_secs}s for model: ${model}"
		return 1
	elif [[ $ec -ne 0 ]]; then
		print_error "Chat failed for model: ${model} (exit ${ec})"
		return 1
	fi
	printf '%s\n' "$completion"
	return 0
}

cmd_embed() {
	local model="" text_file=""
	while [[ $# -gt 0 ]]; do
		local _opt="${1:-}"
		case "$_opt" in
		--model)     model="${2:-}";     shift 2 ;;
		--text-file) text_file="${2:-}"; shift 2 ;;
		*)           shift ;;
		esac
	done

	if [[ -z "$model" ]]; then
		print_error "Model name required. Usage: ollama-helper.sh embed --model <name> --text-file <path>"
		return 1
	fi
	if [[ -z "$text_file" ]]; then
		print_error "Text file required. Usage: ollama-helper.sh embed --model <name> --text-file <path>"
		return 1
	fi
	if [[ ! -f "$text_file" ]]; then
		print_error "Text file not found: ${text_file}"
		return 1
	fi

	# _ensure_running handles binary requirement for the auto-start path
	_ensure_running || return $?

	# Auto-pull model if not installed locally
	if ! _model_installed "$model"; then
		print_info "Model '${model}' not found locally — pulling..."
		_warn_bundle_disk_estimate "$model"
		cmd_pull "$model" || {
			print_error "Auto-pull failed for model: ${model}"
			return 1
		}
	fi

	local timeout_secs="${OLLAMA_CHAT_TIMEOUT:-120}"
	local tmp_body
	tmp_body=$(mktemp) || { print_error "Cannot create temp file"; return 1; }

	local response exit_code=0
	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg model "$model" \
			--rawfile input "$text_file" \
			'{model: $model, input: $input}' \
			>"$tmp_body" 2>/dev/null || {
			rm -f "$tmp_body"
			print_error "Failed to build embed request (jq error)"
			return 1
		}
		# Try /api/embed first (Ollama ≥0.3); fall back to /api/embeddings
		response=$(_ollama_api_file "/api/embed" "$tmp_body" "$timeout_secs") || exit_code=$?
		if [[ $exit_code -ne 0 ]]; then
			# Retry with legacy endpoint and prompt key
			jq -n \
				--arg model "$model" \
				--rawfile prompt "$text_file" \
				'{model: $model, prompt: $prompt}' \
				>"$tmp_body" 2>/dev/null
			exit_code=0
			response=$(_ollama_api_file "/api/embeddings" "$tmp_body" "$timeout_secs") || exit_code=$?
		fi
	else
		rm -f "$tmp_body"
		print_error "jq is required for embed subcommand"
		return 1
	fi

	rm -f "$tmp_body"
	if [[ $exit_code -ne 0 ]] || [[ -z "$response" ]]; then
		print_error "Embed request failed for model: ${model}"
		return 1
	fi

	# Validate response contains embeddings key
	if ! printf '%s' "$response" | grep -q '"embed\|"embeddings"'; then
		print_error "Unexpected embed response from model: ${model}"
		return 1
	fi

	printf '%s\n' "$response"
	return 0
}

cmd_privacy_check() {
	print_info "Ollama privacy check (best-effort — not a guarantee)"
	print_info "Checks: no external TCP connections during inference."

	_require_binary || return 1
	_ensure_running || return $?

	# Find a model to test with
	local models_json
	models_json=$(_ollama_api "/api/tags") || {
		print_error "Cannot retrieve model list"
		return 1
	}
	local test_model=""
	test_model=$(printf '%s' "$models_json" | _extract_model_names | head -1) || test_model=""

	if [[ -z "$test_model" ]]; then
		print_warning "No models installed — skipping inference check"
		print_info "Ollama daemon is running. Pull a model to complete the privacy check."
		print_info "Pull: ollama-helper.sh pull llama3.1:8b"
		return 0
	fi

	print_info "Testing with model: ${test_model}"

	# Gather Ollama process PIDs for network inspection
	local ollama_pids=""
	ollama_pids=$(pgrep -x ollama 2>/dev/null) || \
		ollama_pids=$(pgrep -f "ollama serve" 2>/dev/null) || ollama_pids=""

	# Baseline: capture existing external connections before test
	local baseline_ext=""
	if command -v lsof >/dev/null 2>&1 && [[ -n "$ollama_pids" ]]; then
		local pid_csv
		pid_csv=$(printf '%s' "$ollama_pids" | tr '\n' ',')
		pid_csv="${pid_csv%,}"
		baseline_ext=$(lsof -nP -i TCP -a -p "$pid_csv" 2>/dev/null |
			grep "ESTABLISHED" |
			grep -v "127\.0\.0\.1\|localhost\|::1" || true)
	fi

	# Run a minimal inference request via temp file (avoids inline JSON escaping)
	local test_prompt="Say: ok"
	local test_response="" prv_tmp=""
	prv_tmp=$(mktemp 2>/dev/null) || prv_tmp=""
	if [[ -n "$prv_tmp" ]]; then
		printf '{"model":"%s","prompt":"%s","stream":false}\n' \
			"$test_model" "$test_prompt" >"$prv_tmp"
		test_response=$(_ollama_api_file "${OLLAMA_ENDPOINT_GENERATE}" "$prv_tmp") || true
		rm -f "$prv_tmp"
	fi

	if [[ -z "$test_response" ]]; then
		print_warning "Inference test produced no response — network check may be incomplete"
	fi

	# Post-inference: check for new external connections
	local post_ext=""
	if command -v lsof >/dev/null 2>&1 && [[ -n "$ollama_pids" ]]; then
		local pid_csv
		pid_csv=$(printf '%s' "$ollama_pids" | tr '\n' ',')
		pid_csv="${pid_csv%,}"
		post_ext=$(lsof -nP -i TCP -a -p "$pid_csv" 2>/dev/null |
			grep "ESTABLISHED" |
			grep -v "127\.0\.0\.1\|localhost\|::1" || true)
	fi

	# Diff: report connections that appeared during inference
	local new_ext=""
	if [[ -n "$post_ext" ]]; then
		if [[ "$post_ext" != "$baseline_ext" ]]; then
			new_ext="$post_ext"
		fi
	fi

	if [[ -n "$new_ext" ]]; then
		print_error "Privacy check FAILED: external TCP connections detected during inference:"
		printf '%s\n' "$new_ext"
		print_info "These may indicate telemetry or remote model registry calls."
		print_info "Inspect with: lsof -nP -i TCP -p \$(pgrep -x ollama)"
		return 1
	fi

	print_success "Privacy check PASSED: no external TCP connections detected during inference"
	print_info ""
	print_info "Disclaimer: This check inspects active TCP connections at snapshot time."
	print_info "It cannot detect: DNS queries, UDP traffic, or connections between snapshots."
	print_info "For high-assurance isolation, use a network-level firewall or airgap."
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
  health              Check daemon running + at least one model (exit 0 = healthy)
  chat                Run inference on a prompt file
  embed               Get vector embeddings for text file
  privacy-check       Verify no external connections during inference (best-effort)
  help                Show this help message

Options:
  --num-ctx <n>       Context window size (used with pull/validate)
  --host <host>       Ollama host (default: localhost)
  --port <port>       Ollama port (default: 11434)
  --json              Output in JSON format where supported
  --model <name>      Model name (chat/embed/validate)
  --prompt-file <f>   Prompt input file (chat)
  --text-file <f>     Text input file (embed)
  --max-tokens <n>    Max response tokens / num_predict (chat)
  --temperature <f>   Sampling temperature 0.0–2.0 (chat)

Environment:
  OLLAMA_HOST              Override Ollama host (default: localhost)
  OLLAMA_PORT              Override Ollama port (default: 11434)
  OLLAMA_CHAT_TIMEOUT      Timeout seconds for chat/embed (default: 120)
  AIDEVOPS_OLLAMA_BUNDLE   Path to bundle config JSON

Examples:
  ollama-helper.sh status
  ollama-helper.sh serve
  ollama-helper.sh stop
  ollama-helper.sh models
  ollama-helper.sh health
  ollama-helper.sh pull llama3.1:8b
  ollama-helper.sh pull llama3.2 --num-ctx 8192
  ollama-helper.sh recommend
  ollama-helper.sh validate llama3.2
  ollama-helper.sh validate llama3.2 --num-ctx 4096
  ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/prompt.txt
  ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/p.txt --max-tokens 512 --temperature 0.7
  ollama-helper.sh embed --model nomic-embed-text --text-file /tmp/doc.txt
  ollama-helper.sh privacy-check
  OLLAMA_HOST=192.168.1.10 ollama-helper.sh status

Privacy guarantee:
  privacy-check is a BEST-EFFORT check only. It inspects active TCP connections
  at snapshot time via lsof. It cannot detect DNS queries, UDP traffic, or
  connections between snapshots. For high-assurance offline operation, use a
  network-level firewall or airgap the host.
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
	status)        cmd_status "$@" ;;
	serve)         cmd_serve "$@" ;;
	stop)          cmd_stop "$@" ;;
	models)        cmd_models "$@" ;;
	pull)          cmd_pull "$@" ;;
	recommend)     cmd_recommend "$@" ;;
	validate)      cmd_validate "$@" ;;
	health)        cmd_health "$@" ;;
	chat)          cmd_chat "$@" ;;
	embed)         cmd_embed "$@" ;;
	privacy-check) cmd_privacy_check "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
	return $?
}

# Run main only when executed directly (not when sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
