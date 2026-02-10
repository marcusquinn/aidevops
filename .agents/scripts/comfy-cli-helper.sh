#!/usr/bin/env bash
set -euo pipefail

# comfy-cli-helper.sh — ComfyUI management via comfy-cli
# Wraps comfy-cli with aidevops conventions for install, launch, nodes, models, and snapshots.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
    source "$SCRIPT_DIR/shared-constants.sh"
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

##############################################################################
# Helpers
##############################################################################

log_info() {
    local msg="$1"
    printf "${BLUE}[comfy-cli]${NC} %s\n" "$msg"
    return 0
}

log_success() {
    local msg="$1"
    printf "${GREEN}[comfy-cli]${NC} %s\n" "$msg"
    return 0
}

log_warn() {
    local msg="$1"
    printf "${YELLOW}[comfy-cli]${NC} %s\n" "$msg" >&2
    return 0
}

log_error() {
    local msg="$1"
    printf "${RED}[comfy-cli]${NC} %s\n" "$msg" >&2
    return 0
}

check_comfy_cli() {
    if ! command -v comfy >/dev/null 2>&1; then
        log_error "comfy-cli is not installed."
        log_info "Install with: pip install comfy-cli"
        log_info "Or: brew tap Comfy-Org/comfy-cli && brew install comfy-org/comfy-cli/comfy-cli"
        return 1
    fi
    return 0
}

##############################################################################
# Commands
##############################################################################

cmd_status() {
    log_info "Checking comfy-cli status..."

    if command -v comfy >/dev/null 2>&1; then
        local version
        version=$(comfy --version 2>/dev/null || echo "unknown")
        log_success "comfy-cli installed: $version"
        log_info "Location: $(command -v comfy)"
    else
        log_warn "comfy-cli is not installed"
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        local py_version
        py_version=$(python3 --version 2>/dev/null || echo "unknown")
        log_info "Python: $py_version"
    else
        log_warn "Python 3 not found"
    fi

    if command -v git >/dev/null 2>&1; then
        log_info "git: $(git --version 2>/dev/null)"
    else
        log_warn "git not found (required by comfy-cli)"
    fi

    return 0
}

cmd_install() {
    log_info "Installing comfy-cli..."

    if command -v comfy >/dev/null 2>&1; then
        log_success "comfy-cli is already installed"
        cmd_status
        return 0
    fi

    # Try pip first, then brew
    if command -v pip >/dev/null 2>&1; then
        log_info "Installing via pip..."
        pip install comfy-cli
    elif command -v pip3 >/dev/null 2>&1; then
        log_info "Installing via pip3..."
        pip3 install comfy-cli
    elif command -v brew >/dev/null 2>&1; then
        log_info "Installing via Homebrew..."
        brew tap Comfy-Org/comfy-cli
        brew install comfy-org/comfy-cli/comfy-cli
    else
        log_error "No package manager found. Install pip or Homebrew first."
        return 1
    fi

    if command -v comfy >/dev/null 2>&1; then
        log_success "comfy-cli installed successfully"
        cmd_status
    else
        log_error "Installation failed"
        return 1
    fi

    return 0
}

cmd_setup() {
    local path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --path) path="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    check_comfy_cli || return 1

    if [[ -n "$path" ]]; then
        log_info "Installing ComfyUI to: $path"
        mkdir -p "$path"
        # shellcheck disable=SC2164
        cd "$path"
    fi

    log_info "Running comfy install..."
    comfy install

    log_success "ComfyUI installed"
    log_info "Launch with: comfy-cli-helper.sh launch"
    return 0
}

cmd_launch() {
    local port=""
    local listen=""
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) port="$2"; shift 2 ;;
            --listen) listen="$2"; shift 2 ;;
            --) shift; extra_args+=("$@"); break ;;
            *) extra_args+=("$1"); shift ;;
        esac
    done

    check_comfy_cli || return 1

    local launch_args=()
    if [[ -n "$port" ]] || [[ -n "$listen" ]] || [[ ${#extra_args[@]} -gt 0 ]]; then
        launch_args+=("--")
        [[ -n "$listen" ]] && launch_args+=("--listen" "$listen")
        [[ -n "$port" ]] && launch_args+=("--port" "$port")
        [[ ${#extra_args[@]} -gt 0 ]] && launch_args+=("${extra_args[@]}")
    fi

    log_info "Launching ComfyUI..."
    comfy launch "${launch_args[@]}"
    return 0
}

cmd_node_install() {
    local node_name="${1:-}"
    if [[ -z "$node_name" ]]; then
        log_error "Usage: comfy-cli-helper.sh node-install <node-name>"
        return 1
    fi
    shift

    check_comfy_cli || return 1

    log_info "Installing custom node: $node_name"
    comfy node install "$node_name" "$@"
    log_success "Node installed: $node_name"
    return 0
}

cmd_node_list() {
    local filter="${1:-installed}"

    check_comfy_cli || return 1

    log_info "Listing nodes: $filter"
    comfy node show "$filter"
    return 0
}

cmd_model_download() {
    local url="${1:-}"
    local relative_path="${2:-models/checkpoints}"

    if [[ -z "$url" ]]; then
        log_error "Usage: comfy-cli-helper.sh model-download <url> [relative-path]"
        return 1
    fi

    check_comfy_cli || return 1

    log_info "Downloading model to: $relative_path"
    comfy model download --url "$url" --relative-path "$relative_path"
    log_success "Model downloaded"
    return 0
}

cmd_model_list() {
    local relative_path="${1:-models/checkpoints}"

    check_comfy_cli || return 1

    log_info "Listing models in: $relative_path"
    comfy model list --relative-path "$relative_path"
    return 0
}

cmd_snapshot_save() {
    local output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output="$2"; shift 2 ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    check_comfy_cli || return 1

    local save_args=()
    [[ -n "$output" ]] && save_args+=("--output" "$output")

    log_info "Saving environment snapshot..."
    comfy node save-snapshot "${save_args[@]}"
    log_success "Snapshot saved"
    return 0
}

cmd_snapshot_restore() {
    local snapshot_path="${1:-}"
    if [[ -z "$snapshot_path" ]]; then
        log_error "Usage: comfy-cli-helper.sh snapshot-restore <file.json>"
        return 1
    fi

    if [[ ! -f "$snapshot_path" ]]; then
        log_error "Snapshot file not found: $snapshot_path"
        return 1
    fi

    check_comfy_cli || return 1

    log_info "Restoring snapshot from: $snapshot_path"
    comfy node restore-snapshot "$snapshot_path"
    log_success "Snapshot restored"
    return 0
}

cmd_workflow_deps() {
    local workflow="${1:-}"
    if [[ -z "$workflow" ]]; then
        log_error "Usage: comfy-cli-helper.sh workflow-deps <workflow.json>"
        return 1
    fi

    if [[ ! -f "$workflow" ]]; then
        log_error "Workflow file not found: $workflow"
        return 1
    fi

    check_comfy_cli || return 1

    log_info "Installing dependencies from workflow: $workflow"
    comfy node install-deps --workflow "$workflow"
    log_success "Workflow dependencies installed"
    return 0
}

cmd_help() {
    cat <<'EOF'
comfy-cli-helper.sh — ComfyUI management via comfy-cli

Usage:
  comfy-cli-helper.sh <command> [options]

Commands:
  status                          Check comfy-cli installation status
  install                         Install comfy-cli
  setup [--path <dir>]            Install ComfyUI
  launch [--port N] [--listen IP] Launch ComfyUI server
  node-install <name>             Install a custom node
  node-list [filter]              List nodes (installed|all|enabled|disabled)
  model-download <url> [path]     Download a model
  model-list [path]               List downloaded models
  snapshot-save [--output file]   Save environment snapshot
  snapshot-restore <file>         Restore environment snapshot
  workflow-deps <workflow.json>   Install workflow dependencies
  help                            Show this help

Examples:
  comfy-cli-helper.sh install
  comfy-cli-helper.sh setup --path ~/comfyui
  comfy-cli-helper.sh launch --port 8188
  comfy-cli-helper.sh node-install ComfyUI-Manager
  comfy-cli-helper.sh model-download "https://example.com/model.safetensors" models/loras
  comfy-cli-helper.sh snapshot-save --output my-env.json
  comfy-cli-helper.sh workflow-deps my-workflow.json

Docs: https://docs.comfy.org/comfy-cli/getting-started
EOF
    return 0
}

##############################################################################
# Main
##############################################################################

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        status)           cmd_status "$@" ;;
        install)          cmd_install "$@" ;;
        setup)            cmd_setup "$@" ;;
        launch)           cmd_launch "$@" ;;
        node-install)     cmd_node_install "$@" ;;
        node-list)        cmd_node_list "$@" ;;
        model-download)   cmd_model_download "$@" ;;
        model-list)       cmd_model_list "$@" ;;
        snapshot-save)    cmd_snapshot_save "$@" ;;
        snapshot-restore) cmd_snapshot_restore "$@" ;;
        workflow-deps)    cmd_workflow_deps "$@" ;;
        help|--help|-h)   cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
