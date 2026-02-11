#!/usr/bin/env bash
# =============================================================================
# Plugin Unload Hook — {{PLUGIN_NAME}}
# =============================================================================
# Runs when the plugin is disabled or removed.
# Use this for cleanup: removing temp files, revoking registrations, etc.
#
# Environment variables available:
#   AIDEVOPS_PLUGIN_NAMESPACE  Plugin namespace
#   AIDEVOPS_PLUGIN_DIR        Plugin directory path
#   AIDEVOPS_AGENTS_DIR        Root agents directory
#   AIDEVOPS_HOOK              "unload"
# =============================================================================

set -euo pipefail

main() {
    # shellcheck disable=SC2034  # plugin_dir available for user's hook logic
    local plugin_dir="${AIDEVOPS_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local namespace="${AIDEVOPS_PLUGIN_NAMESPACE:-{{NAMESPACE}}}"

    echo "[${namespace}] Unload hook running..."

    # Example: clean up temp files
    # rm -rf "$HOME/.aidevops/.agent-workspace/tmp/${namespace}-*" 2>/dev/null || true

    echo "[${namespace}] Unload complete"
    return 0
}

main "$@"
