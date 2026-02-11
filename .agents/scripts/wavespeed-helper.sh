#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

# WaveSpeed Helper - REST API client for WaveSpeed AI
# Part of AI DevOps Framework
# Unified API for 200+ generative AI models (image, video, audio, 3D, LLM)

set -euo pipefail

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
    source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Constants
readonly WAVESPEED_API_BASE="https://api.wavespeed.ai/api/v3"
readonly DEFAULT_MODEL="wavespeed-ai/flux-dev"
readonly DEFAULT_POLL_INTERVAL=3
readonly DEFAULT_TIMEOUT=300

# Print helpers (fallback if shared-constants not loaded)
if ! command -v print_info &>/dev/null; then
    print_info() { echo "[INFO] $*"; }
    print_success() { echo "[OK] $*"; }
    print_error() { echo "[ERROR] $*" >&2; }
    print_warning() { echo "[WARN] $*"; }
fi

# Load API key from credentials
load_api_key() {
    if [[ -n "${WAVESPEED_API_KEY:-}" ]]; then
        return 0
    fi

    local cred_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "${cred_file}" ]]; then
        source "${cred_file}"
    fi

    # Try gopass
    if [[ -z "${WAVESPEED_API_KEY:-}" ]] && command -v gopass &>/dev/null; then
        WAVESPEED_API_KEY="$(gopass show -o "aidevops/WAVESPEED_API_KEY" 2>/dev/null)" || true
    fi

    if [[ -z "${WAVESPEED_API_KEY:-}" ]]; then
        print_error "WAVESPEED_API_KEY not set"
        print_info "Run: aidevops secret set WAVESPEED_API_KEY"
        print_info "Or add to ~/.config/aidevops/credentials.sh"
        return 1
    fi

    export WAVESPEED_API_KEY
    return 0
}

# Make authenticated API request
api_request() {
    local method="$1"
    local endpoint="$2"
    shift 2

    curl -s -X "${method}" \
        "${WAVESPEED_API_BASE}${endpoint}" \
        -H "Authorization: Bearer ${WAVESPEED_API_KEY}" \
        -H "Content-Type: application/json" \
        "$@"
}

# Submit a generation task
cmd_generate() {
    local prompt=""
    local model="${DEFAULT_MODEL}"
    local sync_mode="false"
    local poll_interval="${DEFAULT_POLL_INTERVAL}"
    local timeout="${DEFAULT_TIMEOUT}"
    local extra_input=""
    local output_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model|-m)   model="$2"; shift 2 ;;
            --sync)       sync_mode="true"; shift ;;
            --poll)       poll_interval="$2"; shift 2 ;;
            --timeout)    timeout="$2"; shift 2 ;;
            --input)      extra_input="$2"; shift 2 ;;
            --output|-o)  output_file="$2"; shift 2 ;;
            --*)          print_error "Unknown option: $1"; return 1 ;;
            *)
                if [[ -z "${prompt}" ]]; then
                    prompt="$1"
                else
                    print_error "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${prompt}" ]]; then
        print_error "Prompt is required"
        print_info "Usage: wavespeed-helper.sh generate \"your prompt\" [--model provider/model] [--sync]"
        return 1
    fi

    load_api_key || return 1

    # Build input JSON
    local input_json
    if [[ -n "${extra_input}" ]]; then
        input_json=$(printf '{"prompt": %s, %s}' "$(jq -Rn --arg p "${prompt}" '$p')" "${extra_input}")
    else
        input_json=$(printf '{"prompt": %s}' "$(jq -Rn --arg p "${prompt}" '$p')")
    fi

    # Build request body
    local body
    if [[ "${sync_mode}" == "true" ]]; then
        body=$(printf '{"input": %s, "enable_sync_mode": true}' "${input_json}")
    else
        body=$(printf '{"input": %s}' "${input_json}")
    fi

    print_info "Submitting to ${model}..."

    local response
    response=$(api_request POST "/predictions/${model}" -d "${body}")

    # Check for errors
    local error
    error=$(echo "${response}" | jq -r '.error // empty' 2>/dev/null)
    if [[ -n "${error}" ]]; then
        print_error "API error: ${error}"
        echo "${response}" | jq . 2>/dev/null || echo "${response}"
        return 1
    fi

    # Sync mode returns result directly
    if [[ "${sync_mode}" == "true" ]]; then
        local status
        status=$(echo "${response}" | jq -r '.status // empty' 2>/dev/null)
        if [[ "${status}" == "completed" ]]; then
            print_success "Generation complete"
            echo "${response}" | jq -r '.outputs[]? // empty' 2>/dev/null
            save_output "${response}" "${output_file}"
            return 0
        elif [[ "${status}" == "failed" ]]; then
            print_error "Generation failed"
            echo "${response}" | jq . 2>/dev/null || echo "${response}"
            return 1
        fi
    fi

    # Async mode — extract task ID and poll
    local task_id
    task_id=$(echo "${response}" | jq -r '.id // empty' 2>/dev/null)
    if [[ -z "${task_id}" ]]; then
        print_error "No task ID in response"
        echo "${response}" | jq . 2>/dev/null || echo "${response}"
        return 1
    fi

    print_info "Task ID: ${task_id}"
    poll_task "${task_id}" "${poll_interval}" "${timeout}" "${output_file}"
}

# Poll task until completion
poll_task() {
    local task_id="$1"
    local interval="$2"
    local timeout="$3"
    local output_file="${4:-}"
    local elapsed=0

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        local response
        response=$(api_request GET "/predictions/${task_id}/status")

        local status
        status=$(echo "${response}" | jq -r '.status // "unknown"' 2>/dev/null)

        case "${status}" in
            completed)
                print_success "Generation complete (${elapsed}s)"
                echo "${response}" | jq -r '.outputs[]? // empty' 2>/dev/null
                save_output "${response}" "${output_file}"
                return 0
                ;;
            failed)
                print_error "Generation failed"
                echo "${response}" | jq . 2>/dev/null || echo "${response}"
                return 1
                ;;
            pending|processing)
                printf "\r[INFO] Status: %s (%ds/%ds)" "${status}" "${elapsed}" "${timeout}"
                sleep "${interval}"
                elapsed=$((elapsed + interval))
                ;;
            *)
                print_warning "Unknown status: ${status}"
                sleep "${interval}"
                elapsed=$((elapsed + interval))
                ;;
        esac
    done

    echo ""
    print_error "Timeout after ${timeout}s. Task ${task_id} still ${status:-unknown}"
    print_info "Check later: wavespeed-helper.sh status ${task_id}"
    return 1
}

# Save output URLs to file
save_output() {
    local response="$1"
    local output_file="$2"

    if [[ -z "${output_file}" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "${output_file}")"
    echo "${response}" | jq . > "${output_file}"
    print_info "Response saved to: ${output_file}"
    return 0
}

# Check task status
cmd_status() {
    local task_id="${1:-}"

    if [[ -z "${task_id}" ]]; then
        print_error "Task ID is required"
        print_info "Usage: wavespeed-helper.sh status <task-id>"
        return 1
    fi

    load_api_key || return 1

    local response
    response=$(api_request GET "/predictions/${task_id}/status")

    echo "${response}" | jq . 2>/dev/null || echo "${response}"
    return 0
}

# List available models
cmd_models() {
    load_api_key || return 1

    local response
    response=$(api_request GET "/models")

    echo "${response}" | jq . 2>/dev/null || echo "${response}"
    return 0
}

# Upload a file
cmd_upload() {
    local file_path="${1:-}"

    if [[ -z "${file_path}" ]]; then
        print_error "File path is required"
        print_info "Usage: wavespeed-helper.sh upload <file>"
        return 1
    fi

    if [[ ! -f "${file_path}" ]]; then
        print_error "File not found: ${file_path}"
        return 1
    fi

    load_api_key || return 1

    print_info "Uploading: ${file_path}"

    local response
    response=$(curl -s -X POST \
        "${WAVESPEED_API_BASE}/files/upload" \
        -H "Authorization: Bearer ${WAVESPEED_API_KEY}" \
        -F "file=@${file_path}")

    local url
    url=$(echo "${response}" | jq -r '.url // empty' 2>/dev/null)
    if [[ -n "${url}" ]]; then
        print_success "Upload complete"
        echo "${url}"
    else
        print_error "Upload failed"
        echo "${response}" | jq . 2>/dev/null || echo "${response}"
        return 1
    fi

    return 0
}

# Check account balance
cmd_balance() {
    load_api_key || return 1

    local response
    response=$(api_request GET "/balance")

    echo "${response}" | jq . 2>/dev/null || echo "${response}"
    return 0
}

# Check usage stats
cmd_usage() {
    load_api_key || return 1

    local response
    response=$(api_request GET "/usage")

    echo "${response}" | jq . 2>/dev/null || echo "${response}"
    return 0
}

# Show help
show_help() {
    cat <<'EOF'
WaveSpeed Helper - REST API client for WaveSpeed AI

Usage: wavespeed-helper.sh <command> [arguments] [options]

Commands:
  generate <prompt>  Submit generation task to any model
  status <task-id>   Check task status and get results
  models             List available models
  upload <file>      Upload file and get URL for use as input
  balance            Check account balance
  usage              Check usage statistics
  help               Show this help

Generate Options:
  --model, -m <id>   Model ID (default: wavespeed-ai/flux-dev)
  --sync             Use sync mode (blocks until result, no polling)
  --poll <seconds>   Poll interval in seconds (default: 3)
  --timeout <secs>   Timeout in seconds (default: 300)
  --input <json>     Extra input fields as JSON fragment (e.g. '"seed": 42')
  --output, -o <f>   Save full response JSON to file

Examples:
  # Image generation
  wavespeed-helper.sh generate "A cyberpunk city at night" --model wavespeed-ai/flux-dev
  wavespeed-helper.sh generate "A cat" --model wavespeed-ai/flux-schnell --sync

  # Video generation
  wavespeed-helper.sh generate "Camera pans across mountains" --model wavespeed-ai/wan-2.1

  # With extra input parameters
  wavespeed-helper.sh generate "Portrait" --model wavespeed-ai/flux-dev --input '"seed": 42, "width": 1024'

  # Upload file for image-to-video
  URL=$(wavespeed-helper.sh upload photo.jpg)
  wavespeed-helper.sh generate "Person walks forward" --model wavespeed-ai/wan-2.1 --input "\"image_url\": \"${URL}\""

  # Check status of a running task
  wavespeed-helper.sh status abc123-def456

  # Account info
  wavespeed-helper.sh balance
  wavespeed-helper.sh usage

Environment:
  WAVESPEED_API_KEY  API key (get from https://wavespeed.ai/accesskey)
                     Store via: aidevops secret set WAVESPEED_API_KEY

Model ID Format:
  provider/model-name (e.g. wavespeed-ai/flux-dev, openai/dall-e-3)
  Run 'wavespeed-helper.sh models' for the full list.
EOF
}

# Main
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "${command}" in
        generate|gen)   cmd_generate "$@" ;;
        status)         cmd_status "$@" ;;
        models)         cmd_models "$@" ;;
        upload)         cmd_upload "$@" ;;
        balance)        cmd_balance "$@" ;;
        usage)          cmd_usage "$@" ;;
        help|--help|-h) show_help ;;
        *)
            print_error "Unknown command: ${command}"
            show_help
            return 1
            ;;
    esac
}

main "$@"
