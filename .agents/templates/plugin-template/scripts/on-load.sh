#!/usr/bin/env bash
# =============================================================================
# Plugin Load Hook — {{PLUGIN_NAME}}
# =============================================================================
# Runs each time plugin agents are loaded into a session.
# Use this for session-specific setup: environment variables, path additions, etc.
#
# Environment variables available:
#   AIDEVOPS_PLUGIN_NAMESPACE  Plugin namespace
#   AIDEVOPS_PLUGIN_DIR        Plugin directory path
#   AIDEVOPS_AGENTS_DIR        Root agents directory
#   AIDEVOPS_HOOK              "load"
# =============================================================================

set -euo pipefail

main() {
    # shellcheck disable=SC2034  # plugin_dir/namespace available for user's hook logic
    local plugin_dir="${AIDEVOPS_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    # shellcheck disable=SC2034
    local namespace="${AIDEVOPS_PLUGIN_NAMESPACE:-{{NAMESPACE}}}"

    # Example: add plugin scripts to PATH
    # local scripts_dir="$plugin_dir/scripts"
    # if [[ -d "$scripts_dir" ]] && [[ ":$PATH:" != *":$scripts_dir:"* ]]; then
    #     export PATH="$scripts_dir:$PATH"
    # fi

    return 0
}

main "$@"
