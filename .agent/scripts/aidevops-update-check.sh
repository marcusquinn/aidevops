#!/bin/bash
# =============================================================================
# aidevops Update Check - Clean version check for session start
# =============================================================================
# Outputs a single clean line for AI assistants to report

set -euo pipefail

INSTALL_DIR="$HOME/Git/aidevops"
VERSION_FILE="$INSTALL_DIR/VERSION"

get_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo "unknown"
    fi
    return 0
}

detect_app() {
    # Detect which AI coding assistant is running this script
    # Check environment variables set by various tools
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
    else
        # Fallback: check parent process name
        local parent
        parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
        case "$parent" in
            *opencode*) echo "OpenCode" ;;
            *claude*) echo "Claude Code" ;;
            *cursor*) echo "Cursor" ;;
            *) echo "unknown" ;;
        esac
    fi
    return 0
}

get_remote_version() {
    local version
    if command -v jq &>/dev/null; then
        # Use --proto =https to enforce HTTPS and prevent protocol downgrade
        version=$(curl --proto '=https' -fsSL "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n')
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    # Use --proto =https to enforce HTTPS and prevent protocol downgrade
    curl --proto '=https' -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null || echo "unknown"
}

check_ralph_upstream() {
    # Only check if we're in the aidevops repo
    local current_repo
    current_repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
    
    if [[ "$current_repo" == "aidevops" ]]; then
        local script_dir
        script_dir="$(dirname "$0")"
        if [[ -x "${script_dir}/ralph-upstream-check.sh" ]]; then
            "${script_dir}/ralph-upstream-check.sh" 2>/dev/null || true
        fi
    fi
    return 0
}

main() {
    local current remote app
    current=$(get_version)
    remote=$(get_remote_version)
    app=$(detect_app)
    
    # Build version string
    local version_str
    if [[ "$current" == "unknown" ]]; then
        version_str="aidevops not installed"
    elif [[ "$remote" == "unknown" ]]; then
        version_str="aidevops v$current (unable to check for updates)"
    elif [[ "$current" != "$remote" ]]; then
        # Special format for update available - parsed by AGENTS.md
        echo "UPDATE_AVAILABLE|$current|$remote|$app"
        check_ralph_upstream
        return 0
    else
        version_str="aidevops v$current"
    fi
    
    # Include app in output if detected
    if [[ "$app" != "unknown" ]]; then
        echo "$version_str running in $app"
    else
        echo "$version_str"
    fi
    
    # Check ralph upstream when in aidevops repo
    check_ralph_upstream
    
    return 0
}

main "$@"
