#!/usr/bin/env bash
# shellcheck disable=SC2329
# terminal-title-setup.sh - Install shell integration for terminal title sync
# Part of aidevops framework: https://aidevops.sh
#
# Configures shell to sync terminal tab titles with git repo/branch.
# Supports: Zsh (with/without Oh-My-Zsh), Bash, Fish
#
# Usage:
#   terminal-title-setup.sh [command]
#
# Commands:
#   install    Install shell integration (default)
#   uninstall  Remove shell integration
#   status     Check current installation status
#   help       Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; return 0; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; return 0; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; return 0; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; return 0; }

# Marker comments for our integration
MARKER_START="# >>> aidevops terminal-title integration >>>"
MARKER_END="# <<< aidevops terminal-title integration <<<"

# =============================================================================
# Shell Detection
# =============================================================================

detect_shell() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")
    echo "$shell_name"
    return 0
}

has_oh_my_zsh() {
    [[ -d "$HOME/.oh-my-zsh" ]]
    return 0
}

has_oh_my_bash() {
    [[ -d "$HOME/.oh-my-bash" ]]
    return 0
}

has_starship() {
    command -v starship &>/dev/null
    return 0
}

has_powerlevel10k() {
    [[ -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]] || \
    [[ -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k" ]] || \
    grep -q "powerlevel10k" "$HOME/.zshrc" 2>/dev/null
    return 0
}

# =============================================================================
# Tabby Terminal Detection and Configuration
# =============================================================================

TABBY_CONFIG_FILE="$HOME/Library/Application Support/tabby/config.yaml"

has_tabby() {
    [[ -f "$TABBY_CONFIG_FILE" ]]
    return 0
}

# Check if Tabby has disableDynamicTitle: true (blocks OSC title changes)
tabby_has_dynamic_title_disabled() {
    if [[ ! -f "$TABBY_CONFIG_FILE" ]]; then
        return 1
    fi
    grep -q "disableDynamicTitle: true" "$TABBY_CONFIG_FILE" 2>/dev/null
}

# Count how many profiles have dynamic title disabled
tabby_count_disabled_profiles() {
    if [[ ! -f "$TABBY_CONFIG_FILE" ]]; then
        echo "0"
        return 0
    fi
    grep -c "disableDynamicTitle: true" "$TABBY_CONFIG_FILE" 2>/dev/null || echo "0"
    return 0
}

# Fix Tabby config to allow dynamic titles
tabby_enable_dynamic_titles() {
    if [[ ! -f "$TABBY_CONFIG_FILE" ]]; then
        log_error "Tabby config not found: $TABBY_CONFIG_FILE"
        return 1
    fi
    
    # Create backup
    cp "$TABBY_CONFIG_FILE" "${TABBY_CONFIG_FILE}.aidevops-backup"
    
    # Replace all instances (cross-platform: works on both macOS and Linux)
    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "${temp_file:-}"' RETURN
    sed 's/disableDynamicTitle: true/disableDynamicTitle: false/g' "$TABBY_CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$TABBY_CONFIG_FILE"
    
    local count
    count=$(grep -c "disableDynamicTitle: false" "$TABBY_CONFIG_FILE" 2>/dev/null || echo "0")
    log_success "Updated $count Tabby profile(s) to allow dynamic titles"
    log_info "Backup saved to: ${TABBY_CONFIG_FILE}.aidevops-backup"
    log_info "Restart Tabby for changes to take effect"
}

# Check and offer to fix Tabby configuration
check_and_fix_tabby() {
    if ! has_tabby; then
        return 0
    fi
    
    if ! tabby_has_dynamic_title_disabled; then
        log_success "Tabby is configured to allow dynamic tab titles"
        return 0
    fi
    
    local count
    count=$(tabby_count_disabled_profiles)
    
    echo ""
    log_warn "Tabby has 'disableDynamicTitle: true' in $count profile(s)"
    log_info "This prevents terminal title sync from working"
    echo ""
    read -r -p "Fix Tabby config to allow dynamic titles? [Y/n]: " fix_tabby
    
    if [[ "$fix_tabby" =~ ^[Yy]?$ ]]; then
        tabby_enable_dynamic_titles
    else
        log_info "Skipped Tabby config fix"
        log_info "You can fix manually: Settings → Profiles → Uncheck 'Disable dynamic title'"
    fi
}

# =============================================================================
# Integration Code Generators
# =============================================================================

generate_zsh_omz_integration() {
    cat << 'EOF'
# Sync terminal tab title with git repo/branch (works with Oh-My-Zsh)
# Falls back to directory when not in a git repo
_aidevops_terminal_title() {
    local title=""
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local repo branch
        repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
        branch=$(git branch --show-current 2>/dev/null)
        if [[ -n "$repo" ]] && [[ -n "$branch" ]]; then
            title="${repo}/${branch}"
        elif [[ -n "$repo" ]]; then
            title="$repo"
        fi
    fi
    if [[ -n "$title" ]]; then
        print -Pn "\e]0;${title}\a"
    fi
    return 0
}

# Override Oh-My-Zsh title variables to use our function
if [[ -n "${ZSH_VERSION:-}" ]] && [[ "${DISABLE_AUTO_TITLE:-}" != "true" ]]; then
    # Hook into precmd to set title after Oh-My-Zsh
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _aidevops_terminal_title
fi
EOF
}

generate_zsh_plain_integration() {
    cat << 'EOF'
# Sync terminal tab title with git repo/branch
_aidevops_terminal_title() {
    local title=""
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local repo branch
        repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
        branch=$(git branch --show-current 2>/dev/null)
        if [[ -n "$repo" ]] && [[ -n "$branch" ]]; then
            title="${repo}/${branch}"
        elif [[ -n "$repo" ]]; then
            title="$repo"
        fi
    fi
    if [[ -n "$title" ]]; then
        print -Pn "\e]0;${title}\a"
    fi
    return 0
}

# Add to precmd hooks
autoload -Uz add-zsh-hook
add-zsh-hook precmd _aidevops_terminal_title
EOF
}

generate_bash_integration() {
    cat << 'EOF'
# Sync terminal tab title with git repo/branch
_aidevops_terminal_title() {
    local title=""
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local repo branch
        repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
        branch=$(git branch --show-current 2>/dev/null)
        if [[ -n "$repo" ]] && [[ -n "$branch" ]]; then
            title="${repo}/${branch}"
        elif [[ -n "$repo" ]]; then
            title="$repo"
        fi
    fi
    if [[ -n "$title" ]]; then
        echo -ne "\033]0;${title}\007"
    fi
    return 0
}

# Add to PROMPT_COMMAND
if [[ -z "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="_aidevops_terminal_title"
else
    PROMPT_COMMAND="_aidevops_terminal_title; ${PROMPT_COMMAND}"
fi
EOF
}

generate_fish_integration() {
    cat << 'EOF'
# Sync terminal tab title with git repo/branch
function _aidevops_terminal_title --on-event fish_prompt
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1
        set -l repo (basename (git rev-parse --show-toplevel 2>/dev/null))
        set -l branch (git branch --show-current 2>/dev/null)
        if test -n "$repo" -a -n "$branch"
            printf '\033]0;%s/%s\007' $repo $branch
        else if test -n "$repo"
            printf '\033]0;%s\007' $repo
        end
    end
end
EOF
    return 0
}

# =============================================================================
# Installation Functions
# =============================================================================

get_rc_file() {
    local shell_name="$1"
    case "$shell_name" in
        zsh)
            echo "$HOME/.zshrc"
            ;;
        bash)
            # Prefer .bashrc, fall back to .bash_profile
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.bash_profile"
            fi
            ;;
        fish)
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo ""
            ;;
    esac
    return 0
}

is_installed() {
    local rc_file="$1"
    [[ -f "$rc_file" ]] && grep -q "$MARKER_START" "$rc_file"
    return 0
}

remove_integration() {
    local rc_file="$1"
    
    if [[ ! -f "$rc_file" ]]; then
        return 0
    fi
    
    if ! grep -q "$MARKER_START" "$rc_file"; then
        return 0
    fi
    
    # Create backup
    cp "$rc_file" "${rc_file}.aidevops-backup"
    
    # Remove our integration block (cross-platform: works on both macOS and Linux)
    local temp_file
    temp_file=$(mktemp)
    trap 'rm -f "${temp_file:-}"' RETURN
    sed "/$MARKER_START/,/$MARKER_END/d" "$rc_file" > "$temp_file" && mv "$temp_file" "$rc_file"
    
    log_success "Removed integration from $rc_file (backup: ${rc_file}.aidevops-backup)"
}

install_integration() {
    local shell_name="$1"
    local rc_file="$2"
    local integration_code=""
    
    # Generate appropriate integration code
    case "$shell_name" in
        zsh)
            if has_oh_my_zsh; then
                log_info "Detected Oh-My-Zsh"
                integration_code=$(generate_zsh_omz_integration)
            else
                integration_code=$(generate_zsh_plain_integration)
            fi
            ;;
        bash)
            integration_code=$(generate_bash_integration)
            ;;
        fish)
            integration_code=$(generate_fish_integration)
            ;;
        *)
            log_error "Unsupported shell: $shell_name"
            return 1
            ;;
    esac
    
    # Ensure rc file exists
    if [[ ! -f "$rc_file" ]]; then
        mkdir -p "$(dirname "$rc_file")"
        touch "$rc_file"
    fi
    
    # Create backup
    cp "$rc_file" "${rc_file}.aidevops-backup"
    
    # Append integration
    {
        echo ""
        echo "$MARKER_START"
        echo "$integration_code"
        echo "$MARKER_END"
    } >> "$rc_file"
    
    log_success "Installed integration to $rc_file"
}

# =============================================================================
# Commands
# =============================================================================

cmd_install() {
    local shell_name
    shell_name=$(detect_shell)
    local rc_file
    rc_file=$(get_rc_file "$shell_name")
    
    if [[ -z "$rc_file" ]]; then
        log_error "Could not determine RC file for shell: $shell_name"
        return 1
    fi
    
    log_info "Detected shell: $shell_name"
    log_info "RC file: $rc_file"
    
    # Check for special configurations
    if [[ "$shell_name" == "zsh" ]]; then
        if has_oh_my_zsh; then
            log_info "Oh-My-Zsh detected - will integrate with existing title hooks"
        fi
        if has_powerlevel10k; then
            log_info "Powerlevel10k detected - integration should work alongside it"
        fi
    fi
    
    if has_starship; then
        log_info "Starship prompt detected - integration should work alongside it"
    fi
    
    # Remove existing integration if present
    if is_installed "$rc_file"; then
        log_info "Existing integration found, updating..."
        remove_integration "$rc_file"
    fi
    
    # Install new integration
    install_integration "$shell_name" "$rc_file"
    
    # Check and fix Tabby configuration if needed
    check_and_fix_tabby
    
    echo ""
    log_success "Terminal title integration installed!"
    echo ""
    echo "To activate, either:"
    echo "  1. Restart your terminal, or"
    echo "  2. Run: source $rc_file"
    echo ""
    echo "Your terminal tab will now show: repo/branch (e.g., aidevops/feature/xyz)"
}

cmd_uninstall() {
    local shell_name
    shell_name=$(detect_shell)
    local rc_file
    rc_file=$(get_rc_file "$shell_name")
    
    if [[ -z "$rc_file" ]]; then
        log_error "Could not determine RC file for shell: $shell_name"
        return 1
    fi
    
    if ! is_installed "$rc_file"; then
        log_info "No integration found in $rc_file"
        return 0
    fi
    
    remove_integration "$rc_file"
    
    echo ""
    log_success "Terminal title integration removed!"
    echo "Restart your terminal or run: source $rc_file"
}

cmd_status() {
    local shell_name
    shell_name=$(detect_shell)
    local rc_file
    rc_file=$(get_rc_file "$shell_name")
    
    echo "Shell: $shell_name"
    echo "RC file: $rc_file"
    echo ""
    
    if [[ "$shell_name" == "zsh" ]]; then
        echo "Oh-My-Zsh: $(has_oh_my_zsh && echo "yes" || echo "no")"
        echo "Powerlevel10k: $(has_powerlevel10k && echo "yes" || echo "no")"
    fi
    echo "Starship: $(has_starship && echo "yes" || echo "no")"
    
    # Tabby status
    if has_tabby; then
        echo ""
        echo "Tabby terminal: yes"
        if tabby_has_dynamic_title_disabled; then
            local count
            count=$(tabby_count_disabled_profiles)
            log_warn "Tabby has dynamic titles DISABLED in $count profile(s)"
            echo "  Run 'terminal-title-setup.sh install' to fix"
        else
            echo "Tabby dynamic titles: enabled"
        fi
    fi
    echo ""
    
    if [[ -n "$rc_file" ]] && is_installed "$rc_file"; then
        log_success "Terminal title integration is installed"
    else
        log_warn "Terminal title integration is NOT installed"
        echo "Run: terminal-title-setup.sh install"
    fi
    return 0
}

cmd_help() {
    cat << 'EOF'
terminal-title-setup.sh - Install shell integration for terminal title sync

USAGE:
    terminal-title-setup.sh [command]

COMMANDS:
    install      Install shell integration (default)
    uninstall    Remove shell integration
    status       Check current installation status
    help         Show this help message

SUPPORTED SHELLS:
    - Zsh (with or without Oh-My-Zsh, Powerlevel10k, Starship)
    - Bash (with or without Oh-My-Bash)
    - Fish

WHAT IT DOES:
    Adds a hook to your shell that updates the terminal tab title
    with the current git repository and branch name.

    Format: repo/branch (e.g., aidevops/feature/xyz)

    When not in a git repo, the title is not modified.

EXAMPLES:
    # Install integration
    terminal-title-setup.sh install

    # Check status
    terminal-title-setup.sh status

    # Remove integration
    terminal-title-setup.sh uninstall

EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-install}"
    
    case "$command" in
        install)
            cmd_install
            ;;
        uninstall)
            cmd_uninstall
            ;;
        status)
            cmd_status
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
    # Return status of the executed command
}

main "$@"
exit $?
