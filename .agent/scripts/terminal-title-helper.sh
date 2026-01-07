#!/usr/bin/env bash
# terminal-title-helper.sh - Terminal tab/window title integration for aidevops
# Part of aidevops framework: https://aidevops.sh
#
# Sets terminal tab titles using OSC escape sequences (works with most modern terminals)
# Supported: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, GNOME Terminal, etc.
#
# Usage:
#   terminal-title-helper.sh [command] [options]
#
# Commands:
#   rename [title]     Set tab title (defaults to repo/branch)
#   sync               Sync tab title with current git repo/branch
#   reset              Reset tab title to default
#   detect             Check terminal compatibility
#
# Examples:
#   terminal-title-helper.sh sync                    # Set title to "aidevops/feature/xyz"
#   terminal-title-helper.sh rename "My Project"    # Set custom title
#   terminal-title-helper.sh reset                   # Clear custom title
#
# Environment:
#   TERMINAL_TITLE_FORMAT    Format string: "repo/branch" (default), "branch", "repo"
#   TERMINAL_TITLE_ENABLED   Set to "false" to disable terminal title integration

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Configuration (support both old and new env var names for compatibility)
TERMINAL_TITLE_FORMAT="${TERMINAL_TITLE_FORMAT:-${TABBY_TAB_TITLE_FORMAT:-repo/branch}}"
TERMINAL_TITLE_ENABLED="${TERMINAL_TITLE_ENABLED:-${AIDEVOPS_TABBY_ENABLED:-true}}"

# =============================================================================
# Core Functions
# =============================================================================

# Set tab title using OSC escape sequence
# Works with most modern terminals: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, etc.
set_tab_title() {
    local title="$1"
    
    if [[ "$TERMINAL_TITLE_ENABLED" == "false" ]]; then
        return 0
    fi
    
    # OSC 0 sets both icon name and window title
    # OSC 2 sets window title only
    # Using OSC 0 for broader compatibility
    printf '\033]0;%s\007' "$title"
}

# Reset tab title to default (empty string triggers terminal default)
reset_tab_title() {
    # Send empty title to reset
    printf '\033]0;\007'
    log_success "Tab title reset to default"
}

# Detect terminal type and OSC compatibility
detect_terminal() {
    local term_program="${TERM_PROGRAM:-}"
    local term="${TERM:-}"
    
    # Check known terminals by TERM_PROGRAM
    case "$term_program" in
        "Tabby")
            echo "tabby"
            return 0
            ;;
        "iTerm.app")
            echo "iterm2"
            return 0
            ;;
        "Apple_Terminal")
            echo "apple-terminal"
            return 0
            ;;
        "vscode")
            echo "vscode"
            return 0
            ;;
        "WezTerm")
            echo "wezterm"
            return 0
            ;;
        "Hyper")
            echo "hyper"
            return 0
            ;;
    esac
    
    # Check by TERM variable for other terminals
    case "$term" in
        xterm*|rxvt*|screen*|tmux*|alacritty|kitty*)
            echo "compatible"
            return 0
            ;;
    esac
    
    # Check for Windows Terminal
    if [[ -n "${WT_SESSION:-}" ]]; then
        echo "windows-terminal"
        return 0
    fi
    
    # Check for Kitty
    if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
        echo "kitty"
        return 0
    fi
    
    # Fallback - if TERM is set and not dumb, likely compatible
    if [[ -n "$term" ]] && [[ "$term" != "dumb" ]]; then
        echo "compatible"
        return 0
    fi
    
    echo "unknown"
    return 1
}

# Get current git repository name
get_repo_name() {
    local repo_path
    repo_path=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    basename "$repo_path"
}

# Get current git branch name
get_branch_name() {
    git branch --show-current 2>/dev/null || echo ""
}

# Generate tab title based on format
generate_title() {
    local format="${1:-$TERMINAL_TITLE_FORMAT}"
    local repo_name branch_name
    
    repo_name=$(get_repo_name) || repo_name=""
    branch_name=$(get_branch_name) || branch_name=""
    
    case "$format" in
        "repo/branch")
            if [[ -n "$repo_name" ]] && [[ -n "$branch_name" ]]; then
                echo "${repo_name}/${branch_name}"
            elif [[ -n "$repo_name" ]]; then
                echo "$repo_name"
            elif [[ -n "$branch_name" ]]; then
                echo "$branch_name"
            else
                echo ""
            fi
            ;;
        "branch")
            echo "$branch_name"
            ;;
        "repo")
            echo "$repo_name"
            ;;
        "branch/repo")
            if [[ -n "$branch_name" ]] && [[ -n "$repo_name" ]]; then
                echo "${branch_name} (${repo_name})"
            elif [[ -n "$branch_name" ]]; then
                echo "$branch_name"
            elif [[ -n "$repo_name" ]]; then
                echo "$repo_name"
            else
                echo ""
            fi
            ;;
        *)
            # Custom format - use as-is
            echo "$format"
            ;;
    esac
}

# =============================================================================
# Commands
# =============================================================================

cmd_rename() {
    local title="${1:-}"
    
    if [[ -z "$title" ]]; then
        # Generate title from git context
        title=$(generate_title)
    fi
    
    if [[ -z "$title" ]]; then
        log_warn "No title provided and not in a git repository"
        return 1
    fi
    
    set_tab_title "$title"
    log_success "Tab title set to: $title"
}

cmd_sync() {
    local title
    title=$(generate_title)
    
    if [[ -z "$title" ]]; then
        log_warn "Not in a git repository - cannot sync tab title"
        return 1
    fi
    
    set_tab_title "$title"
    log_success "Tab synced: $title"
}

cmd_reset() {
    reset_tab_title
}

cmd_detect() {
    local terminal
    terminal=$(detect_terminal)
    local upper_terminal
    upper_terminal=$(echo "$terminal" | tr '[:lower:]-' '[:upper:]_')
    
    case "$terminal" in
        "tabby")
            log_success "Running in Tabby terminal (full OSC support)"
            ;;
        "iterm2")
            log_success "Running in iTerm2 (full OSC support)"
            ;;
        "windows-terminal")
            log_success "Running in Windows Terminal (full OSC support)"
            ;;
        "kitty")
            log_success "Running in Kitty terminal (full OSC support)"
            ;;
        "wezterm")
            log_success "Running in WezTerm (full OSC support)"
            ;;
        "vscode")
            log_success "Running in VS Code integrated terminal (OSC support)"
            ;;
        "apple-terminal")
            log_success "Running in Apple Terminal (basic OSC support)"
            ;;
        "hyper")
            log_success "Running in Hyper terminal (OSC support)"
            ;;
        "compatible")
            log_info "Running in OSC-compatible terminal: ${TERM:-unknown}"
            ;;
        *)
            log_warn "Unknown terminal - OSC sequences may not work"
            echo "$upper_terminal"
            return 1
            ;;
    esac
    
    echo "$upper_terminal"
}

cmd_help() {
    cat << 'EOF'
terminal-title-helper.sh - Terminal tab/window title integration for aidevops

Sets terminal tab titles using OSC escape sequences. Works with most modern terminals:
Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, GNOME Terminal, etc.

USAGE:
    terminal-title-helper.sh <command> [options]

COMMANDS:
    rename [title]     Set tab title (defaults to repo/branch if no title given)
    sync               Sync tab title with current git repo/branch
    reset              Reset tab title to terminal default
    detect             Check terminal type and OSC compatibility
    help               Show this help message

EXAMPLES:
    # Sync tab title with git context
    terminal-title-helper.sh sync

    # Set custom title
    terminal-title-helper.sh rename "My Project"

    # Check terminal compatibility
    terminal-title-helper.sh detect

ENVIRONMENT VARIABLES:
    TERMINAL_TITLE_FORMAT
        Format for auto-generated titles. Options:
        - "repo/branch" (default): "aidevops/feature/xyz"
        - "branch": "feature/xyz"
        - "repo": "aidevops"
        - "branch/repo": "feature/xyz (aidevops)"

    TERMINAL_TITLE_ENABLED
        Set to "false" to disable terminal title integration

SHELL INTEGRATION:
    Add to ~/.bashrc or ~/.zshrc for automatic sync on directory change:

    # Bash
    PROMPT_COMMAND='~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null'

    # Zsh
    precmd() { ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null }

    # Fish
    function fish_prompt
        ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null
        # ... rest of prompt
    end

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        rename)
            cmd_rename "$@"
            ;;
        sync)
            cmd_sync
            ;;
        reset)
            cmd_reset
            ;;
        detect)
            cmd_detect
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
