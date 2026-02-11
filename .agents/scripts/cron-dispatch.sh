#!/usr/bin/env bash
# cron-dispatch.sh - Execute a cron job by dispatching to OpenCode server
#
# Usage: cron-dispatch.sh <job-id>
#
# Called by crontab entries managed by cron-helper.sh
# Requires OpenCode server running (opencode serve)
#
# Security:
#   - Uses HTTPS by default for remote hosts (non-localhost)
#   - Supports basic auth via OPENCODE_SERVER_PASSWORD
#   - SSL verification enabled by default (disable with OPENCODE_INSECURE=1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# Source shared-constants for resolve_model_tier() (t132.7)
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Configuration
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aidevops"
readonly CONFIG_FILE="$CONFIG_DIR/cron-jobs.json"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"
readonly OPENCODE_INSECURE="${OPENCODE_INSECURE:-}"
readonly MAIL_HELPER="$HOME/.aidevops/agents/scripts/mail-helper.sh"

#######################################
# Determine protocol based on host
# Localhost uses HTTP, remote uses HTTPS
#######################################
get_protocol() {
    local host="$1"
    # Use HTTP only for localhost/127.0.0.1, HTTPS for everything else
    if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
        echo "http"
    else
        echo "https"
    fi
}

# Timestamp for logging
log_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_info() {
    echo "[$(log_timestamp)] [INFO] $*"
}

log_error() {
    echo "[$(log_timestamp)] [ERROR] $*" >&2
}

log_success() {
    echo "[$(log_timestamp)] [SUCCESS] $*"
}

#######################################
# Build curl arguments array for secure requests
# Populates CURL_ARGS array with auth and SSL options
#######################################
build_curl_args() {
    CURL_ARGS=(-sf)
    
    # Add authentication if configured
    if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
        local user="${OPENCODE_SERVER_USERNAME:-admin}"
        CURL_ARGS+=(-u "${user}:${OPENCODE_SERVER_PASSWORD}")
    fi
    
    # Add SSL options for HTTPS
    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    if [[ "$protocol" == "https" ]] && [[ -n "$OPENCODE_INSECURE" ]]; then
        # Allow insecure connections (self-signed certs) - use with caution
        CURL_ARGS+=(-k)
        log_info "WARNING: SSL verification disabled (OPENCODE_INSECURE=1)"
    fi
}

#######################################
# Check server health
#######################################
check_server() {
    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/global/health"
    
    build_curl_args
    
    if curl "${CURL_ARGS[@]}" "$url" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

#######################################
# Get job configuration
#######################################
get_job() {
    local job_id="$1"
    jq -r --arg id "$job_id" '.jobs[] | select(.id == $id)' "$CONFIG_FILE"
}

#######################################
# Update job status in config
#######################################
update_job_status() {
    local job_id="$1"
    local status="$2"
    local timestamp
    timestamp=$(log_timestamp)
    
    local temp_file
    temp_file=$(mktemp)
    _save_cleanup_scope; trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${temp_file}'"
    jq --arg id "$job_id" \
       --arg status "$status" \
       --arg timestamp "$timestamp" \
       '(.jobs[] | select(.id == $id)) |= . + {lastRun: $timestamp, lastStatus: $status}' \
       "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
}

#######################################
# Create OpenCode session
#######################################
create_session() {
    local title="$1"
    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/session"
    
    build_curl_args
    
    curl "${CURL_ARGS[@]}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"$title\"}" | jq -r '.id'
}

#######################################
# Send prompt to session
#######################################
send_prompt() {
    local session_id="$1"
    local task="$2"
    local model="$3"
    local cmd_timeout="$4"
    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/session/${session_id}/message"
    
    # Parse model into provider and model ID
    local provider_id model_id
    provider_id=$(echo "$model" | cut -d'/' -f1)
    model_id=$(echo "$model" | cut -d'/' -f2-)
    
    # Build request body
    local body
    body=$(jq -n \
        --arg provider "$provider_id" \
        --arg model "$model_id" \
        --arg task "$task" \
        '{
            model: {
                providerID: $provider,
                modelID: $model
            },
            parts: [{type: "text", text: $task}]
        }')
    
    build_curl_args
    
    # Send with timeout
    timeout "$cmd_timeout" curl "${CURL_ARGS[@]}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body"
}

#######################################
# Delete session
#######################################
delete_session() {
    local session_id="$1"
    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/session/${session_id}"
    
    build_curl_args
    
    curl "${CURL_ARGS[@]}" -X DELETE "$url" &>/dev/null || true
}

#######################################
# Send notification via mailbox
#######################################
send_notification() {
    local job_id="$1"
    local job_name="$2"
    local status="$3"
    local duration="$4"
    local response="$5"
    
    if [[ ! -x "$MAIL_HELPER" ]]; then
        log_info "Mail helper not available, skipping notification"
        return 0
    fi
    
    local payload
    payload="Job: $job_id ($job_name)
Status: $status
Duration: ${duration}s
Time: $(log_timestamp)

Response:
$response"
    
    "$MAIL_HELPER" send \
        --to "coordinator" \
        --type "status_report" \
        --payload "$payload" \
        --from "cron-agent" || true
}

#######################################
# Main execution
#######################################
main() {
    local job_id="${1:-}"
    
    if [[ -z "$job_id" ]]; then
        log_error "Job ID required"
        echo "Usage: cron-dispatch.sh <job-id>"
        return 1
    fi
    
    log_info "Starting job: $job_id"
    
    # Check config exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        return 1
    fi
    
    # Get job configuration
    local job
    job=$(get_job "$job_id")
    if [[ -z "$job" || "$job" == "null" ]]; then
        log_error "Job not found: $job_id"
        return 1
    fi
    
    local name task workdir timeout model notify
    name=$(echo "$job" | jq -r '.name')
    task=$(echo "$job" | jq -r '.task')
    workdir=$(echo "$job" | jq -r '.workdir')
    timeout=$(echo "$job" | jq -r '.timeout // 600')
    model=$(echo "$job" | jq -r '.model // "anthropic/claude-sonnet-4-20250514"')
    notify=$(echo "$job" | jq -r '.notify // "none"')

    # Resolve tier names to full model strings (t132.7)
    model=$(resolve_model_tier "$model")
    
    log_info "Job: $name"
    log_info "Task: $task"
    log_info "Workdir: $workdir"
    log_info "Timeout: ${timeout}s"
    log_info "Model: $model"
    
    # Check server
    if ! check_server; then
        log_error "OpenCode server not responding on ${OPENCODE_HOST}:${OPENCODE_PORT}"
        update_job_status "$job_id" "failed"
        return 1
    fi
    
    # Change to workdir
    if [[ -n "$workdir" && -d "$workdir" ]]; then
        cd "$workdir" || exit
        log_info "Changed to: $workdir"
    fi
    
    # Track execution time
    local start_time
    start_time=$(date +%s)
    
    # Create session
    local session_id
    session_id=$(create_session "Cron: $name")
    if [[ -z "$session_id" || "$session_id" == "null" ]]; then
        log_error "Failed to create session"
        update_job_status "$job_id" "failed"
        return 1
    fi
    log_info "Created session: $session_id"
    
    # Send prompt and capture response
    local response exit_code=0
    response=$(send_prompt "$session_id" "$task" "$model" "$timeout") || exit_code=$?
    
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Cleanup session
    delete_session "$session_id"
    log_info "Deleted session: $session_id"
    
    # Update status
    if [[ $exit_code -eq 0 ]]; then
        update_job_status "$job_id" "success"
        log_success "Job completed in ${duration}s"
        
        # Log response summary
        local response_text
        response_text=$(echo "$response" | jq -r '.parts[]? | select(.type == "text") | .text' 2>/dev/null | head -c 1000 || echo "$response")
        log_info "Response: $response_text"
        
        # Send notification if configured
        if [[ "$notify" == "mail" ]]; then
            send_notification "$job_id" "$name" "success" "$duration" "$response_text"
        fi
    else
        update_job_status "$job_id" "failed"
        log_error "Job failed after ${duration}s (exit code: $exit_code)"
        
        # Send failure notification
        if [[ "$notify" == "mail" ]]; then
            send_notification "$job_id" "$name" "failed" "$duration" "Exit code: $exit_code"
        fi
        
        return 1
    fi
    
    return 0
}

main "$@"
