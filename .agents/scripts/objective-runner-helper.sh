#!/usr/bin/env bash
# objective-runner-helper.sh - Long-running objective execution with safety guardrails
#
# Executes open-ended objectives via a stateless coordinator loop with configurable
# safety guardrails: budget limits, step limits, scope constraints, checkpoint reviews,
# rollback capability, and full audit logging.
#
# Usage:
#   objective-runner-helper.sh start <objective> [options]
#   objective-runner-helper.sh status <objective-id>
#   objective-runner-helper.sh pause <objective-id>
#   objective-runner-helper.sh resume <objective-id>
#   objective-runner-helper.sh rollback <objective-id>
#   objective-runner-helper.sh audit <objective-id> [--tail N]
#   objective-runner-helper.sh list [--state running|paused|complete|failed]
#   objective-runner-helper.sh help
#
# Options (for start):
#   --max-steps N           Max iterations before stop (default: 50)
#   --checkpoint-every N    Pause for review every N steps (default: 0 = disabled)
#   --max-cost DOLLARS      Max estimated cost in USD (default: 5.00)
#   --max-tokens N          Max total tokens (default: 500000)
#   --allowed-paths "p1,p2" Comma-separated path whitelist (default: cwd)
#   --allowed-tools "t1,t2" Comma-separated tool whitelist (default: all)
#   --workdir PATH          Working directory (default: cwd)
#   --model PROVIDER/MODEL  AI model (default: anthropic/claude-sonnet-4-20250514)
#   --runner NAME           Use existing runner identity (optional)
#   --dry-run               Show config without executing
#
# Directory: ~/.aidevops/.agent-workspace/objectives/<id>/
#   ├── config.json         # Objective configuration and guardrails
#   ├── state.json          # Current state (step count, token usage, cost)
#   ├── audit.log           # Full audit trail of all actions
#   └── runs/               # Per-step output logs
#
# Integration:
#   - Runner: runner-helper.sh (optional identity)
#   - Memory: memory-helper.sh (audit log persistence)
#   - Supervisor: supervisor-helper.sh (batch coordination)
#   - Git: worktree isolation for rollback
#
# Safety guardrails:
#   1. Budget limits: max tokens and estimated cost cap
#   2. Step limits: max iterations before mandatory stop
#   3. Scope constraints: path and tool whitelists
#   4. Checkpoint reviews: periodic human approval gates
#   5. Rollback: git worktree isolation, one-command undo
#   6. Audit log: every action logged with timestamps

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly OBJECTIVES_DIR="${AIDEVOPS_OBJECTIVES_DIR:-$HOME/.aidevops/.agent-workspace/objectives}"
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"
# Used by future runner identity integration
export RUNNER_HELPER="$HOME/.aidevops/agents/scripts/runner-helper.sh"
readonly DEFAULT_MODEL="anthropic/claude-sonnet-4-20250514"
readonly DEFAULT_MAX_STEPS=50
readonly DEFAULT_MAX_COST="5.00"
readonly DEFAULT_MAX_TOKENS=500000
readonly DEFAULT_CHECKPOINT_EVERY=0

readonly BOLD='\033[1m'

#######################################
# Logging
#######################################
log_info() { echo -e "${BLUE}[OBJECTIVE]${NC} $*"; }
log_success() { echo -e "${GREEN}[OBJECTIVE]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[OBJECTIVE]${NC} $*"; }
log_error() { echo -e "${RED}[OBJECTIVE]${NC} $*" >&2; }

#######################################
# Audit logging - append to objective audit trail
#######################################
audit_log() {
    local obj_dir="$1"
    shift
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$timestamp] $*" >> "$obj_dir/audit.log"
    return 0
}

#######################################
# Generate objective ID from timestamp
#######################################
generate_id() {
    echo "obj-$(date +%Y%m%d-%H%M%S)-$$"
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
# Get objective directory
#######################################
obj_dir() {
    local obj_id="$1"
    echo "$OBJECTIVES_DIR/$obj_id"
}

#######################################
# Check if objective exists
#######################################
obj_exists() {
    local obj_id="$1"
    local dir
    dir=$(obj_dir "$obj_id")
    [[ -d "$dir" && -f "$dir/config.json" ]]
}

#######################################
# Read objective config value
#######################################
obj_config() {
    local obj_id="$1"
    local key="$2"
    local dir
    dir=$(obj_dir "$obj_id")
    jq -r --arg key "$key" '.[$key] // empty' "$dir/config.json" 2>/dev/null
}

#######################################
# Read objective state value
#######################################
obj_state() {
    local obj_id="$1"
    local key="$2"
    local dir
    dir=$(obj_dir "$obj_id")
    if [[ -f "$dir/state.json" ]]; then
        jq -r --arg key "$key" '.[$key] // empty' "$dir/state.json" 2>/dev/null
    fi
}

#######################################
# Update objective state
#######################################
update_state() {
    local obj_id="$1"
    shift
    local dir
    dir=$(obj_dir "$obj_id")
    local state_file="$dir/state.json"

    if [[ ! -f "$state_file" ]]; then
        echo '{}' > "$state_file"
    fi

    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "$temp_file"' RETURN

    # Build jq expression from key=value pairs
    local jq_expr="."
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        # Detect numeric values for proper JSON typing
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            jq_expr="$jq_expr | .\"$key\" = $value"
        elif [[ "$value" =~ ^[0-9]+\.[0-9]+$ ]]; then
            jq_expr="$jq_expr | .\"$key\" = $value"
        else
            jq_expr="$jq_expr | .\"$key\" = \"$value\""
        fi
        shift
    done

    jq "$jq_expr" "$state_file" > "$temp_file" && mv "$temp_file" "$state_file"
    return 0
}

#######################################
# Check guardrails - returns 0 if safe, 1 if limit hit
# Sets GUARDRAIL_VIOLATION to the reason if violated
#######################################
check_guardrails() {
    local obj_id="$1"
    local dir
    dir=$(obj_dir "$obj_id")
    GUARDRAIL_VIOLATION=""

    local current_step max_steps max_cost max_tokens
    local estimated_cost total_tokens checkpoint_every

    current_step=$(obj_state "$obj_id" "current_step")
    current_step="${current_step:-0}"

    max_steps=$(obj_config "$obj_id" "max_steps")
    max_cost=$(obj_config "$obj_id" "max_cost")
    max_tokens=$(obj_config "$obj_id" "max_tokens")
    checkpoint_every=$(obj_config "$obj_id" "checkpoint_every")

    estimated_cost=$(obj_state "$obj_id" "estimated_cost")
    estimated_cost="${estimated_cost:-0}"

    total_tokens=$(obj_state "$obj_id" "total_tokens")
    total_tokens="${total_tokens:-0}"

    # Step limit check
    if [[ "$current_step" -ge "$max_steps" ]]; then
        GUARDRAIL_VIOLATION="Step limit reached ($current_step/$max_steps)"
        return 1
    fi

    # Cost limit check (using bc for float comparison)
    if command -v bc &>/dev/null; then
        if [[ $(echo "$estimated_cost >= $max_cost" | bc -l 2>/dev/null || echo "0") -eq 1 ]]; then
            GUARDRAIL_VIOLATION="Cost limit reached (\$$estimated_cost/\$$max_cost)"
            return 1
        fi
    fi

    # Token limit check
    if [[ "$total_tokens" -ge "$max_tokens" ]]; then
        GUARDRAIL_VIOLATION="Token limit reached ($total_tokens/$max_tokens)"
        return 1
    fi

    # Checkpoint review check
    if [[ "$checkpoint_every" -gt 0 ]] && [[ "$current_step" -gt 0 ]]; then
        local remainder=$((current_step % checkpoint_every))
        if [[ "$remainder" -eq 0 ]]; then
            GUARDRAIL_VIOLATION="Checkpoint review due (step $current_step, every $checkpoint_every)"
            return 1
        fi
    fi

    return 0
}

#######################################
# Build scope constraint instructions for the AI prompt
#######################################
build_scope_instructions() {
    local obj_id="$1"
    local instructions=""

    local allowed_paths
    allowed_paths=$(obj_config "$obj_id" "allowed_paths")
    if [[ -n "$allowed_paths" ]]; then
        instructions="## Scope Constraints

You are ONLY allowed to read/modify files within these paths:
"
        local IFS=','
        for path in $allowed_paths; do
            instructions="$instructions- $path
"
        done
        instructions="$instructions
Do NOT access files outside these paths. If you need to, STOP and report the need.
"
    fi

    local allowed_tools
    allowed_tools=$(obj_config "$obj_id" "allowed_tools")
    if [[ -n "$allowed_tools" && "$allowed_tools" != "all" ]]; then
        instructions="${instructions}
## Tool Constraints

You are ONLY allowed to use these tools: $allowed_tools
Do NOT use other tools. If you need a restricted tool, STOP and report the need.
"
    fi

    echo "$instructions"
}

#######################################
# Estimate token cost from log file size
# Rough heuristic: 1 byte ~= 0.25 tokens, cost ~= tokens * $0.000003 (sonnet input)
#######################################
estimate_step_cost() {
    local log_file="$1"
    local bytes=0
    if [[ -f "$log_file" ]]; then
        bytes=$(wc -c < "$log_file" | tr -d ' ')
    fi
    local tokens=$((bytes / 4))
    # Cost estimate: input + output at roughly $3/MTok average
    local cost
    if command -v bc &>/dev/null; then
        cost=$(echo "scale=4; $tokens * 0.000003" | bc -l 2>/dev/null || echo "0.0001")
    else
        cost="0.0001"
    fi
    echo "$tokens $cost"
}

#######################################
# Start a new objective
#######################################
cmd_start() {
    check_jq || return 1

    local objective="${1:-}"
    shift || true

    if [[ -z "$objective" ]]; then
        log_error "Objective description required"
        echo "Usage: objective-runner-helper.sh start \"Improve test coverage to 80%\" [options]"
        return 1
    fi

    # Parse options
    local max_steps="$DEFAULT_MAX_STEPS"
    local checkpoint_every="$DEFAULT_CHECKPOINT_EVERY"
    local max_cost="$DEFAULT_MAX_COST"
    local max_tokens="$DEFAULT_MAX_TOKENS"
    local allowed_paths=""
    local allowed_tools="all"
    local workdir=""
    local model="$DEFAULT_MODEL"
    local runner=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-steps) [[ $# -lt 2 ]] && { log_error "--max-steps requires a value"; return 1; }; max_steps="$2"; shift 2 ;;
            --checkpoint-every) [[ $# -lt 2 ]] && { log_error "--checkpoint-every requires a value"; return 1; }; checkpoint_every="$2"; shift 2 ;;
            --max-cost) [[ $# -lt 2 ]] && { log_error "--max-cost requires a value"; return 1; }; max_cost="$2"; shift 2 ;;
            --max-tokens) [[ $# -lt 2 ]] && { log_error "--max-tokens requires a value"; return 1; }; max_tokens="$2"; shift 2 ;;
            --allowed-paths) [[ $# -lt 2 ]] && { log_error "--allowed-paths requires a value"; return 1; }; allowed_paths="$2"; shift 2 ;;
            --allowed-tools) [[ $# -lt 2 ]] && { log_error "--allowed-tools requires a value"; return 1; }; allowed_tools="$2"; shift 2 ;;
            --workdir) [[ $# -lt 2 ]] && { log_error "--workdir requires a value"; return 1; }; workdir="$2"; shift 2 ;;
            --model) [[ $# -lt 2 ]] && { log_error "--model requires a value"; return 1; }; model="$2"; shift 2 ;;
            --runner) [[ $# -lt 2 ]] && { log_error "--runner requires a value"; return 1; }; runner="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$workdir" ]]; then
        workdir="$(pwd)"
    fi

    if [[ -z "$allowed_paths" ]]; then
        allowed_paths="$workdir"
    fi

    local obj_id
    obj_id=$(generate_id)

    if [[ "$dry_run" == "true" ]]; then
        echo -e "${BOLD}Objective (dry run):${NC}"
        echo "──────────────────────────────────"
        echo "ID: $obj_id"
        echo "Objective: $objective"
        echo "Model: $model"
        echo "Workdir: $workdir"
        echo ""
        echo -e "${BOLD}Guardrails:${NC}"
        echo "  Max steps: $max_steps"
        echo "  Checkpoint every: ${checkpoint_every:-disabled} steps"
        echo "  Max cost: \$$max_cost"
        echo "  Max tokens: $max_tokens"
        echo "  Allowed paths: $allowed_paths"
        echo "  Allowed tools: $allowed_tools"
        if [[ -n "$runner" ]]; then
            echo "  Runner: $runner"
        fi
        return 0
    fi

    # Create objective directory
    local dir
    dir=$(obj_dir "$obj_id")
    mkdir -p "$dir/runs"

    # Create config
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n \
        --arg id "$obj_id" \
        --arg objective "$objective" \
        --arg model "$model" \
        --arg workdir "$workdir" \
        --argjson max_steps "$max_steps" \
        --argjson checkpoint_every "$checkpoint_every" \
        --arg max_cost "$max_cost" \
        --argjson max_tokens "$max_tokens" \
        --arg allowed_paths "$allowed_paths" \
        --arg allowed_tools "$allowed_tools" \
        --arg runner "${runner:-}" \
        --arg created "$timestamp" \
        '{
            id: $id,
            objective: $objective,
            model: $model,
            workdir: $workdir,
            max_steps: $max_steps,
            checkpoint_every: $checkpoint_every,
            max_cost: $max_cost,
            max_tokens: $max_tokens,
            allowed_paths: $allowed_paths,
            allowed_tools: $allowed_tools,
            runner: $runner,
            created: $created
        }' > "$dir/config.json"

    # Initialize state
    jq -n \
        --arg status "running" \
        --arg started "$timestamp" \
        '{
            status: $status,
            current_step: 0,
            total_tokens: 0,
            estimated_cost: 0,
            started: $started,
            last_step: null,
            completed: null,
            completion_reason: null
        }' > "$dir/state.json"

    # Initialize audit log
    audit_log "$dir" "STARTED objective=$objective model=$model max_steps=$max_steps max_cost=$max_cost max_tokens=$max_tokens"
    audit_log "$dir" "GUARDRAILS allowed_paths=$allowed_paths allowed_tools=$allowed_tools checkpoint_every=$checkpoint_every"

    # Store in memory for cross-session recall
    if [[ -x "$MEMORY_HELPER" ]]; then
        "$MEMORY_HELPER" store \
            --auto \
            --type "OBJECTIVE_STARTED" \
            --content "Objective $obj_id started: $objective (max_steps=$max_steps, max_cost=\$$max_cost)" \
            --tags "objective,automation" 2>/dev/null || true
    fi

    log_success "Created objective: $obj_id"
    echo ""
    echo "Directory: $dir"
    echo "Objective: $objective"
    echo ""
    echo -e "${BOLD}Guardrails:${NC}"
    echo "  Max steps: $max_steps"
    echo "  Checkpoint every: ${checkpoint_every} steps (0=disabled)"
    echo "  Max cost: \$$max_cost"
    echo "  Max tokens: $max_tokens"
    echo "  Allowed paths: $allowed_paths"
    echo "  Allowed tools: $allowed_tools"
    echo ""

    # Run the coordinator loop
    run_loop "$obj_id"
    return $?
}

#######################################
# Main coordinator loop - stateless pulse-based execution
#######################################
run_loop() {
    local obj_id="$1"
    local dir
    dir=$(obj_dir "$obj_id")

    check_opencode || return 1

    local objective
    objective=$(obj_config "$obj_id" "objective")
    local model
    model=$(obj_config "$obj_id" "model")
    local workdir
    workdir=$(obj_config "$obj_id" "workdir")

    log_info "Starting coordinator loop for $obj_id"

    while true; do
        local status
        status=$(obj_state "$obj_id" "status")

        # Exit conditions
        if [[ "$status" == "complete" || "$status" == "failed" || "$status" == "cancelled" ]]; then
            log_info "Objective $obj_id is $status"
            break
        fi

        if [[ "$status" == "paused" ]]; then
            log_warn "Objective $obj_id is paused. Use 'resume $obj_id' to continue."
            break
        fi

        # Check guardrails before each step
        if ! check_guardrails "$obj_id"; then
            local violation="$GUARDRAIL_VIOLATION"
            audit_log "$dir" "GUARDRAIL_HIT $violation"

            # Checkpoint reviews pause; hard limits stop
            if [[ "$violation" == *"Checkpoint review"* ]]; then
                update_state "$obj_id" "status=paused"
                log_warn "Checkpoint review: $violation"
                log_info "Review progress, then run: objective-runner-helper.sh resume $obj_id"
                break
            else
                update_state "$obj_id" "status=paused" "completion_reason=$violation"
                log_warn "Guardrail hit: $violation"
                log_info "Objective paused. Review and adjust limits, then resume."
                break
            fi
        fi

        # Increment step
        local current_step
        current_step=$(obj_state "$obj_id" "current_step")
        current_step="${current_step:-0}"
        local next_step=$((current_step + 1))
        local step_timestamp
        step_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        update_state "$obj_id" "current_step=$next_step" "last_step=$step_timestamp"
        audit_log "$dir" "STEP_START step=$next_step"

        # Build prompt with scope constraints and progress context
        local scope_instructions
        scope_instructions=$(build_scope_instructions "$obj_id")

        local max_steps
        max_steps=$(obj_config "$obj_id" "max_steps")

        local prompt="## Objective

$objective

## Progress

Step $next_step of $max_steps maximum.

$scope_instructions

## Instructions

Work toward the objective above. After each meaningful unit of work:
- If the objective is COMPLETE, respond with exactly: <promise>OBJECTIVE_COMPLETE</promise>
- If you are BLOCKED and need human input, respond with exactly: <promise>OBJECTIVE_BLOCKED</promise>
- Otherwise, describe what you accomplished and what remains.

Focus on making measurable progress. Be efficient with tokens."

        # Dispatch to opencode
        local log_file="$dir/runs/step-${next_step}.log"
        local -a cmd_args=("opencode" "run" "-m" "$model" "--title" "objective/$obj_id/step-$next_step")

        log_info "Step $next_step: dispatching to $model"

        local exit_code=0
        local start_time
        start_time=$(date +%s)

        if "${cmd_args[@]}" "$prompt" > "$log_file" 2>&1; then
            exit_code=0
        else
            exit_code=$?
        fi

        local end_time duration
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        # Estimate cost from output
        local step_stats
        step_stats=$(estimate_step_cost "$log_file")
        local step_tokens step_cost
        step_tokens=$(echo "$step_stats" | cut -d' ' -f1)
        step_cost=$(echo "$step_stats" | cut -d' ' -f2)

        # Update cumulative totals
        local prev_tokens prev_cost
        prev_tokens=$(obj_state "$obj_id" "total_tokens")
        prev_tokens="${prev_tokens:-0}"
        prev_cost=$(obj_state "$obj_id" "estimated_cost")
        prev_cost="${prev_cost:-0}"

        local new_tokens=$((prev_tokens + step_tokens))
        local new_cost
        if command -v bc &>/dev/null; then
            new_cost=$(echo "scale=4; $prev_cost + $step_cost" | bc -l 2>/dev/null || echo "$prev_cost")
        else
            new_cost="$prev_cost"
        fi

        update_state "$obj_id" "total_tokens=$new_tokens" "estimated_cost=$new_cost"
        audit_log "$dir" "STEP_END step=$next_step exit=$exit_code duration=${duration}s tokens=$step_tokens cost=\$$step_cost"

        # Check for completion signals in output
        if [[ -f "$log_file" ]]; then
            if grep -q '<promise>OBJECTIVE_COMPLETE</promise>' "$log_file"; then
                update_state "$obj_id" "status=complete" "completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "completion_reason=objective_complete"
                audit_log "$dir" "COMPLETED objective_complete after $next_step steps, \$$new_cost estimated cost"
                log_success "Objective complete after $next_step steps (\$$new_cost estimated cost)"

                # Store completion in memory
                if [[ -x "$MEMORY_HELPER" ]]; then
                    "$MEMORY_HELPER" store \
                        --auto \
                        --type "OBJECTIVE_COMPLETED" \
                        --content "Objective $obj_id completed: $objective ($next_step steps, \$$new_cost)" \
                        --tags "objective,automation,completed" 2>/dev/null || true
                fi
                break
            fi

            if grep -q '<promise>OBJECTIVE_BLOCKED</promise>' "$log_file"; then
                update_state "$obj_id" "status=paused" "completion_reason=blocked"
                audit_log "$dir" "BLOCKED at step $next_step - needs human input"
                log_warn "Objective blocked at step $next_step. Review output and resume."
                break
            fi
        fi

        # Handle dispatch failure
        if [[ $exit_code -ne 0 ]]; then
            audit_log "$dir" "DISPATCH_FAILED step=$next_step exit=$exit_code"
            log_error "Step $next_step failed (exit $exit_code). Pausing objective."
            update_state "$obj_id" "status=paused" "completion_reason=dispatch_failed"
            break
        fi

        log_info "Step $next_step complete (${duration}s, ~$step_tokens tokens, ~\$$step_cost)"
    done

    return 0
}

#######################################
# Show objective status
#######################################
cmd_status() {
    check_jq || return 1

    local obj_id="${1:-}"
    if [[ -z "$obj_id" ]]; then
        log_error "Objective ID required"
        return 1
    fi

    if ! obj_exists "$obj_id"; then
        log_error "Objective not found: $obj_id"
        return 1
    fi

    local dir
    dir=$(obj_dir "$obj_id")

    local objective model workdir max_steps max_cost max_tokens checkpoint_every
    objective=$(obj_config "$obj_id" "objective")
    model=$(obj_config "$obj_id" "model")
    workdir=$(obj_config "$obj_id" "workdir")
    max_steps=$(obj_config "$obj_id" "max_steps")
    max_cost=$(obj_config "$obj_id" "max_cost")
    max_tokens=$(obj_config "$obj_id" "max_tokens")
    checkpoint_every=$(obj_config "$obj_id" "checkpoint_every")

    local status current_step total_tokens estimated_cost started completed completion_reason
    status=$(obj_state "$obj_id" "status")
    current_step=$(obj_state "$obj_id" "current_step")
    total_tokens=$(obj_state "$obj_id" "total_tokens")
    estimated_cost=$(obj_state "$obj_id" "estimated_cost")
    started=$(obj_state "$obj_id" "started")
    completed=$(obj_state "$obj_id" "completed")
    completion_reason=$(obj_state "$obj_id" "completion_reason")

    local status_color="$NC"
    case "$status" in
        running) status_color="$GREEN" ;;
        paused) status_color="$YELLOW" ;;
        complete) status_color="$GREEN" ;;
        failed|cancelled) status_color="$RED" ;;
    esac

    echo -e "${BOLD}Objective: $obj_id${NC}"
    echo "──────────────────────────────────"
    echo "Description: $objective"
    echo -e "Status: ${status_color}${status}${NC}"
    echo "Model: $model"
    echo "Workdir: $workdir"
    echo ""
    echo -e "${BOLD}Progress:${NC}"
    echo "  Steps: ${current_step:-0}/$max_steps"
    echo "  Tokens: ${total_tokens:-0}/$max_tokens"
    echo "  Est. cost: \$${estimated_cost:-0}/\$$max_cost"
    echo "  Checkpoint: every $checkpoint_every steps (0=disabled)"
    echo ""
    echo "Started: ${started:-N/A}"
    if [[ -n "$completed" ]]; then
        echo "Completed: $completed"
    fi
    if [[ -n "$completion_reason" ]]; then
        echo "Reason: $completion_reason"
    fi
    echo ""
    echo "Directory: $dir"

    return 0
}

#######################################
# Pause a running objective
#######################################
cmd_pause() {
    check_jq || return 1

    local obj_id="${1:-}"
    if [[ -z "$obj_id" ]]; then
        log_error "Objective ID required"
        return 1
    fi

    if ! obj_exists "$obj_id"; then
        log_error "Objective not found: $obj_id"
        return 1
    fi

    local status
    status=$(obj_state "$obj_id" "status")
    if [[ "$status" != "running" ]]; then
        log_warn "Objective is not running (status: $status)"
        return 0
    fi

    update_state "$obj_id" "status=paused" "completion_reason=manual_pause"
    local dir
    dir=$(obj_dir "$obj_id")
    audit_log "$dir" "PAUSED manual pause"
    log_success "Paused objective: $obj_id"

    return 0
}

#######################################
# Resume a paused objective
#######################################
cmd_resume() {
    check_jq || return 1
    check_opencode || return 1

    local obj_id="${1:-}"
    if [[ -z "$obj_id" ]]; then
        log_error "Objective ID required"
        return 1
    fi

    if ! obj_exists "$obj_id"; then
        log_error "Objective not found: $obj_id"
        return 1
    fi

    local status
    status=$(obj_state "$obj_id" "status")
    if [[ "$status" != "paused" ]]; then
        log_warn "Objective is not paused (status: $status)"
        return 0
    fi

    update_state "$obj_id" "status=running" "completion_reason="
    local dir
    dir=$(obj_dir "$obj_id")
    audit_log "$dir" "RESUMED"
    log_success "Resumed objective: $obj_id"

    # Continue the loop
    run_loop "$obj_id"
    return $?
}

#######################################
# Rollback objective changes via git
#######################################
cmd_rollback() {
    local obj_id="${1:-}"
    if [[ -z "$obj_id" ]]; then
        log_error "Objective ID required"
        return 1
    fi

    if ! obj_exists "$obj_id"; then
        log_error "Objective not found: $obj_id"
        return 1
    fi

    local workdir
    workdir=$(obj_config "$obj_id" "workdir")

    echo -e "${YELLOW}Rollback will discard ALL uncommitted changes in: $workdir${NC}"
    echo -n "Proceed? [y/N] "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        return 0
    fi

    # Check if workdir is a git worktree
    if git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
        local worktree_root
        worktree_root=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null)
        local main_worktree
        main_worktree=$(git -C "$workdir" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')

        if [[ "$worktree_root" != "$main_worktree" ]]; then
            # This is a worktree - safe to remove entirely
            log_info "Removing worktree: $worktree_root"
            local branch
            branch=$(git -C "$workdir" branch --show-current 2>/dev/null || echo "")
            git -C "$main_worktree" worktree remove "$worktree_root" --force 2>/dev/null || true
            if [[ -n "$branch" ]]; then
                git -C "$main_worktree" branch -D "$branch" 2>/dev/null || true
            fi
            log_success "Worktree removed"
        else
            # Main repo - reset changes
            log_info "Resetting changes in: $workdir"
            git -C "$workdir" checkout -- . 2>/dev/null || true
            git -C "$workdir" clean -fd 2>/dev/null || true
            log_success "Changes reset"
        fi
    else
        log_warn "Workdir is not a git repository. Cannot rollback."
        return 1
    fi

    update_state "$obj_id" "status=cancelled" "completion_reason=rolled_back"
    local dir
    dir=$(obj_dir "$obj_id")
    audit_log "$dir" "ROLLED_BACK workdir=$workdir"
    log_success "Rolled back objective: $obj_id"

    return 0
}

#######################################
# View audit log
#######################################
cmd_audit() {
    local obj_id="${1:-}"
    shift || true

    if [[ -z "$obj_id" ]]; then
        log_error "Objective ID required"
        return 1
    fi

    if ! obj_exists "$obj_id"; then
        log_error "Objective not found: $obj_id"
        return 1
    fi

    local tail_lines=50

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tail) [[ $# -lt 2 ]] && { log_error "--tail requires a value"; return 1; }; tail_lines="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    local dir
    dir=$(obj_dir "$obj_id")
    local audit_file="$dir/audit.log"

    if [[ ! -f "$audit_file" ]]; then
        log_info "No audit log found for: $obj_id"
        return 0
    fi

    echo -e "${BOLD}Audit log: $obj_id${NC} (last $tail_lines entries)"
    echo "──────────────────────────────────"
    tail -n "$tail_lines" "$audit_file"

    return 0
}

#######################################
# List objectives
#######################################
cmd_list() {
    check_jq || return 1

    local filter_state=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state) [[ $# -lt 2 ]] && { log_error "--state requires a value"; return 1; }; filter_state="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ ! -d "$OBJECTIVES_DIR" ]]; then
        log_info "No objectives found"
        echo ""
        echo "Start one with:"
        echo "  objective-runner-helper.sh start \"Your objective\" [options]"
        return 0
    fi

    local objectives
    objectives=$(find "$OBJECTIVES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r)

    if [[ -z "$objectives" ]]; then
        log_info "No objectives found"
        return 0
    fi

    printf "${BOLD}%-30s %-10s %-8s %-10s %s${NC}\n" "ID" "Status" "Steps" "Cost" "Objective"
    printf "%-30s %-10s %-8s %-10s %s\n" "──────────────────────────────" "──────────" "────────" "──────────" "──────────────────────"

    for obj_path in $objectives; do
        local oid
        oid=$(basename "$obj_path")
        local config_file="$obj_path/config.json"
        local state_file="$obj_path/state.json"

        if [[ ! -f "$config_file" ]]; then
            continue
        fi

        local obj_desc status current_step max_steps estimated_cost
        obj_desc=$(jq -r '.objective // "N/A"' "$config_file")
        if [[ -f "$state_file" ]]; then
            status=$(jq -r '.status // "unknown"' "$state_file")
            current_step=$(jq -r '.current_step // 0' "$state_file")
            estimated_cost=$(jq -r '.estimated_cost // 0' "$state_file")
        else
            status="unknown"
            current_step=0
            estimated_cost=0
        fi
        max_steps=$(jq -r '.max_steps // 0' "$config_file")

        # Apply filter
        if [[ -n "$filter_state" && "$status" != "$filter_state" ]]; then
            continue
        fi

        local status_color="$NC"
        case "$status" in
            running) status_color="$GREEN" ;;
            paused) status_color="$YELLOW" ;;
            complete) status_color="$GREEN" ;;
            failed|cancelled) status_color="$RED" ;;
        esac

        printf "%-30s ${status_color}%-10s${NC} %-8s %-10s %s\n" \
            "$oid" "$status" "${current_step}/${max_steps}" "\$$estimated_cost" "${obj_desc:0:40}"
    done

    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat << 'EOF'
objective-runner-helper.sh - Long-running objective execution with safety guardrails

USAGE:
    objective-runner-helper.sh <command> [options]

COMMANDS:
    start <objective>       Start a new objective with guardrails
    status <id>             Show objective status and progress
    pause <id>              Pause a running objective
    resume <id>             Resume a paused objective
    rollback <id>           Rollback all changes (git reset/worktree remove)
    audit <id>              View audit log
    list                    List all objectives
    help                    Show this help

START OPTIONS:
    --max-steps N           Max iterations before stop (default: 50)
    --checkpoint-every N    Pause for review every N steps (default: 0 = disabled)
    --max-cost DOLLARS      Max estimated cost in USD (default: 5.00)
    --max-tokens N          Max total tokens (default: 500000)
    --allowed-paths "p,p"   Comma-separated path whitelist (default: cwd)
    --allowed-tools "t,t"   Comma-separated tool whitelist (default: all)
    --workdir PATH          Working directory (default: cwd)
    --model PROVIDER/MODEL  AI model (default: anthropic/claude-sonnet-4-20250514)
    --runner NAME           Use existing runner identity (optional)
    --dry-run               Show config without executing

LIST OPTIONS:
    --state STATE           Filter by state (running, paused, complete, failed, cancelled)

AUDIT OPTIONS:
    --tail N                Number of lines to show (default: 50)

SAFETY GUARDRAILS:
    1. Budget limits     - Max tokens and estimated cost cap
    2. Step limits       - Max iterations before mandatory stop
    3. Scope constraints - Path and tool whitelists
    4. Checkpoint reviews - Periodic human approval gates
    5. Rollback          - Git worktree isolation, one-command undo
    6. Audit log         - Every action logged with timestamps

EXAMPLES:
    # Simple objective with defaults
    objective-runner-helper.sh start "Improve test coverage to 80%"

    # Constrained objective with checkpoints
    objective-runner-helper.sh start "Refactor auth module" \
      --max-steps 20 \
      --checkpoint-every 5 \
      --max-cost 2.00 \
      --allowed-paths "src/auth,tests/auth"

    # Dry run to preview config
    objective-runner-helper.sh start "Fix all linting errors" --dry-run

    # Check progress
    objective-runner-helper.sh status obj-20260208-143022-12345

    # View audit trail
    objective-runner-helper.sh audit obj-20260208-143022-12345 --tail 100

    # Rollback if things went wrong
    objective-runner-helper.sh rollback obj-20260208-143022-12345

    # List running objectives
    objective-runner-helper.sh list --state running

DIRECTORY:
    Objectives: ~/.aidevops/.agent-workspace/objectives/
    Each objective: config.json, state.json, audit.log, runs/

INTEGRATION:
    Runner:     runner-helper.sh (optional identity for objectives)
    Memory:     memory-helper.sh (audit persistence, cross-session recall)
    Supervisor: supervisor-helper.sh (batch coordination)
    Git:        Worktree isolation for safe rollback

EOF
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        start) cmd_start "$@" ;;
        status) cmd_status "$@" ;;
        pause) cmd_pause "$@" ;;
        resume) cmd_resume "$@" ;;
        rollback) cmd_rollback "$@" ;;
        audit) cmd_audit "$@" ;;
        list) cmd_list "$@" ;;
        help|--help|-h) cmd_help ;;
        *) log_error "Unknown command: $command"; cmd_help; return 1 ;;
    esac
}

main "$@"
