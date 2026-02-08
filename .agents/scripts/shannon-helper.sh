#!/usr/bin/env bash
# shellcheck disable=SC1091

# Shannon AI Pentester Helper Script
# Autonomous exploit-driven web application security testing
# Managed by AI DevOps Framework
#
# Usage: ./shannon-helper.sh [command] [options]
# Commands:
#   install               - Clone and set up Shannon
#   start <url> <repo>    - Start a pentest workflow
#   logs [workflow-id]     - Tail logs for a workflow
#   query <workflow-id>    - Query workflow progress
#   stop                   - Stop all Shannon containers
#   status                 - Check installation and Docker status
#   report [session-dir]   - Show the latest or specified report
#   help                   - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${script_dir}/shared-constants.sh"

readonly SHANNON_DIR="${SHANNON_DIR:-${HOME}/.local/share/shannon}"
readonly SHANNON_REPO="https://github.com/KeygraphHQ/shannon.git"

# Error Messages
readonly ERROR_DOCKER_NOT_RUNNING="Docker is not running or not installed"
readonly ERROR_SHANNON_NOT_INSTALLED="Shannon is not installed at $SHANNON_DIR"
readonly ERROR_URL_REQUIRED="Target URL is required"
readonly ERROR_REPO_REQUIRED="Repository path is required"
readonly ERROR_WORKFLOW_ID_REQUIRED="Workflow ID is required"
readonly ERROR_REPO_PATH_NOT_FOUND="Repository path does not exist"

# Success Messages
readonly SUCCESS_INSTALL_COMPLETE="Shannon installed successfully"
readonly SUCCESS_PENTEST_STARTED="Pentest workflow started"
readonly SUCCESS_CONTAINERS_STOPPED="Shannon containers stopped"

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

print_header() {
    local msg="$1"
    echo -e "${PURPLE}[SHANNON] $msg${NC}"
    return 0
}

print_info() {
    local msg="$1"
    echo -e "${CYAN}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECKING
# ------------------------------------------------------------------------------

check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        return 1
    fi
    return 0
}

check_docker_running() {
    if ! docker info &> /dev/null 2>&1; then
        return 1
    fi
    return 0
}

check_shannon_installed() {
    if [[ ! -d "$SHANNON_DIR" ]] || [[ ! -f "$SHANNON_DIR/shannon" ]]; then
        return 1
    fi
    return 0
}

check_api_key() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        return 0
    fi
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        return 0
    fi
    # Source credentials if available
    if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
        # shellcheck disable=SC1091
        source "${HOME}/.config/aidevops/credentials.sh"
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            return 0
        fi
    fi
    return 1
}

check_dependencies() {
    local has_error=false

    if ! check_docker_installed; then
        print_error "Docker is not installed"
        print_info "Install Docker: https://docs.docker.com/get-docker/"
        has_error=true
    elif ! check_docker_running; then
        print_error "$ERROR_DOCKER_NOT_RUNNING"
        print_info "Start Docker Desktop or the Docker daemon"
        has_error=true
    fi

    if ! check_shannon_installed; then
        print_error "$ERROR_SHANNON_NOT_INSTALLED"
        print_info "Run: ./shannon-helper.sh install"
        has_error=true
    fi

    if $has_error; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# INSTALLATION
# ------------------------------------------------------------------------------

install_shannon() {
    print_header "Installing Shannon AI Pentester"

    if ! check_docker_installed; then
        print_error "Docker is required but not installed"
        print_info "Install Docker: https://docs.docker.com/get-docker/"
        return 1
    fi

    if check_shannon_installed; then
        print_info "Shannon is already installed at $SHANNON_DIR"
        print_info "Updating to latest version..."
        if git -C "$SHANNON_DIR" pull --ff-only 2>&1; then
            print_success "Shannon updated successfully"
        else
            print_warning "Update failed - try removing and reinstalling"
            print_info "  rm -rf $SHANNON_DIR && ./shannon-helper.sh install"
        fi
        return 0
    fi

    print_info "Cloning Shannon from $SHANNON_REPO..."
    local parent_dir
    parent_dir="$(dirname "$SHANNON_DIR")"
    mkdir -p "$parent_dir"

    if git clone "$SHANNON_REPO" "$SHANNON_DIR" 2>&1; then
        chmod +x "$SHANNON_DIR/shannon"
        print_success "$SUCCESS_INSTALL_COMPLETE"
        print_info "Installed to: $SHANNON_DIR"
        print_info ""
        print_info "Next steps:"
        print_info "  1. Set your API key: aidevops secret set ANTHROPIC_API_KEY"
        print_info "  2. Run a pentest: ./shannon-helper.sh start <url> <repo-path>"
    else
        print_error "Failed to clone Shannon repository"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# PENTEST OPERATIONS
# ------------------------------------------------------------------------------

start_pentest() {
    local url="${1:-}"
    local repo="${2:-}"
    local config="${3:-}"
    local output="${4:-}"

    if [[ -z "$url" ]]; then
        print_error "$ERROR_URL_REQUIRED"
        print_info "Usage: ./shannon-helper.sh start <url> <repo-path> [config] [output-dir]"
        return 1
    fi

    if [[ -z "$repo" ]]; then
        print_error "$ERROR_REPO_REQUIRED"
        print_info "Usage: ./shannon-helper.sh start <url> <repo-path> [config] [output-dir]"
        return 1
    fi

    # Resolve repo to absolute path
    if [[ -d "$repo" ]]; then
        repo="$(cd "$repo" && pwd)"
    else
        print_error "$ERROR_REPO_PATH_NOT_FOUND: $repo"
        return 1
    fi

    if ! check_api_key; then
        print_error "No API key found (ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN)"
        print_info "Set your key: aidevops secret set ANTHROPIC_API_KEY"
        return 1
    fi

    print_header "Starting Shannon Pentest"
    print_info "Target: $url"
    print_info "Repository: $repo"
    if [[ -n "$config" ]]; then
        print_info "Config: $config"
    fi

    # Build Shannon command arguments
    local shannon_args="URL=$url REPO=$repo"
    if [[ -n "$config" ]]; then
        shannon_args="$shannon_args CONFIG=$config"
    fi
    if [[ -n "$output" ]]; then
        shannon_args="$shannon_args OUTPUT=$output"
    fi

    print_info "Running: ./shannon start $shannon_args"
    print_warning "This will actively exploit the target. Only use on staging/dev environments."
    print_info "Estimated time: 1-1.5 hours | Estimated cost: ~\$50 USD (Claude 4.5 Sonnet)"
    echo ""

    # Execute Shannon
    # shellcheck disable=SC2086
    if "$SHANNON_DIR/shannon" start $shannon_args 2>&1; then
        print_success "$SUCCESS_PENTEST_STARTED"
        print_info "Monitor progress: ./shannon-helper.sh logs"
        print_info "Temporal UI: http://localhost:8233"
    else
        print_error "Failed to start pentest workflow"
        return 1
    fi
    return 0
}

tail_logs() {
    local workflow_id="${1:-}"

    print_header "Shannon Workflow Logs"

    if [[ -n "$workflow_id" ]]; then
        "$SHANNON_DIR/shannon" logs "ID=$workflow_id" 2>&1
    else
        # Show latest logs from audit-logs directory
        local latest_dir
        latest_dir=$(find "$SHANNON_DIR/audit-logs" -maxdepth 1 -type d -name "*_*" 2>/dev/null | sort -r | head -1)
        if [[ -n "$latest_dir" ]] && [[ -f "$latest_dir/workflow.log" ]]; then
            print_info "Tailing latest workflow: $(basename "$latest_dir")"
            tail -f "$latest_dir/workflow.log"
        else
            print_warning "No workflow logs found"
            print_info "Start a pentest first: ./shannon-helper.sh start <url> <repo>"
        fi
    fi
    return 0
}

query_workflow() {
    local workflow_id="$1"

    if [[ -z "$workflow_id" ]]; then
        print_error "$ERROR_WORKFLOW_ID_REQUIRED"
        print_info "Usage: ./shannon-helper.sh query <workflow-id>"
        return 1
    fi

    print_header "Querying Workflow: $workflow_id"
    "$SHANNON_DIR/shannon" query "ID=$workflow_id" 2>&1
    return 0
}

stop_containers() {
    local clean="${1:-false}"

    print_header "Stopping Shannon Containers"

    if [[ "$clean" == "true" ]] || [[ "$clean" == "--clean" ]]; then
        print_warning "Removing all data including volumes..."
        "$SHANNON_DIR/shannon" stop "CLEAN=true" 2>&1
    else
        "$SHANNON_DIR/shannon" stop 2>&1
    fi

    print_success "$SUCCESS_CONTAINERS_STOPPED"
    return 0
}

# ------------------------------------------------------------------------------
# REPORTING
# ------------------------------------------------------------------------------

show_report() {
    local session_dir="${1:-}"

    print_header "Shannon Security Report"

    if [[ -n "$session_dir" ]]; then
        local report_file="$session_dir/deliverables/comprehensive_security_assessment_report.md"
        if [[ -f "$report_file" ]]; then
            cat "$report_file"
        else
            print_error "Report not found: $report_file"
            return 1
        fi
        return 0
    fi

    # Find latest report
    local latest_dir
    latest_dir=$(find "$SHANNON_DIR/audit-logs" -maxdepth 1 -type d -name "*_*" 2>/dev/null | sort -r | head -1)
    if [[ -z "$latest_dir" ]]; then
        print_warning "No reports found"
        print_info "Run a pentest first: ./shannon-helper.sh start <url> <repo>"
        return 1
    fi

    local report_file="$latest_dir/deliverables/comprehensive_security_assessment_report.md"
    if [[ -f "$report_file" ]]; then
        print_info "Latest report: $report_file"
        echo ""
        cat "$report_file"
    else
        print_warning "Report not yet generated for: $(basename "$latest_dir")"
        print_info "The pentest may still be running. Check: ./shannon-helper.sh logs"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# STATUS
# ------------------------------------------------------------------------------

show_status() {
    print_header "Shannon Status"

    # Installation
    echo ""
    echo "Installation:"
    if check_shannon_installed; then
        print_success "Shannon installed at $SHANNON_DIR"
        local version
        version=$(git -C "$SHANNON_DIR" describe --tags 2>/dev/null || git -C "$SHANNON_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        print_info "Version: $version"
    else
        print_error "Shannon not installed"
        print_info "Run: ./shannon-helper.sh install"
    fi

    # Docker
    echo ""
    echo "Docker:"
    if check_docker_installed; then
        print_success "Docker installed"
        if check_docker_running; then
            print_success "Docker daemon running"
            # Check if Shannon containers are running
            local running
            running=$(docker ps --filter "name=shannon" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$running" -gt 0 ]]; then
                print_info "Shannon containers running: $running"
                docker ps --filter "name=shannon" --format "  {{.Names}}: {{.Status}}" 2>/dev/null
            else
                print_info "No Shannon containers running"
            fi
        else
            print_error "$ERROR_DOCKER_NOT_RUNNING"
        fi
    else
        print_error "Docker not installed"
    fi

    # API Key
    echo ""
    echo "API Key:"
    if check_api_key; then
        print_success "API key configured"
    else
        print_warning "No API key found"
        print_info "Set your key: aidevops secret set ANTHROPIC_API_KEY"
    fi

    # Recent reports
    echo ""
    echo "Recent Reports:"
    if check_shannon_installed; then
        local reports
        reports=$(find "$SHANNON_DIR/audit-logs" -maxdepth 2 -name "comprehensive_security_assessment_report.md" 2>/dev/null | sort -r | head -5)
        if [[ -n "$reports" ]]; then
            echo "$reports" | while IFS= read -r report; do
                local dir
                dir=$(dirname "$(dirname "$report")")
                print_info "$(basename "$dir") - $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$report" 2>/dev/null || stat -c '%y' "$report" 2>/dev/null | cut -d. -f1)"
            done
        else
            print_info "No reports found"
        fi
    fi

    return 0
}

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------

show_help() {
    cat << 'EOF'
Shannon AI Pentester Helper Script
Usage: ./shannon-helper.sh [command] [options]

PENTEST OPERATIONS:
  start <url> <repo> [config] [output]  - Start a pentest workflow
  logs [workflow-id]                     - Tail logs (latest or specific workflow)
  query <workflow-id>                    - Query workflow progress
  stop [--clean]                         - Stop containers (--clean removes data)
  report [session-dir]                   - Show latest or specified report

INSTALLATION & STATUS:
  install                                - Clone and set up Shannon
  status                                 - Check installation and Docker status

GENERAL:
  help                                   - Show this help message

EXAMPLES:
  ./shannon-helper.sh install
  ./shannon-helper.sh status
  ./shannon-helper.sh start https://staging.example.com /path/to/repo
  ./shannon-helper.sh start https://staging.example.com /path/to/repo ./config.yaml
  ./shannon-helper.sh start http://host.docker.internal:3000 /path/to/repo
  ./shannon-helper.sh logs
  ./shannon-helper.sh logs shannon-1234567890
  ./shannon-helper.sh query shannon-1234567890
  ./shannon-helper.sh report
  ./shannon-helper.sh stop
  ./shannon-helper.sh stop --clean

VULNERABILITY COVERAGE:
  - Injection (SQL, command, NoSQL)
  - Cross-Site Scripting (XSS)
  - Server-Side Request Forgery (SSRF)
  - Broken Authentication & Authorization (IDOR, privilege escalation)

IMPORTANT:
  - NEVER run on production environments (Shannon actively exploits targets)
  - Requires written authorization for the target system
  - Estimated time: 1-1.5 hours per full run
  - Estimated cost: ~$50 USD (Claude 4.5 Sonnet)
  - Reports require human validation (LLM-generated)

ENVIRONMENT VARIABLES:
  ANTHROPIC_API_KEY           - Anthropic API key (recommended)
  CLAUDE_CODE_OAUTH_TOKEN     - Claude Code OAuth token (alternative)
  SHANNON_DIR                 - Installation directory (default: ~/.local/share/shannon)

For more information:
  - GitHub: https://github.com/KeygraphHQ/shannon
  - Website: https://keygraph.io
  - Discord: https://discord.gg/KAqzSHHpRt
EOF
    return 0
}

# ------------------------------------------------------------------------------
# MAIN COMMAND HANDLER
# ------------------------------------------------------------------------------

main() {
    local command="${1:-help}"
    shift || true

    # Commands that don't require Shannon to be installed
    case "$command" in
        "install")
            install_shannon
            return $?
            ;;
        "help"|"-h"|"--help")
            show_help
            return 0
            ;;
        "status")
            show_status
            return $?
            ;;
        *)
            # Other commands handled below after dependency check
            ;;
    esac

    # Check dependencies for other commands
    if ! check_dependencies; then
        return 1
    fi

    case "$command" in
        "start"|"run"|"pentest")
            start_pentest "$@"
            ;;
        "logs"|"log"|"tail")
            tail_logs "$@"
            ;;
        "query"|"progress")
            query_workflow "$@"
            ;;
        "stop"|"down")
            stop_containers "$@"
            ;;
        "report"|"results")
            show_report "$@"
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND: $command"
            print_info "Use './shannon-helper.sh help' for usage information"
            return 1
            ;;
    esac

    return $?
}

# Execute main function
main "$@"
