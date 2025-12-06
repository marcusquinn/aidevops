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
}

get_remote_version() {
    local version
    if command -v jq &>/dev/null; then
        version=$(curl -fsSL "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n')
        if [[ -n "$version" ]]; then
            echo "$version"
            return 0
        fi
    fi
    curl -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null || echo "unknown"
}

main() {
    local current remote
    current=$(get_version)
    remote=$(get_remote_version)
    
    if [[ "$current" == "unknown" ]]; then
        echo "aidevops not installed"
    elif [[ "$remote" == "unknown" ]]; then
        echo "aidevops v$current (unable to check for updates)"
    elif [[ "$current" != "$remote" ]]; then
        echo "UPDATE_AVAILABLE|$current|$remote"
    else
        echo "aidevops v$current"
    fi
}

main "$@"
