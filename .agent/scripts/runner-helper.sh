#!/usr/bin/env bash
# runner-helper.sh - Named headless AI agent instances with persistent identity
#
# Runners are named, persistent agent instances that can be dispatched headlessly.
# Each runner gets its own AGENTS.md (personality), config, and optional memory namespace.
#
# Usage:
#   runner-helper.sh create <name> [--description "desc"] [--model provider/model] [--workdir path]
#   runner-helper.sh run <name> "prompt" [--attach URL] [--model provider/model] [--format json] [--timeout N]
#   runner-helper.sh status <name>
#   runner-helper.sh list [--format json]
#   runner-helper.sh edit <name>          # Open AGENTS.md in $EDITOR
#   runner-helper.sh logs <name> [--tail N] [--follow]
#   runner-helper.sh stop <name>          # Abort running session
#   runner-helper.sh destroy <name> [--force]
#   runner-helper.sh help
#
# Directory: ~/.aidevops/.agent-workspace/runners/<name>/
#   ├── AGENTS.md      # Runner personality/instructions
#   ├── config.json    # Runner configuration (model, workdir, etc.)
#   ├── memory.db      # Runner-specific memories (optional, via --namespace)
#   ├── session.id     # Last session ID (for --continue)
#   └── runs/          # Run logs
#
# Integration:
#   - Memory: memory-helper.sh --namespace <runner-name>
#   - Mailbox: mail-helper.sh --to <runner-name>
#   - Cron: cron-helper.sh --task "runner-helper.sh run <name> 'prompt'"
#
# Security:
#   - Uses HTTPS by default for remote OpenCode servers
#   - Supports basic auth via OPENCODE_SERVER_PASSWORD
#   - Runner AGENTS.md files are local-only (not committed to repos)

set -euo pipefail

# Configuration
readonly RUNNERS_DIR="${AIDEVOPS_RUNNERS_DIR:-$HOME/.aidevops/.agent-workspace/runners}"
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"
readonly MAIL_HELPER="$HOME/.aidevops/agents/scripts/mail-helper.sh"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"
readonly DEFAULT_MODEL="anthropic/claude-sonnet-4-20250514"
readonly DEFAULT_TIMEOUT=600

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[RUNNER]${NC} $*"; }
log_success() { echo -e "${GREEN}[RUNNER]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[RUNNER]${NC} $*"; }
log_error() { echo -e "${RED}[RUNNER]${NC} $*" >&2; }

#######################################
# Mailbox bookend: check inbox before work
# Registers agent, checks for unread messages,
# returns context to prepend to prompt
#######################################
mailbox_before_run() {
    local name="$1"

    if [[ ! -x "$MAIL_HELPER" ]]; then
        return 0
    fi

    # Register this runner as active
    AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" register \
        --agent "$name" --role worker 2>/dev/null || true

    # Check for unread messages
    local unread_messages
    unread_messages=$(AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" check --unread-only 2>/dev/null)

    local unread_count
    unread_count=$(echo "$unread_messages" | grep -o '[0-9]* unread' | grep -o '[0-9]*' || echo "0")

    if [[ "$unread_count" -gt 0 ]]; then
        log_info "Mailbox: $unread_count unread message(s) for $name"
        # Return the messages as context (TOON format, parseable by the agent)
        echo "$unread_messages"
    fi
}

#######################################
# Mailbox bookend: report status after work
# Sends status report and deregisters
#######################################
mailbox_after_run() {
    local name="$1"
    local run_status="$2"
    local duration="$3"
    local run_id="$4"

    if [[ ! -x "$MAIL_HELPER" ]]; then
        return 0
    fi

    # Send status report
    AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" send \
        --to coordinator \
        --type status_report \
        --payload "Runner $name completed ($run_status, ${duration}s, $run_id)" \
        2>/dev/null || true

    # Deregister (mark inactive)
    AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" deregister --agent "$name" 2>/dev/null || true

    log_info "Mailbox: status report sent, $name deregistered"
}

#######################################
# Check if jq is available
#######################################
check_jq() {
    if ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed. Install with: brew install jq"
        return 1
    fi
    return 0
}

#######################################
# Check if opencode is available
#######################################
check_opencode() {
    if ! command -v opencode &>/dev/null; then
        log_error "opencode is required but not installed. Install from: https://opencode.ai"
        return 1
    fi
    return 0
}

#######################################
# Validate runner name (alphanumeric, hyphens, underscores)
#######################################
validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid runner name: '$name' (must start with letter, contain only alphanumeric, hyphens, underscores)"
        return 1
    fi
    if [[ ${#name} -gt 40 ]]; then
        log_error "Runner name too long: '$name' (max 40 characters)"
        return 1
    fi
    return 0
}

#######################################
# Get runner directory
#######################################
runner_dir() {
    local name="$1"
    echo "$RUNNERS_DIR/$name"
}

#######################################
# Check if runner exists
#######################################
runner_exists() {
    local name="$1"
    local dir
    dir=$(runner_dir "$name")
    [[ -d "$dir" && -f "$dir/config.json" ]]
}

#######################################
# Get runner config value
#######################################
runner_config() {
    local name="$1"
    local key="$2"
    local dir
    dir=$(runner_dir "$name")
    jq -r --arg key "$key" '.[$key] // empty' "$dir/config.json" 2>/dev/null
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
# Build curl arguments array for secure requests
#######################################
build_curl_args() {
    CURL_ARGS=(-sf)

    if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
        local user="${OPENCODE_SERVER_USERNAME:-opencode}"
        CURL_ARGS+=(-u "${user}:${OPENCODE_SERVER_PASSWORD}")
    fi

    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    if [[ "$protocol" == "https" && -n "${OPENCODE_INSECURE:-}" ]]; then
        CURL_ARGS+=(-k)
    fi
}

#######################################
# Create a new runner
#######################################
cmd_create() {
    check_jq || return 1

    local name="${1:-}"
    shift || true

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        echo "Usage: runner-helper.sh create <name> [--description \"desc\"] [--model provider/model]"
        return 1
    fi

    validate_name "$name" || return 1

    if runner_exists "$name"; then
        log_error "Runner already exists: $name"
        echo "Use 'runner-helper.sh edit $name' to modify, or 'runner-helper.sh destroy $name' to recreate."
        return 1
    fi

    local description="" model="$DEFAULT_MODEL" workdir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --description) [[ $# -lt 2 ]] && { log_error "--description requires a value"; return 1; }; description="$2"; shift 2 ;;
            --model) [[ $# -lt 2 ]] && { log_error "--model requires a value"; return 1; }; model="$2"; shift 2 ;;
            --workdir) [[ $# -lt 2 ]] && { log_error "--workdir requires a value"; return 1; }; workdir="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$description" ]]; then
        description="Runner: $name"
    fi

    local dir
    dir=$(runner_dir "$name")
    mkdir -p "$dir/runs"

    # Create config
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n \
        --arg name "$name" \
        --arg description "$description" \
        --arg model "$model" \
        --arg workdir "${workdir:-}" \
        --arg created "$timestamp" \
        '{
            name: $name,
            description: $description,
            model: $model,
            workdir: $workdir,
            created: $created,
            lastRun: null,
            lastStatus: null,
            runCount: 0
        }' > "$dir/config.json"

    # Create default AGENTS.md
    cat > "$dir/AGENTS.md" << EOF
# $name

$description

## Instructions

Add your runner-specific instructions here. This file defines the runner's
personality, rules, and output format.

## Rules

- Follow the task prompt precisely
- Output structured results when possible
- Report errors clearly with context

## Output Format

Respond with clear, actionable output appropriate to the task.
EOF

    log_success "Created runner: $name"
    echo ""
    echo "Directory: $dir"
    echo "Model: $model"
    echo ""
    echo "Next steps:"
    echo "  1. Edit instructions: runner-helper.sh edit $name"
    echo "  2. Test run: runner-helper.sh run $name \"your prompt\""

    return 0
}

#######################################
# Run a task on a runner
#######################################
cmd_run() {
    check_jq || return 1
    check_opencode || return 1

    local name="${1:-}"
    shift || true

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        echo "Usage: runner-helper.sh run <name> \"prompt\" [--attach URL] [--model provider/model]"
        return 1
    fi

    if ! runner_exists "$name"; then
        log_error "Runner not found: $name"
        echo "Create it with: runner-helper.sh create $name"
        return 1
    fi

    local prompt="${1:-}"
    shift || true

    if [[ -z "$prompt" ]]; then
        log_error "Prompt required"
        echo "Usage: runner-helper.sh run $name \"your prompt here\""
        return 1
    fi

    local attach="" model="" format="" cmd_timeout="$DEFAULT_TIMEOUT" continue_session=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --attach) [[ $# -lt 2 ]] && { log_error "--attach requires a value"; return 1; }; attach="$2"; shift 2 ;;
            --model) [[ $# -lt 2 ]] && { log_error "--model requires a value"; return 1; }; model="$2"; shift 2 ;;
            --format) [[ $# -lt 2 ]] && { log_error "--format requires a value"; return 1; }; format="$2"; shift 2 ;;
            --timeout) [[ $# -lt 2 ]] && { log_error "--timeout requires a value"; return 1; }; cmd_timeout="$2"; shift 2 ;;
            --continue|-c) continue_session=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    local dir
    dir=$(runner_dir "$name")

    # Resolve model (flag > config > default)
    if [[ -z "$model" ]]; then
        model=$(runner_config "$name" "model")
        if [[ -z "$model" ]]; then
            model="$DEFAULT_MODEL"
        fi
    fi

    # Resolve workdir
    local workdir
    workdir=$(runner_config "$name" "workdir")
    if [[ -z "$workdir" ]]; then
        workdir="$(pwd)"
    fi

    # Build opencode run command
    local -a cmd_args=("opencode" "run")

    # Attach to server if specified
    if [[ -n "$attach" ]]; then
        cmd_args+=("--attach" "$attach")
    fi

    # Model
    cmd_args+=("-m" "$model")

    # Session title
    cmd_args+=("--title" "runner/$name")

    # Continue previous session if requested
    if [[ "$continue_session" == "true" ]]; then
        local session_id=""
        if [[ -f "$dir/session.id" ]]; then
            session_id=$(cat "$dir/session.id")
        fi
        if [[ -n "$session_id" ]]; then
            cmd_args+=("-s" "$session_id")
        else
            log_warn "No previous session found for $name, starting fresh"
        fi
    fi

    # Output format
    if [[ -n "$format" ]]; then
        cmd_args+=("--format" "$format")
    fi

    # Mailbox bookend: check inbox before work
    local mailbox_context
    mailbox_context=$(mailbox_before_run "$name" 2>/dev/null || true)

    # Build the full prompt with runner context
    local agents_md="$dir/AGENTS.md"
    local full_prompt
    if [[ -f "$agents_md" ]]; then
        local instructions
        instructions=$(cat "$agents_md")
        full_prompt="$instructions

---

## Task

$prompt"
    else
        full_prompt="$prompt"
    fi

    # Prepend mailbox context if there are unread messages
    if [[ -n "$mailbox_context" ]] && echo "$mailbox_context" | grep -q '[1-9].* unread'; then
        full_prompt="## Mailbox (unread messages from other agents)

$mailbox_context

---

$full_prompt"
        log_info "Prepended mailbox context to prompt"
    fi

    cmd_args+=("$full_prompt")

    # Log the run
    local run_timestamp
    run_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local run_id
    run_id="run-$(date +%s)"
    local log_file="$dir/runs/${run_id}.log"

    log_info "Dispatching to runner: $name"
    log_info "Model: $model"
    log_info "Run ID: $run_id"

    # Execute with timeout (gtimeout on macOS, timeout on Linux)
    local timeout_cmd=""
    if command -v gtimeout &>/dev/null; then
        timeout_cmd="gtimeout"
    elif command -v timeout &>/dev/null; then
        timeout_cmd="timeout"
    fi

    local exit_code=0
    local start_time
    start_time=$(date +%s)

    if [[ -n "$timeout_cmd" ]]; then
        if "$timeout_cmd" "$cmd_timeout" "${cmd_args[@]}" 2>&1 | tee "$log_file"; then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if "${cmd_args[@]}" 2>&1 | tee "$log_file"; then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Update config with run metadata
    local temp_file
    temp_file=$(mktemp)
    local status="success"
    if [[ $exit_code -ne 0 ]]; then
        status="failed"
    fi

    jq --arg timestamp "$run_timestamp" \
       --arg status "$status" \
       --argjson duration "$duration" \
       '.lastRun = $timestamp | .lastStatus = $status | .lastDuration = $duration | .runCount += 1' \
       "$dir/config.json" > "$temp_file"
    mv "$temp_file" "$dir/config.json"

    if [[ $exit_code -eq 0 ]]; then
        log_success "Run complete (${duration}s)"
    else
        log_error "Run failed after ${duration}s (exit code: $exit_code)"
    fi

    # Mailbox bookend: report status after work
    mailbox_after_run "$name" "$status" "$duration" "$run_id" 2>/dev/null || true

    return "$exit_code"
}

#######################################
# Show runner status
#######################################
cmd_status() {
    check_jq || return 1

    local name="${1:-}"

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        return 1
    fi

    if ! runner_exists "$name"; then
        log_error "Runner not found: $name"
        return 1
    fi

    local dir
    dir=$(runner_dir "$name")
    local config="$dir/config.json"

    local description model workdir created last_run last_status run_count last_duration
    local config_values
    config_values=$(jq -r '[
        .description // "N/A",
        .model // "N/A",
        .workdir // "N/A",
        .created // "N/A",
        .lastRun // "never",
        .lastStatus // "N/A",
        (.runCount // 0 | tostring),
        (.lastDuration // "N/A" | tostring)
    ] | join("\n")' "$config")

    {
        read -r description
        read -r model
        read -r workdir
        read -r created
        read -r last_run
        read -r last_status
        read -r run_count
        read -r last_duration
    } <<< "$config_values"

    local status_color="$NC"
    case "$last_status" in
        success) status_color="$GREEN" ;;
        failed) status_color="$RED" ;;
    esac

    echo -e "${BOLD}Runner: $name${NC}"
    echo "──────────────────────────────────"
    echo "Description: $description"
    echo "Model: $model"
    echo "Workdir: $workdir"
    echo "Created: $created"
    echo ""
    echo "Total runs: $run_count"
    echo "Last run: $last_run"
    echo -e "Last status: ${status_color}${last_status}${NC}"
    echo "Last duration: ${last_duration}s"
    echo ""
    echo "Directory: $dir"

    # Check for session file
    if [[ -f "$dir/session.id" ]]; then
        echo "Session ID: $(cat "$dir/session.id")"
    fi

    # Check for memory namespace
    if [[ -x "$MEMORY_HELPER" ]]; then
        local mem_count
        mem_count=$("$MEMORY_HELPER" --namespace "$name" stats 2>/dev/null | grep -c "Total" || echo "0")
        if [[ "$mem_count" -gt 0 ]]; then
            echo "Memory entries: $mem_count"
        fi
    fi

    return 0
}

#######################################
# List all runners
#######################################
cmd_list() {
    local output_format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) [[ $# -lt 2 ]] && { log_error "--format requires a value"; return 1; }; output_format="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ ! -d "$RUNNERS_DIR" ]]; then
        log_info "No runners configured"
        echo ""
        echo "Create one with:"
        echo "  runner-helper.sh create my-runner --description \"What it does\""
        return 0
    fi

    local runners
    runners=$(find "$RUNNERS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

    if [[ -z "$runners" ]]; then
        log_info "No runners configured"
        return 0
    fi

    if [[ "$output_format" == "json" ]]; then
        local -a config_files=()
        for runner_path in $runners; do
            local config_file="$runner_path/config.json"
            if [[ -f "$config_file" ]]; then
                config_files+=("$config_file")
            fi
        done

        if (( ${#config_files[@]} > 0 )); then
            jq -s . "${config_files[@]}"
        else
            echo "[]"
        fi
        return 0
    fi

    printf "${BOLD}%-20s %-35s %-12s %s${NC}\n" "Name" "Description" "Runs" "Last Status"
    printf "%-20s %-35s %-12s %s\n" "──────────────────" "─────────────────────────────────" "──────────" "───────────"

    for runner_path in $runners; do
        local rname
        rname=$(basename "$runner_path")
        local config_file="$runner_path/config.json"

        if [[ ! -f "$config_file" ]]; then
            continue
        fi

        local description run_count last_status
        description=$(jq -r '.description // "N/A"' "$config_file")
        run_count=$(jq -r '.runCount // 0' "$config_file")
        last_status=$(jq -r '.lastStatus // "N/A"' "$config_file")

        local status_color="$NC"
        case "$last_status" in
            success) status_color="$GREEN" ;;
            failed) status_color="$RED" ;;
        esac

        printf "%-20s %-35s %-12s ${status_color}%s${NC}\n" \
            "$rname" "${description:0:35}" "$run_count" "$last_status"
    done

    return 0
}

#######################################
# Edit runner AGENTS.md
#######################################
cmd_edit() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        return 1
    fi

    if ! runner_exists "$name"; then
        log_error "Runner not found: $name"
        return 1
    fi

    local dir
    dir=$(runner_dir "$name")
    local agents_file="$dir/AGENTS.md"

    local editor="${EDITOR:-vim}"
    "$editor" "$agents_file"

    log_success "Updated AGENTS.md for runner: $name"
    return 0
}

#######################################
# View runner logs
#######################################
cmd_logs() {
    local name="${1:-}"
    shift || true

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        return 1
    fi

    if ! runner_exists "$name"; then
        log_error "Runner not found: $name"
        return 1
    fi

    local tail_lines=50 follow=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tail) [[ $# -lt 2 ]] && { log_error "--tail requires a value"; return 1; }; tail_lines="$2"; shift 2 ;;
            --follow|-f) follow=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    local dir
    dir=$(runner_dir "$name")
    local runs_dir="$dir/runs"

    if [[ ! -d "$runs_dir" ]]; then
        log_info "No run logs found for runner: $name"
        return 0
    fi

    local log_files
    log_files=$(find "$runs_dir" -name "*.log" -type f 2>/dev/null | sort -r)

    if [[ -z "$log_files" ]]; then
        log_info "No run logs found for runner: $name"
        return 0
    fi

    if [[ "$follow" == "true" ]]; then
        local latest
        latest=$(echo "$log_files" | head -1)
        log_info "Following latest log: $(basename "$latest")"
        tail -f "$latest"
    else
        local latest
        latest=$(echo "$log_files" | head -1)
        echo -e "${BOLD}Latest run: $(basename "$latest" .log)${NC}"
        tail -n "$tail_lines" "$latest"
    fi

    return 0
}

#######################################
# Stop a running session (abort)
#######################################
cmd_stop() {
    check_jq || return 1

    local name="${1:-}"

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        return 1
    fi

    if ! runner_exists "$name"; then
        log_error "Runner not found: $name"
        return 1
    fi

    local dir
    dir=$(runner_dir "$name")

    if [[ ! -f "$dir/session.id" ]]; then
        log_warn "No active session found for runner: $name"
        return 0
    fi

    local session_id
    session_id=$(cat "$dir/session.id")

    local protocol
    protocol=$(get_protocol "$OPENCODE_HOST")
    local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/session/${session_id}/abort"

    build_curl_args

    if curl "${CURL_ARGS[@]}" -X POST "$url" &>/dev/null; then
        log_success "Aborted session for runner: $name"
    else
        log_warn "Could not abort session (may not be running)"
    fi

    return 0
}

#######################################
# Destroy a runner
#######################################
cmd_destroy() {
    local name="${1:-}"
    shift || true

    if [[ -z "$name" ]]; then
        log_error "Runner name required"
        return 1
    fi

    if ! runner_exists "$name"; then
        log_error "Runner not found: $name"
        return 1
    fi

    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ "$force" != "true" ]]; then
        echo -n "Destroy runner '$name' and all its data? [y/N] "
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "Cancelled"
            return 0
        fi
    fi

    local dir
    dir=$(runner_dir "$name")
    rm -rf "$dir"

    # Clean up memory namespace if it exists
    local ns_dir="$HOME/.aidevops/.agent-workspace/memory/namespaces/$name"
    if [[ -d "$ns_dir" ]]; then
        rm -rf "$ns_dir"
        log_info "Removed memory namespace: $name"
    fi

    log_success "Destroyed runner: $name"
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat << 'EOF'
runner-helper.sh - Named headless AI agent instances

USAGE:
    runner-helper.sh <command> [options]

COMMANDS:
    create <name>           Create a new runner
    run <name> "prompt"     Dispatch a task to a runner
    status <name>           Show runner status and metadata
    list                    List all runners
    edit <name>             Open runner AGENTS.md in $EDITOR
    logs <name>             View run logs
    stop <name>             Abort running session
    destroy <name>          Remove a runner and all its data
    help                    Show this help

CREATE OPTIONS:
    --description "DESC"    Runner description
    --model PROVIDER/MODEL  AI model (default: anthropic/claude-sonnet-4-20250514)
    --workdir PATH          Default working directory

RUN OPTIONS:
    --attach URL            Attach to running OpenCode server (avoids MCP cold boot)
    --model PROVIDER/MODEL  Override model for this run
    --format json           Output format (default or json)
    --timeout SECONDS       Max execution time (default: 600)
    --continue, -c          Continue previous session

LIST OPTIONS:
    --format json           Output as JSON

LOGS OPTIONS:
    --tail N                Number of lines (default: 50)
    --follow, -f            Follow log output

EXAMPLES:
    # Create a code reviewer
    runner-helper.sh create code-reviewer \
      --description "Reviews code for security and quality" \
      --model anthropic/claude-sonnet-4-20250514

    # Run a review task
    runner-helper.sh run code-reviewer "Review src/auth/ for vulnerabilities"

    # Run against warm server (faster, no MCP cold boot)
    runner-helper.sh run code-reviewer "Review src/auth/" \
      --attach http://localhost:4096

    # Continue a previous conversation
    runner-helper.sh run code-reviewer "Now check the error handling" --continue

    # Edit runner instructions
    runner-helper.sh edit code-reviewer

    # View recent logs
    runner-helper.sh logs code-reviewer --tail 100

    # List all runners as JSON
    runner-helper.sh list --format json

DIRECTORY:
    Runners: ~/.aidevops/.agent-workspace/runners/
    Each runner: AGENTS.md, config.json, runs/

INTEGRATION:
    Memory:  memory-helper.sh store --namespace <runner-name> --content "..."
    Mailbox: mail-helper.sh send --to <runner-name> --type task_dispatch --payload "..."
    Cron:    cron-helper.sh add --task "runner-helper.sh run <name> 'prompt'"

REQUIREMENTS:
    - opencode (https://opencode.ai)
    - jq (brew install jq)

EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        create) cmd_create "$@" ;;
        run) cmd_run "$@" ;;
        status) cmd_status "$@" ;;
        list) cmd_list "$@" ;;
        edit) cmd_edit "$@" ;;
        logs) cmd_logs "$@" ;;
        stop) cmd_stop "$@" ;;
        destroy) cmd_destroy "$@" ;;
        help|--help|-h) cmd_help ;;
        *) log_error "Unknown command: $command"; cmd_help; return 1 ;;
    esac
}

main "$@"
