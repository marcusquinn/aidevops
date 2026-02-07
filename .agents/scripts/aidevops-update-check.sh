#!/usr/bin/env bash
# =============================================================================
# aidevops Update Check - Clean version check for session start
# =============================================================================
# Outputs a single clean line for AI assistants to report

set -euo pipefail

# VERSION file locations - check in order of preference:
# 1. Deployed agents directory (setup.sh copies here)
# 2. Legacy location (some older installs)
# 3. Source repo for developers
VERSION_FILE_AGENTS="$HOME/.aidevops/agents/VERSION"
VERSION_FILE_LEGACY="$HOME/.aidevops/VERSION"
VERSION_FILE_DEV="$HOME/Git/aidevops/VERSION"

get_version() {
    # Use -r to check readability, not just existence (avoids cat failure under set -e)
    if [[ -r "$VERSION_FILE_AGENTS" ]]; then
        cat "$VERSION_FILE_AGENTS"
    elif [[ -r "$VERSION_FILE_LEGACY" ]]; then
        cat "$VERSION_FILE_LEGACY"
    elif [[ -r "$VERSION_FILE_DEV" ]]; then
        cat "$VERSION_FILE_DEV"
    else
        echo "unknown"
    fi
    return 0
}

detect_app() {
    # Detect which AI coding assistant is running this script
    # Returns: "AppName|version" or "AppName" or "unknown"
    local app_name="" app_version=""
    
    # Check environment variables set by various tools
    if [[ "${OPENCODE:-}" == "1" ]]; then
        app_name="OpenCode"
        # OpenCode doesn't have --version flag, check package.json
        app_version=$(jq -r '.version // empty' ~/.bun/install/global/node_modules/opencode-ai/package.json 2>/dev/null || echo "")
    elif [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
        app_name="Claude Code"
        app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
    elif [[ -n "${CURSOR_SESSION:-}" ]] || [[ "${TERM_PROGRAM:-}" == "cursor" ]]; then
        app_name="Cursor"
    elif [[ -n "${WINDSURF_SESSION:-}" ]]; then
        app_name="Windsurf"
    elif [[ -n "${CONTINUE_SESSION:-}" ]]; then
        app_name="Continue"
    elif [[ -n "${AIDER_SESSION:-}" ]]; then
        app_name="Aider"
        app_version=$(aider --version 2>/dev/null | head -1 || echo "")
    elif [[ -n "${FACTORY_DROID:-}" ]]; then
        app_name="Factory Droid"
    elif [[ -n "${AUGMENT_SESSION:-}" ]]; then
        app_name="Augment"
    elif [[ -n "${COPILOT_SESSION:-}" ]]; then
        app_name="GitHub Copilot"
    elif [[ -n "${CODY_SESSION:-}" ]]; then
        app_name="Cody"
    elif [[ -n "${KILO_SESSION:-}" ]]; then
        app_name="Kilo Code"
    elif [[ -n "${WARP_SESSION:-}" ]]; then
        app_name="Warp"
    else
        # Fallback: check parent process name
        local parent
        parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
        case "$parent" in
            *opencode*)
                app_name="OpenCode"
                app_version=$(jq -r '.version // empty' ~/.bun/install/global/node_modules/opencode-ai/package.json 2>/dev/null || echo "")
                ;;
            *claude*)
                app_name="Claude Code"
                app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
                ;;
            *cursor*) app_name="Cursor" ;;
            *aider*)
                app_name="Aider"
                app_version=$(aider --version 2>/dev/null | head -1 || echo "")
                ;;
            *) app_name="unknown" ;;
        esac
    fi
    
    # Return with version if available
    if [[ -n "$app_version" && "$app_version" != "unknown" ]]; then
        echo "${app_name}|${app_version}"
    else
        echo "$app_name"
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

get_git_context() {
    # Get current repo and branch for context
    local repo branch
    repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
    branch=$(git branch --show-current 2>/dev/null || echo "")
    
    if [[ -n "$repo" && -n "$branch" ]]; then
        echo "${repo}/${branch}"
    elif [[ -n "$repo" ]]; then
        echo "$repo"
    else
        echo ""
    fi
    return 0
}

main() {
    local current remote app_info app_name app_version git_context
    current=$(get_version)
    remote=$(get_remote_version)
    app_info=$(detect_app)
    git_context=$(get_git_context)
    
    # Parse app name and version
    if [[ "$app_info" == *"|"* ]]; then
        app_name="${app_info%%|*}"
        app_version="${app_info##*|}"
    else
        app_name="$app_info"
        app_version=""
    fi
    
    # Build version string
    local version_str
    if [[ "$current" == "unknown" ]]; then
        version_str="aidevops not installed"
    elif [[ "$remote" == "unknown" ]]; then
        version_str="aidevops v$current (unable to check for updates)"
    elif [[ "$current" != "$remote" ]]; then
        # Special format for update available - parsed by AGENTS.md
        echo "UPDATE_AVAILABLE|$current|$remote|$app_name"
        check_ralph_upstream
        return 0
    else
        version_str="aidevops v$current"
    fi
    
    # Build app string with version if available
    local app_str=""
    if [[ "$app_name" != "unknown" ]]; then
        if [[ -n "$app_version" ]]; then
            app_str="$app_name v$app_version"
        else
            app_str="$app_name"
        fi
    fi
    
    # Build final output
    local output="$version_str"
    if [[ -n "$app_str" ]]; then
        output="$output running in $app_str"
    fi
    if [[ -n "$git_context" ]]; then
        output="$output | $git_context"
    fi
    
    echo "$output"
    
    # Output runtime context hint for the AI model
    local runtime_hint=""
    case "$app_name" in
        OpenCode)
            runtime_hint="You are running in OpenCode. Global config: ~/.config/opencode/opencode.json"
            ;;
        "Claude Code")
            runtime_hint="You are running in Claude Code. Global config: ~/.config/Claude/Claude.json"
            ;;
    esac
    if [[ -n "$runtime_hint" ]]; then
        echo "$runtime_hint"
    fi
    
    # Cache output for agents without Bash (e.g., Plan+)
    local cache_dir="$HOME/.aidevops/cache"
    mkdir -p "$cache_dir"
    if [[ -n "$runtime_hint" ]]; then
        printf '%s\n%s\n' "$output" "$runtime_hint" > "$cache_dir/session-greeting.txt"
    else
        echo "$output" > "$cache_dir/session-greeting.txt"
    fi
    
    # Check ralph upstream when in aidevops repo
    check_ralph_upstream
    
    return 0
}

main "$@"
