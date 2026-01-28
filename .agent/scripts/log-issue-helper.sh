#!/bin/bash
# =============================================================================
# aidevops Issue Logger Helper
# =============================================================================
# Gathers diagnostic information for issue reporting
# Usage: log-issue-helper.sh [diagnostics|check-auth|search "query"]

set -euo pipefail

# -----------------------------------------------------------------------------
# Diagnostic Information Gathering
# -----------------------------------------------------------------------------

get_aidevops_version() {
    # Check in order: deployed agents, legacy location, dev repo
    local version_file_agents="$HOME/.aidevops/agents/VERSION"
    local version_file_legacy="$HOME/.aidevops/VERSION"
    local version_file_dev="$HOME/Git/aidevops/VERSION"
    
    if [[ -f "$version_file_agents" ]]; then
        cat "$version_file_agents"
    elif [[ -f "$version_file_legacy" ]]; then
        cat "$version_file_legacy"
    elif [[ -f "$version_file_dev" ]]; then
        cat "$version_file_dev"
    else
        echo "unknown"
    fi
}

get_latest_version() {
    curl --proto '=https' -fsSL \
        "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" \
        2>/dev/null || echo "unknown"
}

detect_ai_assistant() {
    # Detect which AI coding assistant is running
    if [[ "${OPENCODE:-}" == "1" ]]; then
        echo "OpenCode"
    elif [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
        echo "Claude Code"
    elif [[ -n "${CURSOR_SESSION:-}" ]] || [[ "${TERM_PROGRAM:-}" == "cursor" ]]; then
        echo "Cursor"
    elif [[ -n "${WINDSURF_SESSION:-}" ]]; then
        echo "Windsurf"
    elif [[ -n "${CONTINUE_SESSION:-}" ]]; then
        echo "Continue"
    elif [[ -n "${AIDER_SESSION:-}" ]]; then
        echo "Aider"
    elif [[ -n "${AUGMENT_SESSION:-}" ]]; then
        echo "Augment"
    elif [[ -n "${COPILOT_SESSION:-}" ]]; then
        echo "GitHub Copilot"
    elif [[ -n "${CODY_SESSION:-}" ]]; then
        echo "Cody"
    elif [[ -n "${KILO_SESSION:-}" ]]; then
        echo "Kilo Code"
    else
        # Check parent process
        local parent
        parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
        case "$parent" in
            *opencode*) echo "OpenCode" ;;
            *claude*) echo "Claude Code" ;;
            *cursor*) echo "Cursor" ;;
            *aider*) echo "Aider" ;;
            *) echo "Unknown" ;;
        esac
    fi
}

get_install_method() {
    # Detect how aidevops was installed
    local aidevops_path
    aidevops_path=$(command -v aidevops 2>/dev/null || echo "")
    
    if [[ -z "$aidevops_path" ]]; then
        echo "not in PATH"
    elif [[ "$aidevops_path" == *"homebrew"* ]] || [[ "$aidevops_path" == "/opt/homebrew"* ]]; then
        echo "Homebrew"
    elif [[ "$aidevops_path" == *"node_modules"* ]] || [[ "$aidevops_path" == *"npm"* ]]; then
        echo "npm"
    elif [[ "$aidevops_path" == "$HOME/Git/aidevops"* ]]; then
        echo "source (Git clone)"
    else
        echo "unknown ($aidevops_path)"
    fi
}

get_git_context() {
    local repo branch toplevel
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$toplevel" ]]; then
        repo=$(basename "$toplevel")
        branch=$(git branch --show-current 2>/dev/null || echo "detached")
    else
        repo="none"
        branch="n/a"
    fi
    echo "$repo ($branch)"
}

gather_diagnostics() {
    local current_version latest_version ai_assistant install_method
    local os_info shell_info git_context
    
    current_version=$(get_aidevops_version)
    latest_version=$(get_latest_version)
    ai_assistant=$(detect_ai_assistant)
    install_method=$(get_install_method)
    git_context=$(get_git_context)
    
    # OS info
    if [[ "$(uname)" == "Darwin" ]]; then
        os_info="macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
    elif [[ "$(uname)" == "Linux" ]]; then
        # Use || true to prevent pipefail from exiting on missing PRETTY_NAME
        os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || true)
        # Fallback if PRETTY_NAME not found or empty
        : "${os_info:=Linux $(uname -r)}"
    else
        os_info="$(uname -s) $(uname -r)"
    fi
    
    # Shell info
    shell_info="${SHELL:-unknown}"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        shell_info="zsh $ZSH_VERSION"
    elif [[ -n "${BASH_VERSION:-}" ]]; then
        shell_info="bash $BASH_VERSION"
    fi
    
    # Output in markdown format
    cat <<EOF
- **aidevops version**: $current_version
- **Latest version**: $latest_version
- **Install method**: $install_method
- **AI Assistant**: $ai_assistant
- **OS**: $os_info
- **Shell**: $shell_info
- **Working repo**: $git_context
- **gh CLI**: $(gh --version 2>/dev/null | head -1 || echo "not installed")
EOF
}

# -----------------------------------------------------------------------------
# GitHub CLI Helpers
# -----------------------------------------------------------------------------

check_gh_auth() {
    if ! command -v gh &>/dev/null; then
        echo "ERROR: GitHub CLI (gh) not installed"
        echo "Install with: brew install gh (macOS) or apt install gh (Linux)"
        return 1
    fi
    
    if ! gh auth status &>/dev/null; then
        echo "ERROR: GitHub CLI not authenticated"
        echo "Run: gh auth login"
        return 1
    fi
    
    echo "OK: GitHub CLI authenticated"
    return 0
}

search_issues() {
    local query="$1"
    gh issue list -R marcusquinn/aidevops \
        --state all \
        --search "$query" \
        --limit 10 \
        --json number,title,state,url \
        --jq '.[] | "#\(.number) [\(.state)] \(.title)\n   \(.url)"'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    local command="${1:-diagnostics}"
    
    case "$command" in
        diagnostics)
            gather_diagnostics
            ;;
        check-auth)
            check_gh_auth
            ;;
        search)
            local query="${2:-}"
            if [[ -z "$query" ]]; then
                echo "Usage: log-issue-helper.sh search \"query\""
                return 1
            fi
            search_issues "$query"
            ;;
        help|--help|-h)
            cat <<EOF
aidevops Issue Logger Helper

Usage: log-issue-helper.sh [command]

Commands:
  diagnostics    Gather system and aidevops diagnostic info (default)
  check-auth     Verify GitHub CLI authentication
  search "query" Search existing issues for duplicates
  help           Show this help message

Examples:
  log-issue-helper.sh diagnostics
  log-issue-helper.sh check-auth
  log-issue-helper.sh search "update check"
EOF
            ;;
        *)
            echo "Unknown command: $command"
            echo "Run: log-issue-helper.sh help"
            return 1
            ;;
    esac
}

main "$@"
